terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

# ── VPC & Networking ──────────────────────────────────────────────────────────

resource "aws_vpc" "lab" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = { Name = "gpu-infra-vpc" }
}

resource "aws_internet_gateway" "lab" {
  vpc_id = aws_vpc.lab.id
  tags   = { Name = "gpu-infra-igw" }
}

resource "aws_subnet" "lab" {
  vpc_id                  = aws_vpc.lab.id
  cidr_block              = "10.0.1.0/24"
  availability_zone       = var.aws_az
  map_public_ip_on_launch = true
  tags                    = { Name = "gpu-infra-subnet" }
}

resource "aws_route_table" "lab" {
  vpc_id = aws_vpc.lab.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.lab.id
  }
  tags = { Name = "gpu-infra-rt" }
}

resource "aws_route_table_association" "lab" {
  subnet_id      = aws_subnet.lab.id
  route_table_id = aws_route_table.lab.id
}

# ── Security Group ────────────────────────────────────────────────────────────
# Single node: control plane + worker on one instance
# Calico CNI (no IPIP protocol 4 needed)
# EC2 Instance Connect range included for browser-based SSH

resource "aws_security_group" "gpu_node" {
  name   = "gpu-infra-node-sg"
  vpc_id = aws_vpc.lab.id

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.allowed_ssh_cidr]
    description = "SSH from operator IP"
  }

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["18.206.107.24/29"]
    description = "EC2 Instance Connect us-east-1"
  }

  ingress {
    from_port   = 6443
    to_port     = 6443
    protocol    = "tcp"
    cidr_blocks = [var.allowed_ssh_cidr, "10.0.0.0/16"]
    description = "kube-apiserver"
  }

  ingress {
    from_port   = 2379
    to_port     = 2380
    protocol    = "tcp"
    cidr_blocks = ["10.0.0.0/16"]
    description = "etcd"
  }

  ingress {
    from_port   = 10250
    to_port     = 10252
    protocol    = "tcp"
    cidr_blocks = ["10.0.0.0/16"]
    description = "kubelet"
  }

  ingress {
    from_port   = 30000
    to_port     = 32767
    protocol    = "tcp"
    cidr_blocks = [var.allowed_ssh_cidr]
    description = "NodePort services"
  }

  ingress {
    from_port   = 179
    to_port     = 179
    protocol    = "tcp"
    cidr_blocks = ["10.0.0.0/16"]
    description = "Calico BGP"
  }

  ingress {
    from_port   = 9090
    to_port     = 9090
    protocol    = "tcp"
    cidr_blocks = ["10.0.0.0/16"]
    description = "Prometheus"
  }

  ingress {
    from_port   = 9400
    to_port     = 9400
    protocol    = "tcp"
    cidr_blocks = ["10.0.0.0/16"]
    description = "DCGM exporter"
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "gpu-infra-node-sg" }
}

# ── EC2 Instance ──────────────────────────────────────────────────────────────
# Single node: g5.xlarge runs both control plane and workloads
# containerd pinned to 1.7.29 (2.x breaks CRI with Kubernetes 1.31)

resource "aws_instance" "gpu_node" {
  ami                    = var.ubuntu_ami
  instance_type          = "g5.xlarge"
  key_name               = var.key_name
  subnet_id              = aws_subnet.lab.id
  vpc_security_group_ids = [aws_security_group.gpu_node.id]
  source_dest_check      = false

  metadata_options {
    http_tokens                 = "required"
    http_endpoint               = "enabled"
    http_put_response_hop_limit = 1
  }

  root_block_device {
    volume_type           = "gp3"
    volume_size           = 50
    encrypted             = true
    delete_on_termination = true
  }

  user_data = base64encode(file("${path.module}/bootstrap-gpu-node.sh"))

  tags = {
    Name = "gpu-infra-gpu-node"
    Role = "control-plane-worker"
  }
}

# ── EIP ───────────────────────────────────────────────────────────────────────

resource "aws_eip" "gpu_node" {
  instance = aws_instance.gpu_node.id
  domain   = "vpc"
  tags     = { Name = "gpu-infra-node-eip" }
}

# ── Auto-stop Scheduler ───────────────────────────────────────────────────────
# g5.xlarge: ~$1.006/hr running, ~$0.005/hr stopped (EIP only)

resource "aws_iam_role" "scheduler" {
  name = "gpu-infra-scheduler-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "scheduler.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "scheduler" {
  role = aws_iam_role.scheduler.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["ec2:StopInstances", "ec2:StartInstances"]
      Resource = aws_instance.gpu_node.arn
    }]
  })
}

resource "aws_scheduler_schedule" "gpu_stop" {
  name                         = "gpu-infra-stop"
  schedule_expression          = var.gpu_node_stop_schedule
  schedule_expression_timezone = "UTC"
  flexible_time_window { mode = "OFF" }
  state = "ENABLED"
  target {
    arn      = "arn:aws:scheduler:::aws-sdk:ec2:stopInstances"
    role_arn = aws_iam_role.scheduler.arn
    input    = jsonencode({ InstanceIds = [aws_instance.gpu_node.id] })
  }
}

resource "aws_scheduler_schedule" "gpu_start" {
  name                         = "gpu-infra-start"
  schedule_expression          = var.gpu_node_start_schedule
  schedule_expression_timezone = "UTC"
  flexible_time_window { mode = "OFF" }
  state = "ENABLED"
  target {
    arn      = "arn:aws:scheduler:::aws-sdk:ec2:startInstances"
    role_arn = aws_iam_role.scheduler.arn
    input    = jsonencode({ InstanceIds = [aws_instance.gpu_node.id] })
  }
}
