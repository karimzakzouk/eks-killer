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
cat > /opt/eks-killer/pyreceiver.py <<'EKSKILLER_EOF'
#!/usr/bin/env python3
import socket
import sys
import os

port = int(sys.argv[1]) if len(sys.argv) > 1 else 7777
out_file = sys.argv[2] if len(sys.argv) > 2 else "/opt/eks-killer/incoming-bundle.tar"

print(f"[pyreceiver] Listening on port {port} -> {out_file}", flush=True)

try:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        s.bind(('0.0.0.0', port))
        s.listen(5)
        # Accept loop: readiness probes (nc -z) open empty connections that
        # must be ignored. Only a non-empty transfer counts as the bundle;
        # anything else keeps us listening instead of exiting on a 0-byte file.
        while True:
            conn, addr = s.accept()
            print(f"[pyreceiver] Connection from {addr}", flush=True)
            total = 0
            try:
                with open(out_file + ".tmp", "wb") as f:
                    while True:
                        chunk = conn.recv(65536)
                        if not chunk:
                            break
                        f.write(chunk)
                        total += len(chunk)
            except Exception as e:
                print(f"[pyreceiver] Read error from {addr}: {e}, ignoring", flush=True)
                total = 0
            if total == 0:
                print(f"[pyreceiver] Empty connection from {addr} (port probe?), still listening", flush=True)
                try:
                    conn.close()
                except Exception:
                    pass
                try:
                    os.remove(out_file + ".tmp")
                except Exception:
                    pass
                continue
            os.replace(out_file + ".tmp", out_file)
            print(f"[pyreceiver] SUCCESS: Received {total} bytes into {out_file}", flush=True)
            try:
                conn.sendall(b"OK\n")
            except Exception:
                pass
            try:
                conn.close()
            except Exception:
                pass
            break
except Exception as e:
    print(f"[pyreceiver] ERROR: {e}", flush=True)
    sys.exit(1)
EKSKILLER_EOF
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


cat > /opt/eks-killer/common.sh <<'EKSKILLER_EOF'
#!/usr/bin/env bash
# Shared helpers - sourced by every other script. Not meant to be run directly.

log() {
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*" | tee -a /var/log/eks-killer.log >&2
}

imds_token() {
  curl -s -X PUT "http://169.254.169.254/latest/api/token" \
    -H "X-aws-ec2-metadata-token-ttl-seconds: 21600"
}

imds_get() {
  local path="$1"
  local token
  token="$(imds_token)"
  curl -s -H "X-aws-ec2-metadata-token: $${token}" "http://169.254.169.254/latest/meta-data/$${path}"
}

self_instance_id() { imds_get "instance-id"; }
self_private_ip() { imds_get "local-ipv4"; }
self_region() { imds_get "placement/region"; }

install_awscli() {
  if command -v aws >/dev/null 2>&1; then return; fi
  # Wait for the boot-second-1 background download to finish
  if [ -n "$${AWS_INSTALL_PID:-}" ]; then
    wait "$AWS_INSTALL_PID" 2>/dev/null || true
  fi
  if command -v aws >/dev/null 2>&1; then return; fi
  local cli_arch="x86_64"
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
  /tmp/aws/install --update >/dev/null 2>&1 || /tmp/aws/install >/dev/null 2>&1
  command -v aws >/dev/null 2>&1 || log "install_awscli: WARNING aws cli install failed"
  rm -rf /tmp/aws /tmp/awscliv2.zip
}

