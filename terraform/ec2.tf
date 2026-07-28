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
