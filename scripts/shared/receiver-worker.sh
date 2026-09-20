#!/usr/bin/env bash
# Runs as a long-lived service on every worker (receiver.service). Waits for
# pyreceiver.py (started at boot second 1) to land a failover bundle in
# /opt/eks-killer/incoming-bundle.tar, then drives the same restore sequence
# as bootstrap-master.sh's replacement path: etcd restore, manifest rewrite,
# EIP loopback bind AND EIP association, then node relabel. Only a non-empty
# incoming bundle counts; empty port probes are ignored by pyreceiver.

set -uo pipefail
source /opt/eks-killer/common.sh

HANDOFF_PORT="__HANDOFF_PORT__"
INCOMING="/opt/eks-killer/incoming-bundle.tar"
RESTORE_DIR="/opt/eks-killer/restore"
REGION="$(self_region)"
export AWS_DEFAULT_REGION="$REGION"

install_etcdctl

log "receiver: waiting for handoff bundle via pyreceiver on port ${HANDOFF_PORT}"

while true; do
  # pyreceiver does an atomic os.replace(), so a non-empty file = a complete bundle.
  for i in $(seq 1 60); do
    [ -s "$INCOMING" ] && break
    sleep 2
  done
  [ -s "$INCOMING" ] || { log "receiver: no bundle within 120s, still listening"; continue; }

  log "receiver: bundle received, beginning promotion"
  rm -rf "$RESTORE_DIR"
  mkdir -p "$RESTORE_DIR"
  tar -xf "$INCOMING" -C "$RESTORE_DIR"

  # Peer-streamed container images + composite bundle (fresh-instance path)
  if [ -f "$RESTORE_DIR/k8s-images.tar" ]; then
    log "receiver: importing peer-streamed container images into containerd"
    pkill -9 -f "crictl pull" 2>/dev/null || true
    ctr -n k8s.io images import "$RESTORE_DIR/k8s-images.tar" >>/var/log/eks-killer.log 2>&1 || true
    rm -f "$RESTORE_DIR/k8s-images.tar"
  fi
  if [ -f "$RESTORE_DIR/handoff-bundle.tar.gz" ]; then
    tar -xzf "$RESTORE_DIR/handoff-bundle.tar.gz" -C "$RESTORE_DIR"
    rm -f "$RESTORE_DIR/handoff-bundle.tar.gz"
  fi

  # Validate the bundle BEFORE touching any local state: a truncated or
  # empty delivery must abort loudly, never brick this box.
  bundle_ok=1
  for req in etcd-snapshot.db origin-private-ip.txt origin-node-name.txt admin.conf scheduler.conf controller-manager.conf; do
    if [ ! -s "$RESTORE_DIR/$req" ]; then
      log "receiver: FATAL bundle missing or empty: $req, refusing to touch local state"
      bundle_ok=0
    fi
  done
  if [ ! -d "$RESTORE_DIR/pki" ] || [ ! -d "$RESTORE_DIR/manifests" ]; then
    log "receiver: FATAL bundle missing pki/ or manifests/, refusing to touch local state"
    bundle_ok=0
  fi
  if [ "$bundle_ok" -eq 0 ]; then
    log "receiver: aborting this attempt, still listening for a good bundle"
    continue
  fi

  OLD_IP="$(cat "$RESTORE_DIR/origin-private-ip.txt")"
  NEW_IP="$(self_private_ip)"
  NODE_NAME="$(hostname)"
  self_id="$(self_instance_id)"

  log "receiver: rewriting manifests ${OLD_IP} -> ${NEW_IP}"

  rm -rf /var/lib/etcd-restored
  ETCDCTL_API=3 etcdctl snapshot restore "$RESTORE_DIR/etcd-snapshot.db" \
    --data-dir=/var/lib/etcd-restored \
    --name="${NODE_NAME}" \
    --initial-cluster="${NODE_NAME}=https://${NEW_IP}:2380" \
    --initial-advertise-peer-urls="https://${NEW_IP}:2380" \
    >>/var/log/eks-killer.log 2>&1

  if [ $? -ne 0 ]; then
    log "receiver: FATAL etcd restore failed, aborting this attempt"
    continue
  fi

  systemctl stop kubelet || true
  rm -rf /var/lib/etcd
  mv /var/lib/etcd-restored /var/lib/etcd

  rm -rf /etc/kubernetes/pki /etc/kubernetes/manifests
  mkdir -p /etc/kubernetes/manifests /etc/kubernetes/pki /var/lib/kubelet
  cp -a "$RESTORE_DIR/pki/." /etc/kubernetes/pki/
  cp -a "$RESTORE_DIR/manifests/." /etc/kubernetes/manifests/
  cp "$RESTORE_DIR/admin.conf" /etc/kubernetes/admin.conf
  cp "$RESTORE_DIR/scheduler.conf" /etc/kubernetes/scheduler.conf
  cp "$RESTORE_DIR/controller-manager.conf" /etc/kubernetes/controller-manager.conf
  cp "$RESTORE_DIR/admin.conf" /etc/kubernetes/kubelet.conf

  if [ -d "$RESTORE_DIR/var-lib-kubelet" ]; then
    cp -a "$RESTORE_DIR/var-lib-kubelet/." /var/lib/kubelet/
  fi
  if [ ! -f /var/lib/kubelet/config.yaml ]; then
    log "receiver: no kubelet config in bundle, generating via kubeadm"
    kubeadm init phase kubelet-start >/dev/null 2>&1 || true
  fi

  sed -i "s/${OLD_IP}/${NEW_IP}/g" /etc/kubernetes/manifests/etcd.yaml
  sed -i "s/${OLD_IP}/${NEW_IP}/g" /etc/kubernetes/manifests/kube-apiserver.yaml

  # Discover master EIP by tag and bind it locally: this box cannot hairpin
  # to its own EIP, so kubelet/kubectl/controllers dial the EIP from lo.
  EIP_META="$(aws ec2 describe-addresses --region "$REGION" \
    --filters Name=tag:Name,Values=eks-killer-master-eip \
    --query 'Addresses[0].[PublicIp,AllocationId]' --output text 2>/dev/null)"
  EIP_PUBLIC_IP="$(echo "$EIP_META" | awk '{print $1}')"
  ALLOC_ID="$(echo "$EIP_META" | awk '{print $2}')"

  TARGET_EP="${EIP_PUBLIC_IP:-$NEW_IP}"
  sed -i "s|https://${NEW_IP}:6443|https://${TARGET_EP}:6443|g" /etc/kubernetes/controller-manager.conf
  sed -i "s|https://${OLD_IP}:6443|https://${TARGET_EP}:6443|g" /etc/kubernetes/controller-manager.conf
  sed -i "s|https://${NEW_IP}:6443|https://${TARGET_EP}:6443|g" /etc/kubernetes/scheduler.conf
  sed -i "s|https://${OLD_IP}:6443|https://${TARGET_EP}:6443|g" /etc/kubernetes/scheduler.conf

  if [ -n "$EIP_PUBLIC_IP" ] && [ "$EIP_PUBLIC_IP" != "None" ]; then
    ip addr add "${EIP_PUBLIC_IP}/32" dev lo 2>/dev/null || true
    cat > /etc/systemd/system/eip-lo.service <<EIPLO_EOF
