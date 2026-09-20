#!/usr/bin/env bash
# Runs on ordinary (non-promoted) workers only. On interruption notice,
# cordon+drain so pods reschedule elsewhere before this node disappears.
# No etcd, no snapshot dance - the ASG relaunches a replacement on its own.

set -uo pipefail
source /opt/eks-killer/common-core.sh

POLL_INTERVAL=5
FIRED=0
NODE_NAME="$(hostname)"

log "watcher-worker: starting poll loop for node $NODE_NAME"

while true; do
  token="$(imds_token)"
  action="$(curl -s -o /dev/null -w '%{http_code}' \
    -H "X-aws-ec2-metadata-token: ${token}" \
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
