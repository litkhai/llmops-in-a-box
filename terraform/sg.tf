# Only 80 and 443 are published. Every service is reached through Caddy on the
# HTTPS subdomains it renders, so the direct application ports (3000, 3080,
# 4000, 9002) have no reason to be open to the internet — they carried plain
# HTTP and, in the gateway's case, an admin API.
#
# SSH is opt-in and empty by default: open it for the session that needs it,
# with the CIDR of the machine that needs it, and close it after.
#
#   aws ec2 authorize-security-group-ingress --group-id <sg> --region <region> \
#     --ip-permissions "IpProtocol=tcp,FromPort=22,ToPort=22,\
#   IpRanges=[{CidrIp=$(curl -s https://checkip.amazonaws.com)/32,Description=temp}]"
#
# Or declare it: --tf-var 'ssh_allowed_cidrs=["1.2.3.4/32"]'
resource "aws_security_group" "stack" {
  name = "${var.project_slug}-stack"
  # Do not edit this description. AWS treats it as immutable, so Terraform can
  # only change it by replacing the security group — which replaces the instance
  # attached to it, and with it every Docker volume. The comment block above is
  # where the rationale belongs.
  description = "LLMOps in a Box - inbound from operator CIDR only"
  vpc_id      = data.aws_vpc.default.id

  dynamic "ingress" {
    for_each = var.ssh_allowed_cidrs
    content {
      from_port   = 22
      to_port     = 22
      protocol    = "tcp"
      cidr_blocks = [ingress.value]
      description = "SSH"
    }
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
    description = "HTTPS (Caddy with TLS)"
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
