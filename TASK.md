# Task: PR 2 — Terraform base for single-node EC2 deployment

## Branch
`pr/2-terraform-base` — base: `main`

## Goal
Create the `terraform/` directory with all HCL files needed to provision a
single EC2 instance (t3.xlarge, ap-northeast-2) running the Phase 1 compose
stack. This PR contains only infrastructure declarations — no scripts, no
stack.sh changes, no docs changes.

## Context from stack.yaml

```yaml
targets:
  aws-ec2:
    kind: terraform
    dir: terraform          # <-- this directory does not exist yet
    host: null              # resolved from terraform output public_ip
    vars:
      instance_type: t3.xlarge
      volume_size_gb: 100
      volume_type: gp3
      region: ap-northeast-2
      # key_name and allowed_cidr have no safe default — must be passed explicitly
```

`stack.sh up --target aws-ec2` already calls `terraform init` + `terraform apply`
and reads `public_ip` from terraform output. It fails today only because
`terraform/` does not exist. Creating this directory is the entire unlock.

## Files to create

### `terraform/variables.tf`

```hcl
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
```

### `terraform/main.tf`

```hcl
terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.region
}

# Use the default VPC. A dedicated VPC would add ~30 resources and obscure
# the stack being demonstrated; the demo does not need the isolation.
data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

# Latest Amazon Linux 2023 x86_64 (t3 is x86 — not arm64)
data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-x86_64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}
```

### `terraform/sg.tf`

```hcl
resource "aws_security_group" "stack" {
  name        = "${var.project_slug}-stack"
  description = "LLMOps in a Box — inbound from operator CIDR only"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.allowed_cidr]
    description = "SSH"
  }

  ingress {
    from_port   = 3000
    to_port     = 3000
    protocol    = "tcp"
    cidr_blocks = [var.allowed_cidr]
    description = "Langfuse"
  }

  ingress {
    from_port   = 3080
    to_port     = 3080
    protocol    = "tcp"
    cidr_blocks = [var.allowed_cidr]
    description = "LibreChat"
  }

  ingress {
    from_port   = 4000
    to_port     = 4000
    protocol    = "tcp"
    cidr_blocks = [var.allowed_cidr]
    description = "LiteLLM"
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Outbound — provider API calls and package downloads"
  }

  tags = {
    Name    = "${var.project_slug}-stack"
    Project = var.project_slug
  }
}
```

### `terraform/iam.tf`

```hcl
# IAM role assumed by the EC2 instance — grants read access to SSM parameters
# that hold the stack secrets. Bootstrap script (PR 3) uses this to pull .env.
resource "aws_iam_role" "ec2" {
  name = "${var.project_slug}-ec2"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = {
    Project = var.project_slug
  }
}

resource "aws_iam_role_policy" "ssm_read" {
  name = "${var.project_slug}-ssm-read"
  role = aws_iam_role.ec2.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "ssm:GetParameter",
        "ssm:GetParametersByPath"
      ]
      Resource = "arn:aws:ssm:${var.region}:*:parameter${var.ssm_path_prefix}/*"
    }]
  })
}

resource "aws_iam_instance_profile" "ec2" {
  name = "${var.project_slug}-ec2"
  role = aws_iam_role.ec2.name
}
```

### `terraform/ec2.tf`

```hcl
resource "aws_instance" "stack" {
  ami                    = data.aws_ami.al2023.id
  instance_type          = var.instance_type
  key_name               = var.key_name
  subnet_id              = tolist(data.aws_subnets.default.ids)[0]
  vpc_security_group_ids = [aws_security_group.stack.id]
  iam_instance_profile   = aws_iam_instance_profile.ec2.name

  root_block_device {
    volume_size = var.volume_size_gb
    volume_type = var.volume_type
    encrypted   = true
  }

  # bootstrap-ec2.sh (PR 3) installs Docker, pulls secrets from SSM,
  # and starts the Phase 1 compose stack on first boot.
  user_data = fileexists("${path.module}/../scripts/bootstrap-ec2.sh") ? file("${path.module}/../scripts/bootstrap-ec2.sh") : "#!/bin/bash\necho 'bootstrap-ec2.sh not yet present — see PR 3'"

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"   # IMDSv2 only
    http_put_response_hop_limit = 1
  }

  tags = {
    Name    = "${var.project_slug}-stack"
    Project = var.project_slug
  }
}
```

