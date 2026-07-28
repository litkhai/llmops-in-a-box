output "public_ip" {
  description = "Public IP — read by stack.sh target_host() for remote health checks and URLs"
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
