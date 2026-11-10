variable "name_prefix" {
  description = "Prefix applied to all resource names and tags (e.g. sample-hpinf-use1)."
  type        = string
}

variable "tags" {
  description = "Common tags applied to every resource."
  type        = map(string)
  default     = {}
}

variable "cluster_name" {
  description = "Name of the EKS cluster the observability add-on and collector are installed into."
  type        = string
}

variable "oidc_provider_arn" {
  description = "ARN of the EKS cluster IAM OIDC provider (used to build the collector IRSA trust policy)."
  type        = string
}

variable "oidc_provider" {
  description = "EKS cluster OIDC provider URL WITHOUT the https:// scheme (e.g. oidc.eks.us-east-1.amazonaws.com/id/EXAMPLED539D4633E53DE1B71EXAMPLE)."
  type        = string
}

variable "operator_role_name" {
  description = "Name of the HyperPod inference operator role. KEDA signs AMP queries with it (identityOwner: operator), so it is granted aps:QueryMetrics on this workspace for Prometheus-based replica autoscaling. Null skips the grant."
  type        = string
  default     = null
}

variable "region" {
  description = "AWS region of the EKS cluster and the Amazon Managed Prometheus workspace. Used for the remote_write SigV4 signing region."
  type        = string
}

variable "hyperpod_observability_addon_version" {
  description = "Version of the SageMaker HyperPod observability EKS add-on. Null lets AWS select the default version for the cluster."
  type        = string
  default     = null
}

# Terraform does not allow variable interpolation in defaults, so this defaults to null
# and falls back to name_prefix in main.tf via coalesce().
variable "amp_alias" {
  description = "Alias for the Amazon Managed Prometheus workspace. Defaults to name_prefix when null."
  type        = string
  default     = null
}

variable "prometheus_namespace" {
  description = "Namespace of the metrics collector that assumes the AMP remote-write role. This is the HyperPod observability add-on's collector namespace (NOT a separately-installed prometheus-community chart, which is not deployed). Used to build the collector IRSA trust condition."
  type        = string
  default     = "hyperpod-observability"
}

variable "prometheus_service_account" {
  description = "Service account the add-on's OTel collectors (central + node) run as; it is IRSA-annotated with the collector role, so the role trust MUST name this SA or the collectors fail with sts:AssumeRoleWithWebIdentity 403. Verify against your add-on version."
  type        = string
  default     = "hyperpod-observability-operator-otel-collector"
}

variable "prometheus_chart_version" {
  description = "prometheus-community/prometheus Helm chart version."
  type        = string
  default     = "25.27.0"
}
