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

variable "ssh_allowed_cidrs" {
  description = <<-EOT
    CIDRs allowed to reach port 22. Empty by default: no SSH ingress at all.
    Application traffic does not need it — everything is served over HTTPS by
    Caddy on 80/443. Open it per session for the address that needs it.
  EOT
  type        = list(string)
  default     = []

  validation {
    condition     = !contains(var.ssh_allowed_cidrs, "0.0.0.0/0")
    error_message = "Refusing 0.0.0.0/0 for SSH. Pass the operator's own address, e.g. 1.2.3.4/32."
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