install_k8s_packages() {
  local k8s_version="$1"

  export DEBIAN_FRONTEND=noninteractive
  swapoff -a
  sed -i '/ swap / s/^/#/' /etc/fstab

  modprobe overlay
  modprobe br_netfilter
  cat <<EOF >/etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF
  cat <<EOF >/etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
  sysctl --system

  log "install_k8s_packages: installing core system packages via apt"
  systemctl stop apt-daily.timer apt-daily-upgrade.timer unattended-upgrades.service 2>/dev/null || true
  apt-get update -y -o Acquire::Languages=none
  apt-get install -y --no-install-recommends \
    -o Dpkg::Use-Pty=0 -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" \
    ca-certificates curl gnupg jq netcat-openbsd unzip containerd etcd-client iptables conntrack socat

  # containerd configuration
  mkdir -p /etc/containerd
  containerd config default | tee /etc/containerd/config.toml >/dev/null
  sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
  systemctl restart containerd
  systemctl enable containerd

  # crictl default configuration
  cat <<'EOF' >/etc/crictl.yaml
runtime-endpoint: unix:///run/containerd/containerd.sock
image-endpoint: unix:///run/containerd/containerd.sock
timeout: 10
debug: false
EOF

  local arch="amd64"
  case "$(uname -m)" in
    aarch64|arm64) arch="arm64" ;;
  esac

  local full_version="$k8s_version"
  if [[ "$k8s_version" =~ ^[0-9]+\.[0-9]+$ ]]; then
    full_version="$(curl -sSL "https://dl.k8s.io/release/stable-$${k8s_version}.txt" 2>/dev/null || echo "v$${k8s_version}.0")"
  fi
  [[ ! "$full_version" =~ ^v ]] && full_version="v$${full_version}"

  log "install_k8s_packages: downloading static k8s binaries ($${full_version}, $${arch}) in parallel"
  local k8s_bin_url="https://dl.k8s.io/release/$${full_version}/bin/linux/$${arch}"
  mkdir -p /usr/bin /opt/cni/bin /etc/systemd/system/kubelet.service.d

  local pids=""
  curl -sSL -o /usr/bin/kubelet "$${k8s_bin_url}/kubelet" & pids="$pids $!"
  curl -sSL -o /usr/bin/kubeadm "$${k8s_bin_url}/kubeadm" & pids="$pids $!"
  curl -sSL -o /usr/bin/kubectl "$${k8s_bin_url}/kubectl" & pids="$pids $!"
  (curl -sSL "https://github.com/containernetworking/plugins/releases/download/v1.5.0/cni-plugins-linux-$${arch}-v1.5.0.tgz" | tar -C /opt/cni/bin -xz) & pids="$pids $!"
  (curl -sSL "https://github.com/kubernetes-sigs/cri-tools/releases/download/v1.30.0/crictl-v1.30.0-linux-$${arch}.tar.gz" | tar -C /usr/bin -xz) & pids="$pids $!"
  install_awscli & pids="$pids $!"
  wait $pids

  chmod +x /usr/bin/kubelet /usr/bin/kubeadm /usr/bin/kubectl

  # Pre-pull every image the control plane will need while the network is
  # otherwise idle: overlaps image downloads with EIP/SSM setup and kubeadm
  # preflight instead of paying for them serially after kubelet starts.
  log "install_k8s_packages: pre-pulling control-plane images in background"
  {
    echo "registry.k8s.io/kube-proxy:$full_version"
    kubeadm config images list --kubernetes-version "$full_version" 2>/dev/null
    curl -sSL "https://raw.githubusercontent.com/projectcalico/calico/v3.28.0/manifests/calico.yaml" 2>/dev/null \
      | grep -o 'image: .*' | awk '{print $2}' | sort -u
  } | sort -u > /opt/eks-killer/prepull-images.txt
  : > /opt/eks-killer/prepull-pids.txt
  while read -r img; do
    [ -n "$img" ] || continue
    crictl pull "$img" >>/var/log/eks-killer.log 2>&1 &
    echo "$!" >> /opt/eks-killer/prepull-pids.txt
  done < /opt/eks-killer/prepull-images.txt

  cat <<'EOF' >/etc/systemd/system/kubelet.service
[Unit]
Description=kubelet: The Kubernetes Node Agent
Documentation=https://kubernetes.io/docs/home/
Wants=network-online.target
After=network-online.target

[Service]
ExecStart=/usr/bin/kubelet
Restart=always
StartLimitInterval=0
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

  cat <<'EOF' >/etc/systemd/system/kubelet.service.d/10-kubeadm.conf
