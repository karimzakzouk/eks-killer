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
  curl -s -H "X-aws-ec2-metadata-token: ${token}" "http://169.254.169.254/latest/meta-data/${path}"
}

self_instance_id() { imds_get "instance-id"; }
self_private_ip() { imds_get "local-ipv4"; }
self_region() { imds_get "placement/region"; }

install_awscli() {
  if command -v aws >/dev/null 2>&1; then return; fi
  # Wait for the boot-second-1 background download to finish
  if [ -n "${AWS_INSTALL_PID:-}" ]; then
    wait "$AWS_INSTALL_PID" 2>/dev/null || true
  fi
  if command -v aws >/dev/null 2>&1; then return; fi
  local cli_arch="x86_64"
  [ "$(uname -m)" = "aarch64" ] && cli_arch="aarch64"
  curl -s "https://awscli.amazonaws.com/awscli-exe-linux-${cli_arch}.zip" -o /tmp/awscliv2.zip
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
  # Mask (not just stop) apt timers + kill any in-progress dpkg/apt so userdata never races
  systemctl stop apt-daily.timer apt-daily-upgrade.timer unattended-upgrades.service apt-daily.service apt-daily-upgrade.service 2>/dev/null || true
  systemctl mask apt-daily.timer apt-daily-upgrade.timer unattended-upgrades.service apt-daily.service apt-daily-upgrade.service 2>/dev/null || true
  killall -9 apt apt-get unattended-upgrades dpkg apt.systemd.daily 2>/dev/null || true
  # Hard-wait up to 60s for dpkg locks to be released — #1 cause of failed userdata
  for i in $(seq 1 30); do
    if ! ( lsof /var/lib/dpkg/lock-frontend >/dev/null 2>&1 || lsof /var/lib/dpkg/lock >/dev/null 2>&1 \
           || fuser /var/lib/apt/lists/lock >/dev/null 2>&1 ); then
      break
    fi
    sleep 2
  done
  # Parallel apt downloads (default is 1 per host), turn off recommends/suggests globally
  cat <<'EOF' > /etc/apt/apt.conf.d/99-eks-killer-speedup
Acquire::http::Pipeline-Depth "10";
Acquire::https::Pipeline-Depth "10";
Acquire::http::No-Cache "true";
Acquire::https::No-Cache "true";
Acquire::Queue-Mode "access";
APT::Install-Recommends "false";
APT::Install-Suggests "false";
Acquire::http::Timeout "30";
Acquire::https::Timeout "30";
DPkg::Use-Pty "0";
DPkg::Options {"--force-confdef";"--force-confold";};
EOF
  DEBIAN_FRONTEND=noninteractive apt-get update -y -o Acquire::Languages=none
  DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    ca-certificates curl gnupg jq netcat-openbsd unzip containerd etcd-client iptables conntrack socat lsof psmisc

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
    full_version="$(curl -sSL "https://dl.k8s.io/release/stable-${k8s_version}.txt" 2>/dev/null || echo "v${k8s_version}.0")"
  fi
  [[ ! "$full_version" =~ ^v ]] && full_version="v${full_version}"

  log "install_k8s_packages: downloading static k8s binaries (${full_version}, ${arch}) in parallel"
  local k8s_bin_url="https://dl.k8s.io/release/${full_version}/bin/linux/${arch}"
  mkdir -p /usr/bin /opt/cni/bin /etc/systemd/system/kubelet.service.d

  local pids=""
  curl -sSL -o /usr/bin/kubelet "${k8s_bin_url}/kubelet" & pids="$pids $!"
  curl -sSL -o /usr/bin/kubeadm "${k8s_bin_url}/kubeadm" & pids="$pids $!"
  curl -sSL -o /usr/bin/kubectl "${k8s_bin_url}/kubectl" & pids="$pids $!"
  (curl -sSL "https://github.com/containernetworking/plugins/releases/download/v1.5.0/cni-plugins-linux-${arch}-v1.5.0.tgz" | tar -C /opt/cni/bin -xz) & pids="$pids $!"
  (curl -sSL "https://github.com/kubernetes-sigs/cri-tools/releases/download/v1.30.0/crictl-v1.30.0-linux-${arch}.tar.gz" | tar -C /usr/bin -xz) & pids="$pids $!"
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
  local name="$1" value="$2" region="$3" tier="${4:-Standard}"
  aws ssm put-parameter --region "$region" --name "$name" --type "SecureString" --tier "$tier" --value "$value" --overwrite >/dev/null
}

