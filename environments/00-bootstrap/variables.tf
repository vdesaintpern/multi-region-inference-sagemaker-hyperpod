variable "name_prefix" {
  description = "Prefix applied to all resource names created by this stack. Keep it short, lowercase, and DNS-safe (it is used in the globally-unique S3 bucket name)."
  type        = string
  default     = "sample-hpinf"

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{1,30}[a-z0-9]$", var.name_prefix))
    error_message = "name_prefix must be 3-32 chars, lowercase alphanumeric or hyphen, and start/end alphanumeric."
  }
}

variable "region" {
  description = "AWS region in which to create the remote-state backend (S3 bucket, KMS key, DynamoDB lock table)."
  type        = string
  default     = "us-east-1"
}

variable "tags" {
  description = "Tags applied to every resource created by this stack."
  type        = map(string)
  default = {
    Project   = "hyperpod-inference-sample"
    ManagedBy = "terraform"
    Stack     = "00-bootstrap"
  }
}
