#!/usr/bin/env bash
# Stop the EC2 instance. EIP stays allocated (and still billed ~$3.60/mo).
# /data volume remains attached and ready for the next start.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TF_DIR="$REPO_ROOT/infra/terraform"

export AWS_REGION=$(terraform -chdir="$TF_DIR" output -raw region)
ID=$(terraform -chdir="$TF_DIR" output -raw instance_id)

echo "[info] Stopping instance $ID..."
aws ec2 stop-instances --instance-ids "$ID" >/dev/null
aws ec2 wait instance-stopped --instance-ids "$ID"
echo "[ ok ] Instance stopped."
echo "       Note: EIP still costs ~\$3.60/mo while the instance is stopped."
