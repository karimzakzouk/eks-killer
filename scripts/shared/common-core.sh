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


ESKSUM_PSK="eks-killer-handoff-psk-v1"

# Framed, checksummed + HMAC-authenticated bundle transfer:
# Writes a 257-byte ASCII header (ESKSUM magic + SHA-256 + size + HMAC-SHA256)
# followed by raw file contents to stdout. Receivers validate header,
# checksum, AND HMAC before accepting the payload. Header is human-visible
# for tcpdump debug.
frame_send() {
  local file="$1"
  local size checksum hmac
  size="$(stat -c '%s' "$file" 2>/dev/null || wc -c < "$file")"
  checksum="$(sha256sum "$file" | awk '{print $1}')"
  # HMAC-SHA256(PSK, sha256 || size) — prevents VPC-internal bundle spoofing.
  hmac="$(python3 -c "
import hmac, hashlib, sys
p = sys.argv[1].encode()
m = (sys.argv[2] + sys.argv[3]).encode()
print(hmac.new(p, m, hashlib.sha256).hexdigest())
" "$ESKSUM_PSK" "$checksum" "$size")"
  # Build a 256-byte fixed header: left-aligned fields, right-padded with spaces.
  # Layout: "ESKSUM sha256=<64hex> size=<19dec> hmac=<64hex> <padding>\n"
  #   prefix        = "ESKSUM sha256="                   (14 bytes)
  #   checksum field = %-64s right-padded                (64 bytes)
  #   midfix1       = " size="                            (6 bytes)
  #   size field    = %-19s right-padded                 (19 bytes)
  #   midfix2       = " hmac="                            (6 bytes)
  #   hmac field    = %-64s right-padded                (64 bytes)
  #   trailing gap  = 81 spaces                          (81 bytes)
  #   header total  = 14+64+6+19+6+64+81                (256 bytes)
  #   + newline byte = 257 total framing bytes.
  printf "ESKSUM sha256=%-64s size=%-19s hmac=%-64s%83s" "$checksum" "$size" "$hmac" "" | head -c 256
  printf "\n"
  cat "$file"
}

associate_eip_bounded() {
  local alloc_id="$1" inst_id="$2" region="${3:-$AWS_DEFAULT_REGION}" eip_public="${4:-<unknown>}"
  local i
  for i in $(seq 1 120); do
    if aws ec2 associate-address --region "$region" --instance-id "$inst_id" \
      --allocation-id "$alloc_id" --allow-reassociation >>/var/log/eks-killer.log 2>&1; then
      log "associate_eip: EIP ${eip_public} associated to $inst_id (attempt $i)"
      return 0
    fi
    sleep 5
  done
  log "associate_eip: FATAL EIP $alloc_id not associated to $inst_id after 10 minutes"
  return 1
}
