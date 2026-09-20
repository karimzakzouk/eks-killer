#!/usr/bin/env bash
# Runs forever on the master. Every SNAPSHOT_INTERVAL seconds, takes a fresh
# etcd snapshot and re-tars the PKI/manifest bundle needed to reconstruct
# this control plane elsewhere. Kept purely local - no S3, no network calls.

set -uo pipefail
source /opt/eks-killer/common.sh

SNAPSHOT_INTERVAL="${SNAPSHOT_INTERVAL:-12}"
BUNDLE_DIR="/opt/eks-killer/bundle"
STAGING_DIR="/opt/eks-killer/bundle.staging"

mkdir -p "$BUNDLE_DIR" "$STAGING_DIR"

while true; do
  ETCDCTL_API=3 etcdctl snapshot save "${STAGING_DIR}/etcd-snapshot.db" \
    --endpoints=https://127.0.0.1:2379 \
    --cacert=/etc/kubernetes/pki/etcd/ca.crt \
    --cert=/etc/kubernetes/pki/etcd/server.crt \
    --key=/etc/kubernetes/pki/etcd/server.key \
    >>/var/log/eks-killer.log 2>&1

  if [ $? -eq 0 ]; then
    cp -a /etc/kubernetes/pki "${STAGING_DIR}/pki"
    cp -a /etc/kubernetes/manifests "${STAGING_DIR}/manifests"
    cp /etc/kubernetes/admin.conf "${STAGING_DIR}/admin.conf"
    cp /etc/kubernetes/scheduler.conf "${STAGING_DIR}/scheduler.conf"
    cp /etc/kubernetes/controller-manager.conf "${STAGING_DIR}/controller-manager.conf"
    [ -f /etc/kubernetes/kubelet.conf ] && cp /etc/kubernetes/kubelet.conf "${STAGING_DIR}/kubelet.conf"
    if [ -d /var/lib/kubelet ]; then
      mkdir -p "${STAGING_DIR}/var-lib-kubelet"
      [ -f /var/lib/kubelet/config.yaml ] && cp /var/lib/kubelet/config.yaml "${STAGING_DIR}/var-lib-kubelet/config.yaml"
      [ -f /var/lib/kubelet/kubeadm-flags.env ] && cp /var/lib/kubelet/kubeadm-flags.env "${STAGING_DIR}/var-lib-kubelet/kubeadm-flags.env"
    fi
    self_private_ip >"${STAGING_DIR}/origin-private-ip.txt"
    hostname >"${STAGING_DIR}/origin-node-name.txt"

    tar -C "$STAGING_DIR" -czf "${BUNDLE_DIR}/handoff-bundle.tar.gz.new" .
    mv "${BUNDLE_DIR}/handoff-bundle.tar.gz.new" "${BUNDLE_DIR}/handoff-bundle.tar.gz"
    rm -rf "${STAGING_DIR}/pki" "${STAGING_DIR}/manifests" "${STAGING_DIR}/var-lib-kubelet"

    # Pre-cache control plane container images once for instant peer-streaming on fallback
    if [ ! -f "${BUNDLE_DIR}/k8s-images.tar" ]; then
      local_images="$(ctr -n k8s.io images list -q 2>/dev/null || true)"
      if [ -n "$local_images" ]; then
        log "snapshot-loop: caching control-plane container images for peer streaming"
        ctr -n k8s.io images export "${BUNDLE_DIR}/k8s-images.tar.new" $local_images >>/var/log/eks-killer.log 2>&1 || true
        if [ -f "${BUNDLE_DIR}/k8s-images.tar.new" ]; then
          mv "${BUNDLE_DIR}/k8s-images.tar.new" "${BUNDLE_DIR}/k8s-images.tar"
          log "snapshot-loop: container image cache ready"
        fi
      fi
    fi
  else
    log "snapshot-loop: etcdctl snapshot save failed, keeping previous bundle"
  fi

  sleep "$SNAPSHOT_INTERVAL"
done
