output "amp_workspace_id" {
  description = "ID of the Amazon Managed Prometheus workspace."
  value       = aws_prometheus_workspace.this.id
}

output "amp_workspace_arn" {
  description = "ARN of the Amazon Managed Prometheus workspace (scope for aps:RemoteWrite and cross-region Grafana queries)."
  value       = aws_prometheus_workspace.this.arn
}

output "amp_prometheus_endpoint" {
  description = "Prometheus-compatible endpoint of the AMP workspace (base URL; append api/v1/remote_write or api/v1/query)."
  value       = aws_prometheus_workspace.this.prometheus_endpoint
}
