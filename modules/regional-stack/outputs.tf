output "region" {
  description = "Region of this serving stack."
  value       = var.region
}

output "model_alb_hostnames" {
  description = "Map of model key -> internal ALB DNS name fronting that model's in-cluster routing-service. Populated once the LB Controller reconciles each Ingress. The region root publishes these to the primary region's SSM for the central LiteLLM to discover."
  value       = { for k, ing in kubernetes_ingress_v1.model : k => try(ing.status[0].load_balancer[0].ingress[0].hostname, null) }
}

output "model_gateway_token" {
  description = "Active shared secret the central LiteLLM must send as the model_gateway_header_name header to reach this region's model ALBs. Published to the primary region's SSM (SecureString) for the platform root to inject into LiteLLM."
  value       = random_password.model_gw_token.result
  sensitive   = true
}

output "model_bucket_arn" {
  description = "Model-weights bucket ARN for this region."
  value       = module.model_storage.bucket_arn
}

output "model_bucket_kms_arn" {
  description = "Model-weights bucket KMS key ARN for this region."
  value       = module.model_storage.kms_key_arn
}

output "amp_workspace_arn" {
  description = "Amazon Managed Prometheus workspace ARN (Grafana data source). Null when observability is disabled."
  value       = one(module.observability[*].amp_workspace_arn)
}

output "amp_prometheus_endpoint" {
  description = "AMP remote-write / query endpoint. Null when observability is disabled."
  value       = one(module.observability[*].amp_prometheus_endpoint)
}
