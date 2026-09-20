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
DEADLINE=$(( $(date +%s) + 600 ))
# Slow (no-worker) path legitimately needs ~200s+: boot + install + image pulls.
# The old box dies at T+120s regardless; this deadline only bounds how long we
# DRIVE convergence, so it must cover the slow path, not the notice window.

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
        --query "AutoScalingGroups[0].Instances[?InstanceId!='$self_id'].InstanceId | [0]" \
        --output text 2>/dev/null | tr -d ' \t\r\n')"
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
    --launch-template "LaunchTemplateId=${lt_id},Version=\$Latest" \
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

nc_send() {
  # Stream stdin to $ip:$HANDOFF_PORT and require the receiver's OK reply.
  # Returns nonzero on refused/failed/empty delivery instead of failing silently.
  local ip="$1" resp
  resp="$(nc -w 60 "$ip" "$HANDOFF_PORT" 2>/dev/null)"
  if [[ "$resp" != *"OK"* ]]; then
    log "handoff: FATAL bundle delivery to $ip failed (no OK reply)"
    return 1
  fi
  return 0
}

send_bundle() {
  local ip="$1"
  local is_worker="${2:-1}"
  log "handoff: sending bundle to ${ip}:${HANDOFF_PORT}"
  if [ "$is_worker" -eq 1 ]; then
    cat "$BUNDLE" | nc_send "$ip" || return 1
  else
    if [ -f "/opt/eks-killer/bundle/k8s-images.tar" ]; then
      log "handoff: peer-streaming etcd+pki bundle AND k8s-images.tar to fresh instance (uncompressed fast stream)"
      tar -C /opt/eks-killer/bundle -cf - handoff-bundle.tar.gz k8s-images.tar | nc_send "$ip" || return 1
    else
      cat "$BUNDLE" | nc_send "$ip" || return 1
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
    # Record the spare so the watcher's false-alarm watchdog can remove exactly
    # this instance if no interruption ever follows (rebalance false alarm).
    echo "$target_launch_id" > /opt/eks-killer/spare-instance-id
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
  # The replacement master associates the EIP itself after apiserver is healthy.
  # Sleep 20s to allow promotion to complete, then self-terminate.
  log "handoff: bundle acknowledged. Sleeping 20s then self-terminating."
  rm -f /opt/eks-killer/spare-instance-id
  sleep 20
  log "handoff: COMPLETE, self-terminating ($self_id)"
  aws ec2 terminate-instances --instance-ids "$self_id" >/dev/null 2>&1 || true
}

main