[Unit]
Description=eks-killer bind master EIP to loopback (hairpin-free local API access)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=-/usr/sbin/ip addr add ${EIP_PUBLIC_IP}/32 dev lo

[Install]
WantedBy=multi-user.target
EIPLO_EOF
    systemctl daemon-reload
    systemctl enable eip-lo.service || true
    log "receiver: bound ${EIP_PUBLIC_IP} to lo"
  else
    log "receiver: WARNING could not discover master EIP, skipping lo bind"
  fi

  # Start containerd and kubelet immediately without waiting for redundant pulls
  systemctl restart containerd
  systemctl enable --now kubelet

  log "receiver: waiting for kube-apiserver /healthz to be ready"
  ready=0
  for i in $(seq 1 45); do
    if curl -kfsS https://127.0.0.1:6443/healthz >/dev/null 2>&1; then
      ready=1
      break
    fi
    sleep 1
  done

  if [ "$ready" -ne 1 ]; then
    log "receiver: FATAL apiserver never became healthy, refusing to promote"
    continue
  fi

  # THE fast-path critical step: this promoted worker now owns the EIP.
  # Without this, kubectl keeps pointing at the (terminated) old master.
  if [ -n "$ALLOC_ID" ] && [ "$ALLOC_ID" != "None" ]; then
    ASSOCIATED=0
    for i in $(seq 1 12); do
      if aws ec2 associate-address --region "$REGION" --instance-id "$self_id" \
        --allocation-id "$ALLOC_ID" --allow-reassociation >>/var/log/eks-killer.log 2>&1; then
        ASSOCIATED=1
        break
      fi
      sleep 5
    done
    if [ "$ASSOCIATED" -eq 1 ]; then
      log "receiver: EIP ${EIP_PUBLIC_IP} associated to $self_id"
    else
      log "receiver: FATAL could not associate EIP $ALLOC_ID to $self_id after 60s retries — EIP STUCK"
    fi
  else
    log "receiver: WARNING could not discover EIP allocation id, EIP not re-associated"
  fi

  ORIGIN_NODE_NAME="$(cat "$RESTORE_DIR/origin-node-name.txt" 2>/dev/null || echo '')"
  if [ -n "$ORIGIN_NODE_NAME" ] && [ "$ORIGIN_NODE_NAME" != "$NODE_NAME" ]; then
    KUBECONFIG=/etc/kubernetes/admin.conf kubectl delete node "$ORIGIN_NODE_NAME" \
      >>/var/log/eks-killer.log 2>&1 || true
    KUBECONFIG=/etc/kubernetes/admin.conf kubectl delete pods -A \
      --field-selector spec.nodeName="$ORIGIN_NODE_NAME" --force --grace-period=0 \
      >>/var/log/eks-killer.log 2>&1 || true
  fi

  mkdir -p /root/.kube /home/ubuntu/.kube
  cp -f /etc/kubernetes/admin.conf /root/.kube/config
  cp -f /etc/kubernetes/admin.conf /home/ubuntu/.kube/config
  chown -R ubuntu:ubuntu /home/ubuntu/.kube

  KUBECONFIG=/etc/kubernetes/admin.conf kubectl label node "$NODE_NAME" \
    role- >>/var/log/eks-killer.log 2>&1 || true
  KUBECONFIG=/etc/kubernetes/admin.conf kubectl label node "$NODE_NAME" \
    node-role.kubernetes.io/control-plane= role=master --overwrite >>/var/log/eks-killer.log 2>&1 || true
  KUBECONFIG=/etc/kubernetes/admin.conf kubectl taint node "$NODE_NAME" \
    node-role.kubernetes.io/control-plane:NoSchedule- >>/var/log/eks-killer.log 2>&1 || true

  systemctl stop watcher-worker.service 2>/dev/null || true
  systemctl enable --now snapshot-loop.service
  systemctl enable --now watcher-master.service

  # Restart the HTTP metadata server with a fresh join token so future
  # workers can discover and rejoin this promoted master without SSM.
  kill "$(cat /opt/eks-killer/metadata-server.pid 2>/dev/null)" 2>/dev/null || true
  NEW_JOIN_CMD="$(kubeadm token create --print-join-command --ttl 0 2>>/var/log/eks-killer.log) --node-labels=role=worker --ignore-preflight-errors=Mem"
  python3 -c "