[Service]
Environment="KUBELET_KUBECONFIG_ARGS=--bootstrap-kubeconfig=/etc/kubernetes/bootstrap-kubelet.conf --kubeconfig=/etc/kubernetes/kubelet.conf"
Environment="KUBELET_CONFIG_ARGS=--config=/var/lib/kubelet/config.yaml"
EnvironmentFile=-/var/lib/kubelet/kubeadm-flags.env
EnvironmentFile=-/etc/default/kubelet
ExecStart=
ExecStart=/usr/bin/kubelet $KUBELET_KUBECONFIG_ARGS $KUBELET_CONFIG_ARGS $KUBELET_KUBEADM_ARGS $KUBELET_EXTRA_ARGS
EOF

  systemctl daemon-reload
  systemctl enable kubelet
}

install_etcdctl() {
  if command -v etcdctl >/dev/null 2>&1; then return; fi
  apt-get install -y etcd-client
}


normalize_master_asg() {
  # Self-preservation scale-in: terminate every OTHER master-ASG member with
  # decrement instead of set-desired-capacity alone, which lets the ASG pick
  # the victim (it has picked the freshly promoted master before).
  local grp inst me
  me="$(self_instance_id)"
  grp="$(aws autoscaling describe-auto-scaling-groups \
    --query "AutoScalingGroups[?contains(AutoScalingGroupName, 'eks-killer-master')].AutoScalingGroupName | [0]" \
    --output text 2>/dev/null | tr -d ' \t\r\n')"
  if [ -z "$grp" ] || [ "$grp" = "None" ]; then
    return 0
  fi
  for inst in $(aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names "$grp" \
    --query "AutoScalingGroups[0].Instances[].InstanceId" --output text 2>/dev/null); do
    if [ -n "$inst" ] && [ "$inst" != "None" ] && [ "$inst" != "$me" ]; then
      log "normalize_master_asg: removing spare $inst, keeping self $me"
      aws autoscaling terminate-instance-in-auto-scaling-group --instance-id "$inst" \
        --should-decrement-desired-capacity >/dev/null 2>&1 || true
    fi
  done
  aws autoscaling set-desired-capacity --auto-scaling-group-name "$grp" --desired-capacity 1 >/dev/null 2>&1 || true
}

wait_for_image_pulls() {
  # Block until background image pre-pulls finish using process check (subshell safe)
  local deadline=$(( $(date +%s) + 40 ))
  while pgrep -f "crictl pull" >/dev/null 2>&1 && [ "$(date +%s)" -lt "$deadline" ]; do
    sleep 1
  done
}

ssm_put() {
  local name="$1" value="$2" region="$3" tier="$${4:-Standard}"
  aws ssm put-parameter --region "$region" --name "$name" --type "SecureString" --tier "$tier" --value "$value" --overwrite >/dev/null
}

ssm_get() {
  local name="$1" region="$2"
  aws ssm get-parameter --region "$region" --name "$name" --with-decryption --query 'Parameter.Value' --output text 2>/dev/null
}
EKSKILLER_EOF

cat > /opt/eks-killer/snapshot-loop.sh <<'EKSKILLER_EOF'
#!/usr/bin/env bash
# Runs forever on the master. Every SNAPSHOT_INTERVAL seconds, takes a fresh
# etcd snapshot and re-tars the PKI/manifest bundle needed to reconstruct
# this control plane elsewhere. Kept purely local - no S3, no network calls.

set -uo pipefail
source /opt/eks-killer/common.sh

SNAPSHOT_INTERVAL="$${SNAPSHOT_INTERVAL:-12}"
BUNDLE_DIR="/opt/eks-killer/bundle"
STAGING_DIR="/opt/eks-killer/bundle.staging"

mkdir -p "$BUNDLE_DIR" "$STAGING_DIR"

