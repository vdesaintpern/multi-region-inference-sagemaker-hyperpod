output "vpc_id" {
  description = "The VPC ID (created or BYO)."
  value       = local.vpc_id
}

output "vpc_cidr" {
  description = "The VPC IPv4 CIDR block."
  value       = data.aws_vpc.resolved.cidr_block
}

output "private_subnet_ids" {
  description = "Private subnet IDs across the configured AZs (workloads, ALB, HyperPod, data stores)."
  value       = local.private_subnet_ids
}

output "public_subnet_ids" {
  description = "Public subnet IDs (NAT / egress)."
  value       = local.public_subnet_ids
}

output "gpu_subnet_id" {
  description = "Single private subnet for the HyperPod GPU instance group (EFA cannot cross AZs)."
  value       = try(local.private_subnet_ids[0], null)
}

output "private_route_table_ids" {
  description = "Private subnet route table IDs (one per AZ). The platform root adds cross-region peering routes to these so the central LiteLLM can reach this region's model ALB. Empty for a BYO VPC (manage its routes out-of-band)."
  value       = var.create_vpc ? aws_route_table.private[*].id : []
}
