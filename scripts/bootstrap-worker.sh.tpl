#!/usr/bin/env bash
# Rendered by Terraform (templatefile). EC2 userdata for every worker.
# Installs kubelet/kubeadm/containerd, joins the cluster, and lays down
# (but does not start) the master-role scripts, in case the ASG's
# scale-driven relaunch here ends up being promoted later.
set -x
exec > >(tee -a /var/log/eks-killer-userdata.log) 2>&1

# Stop background apt timers immediately on boot to avoid dpkg lock contention
systemctl stop apt-daily.timer apt-daily-upgrade.timer unattended-upgrades.service 2>/dev/null || true
killall apt apt-get 2>/dev/null || true

mkdir -p /opt/eks-killer

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
  killall apt apt-get 2>/dev/null || true
  apt-get update -y
  apt-get install -y --no-install-recommends ca-certificates curl gnupg jq netcat-openbsd unzip containerd etcd-client iptables conntrack socat

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
  wait $pids

  chmod +x /usr/bin/kubelet /usr/bin/kubeadm /usr/bin/kubectl

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

install_awscli() {
  if command -v aws >/dev/null 2>&1; then return; fi
  local cli_arch="x86_64"
  [ "$(uname -m)" = "aarch64" ] && cli_arch="aarch64"
  curl -s "https://awscli.amazonaws.com/awscli-exe-linux-$${cli_arch}.zip" -o /tmp/awscliv2.zip
  unzip -q -o /tmp/awscliv2.zip -d /tmp
  /tmp/aws/install
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
# Polls the spot interruption notice every 5s. On the first sighting,
# fires the handoff exactly once and then just waits to die.

set -uo pipefail
source /opt/eks-killer/common.sh

POLL_INTERVAL=5
FIRED=0

log "watcher-master: starting poll loop"

while true; do
  token="$(imds_token)"
  action="$(curl -s -o /dev/null -w '%%{http_code}' \
    -H "X-aws-ec2-metadata-token: $${token}" \
    http://169.254.169.254/latest/meta-data/spot/instance-action)"

  if [ "$action" = "200" ] && [ "$FIRED" -eq 0 ]; then
    FIRED=1
    log "watcher-master: interruption notice received, firing handoff"
    /opt/eks-killer/handoff.sh &
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
DEADLINE=$(( $(date +%s) + 100 ))   # leave margin inside the 120s notice window

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
        --query "AutoScalingGroups[0].Instances[?LifecycleState=='InService' || LifecycleState=='Pending'].InstanceId" \
        --output text 2>/dev/null | tr '\t' '\n' | grep -v "$self_id" | head -n1 | tr -d ' \t\r\n')"
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

send_bundle() {
  local ip="$1"
  local is_worker="$${2:-1}"
  log "handoff: sending bundle to $${ip}:$${HANDOFF_PORT}"
  if [ "$is_worker" -eq 1 ]; then
    cat "$BUNDLE" | nc -q2 "$ip" "$HANDOFF_PORT"
  else
    if [ -f "/opt/eks-killer/bundle/k8s-images.tar" ]; then
      log "handoff: peer-streaming etcd+pki bundle AND k8s-images.tar to fresh instance"
      tar -C /opt/eks-killer/bundle -czf - handoff-bundle.tar.gz k8s-images.tar | nc -q2 "$ip" "$HANDOFF_PORT"
    else
      cat "$BUNDLE" | nc -q2 "$ip" "$HANDOFF_PORT"
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
  # The receiver associates the EIP itself. Sleep 20s then self-terminate.
  log "handoff: bundle acknowledged. Sleeping 20s then self-terminating."
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

  # Normalize master ASG desired capacity to 1
  local asg_name
  asg_name="$(aws autoscaling describe-auto-scaling-groups \
    --query "AutoScalingGroups[?contains(AutoScalingGroupName, 'eks-killer-master')].AutoScalingGroupName | [0]" \
    --output text 2>/dev/null | tr -d ' \t\r\n')"
  if [ -n "$asg_name" ] && [ "$asg_name" != "None" ]; then
    aws autoscaling set-desired-capacity --auto-scaling-group-name "$asg_name" --desired-capacity 1 >/dev/null 2>&1 || true
  fi

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

chmod +x /opt/eks-killer/*.sh
sed -i "s/__HANDOFF_PORT__/${handoff_port}/g" /opt/eks-killer/handoff.sh /opt/eks-killer/receiver.sh
systemctl daemon-reload

source /opt/eks-killer/common.sh

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

log "bootstrap-worker: pre-caching control plane images in background"
kubeadm config images pull >>/var/log/eks-killer.log 2>&1 &

log "bootstrap-worker: joined cluster, watcher + receiver running"
