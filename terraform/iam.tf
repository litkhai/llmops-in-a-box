# IAM role assumed by the EC2 instance — grants read access to SSM parameters
# that hold the stack secrets. Bootstrap script pulls them at first boot.
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

  tags = merge(local.common_tags, {
    Name = "${var.project_slug}-ec2-role"
  })
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
      Resource = [
        "arn:aws:ssm:${var.region}:*:parameter${var.ssm_path_prefix}",
        "arn:aws:ssm:${var.region}:*:parameter${var.ssm_path_prefix}/*"
      ]
    }]
  })
}

resource "aws_iam_instance_profile" "ec2" {
  name = "${var.project_slug}-ec2"
  role = aws_iam_role.ec2.name

  tags = merge(local.common_tags, {
    Name = "${var.project_slug}-ec2-profile"
  })
}
