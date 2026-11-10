variable "name_prefix" {
  description = "Prefix applied to all resource names and tags (e.g. sample-hpinf-global)."
  type        = string
}

variable "tags" {
  description = "Common tags applied to every resource."
  type        = map(string)
  default     = {}
}

variable "amp_workspace_arns" {
  description = "ARNs of the per-region Amazon Managed Prometheus workspaces this Grafana workspace queries. Scopes the aps:* permissions. Falls back to [\"*\"] when empty."
  type        = list(string)
  default     = []
}

variable "authentication_providers" {
  description = "Grafana workspace authentication providers. Defaults to AWS_SSO (IAM Identity Center)."
  type        = list(string)
  default     = ["AWS_SSO"]
}

variable "provisioner_token_ttl_seconds" {
  description = "TTL for the Grafana ADMIN service-account token used by the Terraform Grafana provider to provision the datasource + dashboards. Max 2592000 (30 days); recreated automatically on expiry."
  type        = number
  default     = 2592000
}