### `terraform/outputs.tf`

```hcl
output "public_ip" {
  description = "Public IP — read by stack.sh target_host() for remote health checks"
  value       = aws_instance.stack.public_ip
}

output "instance_id" {
  description = "EC2 instance ID"
  value       = aws_instance.stack.id
}

output "ssh_command" {
  description = "SSH connection string"
  value       = "ssh -i <key>.pem ec2-user@${aws_instance.stack.public_ip}"
}

output "stack_urls" {
  description = "Service endpoints (accessible once bootstrap completes)"
  value = {
    langfuse  = "http://${aws_instance.stack.public_ip}:3000"
    librechat = "http://${aws_instance.stack.public_ip}:3080"
    litellm   = "http://${aws_instance.stack.public_ip}:4000"
  }
}
```

### `terraform/.gitignore`

```
.terraform/
.terraform.lock.hcl
terraform.tfstate
terraform.tfstate.backup
*.tfplan
crash.log
override.tf
override.tf.json
*_override.tf
*_override.tf.json
```

## Validation (run before committing)

```bash
# Syntax check all HCL files
terraform -chdir=terraform validate 2>/dev/null || \
  terraform -chdir=terraform init -backend=false && terraform -chdir=terraform validate

# Confirm stack.sh resolves the terraform dir correctly
bash -n scripts/stack.sh
./scripts/stack.sh doctor --target aws-ec2 2>&1 | grep -i terraform
```

If terraform is not installed locally, at minimum confirm:
```bash
# All .tf files parse as valid HCL (no syntax errors visible on inspection)
# .gitignore exists and covers .terraform/ and *.tfstate
```

## Commit

```
git add terraform/
git commit -m "Add Terraform base for single-node EC2 deployment"
```

## PR

```bash
gh pr create \
  --base main \
  --head pr/2-terraform-base \
  --title "Add Terraform base for single-node EC2 deployment" \
  --body "$(cat <<'EOF'
## Summary
- Adds \`terraform/\` with provider config, VPC data sources, security group, IAM role/profile, EC2 instance, and outputs
- Security group restricts all inbound (22, 3000, 3080, 4000) to \`allowed_cidr\` — 0.0.0.0/0 rejected by variable validation
- EC2 uses IMDSv2, encrypted root volume, and IAM instance profile scoped to SSM read on \`/sais/phase-1/*\`
- \`output.public_ip\` is what \`stack.sh target_host()\` reads to resolve the remote host for health checks and URLs

## Unlocks
\`./scripts/stack.sh up --target aws-ec2\` currently exits with "terraform dir not found". This PR removes that blocker.

## Test plan
- [ ] \`terraform -chdir=terraform init\` succeeds
- [ ] \`terraform -chdir=terraform plan -var key_name=test -var allowed_cidr=1.2.3.4/32\` produces a clean plan
- [ ] \`terraform -chdir=terraform plan -var key_name=test -var allowed_cidr=0.0.0.0/0\` fails validation
- [ ] \`./scripts/stack.sh doctor --target aws-ec2\` confirms terraform binary found

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

## Working agreements (from AGENTS.md)
- Keep changes aligned with the current phase declared in `stack.yaml`
- Do not claim the target is implemented until the bootstrap script (PR 3) and
  stack.sh wiring (PR 4) also land — this PR is infrastructure-only
- Never inspect, print, or commit values from `.env` or `secrets/credentials.yaml`
