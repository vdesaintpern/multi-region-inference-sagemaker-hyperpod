output "cluster_name" {
  description = "EKS cluster name."
  value       = module.eks.cluster_name
}

output "cluster_arn" {
  description = "EKS cluster ARN."
  value       = module.eks.cluster_arn
}

output "cluster_endpoint" {
  description = "EKS API server endpoint."
  value       = module.eks.cluster_endpoint
}

output "cluster_certificate_authority_data" {
  description = "Base64 EKS cluster CA certificate."
  value       = module.eks.cluster_certificate_authority_data
}

output "oidc_provider_arn" {
  description = "IAM OIDC provider ARN for IRSA."
  value       = module.eks.oidc_provider_arn
}

output "oidc_provider" {
  description = "OIDC provider URL (without https://) for IRSA trust policies."
  value       = module.eks.oidc_provider
}

output "cluster_security_group_id" {
  description = "EKS cluster security group ID."
  value       = module.eks.cluster_security_group_id
}

output "node_security_group_id" {
  description = "EKS node shared security group ID (used by LiteLLM/system pods for data-store access rules)."
  value       = module.eks.node_security_group_id
}

output "hyperpod_cluster_arn" {
  description = "SageMaker HyperPod cluster ARN."
  value       = aws_cloudformation_stack.hyperpod.outputs["ClusterArn"]
}

output "hyperpod_cluster_name" {
  description = "SageMaker HyperPod cluster name."
  value       = aws_cloudformation_stack.hyperpod.outputs["ClusterName"]
}

output "hyperpod_instance_role_arn" {
  description = "HyperPod instance execution role ARN."
  value       = aws_iam_role.hyperpod_instance.arn
}
