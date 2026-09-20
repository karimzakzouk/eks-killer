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
