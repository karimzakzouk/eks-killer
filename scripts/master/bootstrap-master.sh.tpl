#!/usr/bin/env bash
# Rendered by Terraform (templatefile). This is EC2 userdata for the master.
# Runs on EVERY boot of a master-role instance: the very first one, AND any
# replacement master launched by handoff.sh's no-worker-available fallback.
set -x
exec > >(tee -a /var/log/eks-killer-userdata.log) 2>&1

# Stop background apt timers immediately on boot to avoid dpkg lock contention
systemctl stop apt-daily.timer apt-daily-upgrade.timer unattended-upgrades.service 2>/dev/null || true
killall apt apt-get 2>/dev/null || true

mkdir -p /opt/eks-killer

# Start lightweight Python receiver immediately at boot second 1
cat > /opt/eks-killer/pyreceiver.py <<'PYRECEIVER_EOF'
${pyreceiver_py}
PYRECEIVER_EOF
chmod +x /opt/eks-killer/pyreceiver.py
python3 /opt/eks-killer/pyreceiver.py ${handoff_port} /opt/eks-killer/incoming-bundle.tar > /var/log/pyreceiver.log 2>&1 &
PYRECEIVER_PID=$!

# Download and install AWS CLI v2 in background at boot second 1
(
  cli_arch="x86_64"
  [ "$(uname -m)" = "aarch64" ] && cli_arch="aarch64"
  curl -s "https://awscli.amazonaws.com/awscli-exe-linux-$${cli_arch}.zip" -o /tmp/awscliv2.zip
  python3 -c "
import zipfile, os
with zipfile.ZipFile('/tmp/awscliv2.zip') as z:
    for info in z.infolist():
        z.extract(info, '/tmp')
        mode = info.external_attr >> 16
        if mode:
            os.chmod('/tmp/' + info.filename, mode)
" 2>/dev/null || true
  chmod +x /tmp/aws/install 2>/dev/null || true
  /tmp/aws/install >/dev/null 2>&1 || true
  command -v aws >/dev/null 2>&1 || echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] WARNING: boot-second-1 aws cli install failed" | tee -a /var/log/eks-killer.log
  rm -rf /tmp/aws /tmp/awscliv2.zip
) >/dev/null 2>&1 &
AWS_INSTALL_PID=$!


cat > /opt/eks-killer/common.sh <<'COMMON_EOF'
${common_sh}
COMMON_EOF

cat > /opt/eks-killer/snapshot-loop.sh <<'SNAPSHOT_EOF'
${snapshot_loop_sh}
SNAPSHOT_EOF

cat > /opt/eks-killer/watcher-master.sh <<'WATCHERMASTER_EOF'
${watcher_master_sh}
WATCHERMASTER_EOF

cat > /opt/eks-killer/watcher-worker.sh <<'WATCHERWORKER_EOF'
${watcher_worker_sh}
WATCHERWORKER_EOF

cat > /opt/eks-killer/handoff.sh <<'HANDOFF_EOF'
${handoff_sh}
HANDOFF_EOF

cat > /opt/eks-killer/receiver.sh <<'RECEIVER_EOF'
${receiver_master_sh}
RECEIVER_EOF

cat > /etc/systemd/system/snapshot-loop.service <<'SYSTEMD_SNAPSHOT_EOF'
${systemd_snapshot_loop_service}
SYSTEMD_SNAPSHOT_EOF

cat > /etc/systemd/system/watcher-master.service <<'SYSTEMD_WMASTER_EOF'
${systemd_watcher_master_service}
SYSTEMD_WMASTER_EOF

cat > /etc/systemd/system/watcher-worker.service <<'SYSTEMD_WWORKER_EOF'
${systemd_watcher_worker_service}
SYSTEMD_WWORKER_EOF

cat > /etc/systemd/system/receiver.service <<'SYSTEMD_RECEIVER_EOF'
${systemd_receiver_service}
SYSTEMD_RECEIVER_EOF

cat > /etc/systemd/system/eip-lo.service <<'SYSTEMD_EIPLO_EOF'
${systemd_eip_lo_service}
SYSTEMD_EIPLO_EOF