while true; do
  ETCDCTL_API=3 etcdctl snapshot save "$${STAGING_DIR}/etcd-snapshot.db" \
    --endpoints=https://127.0.0.1:2379 \
    --cacert=/etc/kubernetes/pki/etcd/ca.crt \
    --cert=/etc/kubernetes/pki/etcd/server.crt \
    --key=/etc/kubernetes/pki/etcd/server.key \
    >>/var/log/eks-killer.log 2>&1

  if [ $? -eq 0 ]; then
    cp -a /etc/kubernetes/pki "$${STAGING_DIR}/pki"
    cp -a /etc/kubernetes/manifests "$${STAGING_DIR}/manifests"
    cp /etc/kubernetes/admin.conf "$${STAGING_DIR}/admin.conf"
    cp /etc/kubernetes/scheduler.conf "$${STAGING_DIR}/scheduler.conf"
    cp /etc/kubernetes/controller-manager.conf "$${STAGING_DIR}/controller-manager.conf"
    [ -f /etc/kubernetes/kubelet.conf ] && cp /etc/kubernetes/kubelet.conf "$${STAGING_DIR}/kubelet.conf"
    if [ -d /var/lib/kubelet ]; then
      mkdir -p "$${STAGING_DIR}/var-lib-kubelet"
      [ -f /var/lib/kubelet/config.yaml ] && cp /var/lib/kubelet/config.yaml "$${STAGING_DIR}/var-lib-kubelet/config.yaml"
      [ -f /var/lib/kubelet/kubeadm-flags.env ] && cp /var/lib/kubelet/kubeadm-flags.env "$${STAGING_DIR}/var-lib-kubelet/kubeadm-flags.env"
    fi
    self_private_ip >"$${STAGING_DIR}/origin-private-ip.txt"
    hostname >"$${STAGING_DIR}/origin-node-name.txt"

    tar -C "$STAGING_DIR" -czf "$${BUNDLE_DIR}/handoff-bundle.tar.gz.new" .
    mv "$${BUNDLE_DIR}/handoff-bundle.tar.gz.new" "$${BUNDLE_DIR}/handoff-bundle.tar.gz"
    rm -rf "$${STAGING_DIR}/pki" "$${STAGING_DIR}/manifests" "$${STAGING_DIR}/var-lib-kubelet"

    # Pre-cache control plane container images once for instant peer-streaming on fallback
    if [ ! -f "$${BUNDLE_DIR}/k8s-images.tar" ]; then
      local_images="$(ctr -n k8s.io images list -q 2>/dev/null || true)"
      if [ -n "$local_images" ]; then
        log "snapshot-loop: caching control-plane container images for peer streaming"
        ctr -n k8s.io images export "$${BUNDLE_DIR}/k8s-images.tar.new" $local_images >>/var/log/eks-killer.log 2>&1 || true
        if [ -f "$${BUNDLE_DIR}/k8s-images.tar.new" ]; then
          mv "$${BUNDLE_DIR}/k8s-images.tar.new" "$${BUNDLE_DIR}/k8s-images.tar"
          log "snapshot-loop: container image cache ready"
        fi
      fi
    fi
  else
    log "snapshot-loop: etcdctl snapshot save failed, keeping previous bundle"
  fi

  sleep "$SNAPSHOT_INTERVAL"
done
EKSKILLER_EOF

cat > /opt/eks-killer/watcher-master.sh <<'EKSKILLER_EOF'
#!/usr/bin/env bash
# Polls the spot interruption notice AND the rebalance recommendation every 5s.
# Rebalance can arrive minutes before the 2-minute notice: firing early buys
# wall-clock on the slow (no-worker) path. Fires exactly once; a background
# watchdog removes the spare if no interruption follows (false alarm).

set -uo pipefail
source /opt/eks-killer/common.sh

POLL_INTERVAL=5
FIRED=0
WATCHDOG_DELAY=600 # real interruptions land ~2min after notice; later = false alarm

log "watcher-master: starting poll loop (interruption + rebalance)"

