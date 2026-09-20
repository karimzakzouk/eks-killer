#!/usr/bin/env bash
# Hot-standby master replacement: long-running pyreceiver writes to
# /opt/eks-killer/incoming-bundle.tar, we wait for its signal, then call the
# unified promote_from_bundle() from common.sh. This wrapper used to contain
# a full 200+ line inlined copy of the promotion logic — that lives in
# common.sh:promote_from_bundle now.

set -u
set -o pipefail

source /opt/eks-killer/common-core.sh

mkdir -p /var/log /opt/eks-killer
touch /var/log/eks-killer.log
exec >>/var/log/eks-killer.log 2>&1

log "receiver-master: starting long-running hot-standby loop (is_worker=false)"

while true; do
  while [ ! -s /opt/eks-killer/incoming-bundle.tar ]; do
    sleep 1
  done

  NEW_IP="$(self_private_ip)"
  log "receiver-master: bundle signal received on $NEW_IP — stopping snapshot-loop + watcher before promotion"
  pkill -f snapshot-loop.sh 2>/dev/null || true
  pkill -f watcher-master.sh 2>/dev/null || true

  tar -xf /opt/eks-killer/incoming-bundle.tar common-promote.sh -C /opt/eks-killer/ 2>/dev/null || {
    log "receiver-master: FATAL common-promote.sh missing from bundle, aborting"
    rm -f /opt/eks-killer/incoming-bundle.tar
    exit 1
  }
  source /opt/eks-killer/common-promote.sh

  promote_from_bundle \
    "/opt/eks-killer/incoming-bundle.tar" \
    "$NEW_IP" \
    "false" \
    "" "" \
    "/opt/eks-killer/systemd/eip-lo.service"

  # On promote failure: clear the bundle so we don't tight-loop on a bad file
  rm -f /opt/eks-killer/incoming-bundle.tar
done
