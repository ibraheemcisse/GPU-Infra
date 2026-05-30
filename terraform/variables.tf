variable "aws_region" {
  type    = string
  default = "us-east-1"
}

variable "aws_az" {
  type    = string
  default = "us-east-1a"
}

variable "allowed_ssh_cidr" {
  type        = string
  description = "Your public IP in CIDR notation (e.g., 203.0.113.42/32)"
}

variable "key_name" {
  type        = string
  description = "Name of existing EC2 key pair"
}

variable "ubuntu_ami" {
  type        = string
  default     = "ami-02fd066b86800f60c"
  description = "Ubuntu 22.04 LTS in us-east-1"
}

variable "gpu_worker_stop_schedule" {
  type    = string
  default = "cron(0 18 ? * MON-FRI *)"
}

variable "gpu_worker_start_schedule" {
  type    = string
  default = "cron(0 9 ? * MON-FRI *)"
}
