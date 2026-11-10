# Model weight storage for the HyperPod global inference sample.
#
# This module is instantiated once per region (in the `region` root). Each region gets its own
# KMS-encrypted S3 bucket; its local HyperPod cluster both ingests (downloads from HuggingFace) and
# loads weights from this LOCAL bucket. Regions are independent - there is no cross-region replication
# (each region ingests its own weights), which keeps every region self-contained in the star topology.

# Random suffix keeps the bucket name globally unique across accounts/regions.
resource "random_id" "suffix" {
  byte_length = 4
}

# --------------------------------------------------------------------------------------------------
# KMS key for at-rest encryption of the model weights bucket.
# --------------------------------------------------------------------------------------------------

resource "aws_kms_key" "this" {
  description             = "Encrypts model weights in ${var.name_prefix}-model-weights."
  enable_key_rotation     = true
  deletion_window_in_days = 30
  tags                    = merge(var.tags, { Name = "${var.name_prefix}-model-weights" })
}

resource "aws_kms_alias" "this" {
  name          = "alias/${var.name_prefix}-model-weights"
  target_key_id = aws_kms_key.this.key_id
}

# --------------------------------------------------------------------------------------------------
# Model weights bucket (secure by default).
# --------------------------------------------------------------------------------------------------

resource "aws_s3_bucket" "this" {
  bucket = "${var.name_prefix}-model-weights-${random_id.suffix.hex}"
  tags   = merge(var.tags, { Name = "${var.name_prefix}-model-weights" })

  # Sample convenience: the weights are re-ingestible (downloaded from Hugging Face / your source), and
  # versioning below leaves object versions behind that otherwise block `terraform destroy` with
  # BucketNotEmpty. force_destroy lets destroy empty the bucket (all versions) first. For a bucket holding
  # anything you cannot regenerate, set this to false and empty it deliberately.
  force_destroy = true
}

# Versioning is enabled so model updates are revertible. (Cross-region replication was removed from this
# sample - each region ingests its own weights - so versioning here is only for in-region object history.)
resource "aws_s3_bucket_versioning" "this" {
  bucket = aws_s3_bucket.this.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "this" {
  bucket = aws_s3_bucket.this.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.this.arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "this" {
  bucket                  = aws_s3_bucket.this.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "this" {
  bucket = aws_s3_bucket.this.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}
