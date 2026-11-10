output "namespace" {
  description = "Kubernetes namespace the LiteLLM proxy runs in."
  value       = var.namespace
}

output "service_name" {
  description = "Name of the Kubernetes Service fronting the LiteLLM pods."
  value       = var.service_name
}

output "release_name" {
  description = "Helm release name for the LiteLLM proxy."
  value       = helm_release.litellm.name
}

output "ingress_hostname" {
  description = "DNS name of the internal ALB provisioned by the Ingress. Null until the AWS Load Balancer Controller has reconciled the load balancer."
  value       = try(kubernetes_ingress_v1.this.status[0].load_balancer[0].ingress[0].hostname, null)
}

output "env_secret_name" {
  description = "Name of the Kubernetes Secret holding LITELLM_MASTER_KEY, DATABASE_URL, and (optionally) REDIS_PASSWORD. Pass this to the litellm-rbac module."
  value       = kubernetes_secret.env.metadata[0].name
}

output "masterkey_secret_name" {
  description = "Kubernetes secret (key 'masterkey') holding the LiteLLM master key; used by the RBAC seed job."
  value       = local.masterkey_secret_name
}

output "alb_name" {
  description = "Deterministic name of the internal ALB the Ingress creates. Use with a data.aws_lb lookup to get the ARN for the CloudFront VPC origin."
  value       = local.alb_name
}