chmod +x /opt/eks-killer/*.sh
sed -i "s/__HANDOFF_PORT__/${handoff_port}/g" /opt/eks-killer/handoff.sh /opt/eks-killer/receiver.sh
systemctl daemon-reload

source /opt/eks-killer/common.sh

install_k8s_packages "${kubernetes_version}" &
INSTALL_PID=$!

REGION="${aws_region}"
export AWS_DEFAULT_REGION="$REGION"
SELF_ID="$(self_instance_id)"

echo "${eip_allocation_id}" > /opt/eks-killer/eip-allocation-id

# ── BOOT MODE DECISION ────────────────────────────────────────────────────────
# EIP ownership is the sole signal. No SSM involved.
# Another live instance holds the EIP → REPLACEMENT (keep pyreceiver).
# EIP unowned or owned by self → FRESH INIT (kubeadm init).
# ─────────────────────────────────────────────────────────────────────────────

BOOT_MODE="unknown"

# ── BOOT MODE DECISION ────────────────────────────────────────────────────────
# 1. Primary signal: pyreceiver is listening on :7777. If a peer is failing over,
#    the incoming bundle will arrive at /opt/eks-killer/incoming-bundle.tar within ~15s.
# 2. While packages install in background, poll for bundle arrival.
# 3. Once packages + AWS CLI finish, if still unknown, query EIP ownership as ground truth.
# ─────────────────────────────────────────────────────────────────────────────

log "bootstrap-master: checking for incoming bundle while background install completes..."
for i in $(seq 1 40); do
  if [ -s /opt/eks-killer/incoming-bundle.tar ]; then
    log "bootstrap-master: incoming bundle detected from peer! Selecting REPLACEMENT path"
    BOOT_MODE="replacement"
    break
  fi
  if ! kill -0 "$INSTALL_PID" 2>/dev/null; then
    break
  fi
  sleep 1
done

log "bootstrap-master: waiting for background package install & AWS CLI to complete"
wait "$INSTALL_PID" || log "bootstrap-master: WARNING install_k8s_packages exited non-zero, continuing anyway"
install_etcdctl
install_awscli

if [ "$BOOT_MODE" = "unknown" ]; then
  if [ -s /opt/eks-killer/incoming-bundle.tar ]; then
    BOOT_MODE="replacement"
  else
    EIP_HOLDER="$(aws ec2 describe-addresses --region "$REGION" \
      --filters Name=tag:Name,Values=eks-killer-master-eip \
      --query 'Addresses[0].InstanceId' --output text 2>/dev/null || echo 'None')"
    [ "$EIP_HOLDER" = "None" ] && EIP_HOLDER=""

    if [ -n "$EIP_HOLDER" ] && [ "$EIP_HOLDER" != "$SELF_ID" ]; then
      HOLDER_STATE="$(aws ec2 describe-instances --region "$REGION" \
        --instance-ids "$EIP_HOLDER" \
        --query 'Reservations[0].Instances[0].State.Name' --output text 2>/dev/null || echo 'unknown')"
      if [ "$HOLDER_STATE" = "running" ] || [ "$HOLDER_STATE" = "pending" ]; then
        log "bootstrap-master: EIP held by live instance $EIP_HOLDER ($HOLDER_STATE) — waiting up to 25s for bundle..."
        for j in $(seq 1 25); do
          if [ -s /opt/eks-killer/incoming-bundle.tar ]; then
            BOOT_MODE="replacement"
            break
          fi
          sleep 1
        done
        [ "$BOOT_MODE" = "unknown" ] && BOOT_MODE="replacement"
      else
        log "bootstrap-master: EIP holder $EIP_HOLDER is $HOLDER_STATE, no live peer — FRESH INIT"
        BOOT_MODE="fresh"
      fi
    else
      log "bootstrap-master: EIP is free or held by self — FRESH INIT"
      BOOT_MODE="fresh"
    fi
  fi
fi

if [ "$BOOT_MODE" != "replacement" ]; then
  log "bootstrap-master: FRESH INIT path (Day-1 cluster bootstrap)"
  kill -9 "$PYRECEIVER_PID" 2>/dev/null || true

  aws ec2 associate-address --instance-id "$SELF_ID" \
    --allocation-id "${eip_allocation_id}" --allow-reassociation --region "$REGION" >/dev/null || \
    log "bootstrap-master: WARNING pre-init EIP association failed, will retry after init"

  systemctl enable --now eip-lo.service || true

  log "bootstrap-master: waiting for background image pre-pulls to finish"
  wait_for_image_pulls

  kubeadm init \
    --control-plane-endpoint="${eip_public_ip}:6443" \
    --pod-network-cidr="${pod_cidr}" \
    --upload-certs \
    --ignore-preflight-errors=Mem \
    >>/var/log/eks-killer.log 2>&1

  mkdir -p /root/.kube /home/ubuntu/.kube
  cp -f /etc/kubernetes/admin.conf /root/.kube/config
  cp -f /etc/kubernetes/admin.conf /home/ubuntu/.kube/config
  chown -R ubuntu:ubuntu /home/ubuntu/.kube

  kubectl --kubeconfig=/etc/kubernetes/admin.conf apply -f \
    https://raw.githubusercontent.com/projectcalico/calico/v3.28.0/manifests/calico.yaml \
    >>/var/log/eks-killer.log 2>&1 || log "bootstrap-master: WARNING calico apply failed, retry manually"

  JOIN_CMD="$(kubeadm token create --print-join-command --ttl 0 2>>/var/log/eks-killer.log) --node-labels=role=worker --ignore-preflight-errors=Mem"

  # Start a lightweight HTTP metadata server so workers can discover the join
  # command and admin.conf without SSM. Port 7778, internal VPC only.
  python3 -c "
import http.server, base64, os, threading

JOIN = open('/opt/eks-killer/join-command','w')
JOIN.write('$${JOIN_CMD}')
JOIN.close()
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

s = http.server.HTTPServer(('0.0.0.0', 7778), H)
s.serve_forever()
" >> /var/log/eks-killer.log 2>&1 &
  echo $! > /opt/eks-killer/metadata-server.pid
  log "bootstrap-master: metadata server started on :7778 (join-command + admin-conf for workers)"

  aws ec2 associate-address --instance-id "$SELF_ID" \
    --allocation-id "${eip_allocation_id}" --allow-reassociation --region "$REGION" >/dev/null

  systemctl enable --now snapshot-loop.service
  systemctl enable --now watcher-master.service

  log "bootstrap-master: fresh cluster ready, EIP associated to $SELF_ID"
else
  log "bootstrap-master: REPLACEMENT MASTER path (Hot-Potato failover active)"

  # Ensure the incoming bundle is present (pyreceiver wrote it)
  bundle_deadline=$(( $(date +%s) + 30 ))
  while [ ! -s /opt/eks-killer/incoming-bundle.tar ] && [ "$(date +%s)" -lt "$bundle_deadline" ]; do
    sleep 1
  done

  if [ -s /opt/eks-killer/incoming-bundle.tar ]; then
    log "bootstrap-master: bundle received, beginning promotion"
    rm -rf /opt/eks-killer/restore
    mkdir -p /opt/eks-killer/restore
    tar -xf /opt/eks-killer/incoming-bundle.tar -C /opt/eks-killer/restore

    if [ -f "/opt/eks-killer/restore/k8s-images.tar" ]; then
      log "bootstrap-master: importing peer-streamed container images into containerd"
      pkill -9 -f "crictl pull" 2>/dev/null || true
      ctr -n k8s.io images import /opt/eks-killer/restore/k8s-images.tar >>/var/log/eks-killer.log 2>&1 || true
      rm -f /opt/eks-killer/restore/k8s-images.tar
    fi

    if [ -f "/opt/eks-killer/restore/handoff-bundle.tar.gz" ]; then
      tar -xzf /opt/eks-killer/restore/handoff-bundle.tar.gz -C /opt/eks-killer/restore
      rm -f /opt/eks-killer/restore/handoff-bundle.tar.gz
    fi

    # Validate the bundle BEFORE touching any local state: a truncated or
    # empty delivery must abort loudly, never brick this box.
    bundle_ok=1
    for req in etcd-snapshot.db origin-private-ip.txt origin-node-name.txt admin.conf scheduler.conf controller-manager.conf; do
      if [ ! -s "/opt/eks-killer/restore/$req" ]; then
        log "bootstrap-master: FATAL bundle missing or empty: $req, refusing to touch local state"
        bundle_ok=0
      fi
    done
    if [ ! -d /opt/eks-killer/restore/pki ] || [ ! -d /opt/eks-killer/restore/manifests ]; then
      log "bootstrap-master: FATAL bundle missing pki/ or manifests/, refusing to touch local state"
      bundle_ok=0
    fi
    if [ "$bundle_ok" -eq 0 ]; then
      log "bootstrap-master: aborting replacement promotion, instance will idle for inspection."
      exit 1
    fi

    OLD_IP="$(cat /opt/eks-killer/restore/origin-private-ip.txt)"
    NEW_IP="$(self_private_ip)"
    NODE_NAME="$(hostname)"

    log "bootstrap-master: rewriting manifests $${OLD_IP} -> $${NEW_IP}"

    rm -rf /var/lib/etcd-restored
    ETCDCTL_API=3 etcdctl snapshot restore /opt/eks-killer/restore/etcd-snapshot.db \
      --data-dir=/var/lib/etcd-restored \
      --name="$${NODE_NAME}" \
      --initial-cluster="$${NODE_NAME}=https://$${NEW_IP}:2380" \
      --initial-advertise-peer-urls="https://$${NEW_IP}:2380" \
      >>/var/log/eks-killer.log 2>&1

    systemctl stop kubelet || true
    rm -rf /var/lib/etcd
    mv /var/lib/etcd-restored /var/lib/etcd

    rm -rf /etc/kubernetes/pki /etc/kubernetes/manifests
    mkdir -p /etc/kubernetes/manifests /etc/kubernetes/pki /var/lib/kubelet
    cp -a /opt/eks-killer/restore/pki/. /etc/kubernetes/pki/
    cp -a /opt/eks-killer/restore/manifests/. /etc/kubernetes/manifests/
    cp /opt/eks-killer/restore/admin.conf /etc/kubernetes/admin.conf
    cp /opt/eks-killer/restore/scheduler.conf /etc/kubernetes/scheduler.conf
    cp /opt/eks-killer/restore/controller-manager.conf /etc/kubernetes/controller-manager.conf
    cp /opt/eks-killer/restore/admin.conf /etc/kubernetes/kubelet.conf

    if [ -d /opt/eks-killer/restore/var-lib-kubelet ]; then
      cp -a /opt/eks-killer/restore/var-lib-kubelet/. /var/lib/kubelet/
    fi
    if [ ! -f /var/lib/kubelet/config.yaml ]; then
      log "bootstrap-master: no kubelet config in bundle, generating via kubeadm"
      kubeadm init phase kubelet-start >/dev/null 2>&1 || true
    fi

    sed -i "s/$${OLD_IP}/$${NEW_IP}/g" /etc/kubernetes/manifests/etcd.yaml
    sed -i "s/$${OLD_IP}/$${NEW_IP}/g" /etc/kubernetes/manifests/kube-apiserver.yaml
    sed -i "s|https://$${NEW_IP}:6443|https://${eip_public_ip}:6443|g" /etc/kubernetes/controller-manager.conf
    sed -i "s|https://$${OLD_IP}:6443|https://${eip_public_ip}:6443|g" /etc/kubernetes/controller-manager.conf
    sed -i "s|https://$${NEW_IP}:6443|https://${eip_public_ip}:6443|g" /etc/kubernetes/scheduler.conf
    sed -i "s|https://$${OLD_IP}:6443|https://${eip_public_ip}:6443|g" /etc/kubernetes/scheduler.conf

    # Bind EIP to lo
    ip addr add "${eip_public_ip}/32" dev lo 2>/dev/null || true
    systemctl enable --now eip-lo.service || true

    # Start containerd and kubelet immediately without waiting for redundant pulls
    systemctl restart containerd
    systemctl enable --now kubelet

    log "bootstrap-master: waiting for kube-apiserver /healthz to be ready"
    ready=0
    for i in $(seq 1 45); do
      if curl -kfsS https://127.0.0.1:6443/healthz >/dev/null 2>&1; then
        ready=1
        break
      fi
      sleep 1
    done

    if [ "$ready" -ne 1 ]; then
      log "bootstrap-master: FATAL apiserver never became healthy, refusing to promote"
      exit 1
    fi

    # Associate EIP to self now that apiserver is healthy
    aws ec2 associate-address --instance-id "$SELF_ID" \
      --allocation-id "${eip_allocation_id}" --allow-reassociation --region "$REGION" >/dev/null 2>&1 || true
    log "bootstrap-master: EIP ${eip_public_ip} successfully associated to $SELF_ID"


    ORIGIN_NODE_NAME="$(cat /opt/eks-killer/restore/origin-node-name.txt 2>/dev/null || echo '')"
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

    systemctl enable --now snapshot-loop.service
    systemctl enable --now watcher-master.service

    # Restart the HTTP metadata server with a fresh join token so workers
    # can discover and rejoin the promoted master without SSM.
    kill "$(cat /opt/eks-killer/metadata-server.pid 2>/dev/null)" 2>/dev/null || true
    NEW_JOIN_CMD="$(kubeadm token create --print-join-command --ttl 0 2>>/var/log/eks-killer.log) --node-labels=role=worker --ignore-preflight-errors=Mem"
    python3 -c "
import http.server, base64

open('/opt/eks-killer/join-command','w').write('$${NEW_JOIN_CMD}')
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

    log "bootstrap-master: PROMOTION COMPLETE! Replacement node $NODE_NAME ($SELF_ID) is active master"
  else
    log "bootstrap-master: FATAL no bundle arrived, aborting replacement promotion"
  fi
fi
