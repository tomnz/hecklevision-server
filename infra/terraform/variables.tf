variable "region" {
  description = "AWS region."
  type        = string
}

variable "availability_zone" {
  description = "AZ to pin both the instance and the data EBS volume in (EBS is AZ-scoped). Defaults to the region's \"a\" zone."
  type        = string
  default     = null
}

variable "project" {
  description = "Name prefix for resources and tags."
  type        = string
  default     = "hecklevision"
}

variable "instance_type" {
  description = "EC2 instance type. Viewer capacity is bound by the sustained network baseline: t3.medium (~256 Mbps) handles ~30 viewers of a 7 Mbps passthrough stream; t3.large (~512 Mbps) roughly doubles that."
  type        = string
  default     = "t3.medium"
}

variable "root_volume_size_gb" {
  description = "Root EBS volume size in GB (OS + Docker)."
  type        = number
  default     = 30
}

variable "data_volume_size_gb" {
  description = "Size of the persistent /data EBS volume in GB."
  type        = number
  default     = 20
}

variable "data_volume_iops" {
  description = "IOPS for the data gp3 volume. gp3 baseline is 3000."
  type        = number
  default     = 3000
}

variable "data_volume_throughput" {
  description = "Throughput (MiB/s) for the data gp3 volume. gp3 baseline is 125."
  type        = number
  default     = 125
}

variable "allowed_ssh_cidr" {
  description = "CIDR permitted to SSH into the instance (your home IP /32). Set in terraform.tfvars; bootstrap.sh prints your current public IP."
  type        = string
}

variable "ssh_public_key_path" {
  description = "Path to the dedicated SSH public key uploaded to AWS as the EC2 key pair."
  type        = string
  default     = "~/.ssh/hecklevision_ed25519.pub"
}

variable "ssh_private_key_path" {
  description = "Path to the private key that matches ssh_public_key_path. Passed through to Ansible via the generated inventory."
  type        = string
  default     = "~/.ssh/hecklevision_ed25519"
}

variable "image_tag" {
  description = "Docker Hub tag for codingtom/nginx-rtmp-docker. 'latest' is the passthrough build; 'transcode' is the multi-bitrate build; use a dated tag (e.g. '2026-04-15-no-transcode') to pin."
  type        = string
  default     = "latest"
}

variable "domain" {
  description = "Base domain for SWAG Let's Encrypt certs, e.g. \"example.com\"."
  type        = string
}

variable "subdomains" {
  description = "Subdomains to include in the SWAG cert (ONLY_SUBDOMAINS=true). The SWAG proxy-conf is a default_server that handles any hostname whose cert SAN covers — so to add/remove a hostname, just edit this list."
  type        = list(string)
  default     = ["stream"]
}

variable "extra_domains" {
  description = "Additional FQDNs (other domains/TLDs) to include on the SWAG cert. DNS for each must point at the Elastic IP before apply, or HTTP-01 validation fails."
  type        = list(string)
  default     = []
}

variable "app_upstream" {
  description = "Host of the Hecklevision web app that SWAG proxies everything except /live/ and /stat to, e.g. \"my-app.herokuapp.com\"."
  type        = string
}

variable "timezone" {
  description = "Timezone for the VM and containers (affects log timestamps), e.g. \"America/New_York\"."
  type        = string
  default     = "UTC"
}