while true; do
  token="$(imds_token)"
  action="$(curl -s -o /dev/null -w '%%{http_code}' \
    -H "X-aws-ec2-metadata-token: $${token}" \
    http://169.254.169.254/latest/meta-data/spot/instance-action)"
  reb="$(curl -s -o /dev/null -w '%%{http_code}' \
    -H "X-aws-ec2-metadata-token: $${token}" \
    http://169.254.169.254/latest/meta-data/events/recommendations/rebalance)"

  cause=""
  if [ "$action" = "200" ]; then
    cause="interruption"
  elif [ "$reb" = "200" ]; then
    cause="rebalance"
  fi

  if [ -n "$cause" ] && [ "$FIRED" -eq 0 ]; then
    FIRED=1
    echo "$cause" > /opt/eks-killer/trigger-cause
    log "watcher-master: $cause signal received, firing handoff"
    # Restart the snapshot loop so it takes a fresh etcd snapshot RIGHT NOW
    # instead of up to a full interval stale: the restarted loop snapshots first.
    pkill -f snapshot-loop.sh 2>/dev/null || true
    /opt/eks-killer/handoff.sh &
    # False-alarm watchdog: if no interruption lands and the EIP never moved,
    # the spare we launched is unneeded - terminate that exact instance.
    ( sleep "$WATCHDOG_DELAY"
      wtoken="$(imds_token)"
      waction="$(curl -s -o /dev/null -w '%%{http_code}' \
        -H "X-aws-ec2-metadata-token: $${wtoken}" \
        http://169.254.169.254/latest/meta-data/spot/instance-action)"
      wself="$(self_instance_id)"
      wregion="$(self_region)"
      wholder="$(aws ec2 describe-addresses --region "$wregion" \
        --filters Name=tag:Name,Values=eks-killer-master-eip \
        --query 'Addresses[0].InstanceId' --output text 2>/dev/null)"
      if [ "$waction" != "200" ] && [ "$wholder" = "$wself" ]; then
        wspare="$(cat /opt/eks-killer/spare-instance-id 2>/dev/null || true)"
        if [ -n "$wspare" ] && [ "$wspare" != "$wself" ]; then
          log "watcher-master: false alarm (no interruption in 10min), removing spare $wspare"
          aws autoscaling terminate-instance-in-auto-scaling-group --region "$wregion" \
            --instance-id "$wspare" --should-decrement-desired-capacity >/dev/null 2>&1 || true
          rm -f /opt/eks-killer/spare-instance-id
        fi
      fi ) &
  fi

  sleep "$POLL_INTERVAL"
done
EKSKILLER_EOF

cat > /opt/eks-killer/watcher-worker.sh <<'EKSKILLER_EOF'
#!/usr/bin/env bash
# Runs on ordinary (non-promoted) workers only. On interruption notice,
# cordon+drain so pods reschedule elsewhere before this node disappears.
# No etcd, no snapshot dance - the ASG relaunches a replacement on its own.

set -uo pipefail
source /opt/eks-killer/common.sh

POLL_INTERVAL=5
FIRED=0
NODE_NAME="$(hostname)"

log "watcher-worker: starting poll loop for node $NODE_NAME"

while true; do
  token="$(imds_token)"
  action="$(curl -s -o /dev/null -w '%%{http_code}' \
    -H "X-aws-ec2-metadata-token: $${token}" \
    http://169.254.169.254/latest/meta-data/spot/instance-action)"

  if [ "$action" = "200" ] && [ "$FIRED" -eq 0 ]; then
    FIRED=1
    log "watcher-worker: interruption notice received, cordon+drain"
    kubectl --kubeconfig=/opt/eks-killer/worker-kubeconfig cordon "$NODE_NAME" || true
    kubectl --kubeconfig=/opt/eks-killer/worker-kubeconfig drain "$NODE_NAME" \
      --ignore-daemonsets --delete-emptydir-data --force --timeout=90s || true
    log "watcher-worker: drained, waiting to be reclaimed"
  fi

  sleep "$POLL_INTERVAL"
done
EKSKILLER_EOF

cat > /opt/eks-killer/handoff.sh <<'EKSKILLER_EOF'
#!/usr/bin/env bash
# Fired once by watcher-master.sh when the spot interruption notice lands.
# Picks a target (an existing healthy worker if one exists, otherwise a
# freshly-launched instance), ships the latest etcd+PKI bundle to it, and
# re-points the Elastic IP once the target confirms it's up.

set -uo pipefail
source /opt/eks-killer/common.sh

REGION="$(self_region)"
export AWS_DEFAULT_REGION="$REGION"

HANDOFF_PORT="__HANDOFF_PORT__"
EIP_ALLOC_ID="$(cat /opt/eks-killer/eip-allocation-id 2>/dev/null)"
BUNDLE="/opt/eks-killer/bundle/handoff-bundle.tar.gz"
DEADLINE=$(( $(date +%s) + 600 ))
# Slow (no-worker) path legitimately needs ~200s+: boot + install + image pulls.
# The old box dies at T+120s regardless; this deadline only bounds how long we
# DRIVE convergence, so it must cover the slow path, not the notice window.

