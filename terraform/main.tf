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

# ── Security Groups ───────────────────────────────────────────────────────────

resource "aws_security_group" "control_plane" {
  name   = "gpu-infra-cp-sg"
  vpc_id = aws_vpc.lab.id

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.allowed_ssh_cidr]
    description = "SSH from your IP"
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
    from_port   = -1
    to_port     = -1
    protocol    = "4"
    cidr_blocks = ["10.0.0.0/16"]
    description = "Cilium/IPIP"
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "gpu-infra-cp-sg" }
}

resource "aws_security_group" "gpu_worker" {
  name   = "gpu-infra-worker-sg"
  vpc_id = aws_vpc.lab.id

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.allowed_ssh_cidr]
    description = "SSH"
  }

  ingress {
    from_port   = 10250
    to_port     = 10250
    protocol    = "tcp"
    cidr_blocks = ["10.0.0.0/16"]
    description = "kubelet"
  }

  ingress {
    from_port   = 30000
    to_port     = 32767
    protocol    = "tcp"
    cidr_blocks = [var.allowed_ssh_cidr]
    description = "NodePort"
  }

  ingress {
    from_port   = -1
    to_port     = -1
    protocol    = "4"
    cidr_blocks = ["10.0.0.0/16"]
    description = "Cilium/IPIP"
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "gpu-infra-worker-sg" }
}

# ── EC2 Instances ─────────────────────────────────────────────────────────────

resource "aws_instance" "control_plane" {
  ami                    = var.ubuntu_ami
  instance_type          = "t3.medium"
  key_name               = var.key_name
  subnet_id              = aws_subnet.lab.id
  vpc_security_group_ids = [aws_security_group.control_plane.id]

  metadata_options {
    http_tokens                 = "required"
    http_endpoint               = "enabled"
    http_put_response_hop_limit = 1
  }

  root_block_device {
    volume_type           = "gp3"
    volume_size           = 30
    encrypted             = true
    delete_on_termination = true
  }

  user_data = base64encode(file("${path.module}/bootstrap-control-plane.sh"))

  tags = { Name = "gpu-infra-control-plane" }
}

resource "aws_instance" "gpu_worker" {
  ami                    = var.ubuntu_ami
  instance_type          = "g5.xlarge"
  key_name               = var.key_name
  subnet_id              = aws_subnet.lab.id
  vpc_security_group_ids = [aws_security_group.gpu_worker.id]

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

  user_data = base64encode(file("${path.module}/bootstrap-gpu-worker.sh"))

  tags = { Name = "gpu-infra-gpu-worker" }
}

# ── EIPs ──────────────────────────────────────────────────────────────────────

resource "aws_eip" "control_plane" {
  instance = aws_instance.control_plane.id
  domain   = "vpc"
  tags     = { Name = "gpu-infra-cp-eip" }
}

resource "aws_eip" "gpu_worker" {
  instance = aws_instance.gpu_worker.id
  domain   = "vpc"
  tags     = { Name = "gpu-infra-worker-eip" }
}

# ── Auto-stop Scheduler ───────────────────────────────────────────────────────

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
      Resource = aws_instance.gpu_worker.arn
    }]
  })
}

resource "aws_scheduler_schedule" "gpu_stop" {
  name                = "gpu-infra-stop"
  schedule_expression = var.gpu_worker_stop_schedule
  flexible_time_window { mode = "OFF" }
  target {
    arn      = "arn:aws:scheduler:::aws-sdk:ec2:stopInstances"
    role_arn = aws_iam_role.scheduler.arn
    input    = jsonencode({ InstanceIds = [aws_instance.gpu_worker.id] })
  }
}

resource "aws_scheduler_schedule" "gpu_start" {
  name                = "gpu-infra-start"
  schedule_expression = var.gpu_worker_start_schedule
  flexible_time_window { mode = "OFF" }
  target {
    arn      = "arn:aws:scheduler:::aws-sdk:ec2:startInstances"
    role_arn = aws_iam_role.scheduler.arn
    input    = jsonencode({ InstanceIds = [aws_instance.gpu_worker.id] })
  }
}
