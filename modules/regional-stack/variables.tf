variable "name_prefix" {
  description = "Prefix applied to all resource names and tags for this region."
  type        = string
}

variable "tags" {
  description = "Common tags."
  type        = map(string)
  default     = {}
}

variable "region" {
  description = "AWS region this regional serving stack runs in."
  type        = string
}

# ---- Network references (from the regional-network module in the root stack) ----
variable "vpc_id" { type = string }
variable "vpc_cidr" { type = string }
variable "private_subnet_ids" { type = list(string) }

# ---- Cluster references (from the eks-hyperpod module in the root stack) ----
variable "cluster_name" { type = string }
variable "oidc_provider_arn" { type = string }
variable "oidc_provider" { type = string }
variable "node_security_group_id" { type = string }
variable "hyperpod_cluster_arn" { type = string }

variable "gpu_instance_group_name" {
  description = "Name of the HyperPod GPU instance group (for the Karpenter GPU NodePool). Must match InstanceGroupName in modules/eks-hyperpod/hyperpod.tf."
  type        = string
  default     = "gpuauto"
}

variable "gpu_instance_type" {
  description = "GPU instance type Karpenter provisions (short EC2 form, e.g. g5.2xlarge)."
  type        = string
  default     = "g5.2xlarge"
}

# ---- Model catalog (single source of truth; drives InferenceEndpointConfig) ----
# litellm_alias is carried here only so the region catalog matches the platform catalog verbatim; the
# serving layer itself does not use it (the central LiteLLM in the platform root does).
variable "models" {
  description = "Map of models to serve. See modules/inference-endpoints for field docs; carries litellm_alias for catalog parity with the platform root."
  type = map(object({
    source_type          = string
    served_model_name    = string
    instance_type        = string
    instance_types       = optional(list(string)) # ordered list; replicas spread across these (overrides instance_type)
    litellm_alias        = string
    model_id             = optional(string)
    s3_uri               = optional(string)
    tensor_parallel_size = optional(number, 1)
    routing_strategy     = optional(string, "kvaware")
    max_model_len        = optional(number)
    autoscaling = optional(object({
      min_replicas     = optional(number, 1)
      max_replicas     = optional(number, 3)
      prometheus_query = optional(string)
      target_value     = optional(number)
    }))
  }))
}

# ---- HuggingFace / ingestion ----
variable "hf_token_secret_arn" {
  description = "Secrets Manager ARN holding a HuggingFace token for gated models. Null for open/JumpStart models."
  type        = string
  default     = null
}

variable "enable_observability" {
  description = "Deploy the HyperPod observability add-on + Amazon Managed Prometheus. Its per-node collector DaemonSets are pod-heavy; on small GPU instances (e.g. g5.xlarge, max-pods 14) they can crowd out the serving + S3-mount pods. Disable when running small nodes or when you don't need in-region metrics."
  type        = bool
  default     = true
}

# ---- Per-model internal ALB exposure (cross-region reach for the central LiteLLM) ----
variable "model_alb_inbound_cidrs" {
  description = "Source CIDRs allowed to reach this region's per-model internal ALBs. Include this region's own VPC CIDR (health checks / local LiteLLM) and the primary VPC CIDR (the central LiteLLM reaches the model ALBs over VPC peering). The ALBs are scheme=internal; they are never internet-facing."
  type        = list(string)
}

variable "model_alb_certificate_arn" {
  description = "ACM certificate ARN for the per-model internal ALB HTTPS listeners. When null, the module generates a self-signed certificate and imports it into ACM (sample default; the central LiteLLM must skip verification). Supply a real ACM cert ARN for a trusted chain."
  type        = string
  default     = null
}

# ---- Model-ALB gateway token (admit only the central LiteLLM, not every workload in the VPC CIDR) ----
# scheme=internal + CIDR rules only prove a caller is INSIDE the VPC; the vLLM backend has no auth, so any
# in-VPC pod could call the model ALB directly and bypass LiteLLM's keys/budgets. The ALB listener rule
# therefore admits a request only if it carries a shared secret header that LiteLLM injects. HTTPS (the
# model ALB terminates TLS) keeps the token off the wire; see ARCHITECTURE.md for the trust model and the
# dual-token zero-downtime rotation procedure.

variable "model_gateway_header_name" {
  description = "HTTP header the model ALB requires (and the central LiteLLM injects) to admit a request. MUST match the litellm module's model_gateway_header_name."
  type        = string
  default     = "x-model-gateway-token"
}

variable "gateway_token_version" {
  description = "Bump this (e.g. 1 -> 2) to regenerate the active model-gateway token. Used to drive rotation; see the dual-token procedure in ARCHITECTURE.md."
  type        = string
  default     = "1"
}

variable "additional_accepted_gateway_tokens" {
  description = "Extra gateway-token values the model ALB accepts IN ADDITION to the active one. Normally empty; set to the PREVIOUS token during a zero-downtime rotation so it stays valid until LiteLLM has switched to the new token, then clear it."
  type        = list(string)
  default     = []
}
