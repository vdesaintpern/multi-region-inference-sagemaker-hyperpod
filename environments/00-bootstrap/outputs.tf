output "state_bucket_name" {
  description = "Name of the S3 bucket that holds Terraform remote state. Use as the backend `bucket`."
  value       = aws_s3_bucket.state.id
}

output "state_bucket_arn" {
  description = "ARN of the remote-state S3 bucket."
  value       = aws_s3_bucket.state.arn
}

output "lock_table_name" {
  description = "Name of the DynamoDB lock table. Use as the backend `dynamodb_table` if you prefer DynamoDB locking."
  value       = aws_dynamodb_table.lock.name
}

output "kms_key_arn" {
  description = "ARN of the KMS key encrypting the remote-state bucket."
  value       = aws_kms_key.state.arn
}
