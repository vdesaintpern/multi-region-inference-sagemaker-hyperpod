output "entry_alb_hostname" {
  description = "Internal entry ALB DNS name fronting the central LiteLLM. Reach it privately (bastion port-forward, VPN, or reader-added public exposure)."
  value       = module.litellm.ingress_hostname
}

output "entry_cert_arn" {
  description = "ACM certificate ARN on the entry ALB's 443 listener (provided, or the generated self-signed cert)."
  value       = local.entry_cert_arn
}

output "dev_key_secret_arn" {
  description = "Secrets Manager ARN holding the seeded developer virtual key (use it as the Bearer token)."
  value       = module.litellm_rbac.dev_key_secret_arn
}

output "bastion_instance_id" {
  description = "SSM bastion instance id for port-forwarding to the entry ALB (null when enable_bastion = false)."
  value       = try(module.bastion[0].instance_id, null)
}

output "discovered_regions" {
  description = "Regions found in SSM discovery (published by region roots)."
  value       = sort(tolist(local._region_names))
}

output "active_regions" {
  description = "Regions the gateway routes to (discovered AND listed in var.regions)."
  value       = sort(keys(local.active_regions))
}

output "grafana_endpoint" {
  description = "Central Amazon Managed Grafana workspace URL (null when enable_grafana = false)."
  value       = try(module.observability_global[0].grafana_endpoint, null)
}

output "deployment_summary" {
  description = "Per-alias list of regions LiteLLM load-balances across (one deployment per region)."
  value       = { for alias in distinct([for d in local.deployments : d.litellm_alias]) : alias => [for d in local.deployments : split("//", d.api_base)[1] if d.litellm_alias == alias] }
}
