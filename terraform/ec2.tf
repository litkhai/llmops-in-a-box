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
    http_tokens                 = "required" # IMDSv2 only
    http_put_response_hop_limit = 1
  }

  tags = merge(local.common_tags, {
    Name = "${var.project_slug}-stack"
    Role = "llmops-stack"
  })

  volume_tags = merge(local.common_tags, {
    Name = "${var.project_slug}-stack-root"
  })

  lifecycle {
    # data.aws_ami.al2023 is most_recent, so its id changes whenever Amazon
    # publishes a new AL2023 image. Without this, an unrelated `apply` — a tag
    # edit, a new variable — replaces the instance, and the root volume holding
    # Langfuse, Mongo, and MinIO data goes with it. The AMI only matters on
    # first boot; to move to a newer one, do it deliberately with -replace.
    ignore_changes = [ami]
  }
}