log "handoff: starting, deadline in $((DEADLINE - $(date +%s)))s"

pick_worker_ip() {
  KUBECONFIG=/etc/kubernetes/admin.conf kubectl get nodes -l role=worker \
    -o json 2>/dev/null | \
    jq -r '.items[] | select(.status.conditions[] | select(.type=="Ready" and .status=="True")) |
           .status.addresses[] | select(.type=="InternalIP") | .address' | head -n1
}

launch_fresh_master() {
  local asg_name
  asg_name="$(aws autoscaling describe-auto-scaling-groups \
    --query "AutoScalingGroups[?contains(AutoScalingGroupName, 'eks-killer-master')].AutoScalingGroupName | [0]" \
    --output text 2>/dev/null | tr -d ' \t\r\n')"

  if [ -n "$asg_name" ] && [ "$asg_name" != "None" ]; then
    log "handoff: scaling master ASG $asg_name to capacity 2"
    aws autoscaling set-desired-capacity --auto-scaling-group-name "$asg_name" --desired-capacity 2 >/dev/null
    local self_id
    self_id="$(self_instance_id)"
    local new_id=""
    for i in $(seq 1 30); do
      new_id="$(aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names "$asg_name" \
        --query "AutoScalingGroups[0].Instances[?InstanceId!='$self_id'].InstanceId | [0]" \
        --output text 2>/dev/null | tr -d ' \t\r\n')"
      if [ -n "$new_id" ] && [ "$new_id" != "None" ]; then
        break
      fi
      sleep 2
    done
    if [ -n "$new_id" ] && [ "$new_id" != "None" ]; then
      log "handoff: master ASG launched instance $new_id"
      echo "$new_id"
      return 0
    fi
  fi

  local lt_id
  lt_id="$(aws ec2 describe-launch-templates \
    --filters Name=tag:Name,Values=eks-killer-master-lt \
    --query 'LaunchTemplates[0].LaunchTemplateId' --output text)"

  if [ -z "$lt_id" ] || [ "$lt_id" = "None" ]; then
    log "handoff: FATAL could not find master launch template"
    return 1
  fi

  local new_id
  new_id="$(aws ec2 run-instances \
    --launch-template "LaunchTemplateId=$${lt_id},Version=\$Latest" \
    --query 'Instances[0].InstanceId' --output text | tr -d ' \t\r\n')"

  log "handoff: launched fresh master instance $new_id, waiting for it to come up"
  echo "$new_id"
}

wait_for_receiver() {
  local ip="$1"
  while [ "$(date +%s)" -lt "$DEADLINE" ]; do
    if nc -z -w2 "$ip" "$HANDOFF_PORT" 2>/dev/null; then
      return 0
    fi
    sleep 2
  done
  return 1
}

nc_send() {
  # Stream stdin to $ip:$HANDOFF_PORT and require the receiver's OK reply.
  # Returns nonzero on refused/failed/empty delivery instead of failing silently.
  local ip="$1" resp
  resp="$(nc -w 60 "$ip" "$HANDOFF_PORT" 2>/dev/null)"
  if [[ "$resp" != *"OK"* ]]; then
    log "handoff: FATAL bundle delivery to $ip failed (no OK reply)"
    return 1
  fi
  return 0
}

send_bundle() {
  local ip="$1"
  local is_worker="$${2:-1}"
  log "handoff: sending bundle to $${ip}:$${HANDOFF_PORT}"
  if [ "$is_worker" -eq 1 ]; then
    cat "$BUNDLE" | nc_send "$ip" || return 1
  else
    if [ -f "/opt/eks-killer/bundle/k8s-images.tar" ]; then
      log "handoff: peer-streaming etcd+pki bundle AND k8s-images.tar to fresh instance (uncompressed fast stream)"
      tar -C /opt/eks-killer/bundle -cf - handoff-bundle.tar.gz k8s-images.tar | nc_send "$ip" || return 1
    else
      cat "$BUNDLE" | nc_send "$ip" || return 1
    fi
  fi
}


