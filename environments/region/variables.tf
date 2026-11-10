variable "name_prefix" {
  description = "Prefix applied to all resource names and tags for this region (e.g. sample-hpinf-use1)."
  type        = string
}

variable "region" {
  description = "AWS region this stack deploys into."
  type        = string
}

variable "primary_region" {
  description = "The primary region, where the platform root runs and where every region publishes its discovery entries into SSM. For the primary region's own apply, set this equal to region."
  type        = string
}

variable "ssm_prefix" {
  description = "SSM Parameter Store path prefix for cross-stack discovery (read by the platform root)."
  type        = string
  default     = "/hpinf"
}

variable "tags" {
  description = "Common tags applied to every resource."
  type        = map(string)
  default     = {}
}

variable "vpc_cidr" {
  description = "VPC CIDR for this region. MUST NOT overlap any other region's CIDR (cross-region VPC peering requires non-overlapping ranges). Convention: primary 10.10.0.0/16, next 10.20.0.0/16, etc."
  type        = string
}

variable "az_count" {
  description = "Number of AZs (private + public subnet pairs) to create."
  type        = number
  default     = 2
}

variable "gpu_instance_type" {
  description = "HyperPod GPU instance type (ml.* form). The serving pod is hard-pinned to this type."
  type        = string
}

variable "gpu_instance_types" {
  description = "Interchangeable GPU instance types the managed Karpenter may provision (so a momentarily unavailable single type does not fail provisioning)."
  type        = list(string)
}

variable "gpu_instance_count" {
  description = "0 = Karpenter-owned elastic scale-from-zero (provisions on pending-pod demand, scales back to 0). A NON-zero value PINS the group to exactly that many nodes. Keep 0 for demand-driven serving."
  type        = number
  default     = 0
}

variable "models" {
  description = "Model catalog for this region (single source of truth; drives InferenceEndpointConfig). Keep identical across regions and matching the platform root's catalog so the per-region deployments line up under each litellm_alias."
  type = map(object({
    source_type          = string
    served_model_name    = string
    instance_type        = string
    instance_types       = optional(list(string))
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

variable "hf_token_secret_arn" {
  description = "Secrets Manager ARN holding a HuggingFace token for gated models. Null for open/JumpStart models."
  type        = string
  default     = null
}

variable "enable_observability" {
  description = "Deploy the HyperPod observability add-on + Amazon Managed Prometheus in this region. On a fresh cluster, deploy with this OFF first (so a GPU node comes up), then flip ON and re-apply."
  type        = bool
  default     = true
}

variable "client_cidrs" {
  description = "Extra source CIDRs (beyond this region's own VPC CIDR) allowed to reach this region's per-model internal ALBs. For a NON-primary region set this to the PRIMARY VPC CIDR (e.g. [\"10.10.0.0/16\"]) so the central LiteLLM can reach the model ALBs over VPC peering. Leave empty on the primary region (its own VPC CIDR is always allowed)."
  type        = list(string)
  default     = []
}
