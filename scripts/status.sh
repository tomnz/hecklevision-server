#!/usr/bin/env bash
# Print instance + container status.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TF_DIR="$REPO_ROOT/infra/terraform"

export AWS_REGION=$(terraform -chdir="$TF_DIR" output -raw region)
ID=$(terraform -chdir="$TF_DIR" output -raw instance_id)
IP=$(terraform -chdir="$TF_DIR" output -raw public_ip)
KEY=$(terraform -chdir="$TF_DIR" output -raw ssh_private_key_path)

echo "=== EC2 ==="
aws ec2 describe-instances \
  --instance-ids "$ID" \
  --query 'Reservations[].Instances[].[InstanceId,State.Name,PublicIpAddress,InstanceType,LaunchTime]' \
  --output table

STATE=$(aws ec2 describe-instances --instance-ids "$ID" --query 'Reservations[].Instances[].State.Name' --output text)
if [[ "$STATE" != "running" ]]; then
  echo "[info] Instance is $STATE — skipping container checks."
  exit 0
fi

echo
echo "=== Containers (via SSH to $IP) ==="
ssh -i "$KEY" \
    -o StrictHostKeyChecking=accept-new \
    -o ConnectTimeout=10 \
    "ubuntu@${IP}" \
    'set +e
     echo "--- systemd ---"
     systemctl is-active hecklevision docker 2>&1
     echo
     echo "--- docker ps ---"
     docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
     echo
     echo "--- /data ---"
     df -hT /data 2>/dev/null || echo "/data not mounted"' \
    || echo "[warn] SSH failed (instance may be booting)."
