output "region" {
  description = "Region this stack deployed into."
  value       = var.region
}

output "vpc_id" {
  description = "VPC ID for this region."
  value       = module.network.vpc_id
}

output "vpc_cidr" {
  description = "VPC CIDR for this region."
  value       = module.network.vpc_cidr
}

output "private_route_table_ids" {
  description = "Private route table IDs (the platform root adds peering routes to these)."
  value       = module.network.private_route_table_ids
}

output "cluster_name" {
  description = "EKS cluster name (the platform root's k8s/helm providers attach to the PRIMARY region's cluster via this)."
  value       = module.cluster.cluster_name
}

# --- Primary-cluster attach details consumed by the platform root via terraform_remote_state ---
output "cluster_endpoint" {
  description = "EKS API server endpoint (platform k8s/helm providers)."
  value       = module.cluster.cluster_endpoint
}

output "cluster_certificate_authority_data" {
  description = "Base64 EKS cluster CA (platform k8s/helm providers)."
  value       = module.cluster.cluster_certificate_authority_data
}

output "oidc_provider" {
  description = "EKS OIDC provider (host/path) for IRSA (platform RBAC seed)."
  value       = module.cluster.oidc_provider
}

output "oidc_provider_arn" {
  description = "EKS OIDC provider ARN for IRSA (platform RBAC seed)."
  value       = module.cluster.oidc_provider_arn
}

output "private_subnet_ids" {
  description = "Private subnet IDs (platform entry ALB, Aurora/Redis, bastion)."
  value       = module.network.private_subnet_ids
}

output "node_security_group_id" {
  description = "HyperPod/EKS node security group (platform may allow it to Aurora/Redis)."
  value       = module.cluster.node_security_group_id
}

output "model_alb_hostnames" {
  description = "Map of model key -> internal ALB DNS fronting that model in this region."
  value       = module.platform.model_alb_hostnames
}

output "amp_workspace_arn" {
  description = "AMP workspace ARN for this region (null when observability is disabled)."
  value       = module.platform.amp_workspace_arn
}
