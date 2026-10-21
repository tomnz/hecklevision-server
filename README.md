# hecklevision-server

AWS-hosted streaming infrastructure for [Hecklevision](https://github.com/tomnz/hecklevision). Provisioned with Terraform, configured with Ansible. Fronts the Hecklevision Flask web app (e.g. on Heroku), adding same-origin live HLS streaming for overlaid-heckle movie nights.

## Architecture

- Single **t3.medium EC2** instance, Ubuntu 24.04 LTS. ~$30/mo compute if left running (us-west-2 pricing); +$4 EBS, +$3.60 EIP. Comfortably serves ~30 viewers of a 7 Mbps stream — see `instance_type` in `variables.tf` for sizing.
- **Elastic IP** — stable across stop/start/resize.
- Separate **gp3 EBS data volume** mounted at `/data` — persists across instance replacement, `prevent_destroy` on the Terraform resource.
- Two Docker containers managed by a systemd unit + `docker compose`:
  - `rtmp` — [`codingtom/nginx-rtmp-docker:latest`](https://hub.docker.com/r/codingtom/nginx-rtmp-docker) (passthrough / no-transcode). Publishes on `1935/tcp` public; serves HLS on `127.0.0.1:8080` (loopback only). HLS chunks live in a tmpfs so zero disk I/O.
  - `swag` — `linuxserver/swag:latest`. Let's Encrypt on `80/tcp`+`443/tcp`. Config persisted to `/data/swag/config`.

### Request routing

The Ansible-rendered `hecklevision.subdomain.conf` uses `server_name *.<domain> <extra_domains>;` so any cert-covered hostname routes here (no enumeration in nginx for subdomains). SWAG's cert covers exactly the `subdomains` of `domain`, plus any FQDNs in `extra_domains` (all set in `terraform.tfvars` — see [Configuration](#configuration)).

- `https://<sub>.<domain>/live/*` → local `rtmp:8080` (HLS playback, same-origin — avoids CORS)
- `https://<sub>.<domain>/stat*` → local `rtmp:8080/stat` (RTMP stat page)
- `https://<sub>.<domain>/*` (everything else) → `https://<app_upstream>` (the web app)
- `rtmp://<sub>.<domain>:1935/live/<key>` → direct RTMP ingest (no TLS — RTMP protocol limitation)

Security group: SSH restricted to your IP; 80/443/1935 public; 8080 loopback-only. IMDSv2 required. SSH is key-only (Ubuntu AMI default). The instance also has an IAM profile granting `AmazonSSMManagedInstanceCore`, so you can shell in via `aws ssm start-session` if SSH is blocked (see "Known gotchas" re: router IPS).

## Repository layout

```
hecklevision-server/
├── container/     # submodule → tomnz/nginx-rtmp-docker (the RTMP image source)
├── frontend/      # submodule → tomnz/hecklevision       (the Heroku web app)
├── infra/terraform/   # AWS provisioning
├── ansible/           # VM configuration (roles: common, data_volume, docker, app)
└── scripts/           # bootstrap, apply, start/stop, ssh, status
```

The two submodules are independent GitHub repos:

- **`container/`** ([tomnz/nginx-rtmp-docker](https://github.com/tomnz/nginx-rtmp-docker), branch `main`) — Alpine 3.24 + packaged nginx + `nginx-mod-rtmp`. Supports a `TRANSCODE` build arg (default `false`) that picks `nginx/nginx.conf` vs `nginx/nginx.transcode.conf`. Runtime env vars (`HTTP_PORT`, `RTMP_PORT`, `HLS_FRAGMENT`, `HLS_PLAYLIST_LENGTH`, `HLS_SYNC`) allow tuning without rebuilding. Publish pipeline: `container/scripts/publish.sh` builds both variants and pushes to Docker Hub with dated + `:latest` + `:transcode` + `:archive-*` tags.
- **`frontend/`** ([tomnz/hecklevision](https://github.com/tomnz/hecklevision), branch `master` — kept on `master` so Heroku auto-deploys from push). Flask app, deployed by `git push origin master`.

## Prerequisites

- macOS with Homebrew, or an Arch-based Linux (Arch, CachyOS, …) with pacman
- An AWS account with credentials available to the AWS CLI. Any of these works: classic `aws configure`, `aws configure sso`, or the modern `aws login` (root user session). `apply.sh` calls `aws configure export-credentials --format env` to bridge temporary creds into Terraform's provider chain.
- A place to manage DNS A records for your SWAG subdomains. Not Route53 — we assume DNS is elsewhere.
- Optional: `session-manager-plugin` for SSM shell access:
  ```bash
  brew install --cask session-manager-plugin   # macOS
  paru -S aws-session-manager-plugin           # Arch (AUR)
  ```

## First-time setup

```bash
./scripts/bootstrap.sh
```

Idempotent. Installs CLI tools (`terraform ansible awscli jq git rsync`) via brew or pacman, checks for `~/.ssh/hecklevision_ed25519` (generates it only with `GENERATE_SSH_KEY=1`, for a brand-new deployment), runs `git submodule update --init --recursive`, installs Ansible collections, checks AWS auth (warn-only), and prints your current public IP for `terraform.tfvars`.

Edit `infra/terraform/terraform.tfvars` (already seeded from the example): set your region, domain and web app host, and the `allowed_ssh_cidr` value the script printed. Then create DNS A records for each hostname once `apply.sh` has allocated the Elastic IP (see [Configuration](#configuration)).

## Configuration

Everything deployment-specific lives in `infra/terraform/terraform.tfvars`, which is gitignored. `apply.sh` passes the values through Terraform outputs to Ansible, so there's nothing to edit under `ansible/`.

| Variable | Required | Purpose |
|---|---|---|
| `region` | yes | AWS region |
| `domain` | yes | Base domain; hostnames are `<subdomain>.<domain>` |
| `app_upstream` | yes | Host of the Hecklevision web app, e.g. `my-app.herokuapp.com` |
| `allowed_ssh_cidr` | yes | Your public IP as `/32`; `ssh.sh` keeps it current |
| `subdomains` | no (`["stream"]`) | Hostnames under `domain` on the cert |
| `extra_domains` | no (`[]`) | Full hostnames on other domains/TLDs to add to the cert |
| `timezone` | no (`UTC`) | VM and container timezone (log timestamps) |
| `availability_zone` | no (region's `a` zone) | AZ for the instance and data volume |
| `instance_type`, `image_tag`, volume sizes | no | See `variables.tf` |

SWAG gets its certificates with Let's Encrypt HTTP-01 validation, so every hostname needs a DNS A record pointing at the Elastic IP (`terraform -chdir=infra/terraform output -raw public_ip`) before the playbook runs. On a brand-new deployment that means: `SKIP_ANSIBLE=1 ./scripts/apply.sh`, create the DNS records, then `./scripts/apply.sh`.

### Adding a second machine

The stack is managed from local files that aren't in git. Copy these from the machine that already manages it before running `apply.sh`:

| File | Why |
|---|---|
| `~/.ssh/hecklevision_ed25519` + `.pub` | Public key is baked into `aws_key_pair`; a new key would replace it and lock Ansible out of the existing VM. `chmod 600` the private key. |
| `infra/terraform/terraform.tfstate` | Without it Terraform plans a second, duplicate stack. |
| `infra/terraform/terraform.tfvars` | All deployment settings. `allowed_ssh_cidr` gets rewritten by `ssh.sh` to whichever machine connected last. |

Local state means only one machine should run Terraform at a time — whoever ran last holds the authoritative `terraform.tfstate`, so copy it back before switching. Migrating to the S3 backend in `versions.tf` removes this.

## Provision + configure

```bash
./scripts/apply.sh
```

1. Exports temporary AWS credentials into the environment.
2. `terraform apply` — creates EIP, EBS data volume, SG, IAM role for SSM, EC2 instance, attachments.
3. Renders `ansible/inventory.ini` from terraform outputs.
4. Runs `ansible-playbook site.yml` — installs Docker, mounts `/data`, renders the compose file + systemd unit + SWAG proxy-conf, pulls images, brings the stack up.

Re-run it any time. Both layers are idempotent.

## Day-to-day

| Task | Command |
|---|---|
| Open a shell on the VM | `./scripts/ssh.sh` — auto-updates the SG allow-list if your home IP changed |
| Shell via SSM (bypasses port 22) | `aws ssm start-session --region $(terraform -chdir=infra/terraform output -raw region) --target $(terraform -chdir=infra/terraform output -raw instance_id)` |
| Check health | `./scripts/status.sh` |
| Stop the VM (EIP + data volume kept) | `./scripts/stop.sh` |
| Start the VM again | `./scripts/start.sh` |
| Update containers to latest image | `./scripts/apply.sh --tags update` |
| Upgrade all OS packages (incl. Docker), reboot if needed | `./scripts/apply.sh -- --tags upgrade` |
| Re-run Ansible only (skip TF) | `SKIP_TF=1 ./scripts/apply.sh` |
| Resize instance | edit `instance_type` in tfvars or variables.tf, `./scripts/apply.sh` (~90s in-place stop/modify/start) |
| Rebuild + republish the RTMP image | `cd container && ./scripts/publish.sh` |
| Deploy a frontend change | `cd frontend && git push` (Heroku auto-deploys from `master`) |
| Use the web app while the VM is stopped | Go straight to `https://<app_upstream>`. `/submit`, `/messages` and `/messages?history` work; the player has no stream. |

The compose stack comes back automatically on boot via `hecklevision.service` (systemd).

## Stream latency tuning

Viewer delay comes from three settings that only work together:

| Setting | Where | Current |
|---|---|---|
| Keyframe interval | OBS → Settings → Output → Streaming | 1s (23 frames at 23.976 fps = 0.959s) |
| `hls_fragment`, `hls_playlist_length` | `ansible/group_vars/all.yml` | `900ms`, `16s` |
| `liveSyncDurationCount`, `liveMaxLatencyDurationCount` | `frontend/static/player.js` | 3, 10 (segments) |

A segment closes on the first keyframe at or past `hls_fragment`, so the OBS keyframe interval sets the real segment length; `hls_fragment` must sit just below it, or segments double. The player counts in segments: it targets `liveSyncDurationCount` behind live and jumps forward past `liveMaxLatencyDurationCount`, which must stay inside the playlist. Cast receivers ignore `player.js` and only benefit from shorter segments.

## RTMP image variants

Two tags live on Docker Hub under `codingtom/nginx-rtmp-docker`, both built from the same codebase via `TRANSCODE` build arg:

- `:latest` — passthrough. HLS written directly in the live RTMP application; ffmpeg not in the critical path. Recommended.
- `:transcode` — re-encodes source into multiple HLS variants (720p/480p/360p/240p). Needs serious CPU (t3.small or t3.medium will not be enough — bump to `c6i.large` or similar).

Pin to a dated tag (`:YYYY-MM-DD-no-transcode` / `:YYYY-MM-DD-transcode`) in tfvars for reproducibility. `:archive-*` tags preserve the 2020/2021 pre-modernization builds in case you need to roll back.

## Known gotchas

- **EIPs cost ~$3.60/mo even on stopped instances.** AWS has billed all allocated public IPv4 addresses since Feb 2024. If you want to pause billing entirely, destroy and re-create the EIP (you'll get a new IP and need to update DNS).
- **`prevent_destroy` on the data volume** is a safety net — `terraform destroy` will fail until you temporarily comment out the lifecycle block in `infra/terraform/main.tf`. Intentional.
- **SSH CIDR drift**: `scripts/ssh.sh` auto-detects your public IP and runs a targeted `terraform apply` on the SSH ingress rule if it's changed. Set `SKIP_IP_CHECK=1` to skip that.
- **Home router IPS (e.g. UniFi) can silently drop outbound SSH to AWS EIPs** — it flags cloud-IP SSH as suspicious. Symptoms: port 22 timeouts while 80/443/1935 reach the instance fine. Fallback: allowlist the destination in the router, or use `aws ssm start-session` (bypasses port 22 entirely).
- **Docker Hub pull rate limits** aren't an issue for a single VM. Keep in mind if you ever add CI that pulls heavily.
- **1935/udp is not opened.** nginx-rtmp is TCP-only. Add SRT (different image) if you ever need a UDP-based protocol.
- **No automated backups.** Future work: `aws_dlm_lifecycle_policy` on the `Role=data` tag for nightly snapshots.
- **Terraform state is local** — backed up only on the machine that runs Terraform. If that machine dies the stack keeps running but becomes unmanaged. Migrate to the commented-out S3 backend in `versions.tf` if that ever matters.
- **`aws login` creds**: `apply.sh` exports them via `aws configure export-credentials` because Terraform's AWS provider credential chain doesn't grok the session cache directly. Expires after ~1 hour; re-run `apply.sh` and it refreshes automatically.

## Future improvements (non-blocking)

- S3 + DynamoDB backend for Terraform state
- `aws_dlm_lifecycle_policy` snapshot schedule on the data volume
- Route53 for DNS so cutover is part of `terraform apply`
- Multi-arch RTMP image (`linux/arm64` in `container/scripts/publish.sh`) to unlock cheaper Graviton instances like `t4g.small`
