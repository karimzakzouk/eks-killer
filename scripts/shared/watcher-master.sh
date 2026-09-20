#!/usr/bin/env bash
# Polls the spot interruption notice AND the rebalance recommendation every 5s.
# Rebalance can arrive minutes before the 2-minute notice: firing early buys
# wall-clock on the slow (no-worker) path. Fires exactly once; a background
# watchdog removes the spare if no interruption follows (false alarm).

set -uo pipefail
source /opt/eks-killer/common-core.sh

POLL_INTERVAL=5
FIRED=0
WATCHDOG_DELAY=600 # real interruptions land ~2min after notice; later = false alarm

log "watcher-master: starting poll loop (interruption + rebalance)"

while true; do
  token="$(imds_token)"
  action="$(curl -s -o /dev/null -w '%{http_code}' \
    -H "X-aws-ec2-metadata-token: ${token}" \
    http://169.254.169.254/latest/meta-data/spot/instance-action)"
  reb="$(curl -s -o /dev/null -w '%{http_code}' \
    -H "X-aws-ec2-metadata-token: ${token}" \
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
      waction="$(curl -s -o /dev/null -w '%{http_code}' \
        -H "X-aws-ec2-metadata-token: ${wtoken}" \
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
