#!/usr/bin/env bash
# Runs as a long-lived service on every node that is eligible to become the
# new control plane: ordinary workers, and any freshly-launched replacement
# master instance. Sits listening on HANDOFF_PORT; on receiving a bundle it
# restores etcd + PKI locally, rewrites the two IP-specific manifests, and
# lets the kubelet that's already running pick up the new static pods.

set -uo pipefail
source /opt/eks-killer/common.sh

HANDOFF_PORT="__HANDOFF_PORT__"
INCOMING="/opt/eks-killer/incoming-bundle.tar.gz"
RESTORE_DIR="/opt/eks-killer/restore"
REGION="$(self_region)"
export AWS_DEFAULT_REGION="$REGION"

install_etcdctl

log "receiver: listening on port ${HANDOFF_PORT}"

while true; do
  rm -f "$INCOMING"
  nc -l -p "$HANDOFF_PORT" >"$INCOMING"

  if [ ! -s "$INCOMING" ]; then
    log "receiver: got an empty connection, ignoring"
    continue
  fi

  log "receiver: bundle received, beginning promotion"
  rm -rf "$RESTORE_DIR"
  mkdir -p "$RESTORE_DIR"
  tar -xzf "$INCOMING" -C "$RESTORE_DIR"

  # Check for peer-streamed container images and composite bundle
  if [ -f "${RESTORE_DIR}/k8s-images.tar" ]; then
    log "receiver: importing peer-streamed container images into containerd"
    ctr -n k8s.io images import "${RESTORE_DIR}/k8s-images.tar" >>/var/log/eks-killer.log 2>&1 || true
    rm -f "${RESTORE_DIR}/k8s-images.tar"
  fi

  if [ -f "${RESTORE_DIR}/handoff-bundle.tar.gz" ]; then
    tar -xzf "${RESTORE_DIR}/handoff-bundle.tar.gz" -C "$RESTORE_DIR"
    rm -f "${RESTORE_DIR}/handoff-bundle.tar.gz"
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
    echo "FAIL"
    continue
  fi

  # Acknowledge to the sender — nc_send requires "OK" or it waits 60s and fails.
  echo "OK"

  OLD_IP="$(cat "${RESTORE_DIR}/origin-private-ip.txt")"
  NEW_IP="$(self_private_ip)"
  NODE_NAME="$(hostname)"

  log "receiver: rewriting manifests ${OLD_IP} -> ${NEW_IP}"

  rm -rf /var/lib/etcd-restored
  ETCDCTL_API=3 etcdctl snapshot restore "${RESTORE_DIR}/etcd-snapshot.db" \
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
  cp -a "${RESTORE_DIR}/pki/." /etc/kubernetes/pki/
  cp -a "${RESTORE_DIR}/manifests/." /etc/kubernetes/manifests/
  cp "${RESTORE_DIR}/admin.conf" /etc/kubernetes/admin.conf
  cp "${RESTORE_DIR}/scheduler.conf" /etc/kubernetes/scheduler.conf
  cp "${RESTORE_DIR}/controller-manager.conf" /etc/kubernetes/controller-manager.conf

  # Discover master EIP and bind it locally: this box cannot hairpin to its own EIP,
  # and our kubelet/kubectl/controllers dial the control-plane endpoint (the EIP).
  # Doing this BEFORE starting kubelet ensures local dials to the EIP succeed.
  EIP_PUBLIC_IP="$(aws ec2 describe-addresses --region "$REGION" \
    --filters Name=tag:Name,Values=eks-killer-master-eip \
    --query 'Addresses[0].PublicIp' --output text 2>/dev/null)"
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

  # Restore kubelet credentials using embedded client certs from admin.conf
  cp "${RESTORE_DIR}/admin.conf" /etc/kubernetes/kubelet.conf

  if [ -d "${RESTORE_DIR}/var-lib-kubelet" ]; then
    cp -a "${RESTORE_DIR}/var-lib-kubelet/." /var/lib/kubelet/
  fi
  # If config.yaml is still missing, generate it with kubeadm
  if [ ! -f /var/lib/kubelet/config.yaml ]; then
    kubeadm init phase kubelet-start >/dev/null 2>&1 || true
  fi

  # Rewrite static pod manifests to this node's private IP
  sed -i "s/${OLD_IP}/${NEW_IP}/g" /etc/kubernetes/manifests/etcd.yaml
  sed -i "s/${OLD_IP}/${NEW_IP}/g" /etc/kubernetes/manifests/kube-apiserver.yaml

  # Rewrite controller-manager and scheduler to talk to EIP (valid SAN in apiserver.crt & bound to lo)
  TARGET_EP="${EIP_PUBLIC_IP:-$NEW_IP}"
  sed -i "s/${OLD_IP}/${TARGET_EP}/g" /etc/kubernetes/controller-manager.conf /etc/kubernetes/scheduler.conf

  mkdir -p /root/.kube
  cp /etc/kubernetes/admin.conf /root/.kube/config

  systemctl start kubelet

  log "receiver: waiting for apiserver to answer locally"
  READY=0
  for i in $(seq 1 40); do
    if curl -kfsS https://127.0.0.1:6443/healthz >/dev/null 2>&1; then
      READY=1
      break
    fi
    sleep 2
  done

  if [ "$READY" -ne 1 ]; then
    log "receiver: FATAL apiserver never became healthy, aborting"
    continue
  fi

  # Notify handoff/SSM immediately so EIP association completes without waiting for node reconciliation
  self_id="$(self_instance_id)"

  ORIGIN_NODE_NAME="$(cat "${RESTORE_DIR}/origin-node-name.txt" 2>/dev/null || echo '')"
  if [ -n "$ORIGIN_NODE_NAME" ] && [ "$ORIGIN_NODE_NAME" != "$NODE_NAME" ]; then
    KUBECONFIG=/etc/kubernetes/admin.conf kubectl delete node "$ORIGIN_NODE_NAME" \
      >>/var/log/eks-killer.log 2>&1 || true
    KUBECONFIG=/etc/kubernetes/admin.conf kubectl delete pods -A \
      --field-selector spec.nodeName="$ORIGIN_NODE_NAME" --force --grace-period=0 \
      >>/var/log/eks-killer.log 2>&1 || true
  fi

  KUBECONFIG=/etc/kubernetes/admin.conf kubectl label node "$NODE_NAME" \
    role- >>/var/log/eks-killer.log 2>&1 || true
  KUBECONFIG=/etc/kubernetes/admin.conf kubectl label node "$NODE_NAME" \
    node-role.kubernetes.io/control-plane= role=master --overwrite >>/var/log/eks-killer.log 2>&1 || true
  KUBECONFIG=/etc/kubernetes/admin.conf kubectl taint node "$NODE_NAME" \
    node-role.kubernetes.io/control-plane:NoSchedule- >>/var/log/eks-killer.log 2>&1 || true

  systemctl stop watcher-worker.service 2>/dev/null || true
  systemctl enable --now snapshot-loop.service
  systemctl enable --now watcher-master.service

  # Victim-explicit scale-in: kill the spare(s), never let the ASG choose.
  normalize_master_asg

  log "receiver: PROMOTION COMPLETE, this node ($self_id) is now the master"
done
