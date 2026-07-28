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
    description = "Outbound - provider API calls and package downloads"
  }

  tags = merge(local.common_tags, {
    Name = "${var.project_slug}-stack-sg"
  })
}
