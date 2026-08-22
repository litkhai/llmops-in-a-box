output "public_ip" {
  description = "Public IP — read by stack.sh target_host() for remote health checks and URLs"
  value       = aws_instance.stack.public_ip
}

output "instance_id" {
  description = "EC2 instance ID"
  value       = aws_instance.stack.id
}

output "ssh_command" {
  description = "SSH connection string. Requires an ssh_allowed_cidrs entry, or a temporary rule on the security group below."
  value       = "ssh -i <key>.pem ec2-user@${aws_instance.stack.public_ip}"
}

output "security_group_id" {
  description = "Security group ID — used to open and close SSH for a session"
  value       = aws_security_group.stack.id
}

# Deliberately not a host:port map. Only 80 and 443 are published, so the
# services are reachable at https://<subdomain>.<DOMAIN_BASE> and nowhere else.
# `./scripts/stack.sh urls --target aws-ec2` resolves those from stack.yaml.
output "stack_urls" {
  description = "How to reach the services (subdomains come from stack.yaml targets.aws-ec2.domain)"
  value = {
    note      = "Published ports: 80, 443 only. Use the HTTPS subdomains below."
    langfuse  = "https://langfuse.<DOMAIN_BASE>"
    librechat = "https://chat.<DOMAIN_BASE>"
    litellm   = "https://litellm.<DOMAIN_BASE>"
    media     = "https://media.<DOMAIN_BASE>"
  }
}
