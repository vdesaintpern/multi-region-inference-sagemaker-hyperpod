# One-time bootstrap of the Terraform remote-state backend for the HyperPod global
# inference sample. Apply this stack FIRST, with a LOCAL backend (see versions.tf).
# It creates:
#   - A KMS key (+ alias) used to encrypt the state bucket at rest.
#   - An S3 bucket for remote state: versioned, KMS-encrypted, private, TLS-only,
#     bucket-owner-enforced ownership, force_destroy = false.
#   - A DynamoDB table for teams that prefer DynamoDB-based state locking.
#
# S3 native state locking (the `use_lockfile = true` backend option) needs no
# infrastructure and is the recommended default. The DynamoDB table is provided
# as an alternative for teams standardised on DynamoDB locking.

provider "aws" {
  region = var.region

  default_tags {
    tags = var.tags
  }
}

# Account id is used to scope the KMS key policy to this account's root.
data "aws_caller_identity" "current" {}

# Random suffix keeps the state bucket name globally unique across accounts/regions.
resource "random_id" "suffix" {
  byte_length = 4
}

locals {
  bucket_name = "${var.name_prefix}-tf-state-${random_id.suffix.hex}"
  lock_table  = "${var.name_prefix}-tf-lock"
}

# --------------------------------------------------------------------------------------------------
# KMS key for at-rest encryption of the remote-state bucket.
# --------------------------------------------------------------------------------------------------

data "aws_iam_policy_document" "kms" {
  # checkov:skip=CKV_AWS_109: This is the AWS-recommended default KMS key policy that delegates key
  #   administration to the account root (IAM). Without it the key can become unmanageable.
  # checkov:skip=CKV_AWS_111: Same as above -- root delegation is the documented KMS default and is a
  #   prerequisite for using IAM policies to manage key access.
  # checkov:skip=CKV_AWS_356: kms:* on resource "*" here means "this key" (a key policy is scoped to its
  #   own key); it does not grant cross-key access.
  # Account administrators retain full control of the key.
  statement {
    sid       = "EnableAccountRootPermissions"
    effect    = "Allow"
    actions   = ["kms:*"]
    resources = ["*"]
    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"]
    }
  }
}

resource "aws_kms_key" "state" {
  description             = "Encrypts Terraform remote state in ${local.bucket_name}."
  enable_key_rotation     = true
  deletion_window_in_days = 30
  policy                  = data.aws_iam_policy_document.kms.json
  tags                    = { Name = "${var.name_prefix}-tf-state" }
}

resource "aws_kms_alias" "state" {
  name          = "alias/${var.name_prefix}-tf-state"
  target_key_id = aws_kms_key.state.key_id
}

# --------------------------------------------------------------------------------------------------
# Remote-state S3 bucket (secure by default).
# --------------------------------------------------------------------------------------------------

# force_destroy is intentionally left at its default of false: the state bucket must not be
# emptied and deleted by `terraform destroy`, since that would erase every stack's state history.
resource "aws_s3_bucket" "state" {
  bucket = local.bucket_name
  tags   = { Name = "${var.name_prefix}-tf-state" }
}

# Versioning is REQUIRED for a state bucket so prior state revisions can be recovered.
resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.state.arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "state" {
  bucket                  = aws_s3_bucket.state.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "state" {
  bucket = aws_s3_bucket.state.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

# Deny any request that does not travel over TLS.
data "aws_iam_policy_document" "state_bucket" {
  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.state.arn, "${aws_s3_bucket.state.arn}/*"]
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "state" {
  bucket = aws_s3_bucket.state.id
  policy = data.aws_iam_policy_document.state_bucket.json

  # The public access block must exist before a bucket policy is attached.
  depends_on = [aws_s3_bucket_public_access_block.state]
}

# --------------------------------------------------------------------------------------------------
# DynamoDB lock table (alternative to S3 native locking).
# --------------------------------------------------------------------------------------------------

resource "aws_dynamodb_table" "lock" {
  name         = local.lock_table
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "LockID"

  attribute {
    name = "LockID"
    type = "S"
  }

  server_side_encryption {
    enabled     = true
    kms_key_arn = aws_kms_key.state.arn
  }

  point_in_time_recovery {
    enabled = true
  }

  tags = { Name = local.lock_table }
}