main() {
  local self_id target_ip target_launch_id used_worker=0

  self_id="$(self_instance_id)"

  target_ip="$(pick_worker_ip)"

  if [ -n "$target_ip" ]; then
    used_worker=1
    log "handoff: promoting existing worker at $target_ip"
  else
    log "handoff: no healthy worker found, launching fresh master"
    target_launch_id="$(launch_fresh_master)" || { log "handoff: ABORT, no fallback available"; exit 1; }
    # Record the spare so the watcher's false-alarm watchdog can remove exactly
    # this instance if no interruption ever follows (rebalance false alarm).
    echo "$target_launch_id" > /opt/eks-killer/spare-instance-id
  fi

  if [ "$used_worker" -eq 0 ]; then
    while [ -z "$target_ip" ] && [ "$(date +%s)" -lt "$DEADLINE" ]; do
      target_ip="$(aws ec2 describe-instances --instance-ids "$target_launch_id" \
        --query 'Reservations[0].Instances[0].PrivateIpAddress' --output text 2>/dev/null)"
      [ "$target_ip" = "None" ] && target_ip=""
      sleep 3
    done
  fi

  if [ -z "$target_ip" ]; then
    log "handoff: FATAL never got a target IP in time"
    exit 1
  fi

  if ! wait_for_receiver "$target_ip"; then
    log "handoff: FATAL receiver never came up on $target_ip within deadline"
    exit 1
  fi

  send_bundle "$target_ip" "$used_worker" || { log "handoff: FATAL bundle delivery failed, aborting"; exit 1; }

  # Bundle delivery confirmed (TCP close + OK reply from receiver).
  # The replacement master associates the EIP itself after apiserver is healthy.
  # Sleep 20s to allow promotion to complete, then self-terminate.
  log "handoff: bundle acknowledged. Sleeping 20s then self-terminating."
  rm -f /opt/eks-killer/spare-instance-id
  sleep 20
  log "handoff: COMPLETE, self-terminating ($self_id)"
  aws ec2 terminate-instances --instance-ids "$self_id" >/dev/null 2>&1 || true
}

main
EKSKILLER_EOF

cat > /opt/eks-killer/receiver.sh <<'EKSKILLER_EOF'
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

log "receiver: listening on port $${HANDOFF_PORT}"

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
  if [ -f "$${RESTORE_DIR}/k8s-images.tar" ]; then
    log "receiver: importing peer-streamed container images into containerd"
    ctr -n k8s.io images import "$${RESTORE_DIR}/k8s-images.tar" >>/var/log/eks-killer.log 2>&1 || true
    rm -f "$${RESTORE_DIR}/k8s-images.tar"
  fi

  if [ -f "$${RESTORE_DIR}/handoff-bundle.tar.gz" ]; then
    tar -xzf "$${RESTORE_DIR}/handoff-bundle.tar.gz" -C "$RESTORE_DIR"
    rm -f "$${RESTORE_DIR}/handoff-bundle.tar.gz"
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

  OLD_IP="$(cat "$${RESTORE_DIR}/origin-private-ip.txt")"
  NEW_IP="$(self_private_ip)"
  NODE_NAME="$(hostname)"

  log "receiver: rewriting manifests $${OLD_IP} -> $${NEW_IP}"

  rm -rf /var/lib/etcd-restored
  ETCDCTL_API=3 etcdctl snapshot restore "$${RESTORE_DIR}/etcd-snapshot.db" \
    --data-dir=/var/lib/etcd-restored \
    --name="$${NODE_NAME}" \
    --initial-cluster="$${NODE_NAME}=https://$${NEW_IP}:2380" \
    --initial-advertise-peer-urls="https://$${NEW_IP}:2380" \
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
  cp -a "$${RESTORE_DIR}/pki/." /etc/kubernetes/pki/
  cp -a "$${RESTORE_DIR}/manifests/." /etc/kubernetes/manifests/
  cp "$${RESTORE_DIR}/admin.conf" /etc/kubernetes/admin.conf
  cp "$${RESTORE_DIR}/scheduler.conf" /etc/kubernetes/scheduler.conf
  cp "$${RESTORE_DIR}/controller-manager.conf" /etc/kubernetes/controller-manager.conf

  # Discover master EIP and bind it locally: this box cannot hairpin to its own EIP,
  # and our kubelet/kubectl/controllers dial the control-plane endpoint (the EIP).
  # Doing this BEFORE starting kubelet ensures local dials to the EIP succeed.
  EIP_PUBLIC_IP="$(aws ec2 describe-addresses --region "$REGION" \
    --filters Name=tag:Name,Values=eks-killer-master-eip \
    --query 'Addresses[0].PublicIp' --output text 2>/dev/null)"
  if [ -n "$EIP_PUBLIC_IP" ] && [ "$EIP_PUBLIC_IP" != "None" ]; then
    ip addr add "$${EIP_PUBLIC_IP}/32" dev lo 2>/dev/null || true
    cat > /etc/systemd/system/eip-lo.service <<EIPLO_EOF
