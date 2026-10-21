#!/usr/bin/env bash
# SSH into the VM using the dedicated key. Extra args pass through.
#   ./scripts/ssh.sh                         # interactive shell
#   ./scripts/ssh.sh 'docker ps'             # run one command
#
# Before connecting, compare your current public IP to the SG allow-list
# (`allowed_ssh_cidr` in terraform.tfvars) and, if different, do a targeted
# `terraform apply` to update the SG rule and tfvars. Set SKIP_IP_CHECK=1
# to bypass.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TF_DIR="$REPO_ROOT/infra/terraform"
TFVARS="$TF_DIR/terraform.tfvars"

SKIP_IP_CHECK="${SKIP_IP_CHECK:-0}"

info()  { printf "\033[1;34m[info]\033[0m %s\n" "$*" >&2; }
ok()    { printf "\033[1;32m[ ok ]\033[0m %s\n" "$*" >&2; }
warn()  { printf "\033[1;33m[warn]\033[0m %s\n" "$*" >&2; }
fail()  { printf "\033[1;31m[fail]\033[0m %s\n" "$*" >&2; exit 1; }

# --- Optional: check public IP + reconcile SG rule --------------------------

if [[ "$SKIP_IP_CHECK" != "1" && -f "$TFVARS" ]]; then
  MY_IP=""
  for svc in "https://checkip.amazonaws.com" "https://ifconfig.me" "https://icanhazip.com"; do
    MY_IP="$(curl -fsS --max-time 3 "$svc" 2>/dev/null | tr -d '[:space:]' || true)"
    [[ -n "$MY_IP" ]] && break
  done

  if [[ -n "$MY_IP" ]]; then
    NEW_CIDR="${MY_IP}/32"
    CUR_CIDR="$(awk -F'"' '/^allowed_ssh_cidr/{print $2}' "$TFVARS")"
    if [[ -z "$CUR_CIDR" ]]; then
      warn "allowed_ssh_cidr not set in $TFVARS — skipping IP reconcile."
    elif [[ "$CUR_CIDR" != "$NEW_CIDR" ]]; then
      info "Public IP changed: $CUR_CIDR → $NEW_CIDR. Updating SG rule..."

      # Export AWS creds (for the modern `aws login` flow).
      if aws configure export-credentials --format env >/tmp/aws-creds.$$ 2>/dev/null; then
        # shellcheck disable=SC1090
        source /tmp/aws-creds.$$ && rm -f /tmp/aws-creds.$$
      fi

      # Atomically rewrite the tfvars line.
      tmp="$(mktemp "${TFVARS}.XXXXXX")"
      sed -E "s|^allowed_ssh_cidr = \".*\"|allowed_ssh_cidr = \"${NEW_CIDR}\"|" "$TFVARS" >"$tmp"
      mv "$tmp" "$TFVARS"

      # Targeted apply: replace just the SSH ingress rule. `-replace` forces
      # a recreate because cidr_ipv4 on this resource type is ForceNew.
      terraform -chdir="$TF_DIR" apply \
        -input=false \
        -auto-approve \
        -target=aws_vpc_security_group_ingress_rule.ssh \
        -replace=aws_vpc_security_group_ingress_rule.ssh \
        >/dev/null
      ok "SG rule updated to $NEW_CIDR."
    fi
  else
    warn "Could not detect public IP — proceeding with current SG rule."
  fi
fi

# --- SSH --------------------------------------------------------------------

IP=$(terraform -chdir="$TF_DIR" output -raw public_ip)
KEY=$(terraform -chdir="$TF_DIR" output -raw ssh_private_key_path)

exec ssh -i "$KEY" -o StrictHostKeyChecking=accept-new -o ServerAliveInterval=30 "ubuntu@${IP}" "$@"
