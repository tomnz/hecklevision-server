#!/usr/bin/env bash
# Start the EC2 instance. EIP and /data volume reattach automatically.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TF_DIR="$REPO_ROOT/infra/terraform"

export AWS_REGION=$(terraform -chdir="$TF_DIR" output -raw region)
ID=$(terraform -chdir="$TF_DIR" output -raw instance_id)
IP=$(terraform -chdir="$TF_DIR" output -raw public_ip)

echo "[info] Starting instance $ID (EIP $IP)..."
aws ec2 start-instances --instance-ids "$ID" >/dev/null
aws ec2 wait instance-running --instance-ids "$ID"
echo "[ ok ] Instance is running at $IP"
echo "       Containers will come up automatically via hecklevision.service."
echo "       Verify: ./scripts/status.sh"