[Unit]
Description=eks-killer bind master EIP to loopback (hairpin-free local API access)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=-/usr/sbin/ip addr add $${EIP_PUBLIC_IP}/32 dev lo

[Install]
WantedBy=multi-user.target
EIPLO_EOF
    systemctl daemon-reload
    systemctl enable eip-lo.service || true
    log "receiver: bound $${EIP_PUBLIC_IP} to lo"
  else
    log "receiver: WARNING could not discover master EIP, skipping lo bind"
  fi

  # Restore kubelet credentials using embedded client certs from admin.conf
  cp "$${RESTORE_DIR}/admin.conf" /etc/kubernetes/kubelet.conf

  if [ -d "$${RESTORE_DIR}/var-lib-kubelet" ]; then
    cp -a "$${RESTORE_DIR}/var-lib-kubelet/." /var/lib/kubelet/
  fi
  # If config.yaml is still missing, generate it with kubeadm
  if [ ! -f /var/lib/kubelet/config.yaml ]; then
    kubeadm init phase kubelet-start >/dev/null 2>&1 || true
  fi

  # Rewrite static pod manifests to this node's private IP
  sed -i "s/$${OLD_IP}/$${NEW_IP}/g" /etc/kubernetes/manifests/etcd.yaml
  sed -i "s/$${OLD_IP}/$${NEW_IP}/g" /etc/kubernetes/manifests/kube-apiserver.yaml

  # Rewrite controller-manager and scheduler to talk to EIP (valid SAN in apiserver.crt & bound to lo)
  TARGET_EP="$${EIP_PUBLIC_IP:-$NEW_IP}"
  sed -i "s/$${OLD_IP}/$${TARGET_EP}/g" /etc/kubernetes/controller-manager.conf /etc/kubernetes/scheduler.conf

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

  ORIGIN_NODE_NAME="$(cat "$${RESTORE_DIR}/origin-node-name.txt" 2>/dev/null || echo '')"
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
EKSKILLER_EOF

cat > /etc/systemd/system/snapshot-loop.service <<'EKSKILLER_EOF'
[Unit]
Description=eks-killer local etcd+PKI snapshot loop
After=kubelet.service

[Service]
Type=simple
ExecStart=/opt/eks-killer/snapshot-loop.sh
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EKSKILLER_EOF

cat > /etc/systemd/system/watcher-master.service <<'EKSKILLER_EOF'
[Unit]
Description=eks-killer master spot-interruption watcher
After=kubelet.service

[Service]
Type=simple
ExecStart=/opt/eks-killer/watcher-master.sh
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EKSKILLER_EOF

cat > /etc/systemd/system/watcher-worker.service <<'EKSKILLER_EOF'
[Unit]
Description=eks-killer worker spot-interruption watcher
After=kubelet.service

[Service]
Type=simple
ExecStart=/opt/eks-killer/watcher-worker.sh
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EKSKILLER_EOF

cat > /etc/systemd/system/receiver.service <<'EKSKILLER_EOF'
[Unit]
Description=eks-killer handoff bundle receiver
After=kubelet.service network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/opt/eks-killer/receiver.sh
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EKSKILLER_EOF

cat > /etc/systemd/system/eip-lo.service <<'EKSKILLER_EOF'
[Unit]
Description=eks-killer bind master EIP to loopback (hairpin-free local API access)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=-/usr/sbin/ip addr add ${eip_public_ip}/32 dev lo

[Install]
WantedBy=multi-user.target
EKSKILLER_EOF

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
