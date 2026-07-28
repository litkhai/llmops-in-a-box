variable "region" {
  description = "AWS region"
  type        = string
  default     = "ap-northeast-2"
}

variable "instance_type" {
  description = "EC2 instance type"
  type        = string
  default     = "t3.xlarge"
}

variable "volume_size_gb" {
  description = "Root EBS volume size in GiB"
  type        = number
  default     = 100
}

variable "volume_type" {
  description = "EBS volume type"
  type        = string
  default     = "gp3"
}

variable "key_name" {
  description = "EC2 key pair name for SSH access. No default — pass with --tf-var key_name=<name>."
  type        = string
}

variable "allowed_cidr" {
  description = "CIDR block allowed inbound. Never 0.0.0.0/0. Pass with --tf-var allowed_cidr=<your-ip>/32."
  type        = string

  validation {
    condition     = var.allowed_cidr != "0.0.0.0/0"
    error_message = "allowed_cidr must not be 0.0.0.0/0 — this stack holds live provider API keys."
  }
}

variable "project_slug" {
  description = "Resource name prefix — matches stack.yaml project.slug"
  type        = string
  default     = "sais"
}

variable "ssm_path_prefix" {
  description = "SSM Parameter Store path prefix for stack secrets"
  type        = string
  default     = "/sais/phase-1"
}
