output "dev_key_secret_arn" {
  description = "Secrets Manager ARN holding the generated developer virtual key (created here or supplied by the caller)."
  value       = local.dev_key_secret_arn
}

output "job_name" {
  description = "Name of the Kubernetes Job that seeds LiteLLM RBAC."
  value       = kubernetes_job_v1.seed.metadata[0].name
}

output "irsa_role_arn" {
  description = "IRSA role ARN the seeding Job runs as (created here or supplied by the caller)."
  value       = local.irsa_role_arn
}

output "service_account_name" {
  description = "Kubernetes ServiceAccount the seeding Job runs as."
  value       = kubernetes_service_account.job.metadata[0].name
}
