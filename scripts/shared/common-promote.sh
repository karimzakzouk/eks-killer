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
