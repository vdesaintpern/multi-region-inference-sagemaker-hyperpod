output "bucket_id" {
  description = "Name (ID) of the model weights bucket."
  value       = aws_s3_bucket.this.id
}

output "bucket_arn" {
  description = "ARN of the model weights bucket."
  value       = aws_s3_bucket.this.arn
}

output "bucket_regional_domain_name" {
  description = "Region-specific domain name of the bucket (use to load weights from the local region)."
  value       = aws_s3_bucket.this.bucket_regional_domain_name
}

output "kms_key_arn" {
  description = "ARN of the KMS key encrypting the model weights bucket."
  value       = aws_kms_key.this.arn
}