ssm_get() {
  local name="$1" region="$2"
  aws ssm get-parameter --region "$region" --name "$name" --with-decryption --query 'Parameter.Value' --output text 2>/dev/null
}

associate_eip_bounded() {
  # Bounded EIP association: 120 retries × 5s = 10 minutes total worst case.
  # Fatal on failure (exit 1) instead of a WARNING that leaves kubectl pointed at a dead box.
  local alloc_id="$1"
  local inst_id="$2"
  local region="${3:-$AWS_DEFAULT_REGION}"
  local eip_public="${4:-<unknown>}"
  local associated=0
  for i in $(seq 1 120); do
    if aws ec2 associate-address --region "$region" --instance-id "$inst_id" \
      --allocation-id "$alloc_id" --allow-reassociation >>/var/log/eks-killer.log 2>&1; then
      associated=1
      break
    fi
    sleep 5
  done
  if [ "$associated" -eq 1 ]; then
    log "associate_eip: EIP ${eip_public} successfully associated to $inst_id (attempt $i)"
    return 0
  else
    log "associate_eip: FATAL EIP $alloc_id not associated to $inst_id after 10 minutes — kubectl cannot reach apiserver via EIP"
    return 1
  fi
}


# ═══════════════════════════════════════════════════════════════════════════════
# Unified eks-killer master promotion logic.
#
# Three original call sites (receiver-master.sh hot standby, receiver-worker.sh
# fast-path, bootstrap-master replacement path) were near-identical ~200-line
# copies. This single function is the source of truth.
#
# Callers:
#   receiver-master.sh:       is_worker=false, EIP discovered via tag lookup
#   receiver-worker.sh:       is_worker=true (runs kubeadm reset + etcd wait),
#                             EIP discovered via tag lookup
#   bootstrap-master.tpl:     is_worker=false, EIP passed via template vars
#
# Args (all positional; use "" to leave a slot empty for defaults):
#   $1 bundle_tar      — path to incoming-bundle.tar (validate-before-mutate)
#   $2 new_private_ip  — this node's current private IP; default=imds lookup
#   $3 is_worker       — "true" = this node was a worker; run kubeadm reset
#                        and wait for etcd-dir restoration; default=false
#   $4 eip_alloc_id    — EIP allocation id. If "", attempt runtime discovery
#                        via AWS tag Name=eks-killer-master-eip.
#   $5 eip_public_ip   — EIP public IPv4 (used for logs; discovered if "")
#   $6 eip_lo_unit     — path to eip-lo.service systemd unit to install
# ═══════════════════════════════════════════════════════════════════════════════
promote_from_bundle() {
  local bundle_file="${1:-/opt/eks-killer/incoming-bundle.tar}"
  local NEW_IP="${2:-$(self_private_ip)}"
  local IS_WORKER="${3:-false}"
  local ALLOC_ID="$4"
  local EIP_PUBLIC_IP="$5"
  local EIP_LO_UNIT="${6:-/opt/eks-killer/systemd/eip-lo.service}"

  local SELF_ID REGION NODE_NAME
  SELF_ID="$(self_instance_id)"
  REGION="$(self_region)"
  NODE_NAME="$(hostname)"

  log "promote: =================================================="
  log "promote: REPLACEMENT MASTER promotion starting on $NODE_NAME ($SELF_ID / $NEW_IP)"
  log "promote: bundle=$bundle_file  worker-path=$IS_WORKER"

  # ── 1. EIP discovery (only if caller did not pass alloc id) ────────────────
  if [ -z "$ALLOC_ID" ]; then
    log "promote: no EIP alloc id passed, discovering via tag"
    local eip_info
    eip_info="$(aws ec2 describe-addresses --region "$REGION" \
      --filters Name=tag:Name,Values=eks-killer-master-eip \
      --query "Addresses[0].[AllocationId,PublicIp]" --output text 2>>/var/log/eks-killer.log)"
    ALLOC_ID="$(echo "$eip_info" | awk 'NR==1{print $1}')"
    EIP_PUBLIC_IP="$(echo "$eip_info" | awk 'NR==1{print $2}')"
    log "promote: discovered EIP $EIP_PUBLIC_IP alloc=$ALLOC_ID"
  fi

  # ── 2. Bundle format resolution + validate-before-mutate ──────────────────
  # Two bundle layouts arrive from handoff.sh:
  #   a) Direct:  manifest.yaml|etcd-snapshot.db|pki/|... at top of the tar.
  #   b) Combined: outer tar wraps handoff-bundle.tar.gz + optional
  #      k8s-images.tar peer-streamed container image cache.
  local RESTORE_DIR="/opt/eks-killer/restore"
  local FLAT_BUNDLE=""
  local COMBINED_TMPDIR=""
  if [ ! -s "$bundle_file" ]; then
    log "promote: FATAL bundle $bundle_file missing or empty, aborting"
    return 1
  fi
  if tar -tf "$bundle_file" 2>/dev/null | grep -q '^handoff-bundle.tar.gz$'; then
    log "promote: detected combined (outer wrap) bundle format, unwrapping"
    COMBINED_TMPDIR="$(mktemp -d /tmp/eks-killer-combined.XXXXXX)"
    tar -C "$COMBINED_TMPDIR" -xpf "$bundle_file" >>/var/log/eks-killer.log 2>&1
    if [ -f "$COMBINED_TMPDIR/k8s-images.tar" ]; then
      log "promote: combined bundle includes peer-streamed k8s-images.tar, pre-importing"
      pkill -9 -f "crictl pull" 2>/dev/null || true
      mkdir -p /opt/eks-killer/bundle
      cp -f "$COMBINED_TMPDIR/k8s-images.tar" /opt/eks-killer/bundle/k8s-images.tar
      systemctl is-active --quiet containerd || ( systemctl enable --now containerd >>/var/log/eks-killer.log 2>&1 || true )
      for x in 1 2 3 4 5 6 7 8 9 10; do
        [ -S /run/containerd/containerd.sock ] && break
        sleep 2
      done
      ctr -n k8s.io images import "$COMBINED_TMPDIR/k8s-images.tar" >>/var/log/eks-killer.log 2>&1 || \
        log "promote: WARNING k8s-images.tar import failed (images will pull fresh on demand)"
    fi
    FLAT_BUNDLE="$COMBINED_TMPDIR/handoff-bundle.tar.gz"
    [ ! -f "$FLAT_BUNDLE" ] && { log "promote: FATAL combined bundle has no handoff-bundle.tar.gz inside"; rm -rf "$COMBINED_TMPDIR"; return 1; }
  else
    FLAT_BUNDLE="$bundle_file"
  fi

  rm -rf "$RESTORE_DIR"
  mkdir -p "$RESTORE_DIR"
  tar -C "$RESTORE_DIR" -xpf "$FLAT_BUNDLE" >>/var/log/eks-killer.log 2>&1
  [ -n "$COMBINED_TMPDIR" ] && rm -rf "$COMBINED_TMPDIR"
  rm -f "$bundle_file"

  # Union of files required by the original 3 call sites (receiver-master,
  # receiver-worker, bootstrap replacement path) — union for safety across
  # all three promotion entrypoints.
  for required in manifest.yaml etcd-snapshot.db \
    origin-private-ip.txt origin-node-name.txt \
    admin.conf scheduler.conf controller-manager.conf \
    pki/ca.crt pki/front-proxy-ca.crt pki/apiserver-etcd-client.crt pki/apiserver-kubelet-client.crt; do
    if [ ! -f "$RESTORE_DIR/$required" ]; then
      log "promote: FATAL bundle missing $required, aborting (cluster state untouched)"
      return 1
    fi
  done
  if ! grep -q 'apiVersion: v1' "$RESTORE_DIR/manifest.yaml" 2>/dev/null; then
    log "promote: FATAL manifest.yaml invalid, aborting"
    return 1
  fi
  log "promote: bundle valid, proceeding to state mutation"

  # ── 3. Worker-path-only: kubeadm reset + prepare kubelet pki dirs ──────────
  local ORIGIN_PRIVATE_IP=""
  ORIGIN_PRIVATE_IP="$(cat "$RESTORE_DIR/origin-private-ip.txt" 2>/dev/null || echo '')"

  if [ "$IS_WORKER" = "true" ]; then
    log "promote: worker-promotion path — kubeadm reset -f first"
    kubeadm reset -f --ignore-preflight-errors=all >>/var/log/eks-killer.log 2>&1 || true
    mkdir -p /var/lib/kubelet/pki
    if [ -d "$RESTORE_DIR/kubelet/pki" ]; then
      cp -a "$RESTORE_DIR/kubelet/pki/." /var/lib/kubelet/pki/
      log "promote: restored /var/lib/kubelet/pki from bundle"
    fi
  fi

  # ── 4. Stop everything, wipe, restore etcd snapshot + PKI ─────────────────
  systemctl stop kubelet >>/var/log/eks-killer.log 2>&1 || true
  systemctl stop containerd >>/var/log/eks-killer.log 2>&1 || true
  kubelet --version >>/var/log/eks-killer.log 2>&1 || true

  rm -rf /etc/kubernetes/*
  [ "$IS_WORKER" = "true" ] && rm -rf /var/lib/kubelet/pki/* /var/lib/etcd/member
  [ -d /var/lib/etcd ] && ! [ -L /var/lib/etcd ] && rm -rf /var/lib/etcd/member

  mkdir -p /etc/kubernetes/pki /var/lib/kubelet/pki
  cp -a "$RESTORE_DIR/pki/." /etc/kubernetes/pki/
  cp -f "$RESTORE_DIR/admin.conf" /etc/kubernetes/admin.conf
  chmod 600 /etc/kubernetes/admin.conf /etc/kubernetes/kubelet.conf 2>/dev/null || true
  chmod 600 /etc/kubernetes/controller-manager.conf /etc/kubernetes/scheduler.conf 2>/dev/null || true

  log "promote: restoring etcd snapshot -> /var/lib/etcd"
  ETCDCTL_API=3 etcdctl snapshot restore "$RESTORE_DIR/etcd-snapshot.db" \
    --name="$NODE_NAME" \
    --data-dir=/var/lib/etcd \
    --initial-cluster="$NODE_NAME=https://$NEW_IP:2380" \
    --initial-advertise-peer-urls="https://$NEW_IP:2380" \
    --skip-hash-check=true >>/var/log/eks-killer.log 2>&1 \
    || { log "promote: FATAL etcd snapshot restore failed"; return 1; }

  if [ -d "$RESTORE_DIR/manifests" ]; then
    mkdir -p /etc/kubernetes/manifests
    cp -a "$RESTORE_DIR/manifests/." /etc/kubernetes/manifests/
  fi
  if [ "$IS_WORKER" = "true" ] && [ -d "$RESTORE_DIR/var-lib-kubelet" ]; then
    [ -f "$RESTORE_DIR/var-lib-kubelet/config.yaml" ] && \
      cp "$RESTORE_DIR/var-lib-kubelet/config.yaml" /var/lib/kubelet/config.yaml
    [ -f "$RESTORE_DIR/var-lib-kubelet/kubeadm-flags.env" ] && \
      cp "$RESTORE_DIR/var-lib-kubelet/kubeadm-flags.env" /var/lib/kubelet/kubeadm-flags.env
  fi
  mkdir -p /var/lib/kubelet/pki
  if [ -d "$RESTORE_DIR/kubelet/pki" ]; then
    cp -a "$RESTORE_DIR/kubelet/pki/." /var/lib/kubelet/pki/
  fi

  # ── 5. IP rewrites in kubeconfigs + static manifests ──────────────────────
  log "promote: rewriting IPs ${ORIGIN_PRIVATE_IP:-<origin-unknown>} -> $NEW_IP"
  for f in /etc/kubernetes/manifests/kube-apiserver.yaml \
           /etc/kubernetes/manifests/kube-controller-manager.yaml \
           /etc/kubernetes/manifests/kube-scheduler.yaml \
           /etc/kubernetes/manifests/etcd.yaml \
           /etc/kubernetes/kubelet.conf \
           /etc/kubernetes/controller-manager.conf \
           /etc/kubernetes/scheduler.conf; do
    [ -f "$f" ] && [ -n "$ORIGIN_PRIVATE_IP" ] && \
      sed -i "s|$ORIGIN_PRIVATE_IP|$NEW_IP|g" "$f" 2>/dev/null || true
  done
  for kc in kubelet.conf controller-manager.conf scheduler.conf; do
    if [ -f "/etc/kubernetes/$kc" ] && ! grep -q "server: https://$NEW_IP" "/etc/kubernetes/$kc" 2>/dev/null; then
      log "promote: regenerating $kc via kubeadm phase kubeconfig"
      kubeadm init phase kubeconfig "$(echo "$kc" | sed 's/.conf$//')" --apiserver-advertise-address="$NEW_IP" --apiserver-cert-extra-sans="$EIP_PUBLIC_IP" --control-plane-endpoint="${EIP_PUBLIC_IP}:6443" --cert-dir=/etc/kubernetes/pki >>/var/log/eks-killer.log 2>&1 || true
    fi
  done

  # ── 6. Re-run kubeadm cert phase (in case NEW_IP not covered by SANs) ──────
  kubeadm init phase certs apiserver --apiserver-advertise-address="$NEW_IP" \
    --apiserver-cert-extra-sans="$EIP_PUBLIC_IP" --control-plane-endpoint="${EIP_PUBLIC_IP}:6443" \
    --cert-dir=/etc/kubernetes/pki >>/var/log/eks-killer.log 2>&1 || true
  kubeadm init phase kubelet-finalize all --cert-dir=/etc/kubernetes/pki >>/var/log/eks-killer.log 2>&1 || true
  kubeadm init phase kubelet-start --config /dev/stdin >/dev/null 2>>/var/log/eks-killer.log <<EOFKUBELET 2>/dev/null || true
apiVersion: kubeadm.k8s.io/v1beta3
kind: InitConfiguration
localAPIEndpoint:
  advertiseAddress: $NEW_IP
  bindPort: 6443
nodeRegistration:
  criSocket: unix:///var/run/containerd/containerd.sock
  taints: []
---
apiVersion: kubeadm.k8s.io/v1beta3
kind: ClusterConfiguration
controlPlaneEndpoint: ${EIP_PUBLIC_IP}:6443
networking:
  podSubnet: 192.168.0.0/16
EOFKUBELET
  # Re-copy kubelet config since kubeadm may have reset it
  [ -f "$RESTORE_DIR/var-lib-kubelet/config.yaml" ] && \
    cp "$RESTORE_DIR/var-lib-kubelet/config.yaml" /var/lib/kubelet/config.yaml 2>/dev/null || true

  # ── 7. Install & start eip-lo.service, restore origin info ─────────────────
  cp -f "$EIP_LO_UNIT" /etc/systemd/system/eip-lo.service 2>/dev/null || true
  systemctl daemon-reload
  systemctl enable --now eip-lo.service >>/var/log/eks-killer.log 2>&1 || \
    log "promote: WARNING eip-lo.service failed to start"

  mkdir -p /opt/eks-killer/restore
  [ -f "$RESTORE_DIR/origin-private-ip.txt" ] && \
    cp -f "$RESTORE_DIR/origin-private-ip.txt" /opt/eks-killer/restore/origin-private-ip.txt
  [ -f "$RESTORE_DIR/origin-node-name.txt" ] && \
    cp -f "$RESTORE_DIR/origin-node-name.txt" /opt/eks-killer/restore/origin-node-name.txt

  # ── 8. Rebuild containerd config + import cached images ────────────────────
  mkdir -p /etc/containerd/certs.d /etc/containerd/hosts.d
  [ ! -f /etc/containerd/config.toml ] && containerd config default > /etc/containerd/config.toml
  cat >/etc/containerd/config.toml <<EOF
version = 2
root = "/var/lib/containerd"
state = "/run/containerd"
[plugins."io.containerd.grpc.v1.cri".registry]
   config_path = "/etc/containerd/certs.d"
EOF
  mkdir -p /etc/containerd/certs.d/docker.io /etc/containerd/certs.d/registry.k8s.io /etc/containerd/certs.d/public.ecr.aws /etc/containerd/certs.d/quay.io
  for reg in docker.io registry.k8s.io public.ecr.aws quay.io; do
    [ ! -f "/etc/containerd/certs.d/$reg/hosts.toml" ] && \
      printf 'server = "https://%s"\n[host."https://%s"]\n' "$reg" "$reg" > "/etc/containerd/certs.d/$reg/hosts.toml"
  done

  systemctl enable --now containerd >>/var/log/eks-killer.log 2>&1 || \
    systemctl restart containerd >>/var/log/eks-killer.log 2>&1 || true
  for x in 1 2 3 4 5 6 7 8 9 10; do
    [ -S /run/containerd/containerd.sock ] && break
    sleep 2
  done

  if [ -f /opt/eks-killer/bundle/k8s-images.tar ]; then
    ctr -n k8s.io images import /opt/eks-killer/bundle/k8s-images.tar >>/var/log/eks-killer.log 2>&1 || \
      log "promote: WARNING pre-cached k8s-images.tar import failed (images will pull fresh)"
  fi

  # ── 9. Start kubelet, wait for apiserver health ───────────────────────────
  systemctl enable --now kubelet >>/var/log/eks-killer.log 2>&1 || \
    systemctl restart kubelet >>/var/log/eks-killer.log 2>&1 || true

  log "promote: waiting for apiserver 6443 -> healthz"
  local ready=0
  for i in $(seq 1 60); do
    ss -ltn 2>/dev/null | grep -q ":6443 " && \
      curl -skf --max-time 2 --cacert /etc/kubernetes/pki/ca.crt \
        "https://127.0.0.1:6443/livez?verbose" >/dev/null 2>&1 && \
      { ready=1; break; }
    sleep 5
  done
  if [ "$ready" -ne 1 ]; then
    log "promote: FATAL apiserver never became healthy, refusing to promote"
    return 1
  fi

  # ── 10. EIP association ────────────────────────────────────────────────────
  if [ -n "$ALLOC_ID" ] && [ "$ALLOC_ID" != "None" ]; then
    associate_eip_bounded "$ALLOC_ID" "$SELF_ID" "$REGION" "$EIP_PUBLIC_IP" \
      || { log "promote: FATAL EIP not associated after bounded retries — aborting"; return 1; }
  else
    log "promote: WARNING could not discover EIP allocation id, EIP not re-associated"
  fi

  # ── 11. Delete origin node + its pods from etcd state ──────────────────────
  local ORIGIN_NODE_NAME="$(cat "$RESTORE_DIR/origin-node-name.txt" 2>/dev/null || echo '')"
  if [ -n "$ORIGIN_NODE_NAME" ] && [ "$ORIGIN_NODE_NAME" != "$NODE_NAME" ]; then
    KUBECONFIG=/etc/kubernetes/admin.conf kubectl delete node "$ORIGIN_NODE_NAME" \
      >>/var/log/eks-killer.log 2>&1 || true
    KUBECONFIG=/etc/kubernetes/admin.conf kubectl delete pods -A \
      --field-selector spec.nodeName="$ORIGIN_NODE_NAME" --force --grace-period=0 \
      >>/var/log/eks-killer.log 2>&1 || true
  fi

  # ── 12. Relabel + remove control-plane taint, install admin.conf for ubuntu ─
  KUBECONFIG=/etc/kubernetes/admin.conf kubectl label node "$NODE_NAME" \
    role- >>/var/log/eks-killer.log 2>&1 || true
  KUBECONFIG=/etc/kubernetes/admin.conf kubectl label node "$NODE_NAME" \
    node-role.kubernetes.io/control-plane= role=master --overwrite >>/var/log/eks-killer.log 2>&1 || true
  KUBECONFIG=/etc/kubernetes/admin.conf kubectl taint node "$NODE_NAME" \
    node-role.kubernetes.io/control-plane:NoSchedule- >>/var/log/eks-killer.log 2>&1 || true

  mkdir -p /root/.kube /home/ubuntu/.kube
  cp -f /etc/kubernetes/admin.conf /root/.kube/config
  cp -f /etc/kubernetes/admin.conf /home/ubuntu/.kube/config
  chown -R ubuntu:ubuntu /home/ubuntu/.kube

  # ── 13. Swap daemons: stop receiver/watch-worker, start snapshot/watch-master ──
  systemctl daemon-reload
  systemctl disable --now receiver.service >>/var/log/eks-killer.log 2>&1 || true
  systemctl stop watcher-worker.service >>/var/log/eks-killer.log 2>&1 || true
  systemctl enable --now snapshot-loop.service >>/var/log/eks-killer.log 2>&1 || true
  systemctl enable --now watcher-master.service >>/var/log/eks-killer.log 2>&1 || true

  # ── 14. Restart metadata HTTP server on :7778 with a fresh kubeadm join token ─
  kill "$(cat /opt/eks-killer/metadata-server.pid 2>/dev/null)" 2>/dev/null || true
  local NEW_JOIN_CMD
  NEW_JOIN_CMD="$(kubeadm token create --print-join-command --ttl 0 2>>/var/log/eks-killer.log) --node-labels=role=worker --ignore-preflight-errors=Mem"
  python3 -c "
import http.server, base64

open('/opt/eks-killer/join-command','w').write('${NEW_JOIN_CMD}')
ADMIN = base64.b64encode(open('/etc/kubernetes/admin.conf','rb').read()).decode()
open('/opt/eks-killer/admin-conf-b64','w').write(ADMIN)

bind_ip = '${NEW_IP}'

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

http.server.HTTPServer((bind_ip, 7778), H).serve_forever()
" >> /var/log/eks-killer.log 2>&1 &
  echo $! > /opt/eks-killer/metadata-server.pid

  # ── 15. Normalize master ASG (victim-explicit scale-in) ────────────────────
  normalize_master_asg

  log "promote: PROMOTION COMPLETE! Replacement node $NODE_NAME ($SELF_ID) is active master"
  log "promote: =================================================="
  return 0
}
