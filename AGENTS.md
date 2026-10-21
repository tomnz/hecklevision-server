# AGENTS.md

Short orientation for AI agents working in this repo. Full docs: `README.md`.

> **Keep this file honest.** If you change something it describes (add/remove a script, change the auth flow, rewire submodules, etc.), update this file in the same change. Stale orientation is worse than none.

## What this is

Terraform + Ansible stack that runs a single EC2 VM with two Docker containers: `nginx-rtmp` (RTMP ingest + HLS) and SWAG (Let's Encrypt + reverse proxy). Fronts the [tomnz/hecklevision](https://github.com/tomnz/hecklevision) Flask app (e.g. on Heroku), stitching same-origin HLS onto the web app's hostnames.

If `CLAUDE.local.md` exists (gitignored), read it too: it holds the specifics of the operator's own deployment.

## Submodules

- `container/` → `tomnz/nginx-rtmp-docker` — Dockerfile + nginx config for the RTMP image. Has its own `scripts/publish.sh` that pushes to Docker Hub.
- `frontend/` → `tomnz/hecklevision` — the Heroku-hosted Flask frontend. **Branch is `master`** and pushing to `master` triggers a Heroku auto-deploy.

Run `git submodule update --init --recursive` after cloning.

## Scripts (all in `scripts/`)

| Script | Purpose |
|---|---|
| `bootstrap.sh` | One-time local setup (macOS via brew, Arch/CachyOS via pacman): tool installs, ssh key check, submodule init, galaxy collections |
| `apply.sh` | Main deploy — exports AWS creds, `terraform apply`, renders Ansible inventory, runs playbook. `--tags update` for image refresh; `--tags upgrade` for a full apt upgrade + reboot if required (never runs otherwise); `SKIP_TF=1` to skip Terraform |
| `ssh.sh` | SSH to the VM; auto-reconciles `allowed_ssh_cidr` SG rule if your public IP changed |
| `status.sh` | EC2 state + container health |
| `start.sh` / `stop.sh` | `aws ec2 start/stop-instances`. Manual console use is fine too |

## Configuration

All deployment-specific values (region, domain, subdomains, extra domains, web app host, timezone, SSH CIDR) live in the gitignored `infra/terraform/terraform.tfvars`. `apply.sh` passes them through Terraform outputs to Ansible as JSON extra-vars; `ansible/group_vars/all.yml` holds only neutral defaults. Keep it that way: this repo is public, so never commit real domains, IPs, account IDs or hostnames.

## Key gotchas

- **AWS auth**: `aws login` gives a temporary STS session. `apply.sh` bridges creds via `aws configure export-credentials` because Terraform's provider chain doesn't grok the session cache. Session expires ~1hr; re-run `apply.sh` refreshes.
- **The deployment's hostnames are down whenever the VM is stopped** (SWAG fronts everything). The web app is still reachable directly at `https://<app_upstream>` — use that to check a frontend deploy or test submit/history without starting the VM. The player there has no stream.
- **Port 22 can be flaky** — home router IPS (e.g. UniFi) sometimes drops SSH to cloud EIPs. Instance has an IAM profile for SSM, so `aws ssm start-session --target <instance-id>` is the fallback.
- **Terraform state is local & gitignored**. `terraform.tfvars` too. The `.example` is committed. A second machine needs `terraform.tfstate`, `terraform.tfvars`, and `~/.ssh/hecklevision_ed25519{,.pub}` copied over — see README "Adding a second machine".
- **HLS latency settings are coupled across three places**: the OBS keyframe interval (sets real segment length), `hls_fragment` / `hls_playlist_length` in `ansible/group_vars/all.yml`, and the live-edge segment counts in `frontend/static/player.js` (which must fit inside the playlist). Change them together; comments in both files point at each other. Cast receivers ignore `player.js` and only benefit from shorter segments.
- **`prevent_destroy` is set on the data EBS volume**. `terraform destroy` will fail unless you comment that out — intentional safety net.
