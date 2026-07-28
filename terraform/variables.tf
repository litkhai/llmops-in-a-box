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
  description = "CIDR block allowed inbound. Use 0.0.0.0/0 for open access (each service has its own auth)."
  type        = string
  default     = "0.0.0.0/0"
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
