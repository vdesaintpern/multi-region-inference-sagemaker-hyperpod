output "job_manifest_yaml" {
  description = "batch/v1 Job manifest (YAML) that ingests the model weights. Empty string when model_source_type = jumpstart (no ingestion needed). Apply via the kubectl provider in the caller."
  value       = local.needs_ingestion ? yamlencode(local.job_object) : ""
}

output "irsa_policy_json" {
  description = "IAM policy JSON for the ingestion Job's IRSA role: write access to the target bucket and read access to the HF token secret when set."
  value       = jsonencode(local.irsa_policy)
}

output "needs_ingestion" {
  description = "True when weights must be ingested (huggingface or s3), false for jumpstart."
  value       = local.needs_ingestion
}
