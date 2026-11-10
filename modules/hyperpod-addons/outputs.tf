output "operator_role_arn" {
  description = "IRSA role ARN assumed by the HyperPod inference operator."
  value       = aws_iam_role.operator.arn
}

output "operator_role_name" {
  description = "Name of the inference operator role. KEDA (running under this role) signs AMP queries with it, so grant it aps:QueryMetrics when autoscaling on Prometheus metrics."
  value       = aws_iam_role.operator.name
}

output "lb_controller_role_arn" {
  description = "IRSA role ARN assumed by the AWS Load Balancer Controller."
  value       = aws_iam_role.lb_controller.arn
}

output "operator_addon_id" {
  description = "ID of the amazon-sagemaker-hyperpod-inference EKS add-on."
  value       = aws_eks_addon.hyperpod_inference_operator.id
}