import http.server, base64

open('/opt/eks-killer/join-command','w').write('${NEW_JOIN_CMD}')
ADMIN = base64.b64encode(open('/etc/kubernetes/admin.conf','rb').read()).decode()
open('/opt/eks-killer/admin-conf-b64','w').write(ADMIN)

class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, fmt, *a): pass
    def do_GET(self):
        if self.path == '/join-command':
            body = open('/opt/eks-killer/join-command','rb').read()
        elif self.path == '/admin-conf':
            body = open('/opt/eks-killer/admin-conf-b64','rb').read()
        else:
            self.send_response(404); self.end_headers(); return
        self.send_response(200); self.send_header('Content-Length', len(body)); self.end_headers()
        self.wfile.write(body)

http.server.HTTPServer(('0.0.0.0', 7778), H).serve_forever()
" >> /var/log/eks-killer.log 2>&1 &
  echo $! > /opt/eks-killer/metadata-server.pid

  # Victim-explicit scale-in: kill the spare(s), never let the ASG choose.
  normalize_master_asg

  # This node is now the control plane; stop watching for more bundles.
  systemctl disable --now receiver.service 2>/dev/null || true

  log "receiver: PROMOTION COMPLETE, $NODE_NAME ($self_id) is now the master"
  exit 0
done
