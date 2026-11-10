# Reusable SSM jumpbox: a small private EC2 instance reachable only through AWS Systems Manager
# Session Manager (no SSH, no public IP, no inbound rules). Use it to port-forward from a laptop to
# in-VPC endpoints (internal ALBs, RDS, ElastiCache, in-cluster services) via
# AWS-StartPortForwardingSessionToRemoteHost. Deployed from a SEPARATE root/state so it can be
# created and destroyed independently of the main stack.

data "aws_ssm_parameter" "ami" {
  name = var.ami_ssm_parameter
}

# --------------------------------------------------------------------------------------------------
# Instance IAM role: only the managed policy Session Manager needs.
# --------------------------------------------------------------------------------------------------

data "aws_iam_policy_document" "assume" {
  statement {
    actions = ["sts:AssumeRole"]
    effect  = "Allow"
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "this" {
  name               = "${var.name_prefix}-jumpbox"
  assume_role_policy = data.aws_iam_policy_document.assume.json
  tags               = merge(var.tags, { Name = "${var.name_prefix}-jumpbox" })
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.this.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "this" {
  name = "${var.name_prefix}-jumpbox"
  role = aws_iam_role.this.name
  tags = var.tags
}

# --------------------------------------------------------------------------------------------------
# Security group: no inbound (Session Manager is outbound-only); egress open so the agent can reach
# SSM and the host can reach in-VPC targets you tunnel to.
# --------------------------------------------------------------------------------------------------

resource "aws_security_group" "this" {
  name        = "${var.name_prefix}-jumpbox"
  description = "SSM jumpbox: no inbound, egress all."
  vpc_id      = var.vpc_id
  tags        = merge(var.tags, { Name = "${var.name_prefix}-jumpbox" })
}

resource "aws_vpc_security_group_egress_rule" "all" {
  security_group_id = aws_security_group.this.id
  description       = "Allow all outbound (SSM endpoints + tunnel targets)."
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

# --------------------------------------------------------------------------------------------------
# The instance.
# --------------------------------------------------------------------------------------------------

resource "aws_instance" "this" {
  ami                         = data.aws_ssm_parameter.ami.value
  instance_type               = var.instance_type
  subnet_id                   = var.subnet_id
  vpc_security_group_ids      = [aws_security_group.this.id]
  iam_instance_profile        = aws_iam_instance_profile.this.name
  associate_public_ip_address = false

  # Require IMDSv2.
  metadata_options {
    http_tokens   = "required"
    http_endpoint = "enabled"
  }

  root_block_device {
    volume_size = 8
    volume_type = "gp3"
    encrypted   = true
  }

  tags = merge(var.tags, { Name = "${var.name_prefix}-jumpbox" })
}
