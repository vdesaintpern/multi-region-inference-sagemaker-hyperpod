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
  description = "Name of the EKS cluster the add-ons are installed into."
  type        = string
}

variable "oidc_provider_arn" {
  description = "ARN of the EKS cluster IAM OIDC provider (used to build IRSA trust policies)."
  type        = string
}

variable "oidc_provider" {
  description = "EKS cluster OIDC provider URL WITHOUT the https:// scheme (e.g. oidc.eks.us-east-1.amazonaws.com/id/EXAMPLED539D4633E53DE1B71EXAMPLE)."
  type        = string
}

variable "vpc_id" {
  description = "VPC ID of the EKS cluster. Passed to the AWS Load Balancer Controller."
  type        = string
}

variable "region" {
  description = "AWS region of the EKS cluster. Passed to the AWS Load Balancer Controller."
  type        = string
}

variable "operator_addon_version" {
  description = "Version of the amazon-sagemaker-hyperpod-inference EKS add-on. Null lets AWS select the default version for the cluster."
  type        = string
  default     = null
}

variable "operator_namespace" {
  description = "Kubernetes namespace the HyperPod inference operator service accounts are created in. Used to build the IRSA trust condition."
  type        = string
  default     = "hyperpod-inference-system"
}

variable "operator_service_account" {
  description = "Kubernetes service account the HyperPod inference operator controller-manager runs as. Used to scope the IRSA trust condition to exactly this service account. Matches the name the amazon-sagemaker-hyperpod-inference add-on creates in operator_namespace."
  type        = string
  default     = "hyperpod-inference-controller-manager"
}

variable "cert_manager_version" {
  description = "cert-manager Helm chart version. cert-manager is a prerequisite for the HyperPod inference operator webhooks."
  type        = string
  default     = "v1.15.3"
}

variable "lb_controller_chart_version" {
  description = "aws-load-balancer-controller Helm chart version."
  type        = string
  default     = "1.8.2"
}

variable "lb_controller_policy_json" {
  description = "IAM policy JSON for the AWS Load Balancer Controller. When null, the module creates the recommended v2.x policy in-module."
  type        = string
  default     = null
}

variable "hyperpod_cluster_arn" {
  description = "ARN of the HyperPod cluster. Set as hyperpodClusterArn in the operator add-on config so the controller-manager (running on a non-HyperPod node) can determine its cluster."
  type        = string
}

variable "model_weights_bucket_arns" {
  description = "S3 bucket ARNs the inference operator may read model weights from. Scopes the operator's ModelWeightsRead permission. Empty list (the default) grants NO model-weights read at all (fail closed); set explicitly to the bucket(s) holding your weights."
  type        = list(string)
  default     = []
}
