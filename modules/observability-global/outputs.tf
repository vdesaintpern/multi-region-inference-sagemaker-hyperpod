output "grafana_workspace_id" {
  description = "ID of the Amazon Managed Grafana workspace."
  value       = aws_grafana_workspace.this.id
}

output "grafana_endpoint" {
  description = "Grafana workspace endpoint URL."
  value       = "https://${aws_grafana_workspace.this.endpoint}"
}

output "grafana_role_arn" {
  description = "ARN of the IAM role assumed by the Grafana workspace to query AMP and CloudWatch."
  value       = aws_iam_role.grafana.arn
}

output "grafana_provisioner_token" {
  description = "ADMIN service-account token for the Grafana provider (datasource + dashboard provisioning). Sensitive."
  value       = aws_grafana_workspace_service_account_token.provisioner.key
  sensitive   = true
}
