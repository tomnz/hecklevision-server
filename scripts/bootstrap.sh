#!/usr/bin/env bash
# Idempotent local dev bootstrap for macOS (Homebrew) or Arch-based Linux (pacman).
# - Installs required CLI tools
# - Checks for the dedicated SSH key (generates one only if GENERATE_SSH_KEY=1)
# - Initializes git submodules
# - Installs Ansible collections
# - Warns if AWS CLI isn't authenticated or Terraform state is missing
# - Prints the current public IP for terraform.tfvars

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

SSH_KEY="${SSH_KEY:-$HOME/.ssh/hecklevision_ed25519}"
GENERATE_SSH_KEY="${GENERATE_SSH_KEY:-0}"
TFVARS="infra/terraform/terraform.tfvars"
TFVARS_EXAMPLE="infra/terraform/terraform.tfvars.example"
TFSTATE="infra/terraform/terraform.tfstate"

info()  { printf "\033[1;34m[info]\033[0m %s\n" "$*"; }
warn()  { printf "\033[1;33m[warn]\033[0m %s\n" "$*"; }
ok()    { printf "\033[1;32m[ ok ]\033[0m %s\n" "$*"; }
fail()  { printf "\033[1;31m[fail]\033[0m %s\n" "$*" >&2; exit 1; }

# --- CLI tools ----------------------------------------------------------------

case "$(uname -s)" in
  Darwin)
    command -v brew >/dev/null 2>&1 || fail "Homebrew not found. Install it from https://brew.sh and re-run."
    info "Installing / upgrading CLI tools via Homebrew (idempotent)..."
    brew install --quiet terraform ansible awscli jq git rsync >/dev/null
    command -v session-manager-plugin >/dev/null 2>&1 \
      || warn "Optional: 'brew install --cask session-manager-plugin' for SSM shell access."
    ;;
  Linux)
    command -v pacman >/dev/null 2>&1 \
      || fail "Only Arch-based distros (pacman) are scripted. Install manually: terraform ansible aws-cli-v2 jq git rsync curl."
    info "Installing CLI tools via pacman (idempotent; may prompt for sudo)..."
    sudo pacman -S --needed --noconfirm terraform ansible aws-cli-v2 jq git rsync curl openssh
    command -v session-manager-plugin >/dev/null 2>&1 \
      || warn "Optional: 'paru -S aws-session-manager-plugin' (AUR) for SSM shell access."
    ;;
  *)
    fail "Unsupported OS: $(uname -s)"
    ;;
esac
ok "CLI tools present."

# --- SSH key ------------------------------------------------------------------
# The public key is baked into the aws_key_pair resource, so a second machine
# must reuse the existing keypair rather than mint a new one.

if [[ ! -f "$SSH_KEY" ]]; then
  if [[ "$GENERATE_SSH_KEY" == "1" ]]; then
    info "Generating dedicated SSH keypair at $SSH_KEY"
    ssh-keygen -t ed25519 -N "" -f "$SSH_KEY" -C "hecklevision@$(hostname)"
    ok "Keypair generated."
  else
    fail "SSH key missing at $SSH_KEY. Copy it (and ${SSH_KEY}.pub) from the machine that deployed the stack,
       chmod 600 it, and re-run. For a brand-new deployment, re-run with GENERATE_SSH_KEY=1."
  fi
else
  ok "SSH keypair present at $SSH_KEY"
fi

chmod 600 "$SSH_KEY"
[[ -f "${SSH_KEY}.pub" ]] || fail "Public key missing at ${SSH_KEY}.pub — regenerate with: ssh-keygen -y -f $SSH_KEY > ${SSH_KEY}.pub"

# --- Git submodules -----------------------------------------------------------

info "Initializing git submodules..."
git submodule update --init --recursive
ok "Submodules ready."

# --- Ansible collections ------------------------------------------------------

info "Installing Ansible collections from ansible/requirements.yml..."
ansible-galaxy collection install -r ansible/requirements.yml >/dev/null
ok "Ansible collections installed."

# --- AWS CLI auth check -------------------------------------------------------

if aws sts get-caller-identity >/dev/null 2>&1; then
  identity="$(aws sts get-caller-identity --output json | jq -r '.Arn')"
  ok "AWS CLI authenticated as: $identity"
else
  warn "AWS CLI is not authenticated. Run 'aws login' (or 'aws configure' / 'aws configure sso') before './scripts/apply.sh'."
fi

# --- Terraform state check ----------------------------------------------------

if [[ ! -f "$TFSTATE" ]]; then
  warn "No $TFSTATE. If the stack is already deployed, copy terraform.tfstate from the machine that
       deployed it before running apply.sh — otherwise Terraform will try to create a duplicate stack."
fi

# --- Seed terraform.tfvars if missing ----------------------------------------

if [[ ! -f "$TFVARS" ]]; then
  info "Creating $TFVARS from example (you'll edit allowed_ssh_cidr next)"
  cp "$TFVARS_EXAMPLE" "$TFVARS"
fi

# --- Detect public IP ---------------------------------------------------------

MY_IP=""
for svc in "https://checkip.amazonaws.com" "https://ifconfig.me" "https://icanhazip.com"; do
  MY_IP="$(curl -fsS --max-time 5 "$svc" 2>/dev/null | tr -d '[:space:]' || true)"
  [[ -n "$MY_IP" ]] && break
done

if [[ -z "$MY_IP" ]]; then
  warn "Could not auto-detect your public IP. Find it manually and set allowed_ssh_cidr in $TFVARS."
else
  CIDR="${MY_IP}/32"
  ok "Your public IP appears to be: $CIDR"
  CURRENT="$(grep -E '^allowed_ssh_cidr' "$TFVARS" 2>/dev/null | sed -E 's/.*"(.*)".*/\1/')"
  if [[ "$CURRENT" == "$CIDR" ]]; then
    ok "$TFVARS already pinned to $CIDR"
  else
    echo
    echo "  Paste this into $TFVARS (replacing any existing allowed_ssh_cidr line):"
    echo "      allowed_ssh_cidr = \"$CIDR\""
    echo "  (or just run ./scripts/ssh.sh, which updates it and the SG rule automatically)"
    echo
  fi
fi

echo
ok "Bootstrap complete. Next: edit $TFVARS, then run ./scripts/apply.sh"
