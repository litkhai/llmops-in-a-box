resource "aws_security_group" "stack" {
  name        = "${var.project_slug}-stack"
  description = "LLMOps in a Box - inbound from operator CIDR only"
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

  ingress {
    from_port   = 9002
    to_port     = 9002
    protocol    = "tcp"
    cidr_blocks = [var.allowed_cidr]
    description = "MinIO API (generated image hosting)"
  }

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "HTTP (redirects to HTTPS via Caddy)"
  }

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "HTTPS (Caddy with Let's Encrypt)"
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Outbound - provider API calls and package downloads"
  }

  tags = merge(local.common_tags, {
    Name = "${var.project_slug}-stack-sg"
  })
}
