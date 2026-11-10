variable "name_prefix" {
  description = "Prefix applied to all resource names and tags (e.g. sample-hpinf-use1)."
  type        = string
}

variable "model_source_type" {
  description = "Where model weights come from: jumpstart (managed by SageMaker, no ingestion), huggingface (download from the HF Hub), or s3 (copy from an existing bucket/prefix)."
  type        = string

  validation {
    condition     = contains(["jumpstart", "huggingface", "s3"], var.model_source_type)
    error_message = "model_source_type must be one of: jumpstart, huggingface, s3."
  }
}

variable "model_id" {
  description = "Hugging Face repo id (e.g. meta-llama/Llama-3.1-8B-Instruct) or JumpStart model id. Required for huggingface/jumpstart."
  type        = string
  default     = null
}

variable "model_s3_uri" {
  description = "Source S3 URI to copy weights from when model_source_type = s3. Replace the example bucket with your own (e.g. s3://amzn-s3-demo-source-bucket/models/my-model)."
  type        = string
  default     = null
}

variable "target_bucket" {
  description = "Name of the primary model weights bucket the job writes to."
  type        = string
}

variable "target_prefix" {
  description = "Key prefix under which weights are stored in the target bucket."
  type        = string
  default     = "models/"
}

variable "hf_token_secret_arn" {
  description = "Secrets Manager ARN holding the Hugging Face access token. Referenced (not read) by this module; the Job mounts it from a Kubernetes secret. Null for public models."
  type        = string
  default     = null
}

variable "image" {
  description = "Container image the ingestion Job runs. Defaults to a generic public Python image."
  type        = string
  default     = "public.ecr.aws/docker/library/python:3.12-slim"
}

variable "service_account_name" {
  description = "Kubernetes service account (IRSA) the Job runs as; must be bound to a role using irsa_policy_json."
  type        = string
  default     = "model-ingestion"
}

variable "namespace" {
  description = "Kubernetes namespace the ingestion Job runs in."
  type        = string
  default     = "model-ingestion"
}

variable "tags" {
  description = "Common tags applied to every resource."
  type        = map(string)
  default     = {}
}
