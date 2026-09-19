#!/usr/bin/env bash
# ==============================================================================
# AWS Spot Killer: Trigger a real AWS Spot Interruption via AWS FIS
# ==============================================================================
# Calls AWS Fault Injection Simulator (FIS) action:
#   aws:ec2:send-spot-instance-interruptions
#
# This injects the genuine AWS 2-minute Spot interruption warning into the
# instance's metadata (IMDS) at http://169.254.169.254/latest/meta-data/spot/instance-action
# and terminates the spot instance exactly 2 minutes later from the AWS side.
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TERRAFORM_DIR="${SCRIPT_DIR}/../terraform"

REGION="${AWS_DEFAULT_REGION:-us-east-1}"

echo "[eks-killer] Looking up AWS FIS Spot Killer template..."
EXPERIMENT_ID=""
if [ -d "$TERRAFORM_DIR" ]; then
  EXPERIMENT_ID="$(terraform -chdir="$TERRAFORM_DIR" output -raw spot_killer_experiment_id 2>/dev/null || true)"
fi

if [ -z "$EXPERIMENT_ID" ] || [ "$EXPERIMENT_ID" = "None" ]; then
  EXPERIMENT_ID="$(aws fis list-experiment-templates --region "$REGION" \
    --query "experimentTemplates[?tags.Project=='eks-killer' || contains(description, 'eks-killer')].id | [0]" \
    --output text 2>/dev/null || true)"
fi

if [ -z "$EXPERIMENT_ID" ] || [ "$EXPERIMENT_ID" = "None" ]; then
  echo "Error: Could not find FIS spot killer experiment template." >&2
  echo "Run 'terraform apply' to create the AWS FIS spot killer template." >&2
  exit 1
fi

echo "[eks-killer] Found FIS Template: $EXPERIMENT_ID"
echo "[eks-killer] Starting official AWS Spot Interruption experiment..."

EXP_ID="$(aws fis start-experiment --region "$REGION" \
  --experiment-template-id "$EXPERIMENT_ID" \
  --query "experiment.id" --output text)"

echo "======================================================================"
echo "⚡ REAL AWS SPOT INTERRUPTION INITIATED: $EXP_ID"
echo "======================================================================"
echo "1. AWS has injected the 2-minute warning into the master's IMDS."
echo "2. watcher-master service will detect it via polling."
echo "3. handoff.sh will execute automatic failover."
echo "4. AWS will terminate the old instance in 2 minutes."
echo "======================================================================"

