locals {
  availability_zone = coalesce(var.availability_zone, "${var.region}a")
}

########################################
# Data sources
########################################

data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
  }

  filter {
    name   = "architecture"
    values = ["x86_64"]
  }

  filter {
    name   = "root-device-type"
    values = ["ebs"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default_az" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }

  filter {
    name   = "availability-zone"
    values = [local.availability_zone]
  }

  filter {
    name   = "default-for-az"
    values = ["true"]
  }
}

########################################
# Key pair
########################################

resource "aws_key_pair" "hecklevision" {
  key_name   = "${var.project}-key"
  public_key = file(pathexpand(var.ssh_public_key_path))
}

########################################
# Security group
########################################

resource "aws_security_group" "hecklevision" {
  name        = "${var.project}-sg"
  description = "Allow SSH (restricted), HTTP/HTTPS (public), RTMP (public)."
  vpc_id      = data.aws_vpc.default.id

  tags = {
    Name = "${var.project}-sg"
  }
}

resource "aws_vpc_security_group_ingress_rule" "ssh" {
  security_group_id = aws_security_group.hecklevision.id
  description       = "SSH from operator IP"
  cidr_ipv4         = var.allowed_ssh_cidr
  ip_protocol       = "tcp"
  from_port         = 22
  to_port           = 22
}

resource "aws_vpc_security_group_ingress_rule" "http" {
  security_group_id = aws_security_group.hecklevision.id
  description       = "HTTP for Lets Encrypt HTTP-01 and redirect"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = 80
  to_port           = 80
}

resource "aws_vpc_security_group_ingress_rule" "https" {
  security_group_id = aws_security_group.hecklevision.id
  description       = "HTTPS served by SWAG"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
}

resource "aws_vpc_security_group_ingress_rule" "rtmp" {
  security_group_id = aws_security_group.hecklevision.id
  description       = "RTMP ingest"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = 1935
  to_port           = 1935
}

resource "aws_vpc_security_group_egress_rule" "all" {
  security_group_id = aws_security_group.hecklevision.id
  description       = "All outbound"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

########################################
# Data EBS volume (persists across instance replacement)
########################################

resource "aws_ebs_volume" "data" {
  availability_zone = local.availability_zone
  size              = var.data_volume_size_gb
  type              = "gp3"
  iops              = var.data_volume_iops
  throughput        = var.data_volume_throughput
  encrypted         = true

  tags = {
    Name = "${var.project}-data"
    Role = "data"
  }

  lifecycle {
    prevent_destroy = true
    # Allow manual growth (aws ec2 modify-volume) without forcing Terraform to act.
    ignore_changes = [size]
  }
}

########################################
# Elastic IP (static, stays associated across stop/start)
########################################

resource "aws_eip" "hecklevision" {
  domain = "vpc"

  tags = {
    Name = "${var.project}-eip"
  }
}

########################################
# IAM role + instance profile for SSM Session Manager
########################################
# Gives the instance permission to talk to the SSM service, so we can open a
# shell via `aws ssm start-session --target <instance>` without SSH or any
# public port 22 exposure. The SSM Agent is pre-installed on Canonical's
# Ubuntu AMIs.

resource "aws_iam_role" "ssm" {
  name = "${var.project}-ssm-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "ec2.amazonaws.com"
      }
      Action = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ssm_core" {
  role       = aws_iam_role.ssm.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "ssm" {
  name = "${var.project}-ssm-profile"
  role = aws_iam_role.ssm.name
}

########################################
# EC2 instance
########################################

resource "aws_instance" "hecklevision" {
  ami                         = data.aws_ami.ubuntu.id
  instance_type               = var.instance_type
  availability_zone           = local.availability_zone
  subnet_id                   = data.aws_subnets.default_az.ids[0]
  key_name                    = aws_key_pair.hecklevision.key_name
  vpc_security_group_ids      = [aws_security_group.hecklevision.id]
  associate_public_ip_address = true
  iam_instance_profile        = aws_iam_instance_profile.ssm.name

  root_block_device {
    volume_type           = "gp3"
    volume_size           = var.root_volume_size_gb
    encrypted             = true
    delete_on_termination = true
  }

  metadata_options {
    http_tokens   = "required" # IMDSv2
    http_endpoint = "enabled"
  }

  credit_specification {
    cpu_credits = "standard" # no surprise burst bills; nginx passthrough stays under baseline
  }

  # Minimal bootstrap — hostname only. Ubuntu 24.04 ships with python3 for Ansible.
  user_data = <<-EOF
    #!/bin/bash
    hostnamectl set-hostname ${var.project}
  EOF

  tags = {
    Name = var.project
  }

  lifecycle {
    # Don't rebuild on new Ubuntu AMI releases. Use -replace to force.
    ignore_changes = [ami]
  }
}

########################################
# EBS attachment (separate from instance — survives instance replacement)
########################################

resource "aws_volume_attachment" "data" {
  device_name = "/dev/sdf"
  volume_id   = aws_ebs_volume.data.id
  instance_id = aws_instance.hecklevision.id

  # Lets `terraform destroy` / replace cleanly detach by stopping the instance first.
  stop_instance_before_detaching = true
}

########################################
# EIP association
########################################

resource "aws_eip_association" "hecklevision" {
  allocation_id = aws_eip.hecklevision.id
  instance_id   = aws_instance.hecklevision.id
}
