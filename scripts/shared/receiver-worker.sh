#!/usr/bin/env bash
# Fast-path worker promotion: a worker that received the etcd bundle becomes
# the new master. Delegates to promote_from_bundle() in common.sh with
# is_worker=true (runs kubeadm reset first, waits for etcd restore).

set -u
set -o pipefail

source /opt/eks-killer/common-core.sh

mkdir -p /var/log /opt/eks-killer
touch /var/log/eks-killer.log
exec >>/var/log/eks-killer.log 2>&1

log "receiver-worker: starting long-running fast-path worker-promotion loop (is_worker=true)"

while true; do
  while [ ! -s /opt/eks-killer/incoming-bundle.tar ]; do
    sleep 1
  done

  NEW_IP="$(self_private_ip)"
  log "receiver-worker: bundle signal received on worker $NEW_IP — stopping watcher-worker before promotion"
  pkill -f watcher-worker.sh 2>/dev/null || true

  tar -xf /opt/eks-killer/incoming-bundle.tar common-promote.sh -C /opt/eks-killer/ 2>/dev/null || {
    log "receiver-worker: FATAL common-promote.sh missing from bundle, aborting"
    rm -f /opt/eks-killer/incoming-bundle.tar
    exit 1
  }
  source /opt/eks-killer/common-promote.sh

  promote_from_bundle \
    "/opt/eks-killer/incoming-bundle.tar" \
    "$NEW_IP" \
    "true" \
    "" "" \
    "/opt/eks-killer/systemd/eip-lo.service"

  rm -f /opt/eks-killer/incoming-bundle.tar
done
