variable "name_prefix" {
  description = "Prefix applied to endpoint/CR names."
  type        = string
}

variable "namespace" {
  description = "Kubernetes namespace for the InferenceEndpointConfig resources."
  type        = string
  default     = "default"
}

variable "models" {
  description = <<-EOT
    Map of models to serve. Key = logical model name. Each value:
      source_type          : "jumpstart" | "huggingface" | "s3"
      model_id             : JumpStart model id or HuggingFace repo id (jumpstart/huggingface)
      s3_uri               : s3://bucket/prefix for weights (s3, and huggingface after ingestion)
      instance_type        : SageMaker instance type (e.g. ml.g5.2xlarge)
      served_model_name     : name vLLM serves and clients request via LiteLLM
      tensor_parallel_size : GPUs to shard across (default 1)
      routing_strategy     : prefixaware | kvaware | session | roundrobin (default prefixaware).
                             prefixaware keeps the OpenAI /v1/chat/completions API; kvaware is routed by
                             measured KV-cache hit rate but requires the /completions API.
      max_model_len        : optional vLLM max context length (cap to fit KV cache on small GPUs)
  EOT
  type = map(object({
    source_type          = string
    served_model_name    = string
    instance_type        = string
    instance_types       = optional(list(string)) # ordered list; if set, replicas spread across these (overrides instance_type)
    model_id             = optional(string)
    s3_uri               = optional(string)
    tensor_parallel_size = optional(number, 1)
    routing_strategy     = optional(string, "prefixaware")
    max_model_len        = optional(number)
    # Replica autoscaling (KEDA, via the operator's autoScalingSpec). Rendered only when set AND
    # amp_server_address is provided (needs a Prometheus/AMP backend to query). min/max bound the
    # replica count; prometheus_query is a PromQL scalar; target_value is the per-replica target.
    autoscaling = optional(object({
      min_replicas     = optional(number, 1)
      max_replicas     = optional(number, 3)
      prometheus_query = optional(string)
      target_value     = optional(number)
    }))
  }))
}

variable "amp_server_address" {
  description = "AMP workspace base URL for KEDA prometheus triggers (no trailing slash, no /api path). Null disables prometheus-based replica autoscaling. Comes from the observability module."
  type        = string
  default     = null
}

variable "s3_bucket_name" {
  description = "Managed model-weights bucket in this region (for source_type s3/huggingface)."
  type        = string
  default     = null
}

variable "s3_bucket_region" {
  description = "Region of the model-weights bucket."
  type        = string
  default     = null
}

variable "enable_intelligent_routing" {
  description = <<-EOT
    Enable the managed Intelligent Router (intelligentRoutingSpec) with the per-model routing_strategy,
    plus the tiered KV cache (kvCacheSpec: L1 CPU + optional L2 Redis). Mutually exclusive with
    enable_inference_gateway (the CRD enforces this) -- when true, inferenceGateway is forced off.
  EOT
  type        = bool
  default     = true
}

variable "enable_inference_gateway" {
  description = "Enable the plain HyperPod Inference Gateway. Ignored when enable_intelligent_routing is true (mutually exclusive)."
  type        = bool
  default     = true
}

variable "cluster_name" {
  description = "EKS cluster name. Used by the post-apply local-exec that patches the LMCache remote serde to `naive` (LMCache #2787 workaround)."
  type        = string
  default     = null
}

variable "region" {
  description = "AWS region for the EKS cluster (for the LMCache serde post-apply local-exec)."
  type        = string
  default     = null
}

variable "enable_l2_cache" {
  description = <<-EOT
    Enable the L2 (remote Redis) tier of the KV cache. MUST be known at plan time: it gates the
    terraform_data.lmcache_serde for_each, and for_each keys cannot depend on apply-time values. Do NOT
    derive L2-enablement from l2_cache_redis_host (that endpoint is unknown until the ElastiCache cluster is
    created, which makes the plan fail with "Invalid for_each argument"). The host is used only as a value.
  EOT
  type        = bool
  default     = false
}

variable "l2_cache_redis_host" {
  description = <<-EOT
    ElastiCache Redis host for the L2 tiered KV cache. NOTE: the HyperPod operator REJECTS a raw external
    hostname in l2CacheLocalUrl ("must be a cluster-local Service DNS name ending in .svc"). So this host is
    NOT placed in the URL directly; instead it becomes the externalName of an in-cluster ExternalName Service
    (l2_cache_service_name), and the CR points at that Service's .svc DNS which CNAMEs to ElastiCache. Used
    only as a value (may be known only after apply); enablement is controlled by enable_l2_cache.
  EOT
  type        = string
  default     = null
}

variable "l2_cache_service_name" {
  description = <<-EOT
    Name of the in-cluster ExternalName Service (created in var.namespace) that aliases the ElastiCache L2
    endpoint. The operator only accepts a cluster-local .svc DNS name for l2CacheLocalUrl, so the CR points at
    "<this>.<namespace>.svc.cluster.local" which DNS-CNAMEs to l2_cache_redis_host (ElastiCache).
  EOT
  type        = string
  default     = "kv-l2-redis"
}

variable "l2_cache_redis_port" {
  description = "ElastiCache Redis port for the L2 tiered KV cache."
  type        = number
  default     = 6379
}
