output "instance_id" {
  description = "EC2 instance ID."
  value       = aws_instance.hecklevision.id
}

output "public_ip" {
  description = "Static Elastic IP — stable across stop/start."
  value       = aws_eip.hecklevision.public_ip
}

output "data_volume_id" {
  description = "ID of the persistent /data EBS volume."
  value       = aws_ebs_volume.data.id
}

output "ssh_private_key_path" {
  description = "Path to the private key that matches the uploaded public key."
  value       = pathexpand(var.ssh_private_key_path)
}

output "ssh_command" {
  description = "Copy-paste SSH command."
  value       = "ssh -i ${pathexpand(var.ssh_private_key_path)} ubuntu@${aws_eip.hecklevision.public_ip}"
}

output "image_tag" {
  description = "Docker image tag passed through to Ansible."
  value       = var.image_tag
}

output "domain" {
  description = "Base domain for SWAG."
  value       = var.domain
}

output "subdomains" {
  description = "Subdomains included in SWAG certs."
  value       = var.subdomains
}

output "extra_domains" {
  description = "Additional FQDNs included in SWAG certs."
  value       = var.extra_domains
}

output "app_upstream" {
  description = "Web app host that SWAG proxies to."
  value       = var.app_upstream
}

output "timezone" {
  description = "Timezone for the VM and containers."
  value       = var.timezone
}

output "region" {
  description = "AWS region the stack lives in. Scripts export it as AWS_REGION so the CLI default region doesn't matter."
  value       = var.region
}
