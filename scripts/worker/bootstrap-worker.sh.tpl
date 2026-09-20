#!/usr/bin/env bash
# Rendered by Terraform (templatefile). EC2 userdata for every worker.
# Installs kubelet/kubeadm/containerd, joins the cluster, and lays down
# the master-role scripts (in case this node is promoted during failover).
# The embedded scripts are kept byte-identical to bootstrap-master.sh.tpl -
# that file is the single source of truth; this file only swaps the boot
# flow (join instead of kubeadm init).
set -x
exec > >(tee -a /var/log/eks-killer-userdata.log) 2>&1

# Stop background apt timers immediately on boot to avoid dpkg lock contention
systemctl stop apt-daily.timer apt-daily-upgrade.timer unattended-upgrades.service 2>/dev/null || true
killall apt apt-get 2>/dev/null || true

mkdir -p /opt/eks-killer

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

cat > /opt/eks-killer/common-core.sh <<'COMMON_CORE_EOF'
${common_core_sh}
COMMON_CORE_EOF

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
${receiver_worker_sh}
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

chmod +x /opt/eks-killer/*.sh
sed -i "s/__HANDOFF_PORT__/${handoff_port}/g" /opt/eks-killer/handoff.sh /opt/eks-killer/receiver.sh
systemctl daemon-reload

source /opt/eks-killer/common-core.sh

install_k8s_packages "${kubernetes_version}"
install_etcdctl
install_awscli

REGION="${aws_region}"
export AWS_DEFAULT_REGION="$REGION"

log "bootstrap-worker: discovering master IP"
MASTER_IP=""
for i in $(seq 1 60); do
  MASTER_IP="$(aws ec2 describe-instances --region "$REGION" \
    --filters "Name=tag:Role,Values=master" "Name=instance-state-name,Values=running" \
    --query 'Reservations[0].Instances[0].PrivateIpAddress' --output text 2>/dev/null)"
  [ "$MASTER_IP" = "None" ] && MASTER_IP=""
  [ -n "$MASTER_IP" ] && break
  sleep 5
done

if [ -z "$MASTER_IP" ]; then
  log "bootstrap-worker: FATAL could not discover master IP"
  exit 1
fi

log "bootstrap-worker: master is $MASTER_IP, waiting for join command on port 7778"
JOIN_CMD=""
for i in $(seq 1 60); do
  JOIN_CMD="$(curl -sf --max-time 5 "http://$MASTER_IP:7778/join-command" 2>/dev/null)"
  if [ -n "$JOIN_CMD" ] && [ "$JOIN_CMD" != "None" ]; then
    break
  fi
  sleep 5
done

if [ -z "$JOIN_CMD" ] || [ "$JOIN_CMD" = "None" ]; then
  log "bootstrap-worker: FATAL never got a join command from master, giving up"
  exit 1
fi

eval "$JOIN_CMD --ignore-preflight-errors=Mem" >>/var/log/eks-killer.log 2>&1

log "bootstrap-worker: fetching admin.conf from master"
curl -sf --max-time 10 "http://$MASTER_IP:7778/admin-conf" | base64 -d > /opt/eks-killer/worker-kubeconfig

systemctl enable --now watcher-worker.service
systemctl enable --now receiver.service

log "bootstrap-worker: joined cluster, pyreceiver + receiver + watcher running"
