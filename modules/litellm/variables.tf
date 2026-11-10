variable "name_prefix" {
  description = "Prefix applied to all resource names and tags (e.g. sample-litellm-use1)."
  type        = string
}

variable "tags" {
  description = "Common tags applied to every resource."
  type        = map(string)
  default     = {}
}

variable "namespace" {
  description = "Kubernetes namespace the LiteLLM proxy is deployed into."
  type        = string
  default     = "litellm"
}

variable "db_secret_username_key" {
  description = "JSON field name inside the DB Secret that holds the username (chart db.secret.usernameKey). A key name, not a credential."
  type        = string
  default     = "username"
}

variable "db_secret_password_key" {
  description = "JSON field name inside the DB Secret that holds the password (chart db.secret.passwordKey). A key name, not a credential."
  type        = string
  default     = "password"
}

variable "create_namespace" {
  description = "If true, this module creates the namespace so the env secret can be created before the Helm release. Left false on the Helm release itself to avoid a duplicate-create conflict."
  type        = bool
  default     = true
}

variable "deployments" {
  description = <<-EOT
    Flat list of LiteLLM deployments. The platform root builds this by cross-producting each model with
    each region, so one logical model (alias) has one deployment per region. Entries that share
    litellm_alias form a LiteLLM routing group across regions: session affinity pins a conversation to the
    region that served its first request (keeping that region's KV cache warm), and routing_strategy places
    only NEW/spilled sessions across the group. Each entry becomes a model_list entry:
      model_name              = litellm_alias
      litellm_params.model    = "openai/<served_model_name>"
      litellm_params.api_base = api_base   (that region's internal model ALB, reached over VPC peering)
      litellm_params.api_key  = "dummy"    (vLLM ignores the key)
  EOT
  type = list(object({
    litellm_alias     = string
    served_model_name = string
    api_base          = string
    # Shared secret the region's model ALB requires; injected as the model_gateway_header_name header on
    # every upstream call so only LiteLLM can reach the model ALB. Null = no gateway token for this entry.
    gateway_token = optional(string)
  }))
  default = []
}

variable "model_gateway_header_name" {
  description = "HTTP header LiteLLM sends to the per-model ALBs to prove it is the gateway. MUST match the regional-stack module's model_gateway_header_name."
  type        = string
  default     = "x-model-gateway-token"
}

variable "model_upstream_ssl_verify" {
  description = <<-EOT
    Whether LiteLLM verifies the TLS certificate of the per-model ALB upstreams (api_base is https://).
    The model ALBs terminate TLS; with the sample's self-signed ALB certificate this must be false or
    every upstream call fails certificate verification.

    TESTING-ONLY DEFAULT: false disables certificate verification, which removes protection against a
    man-in-the-middle on the inter-region model traffic (a spoofed upstream can impersonate a model
    ALB). It is set false here solely to make the self-signed sample work out of the box. Do NOT run
    with false outside this sample. Set to true once the model ALBs present a trusted (real ACM)
    certificate. Rendered as litellm_settings.ssl_verify in the proxy config.
  EOT
  type        = bool
  default     = false
}

# ------- Cross-region router behaviour (affinity-first load routing) -------

variable "routing_strategy" {
  description = "LiteLLM router strategy for placing NEW sessions and spill across the per-region deployments of an alias: simple-shuffle | least-busy | usage-based-routing-v2 | latency-based-routing | cost-based-routing. Session affinity (below) runs FIRST and keeps a conversation on its cache-warm region regardless of this."
  type        = string
  default     = "least-busy"
}

variable "enable_session_affinity" {
  description = "Pin every request of a conversation to the region that served its first request (keyed on x-litellm-session-id / x-litellm-trace-id / metadata.session_id) so the per-region KV/prefix cache stays warm. Enabled via optional_pre_call_checks=[session_affinity]; needs Redis (configured) to share the pin across replicas."
  type        = bool
  default     = true
}

variable "session_affinity_ttl_seconds" {
  description = "How long a session stays pinned to its region (router_settings.deployment_affinity_ttl_seconds)."
  type        = number
  default     = 3600
}

variable "cooldown_time" {
  description = "Seconds to cool a region's deployment down after it exceeds allowed_fails (router_settings.cooldown_time). The session pin is kept, so a recovered region reclaims its sessions."
  type        = number
  default     = 30
}

variable "allowed_fails" {
  description = "Failures before a region's deployment is put in cooldown and NEW sessions spill to another region (router_settings.allowed_fails)."
  type        = number
  default     = 3
}

variable "num_retries" {
  description = "Router retries across the remaining healthy regions before surfacing the error (router_settings.num_retries)."
  type        = number
  default     = 2
}

# ------- Secrets (referenced by ARN; never read the plaintext into code paths that log) -------

variable "master_key_secret_arn" {
  description = "Secrets Manager ARN holding the LiteLLM master key. Surfaced to pods via a Kubernetes secret as LITELLM_MASTER_KEY."
  type        = string
}

variable "master_key_json_key" {
  description = "If the master key secret stores JSON, the key within it holding the master key. When null the raw SecretString is used verbatim."
  type        = string
  default     = null
}

variable "db_secret_arn" {
  description = "Secrets Manager ARN holding Aurora credentials as JSON {username,password,dbname,port}. Used to build DATABASE_URL."
  type        = string
}

variable "db_host" {
  description = "Aurora writer endpoint hostname. Combined with the db secret to build DATABASE_URL."
  type        = string
}

variable "redis_host" {
  description = "ElastiCache Redis primary endpoint hostname for router rate-limit counters."
  type        = string
}

variable "redis_port" {
  description = "ElastiCache Redis port."
  type        = number
  default     = 6379
}

variable "redis_auth_secret_arn" {
  description = "Secrets Manager ARN holding the Redis AUTH token as JSON {auth_token,port}. Null when the Redis cluster has no AUTH token."
  type        = string
  default     = null
}

variable "redis_auth_enabled" {
  description = "Whether Redis AUTH is used (known at plan time; gates reading redis_auth_secret_arn). Set false only if the Redis cluster has no AUTH token."
  type        = bool
  default     = true
}

# ------- Helm chart coordinates -------
# VERIFY: Confirm the current LiteLLM chart coordinates before applying. The community chart is
# published to https://berriai.github.io/litellm/ and also to oci://ghcr.io/berriai/litellm-helm.
# Set repository/chart/chart_version to match the release you intend to run.

variable "chart" {
  description = "LiteLLM Helm chart name (OCI-published)."
  type        = string
  default     = "litellm-helm"
}

variable "repository" {
  description = "OCI registry hosting the LiteLLM chart."
  type        = string
  default     = "oci://ghcr.io/berriai"
}

variable "chart_version" {
  description = "LiteLLM Helm chart version."
  type        = string
  default     = "1.103.0"
}

variable "release_name" {
  description = "Helm release name for the LiteLLM proxy."
  type        = string
  default     = "litellm"
}

variable "replicas" {
  description = "Number of LiteLLM proxy replicas."
  type        = number
  default     = 2
}

variable "run_db_migrations" {
  description = <<-EOT
    Whether this deployment runs the Prisma schema migration Job and allows schema updates. Set true on the
    PRIMARY (single writer owns the schema) and false on SECONDARY regions (they share the same Aurora global
    database and must not race migrations). When false, the migration Job is disabled and DISABLE_SCHEMA_UPDATE
    is set so the proxy does not attempt DDL against the (write-forwarded) database.
  EOT
  type        = bool
  default     = true
}

variable "image_tag" {
  description = "LiteLLM container image tag."
  type        = string
  default     = "main-stable"
}

variable "service_name" {
  description = "Name of the Kubernetes Service fronting the LiteLLM pods. The Ingress routes to this service."
  type        = string
  default     = "litellm"
}

variable "service_port" {
  description = "Port the LiteLLM Service and proxy listen on."
  type        = number
  default     = 4000
}

variable "system_node_selector" {
  description = "Node selector pinning LiteLLM pods to the CPU/system node tier."
  type        = map(string)
  default     = { workload = "system" }
}

# ------- Internal ALB Ingress (AWS Load Balancer Controller) -------

variable "subnet_ids" {
  description = "Optional private subnet IDs for the internal ALB (alb.ingress.kubernetes.io/subnets). When empty the controller auto-discovers subnets tagged kubernetes.io/role/internal-elb."
  type        = list(string)
  default     = []
}

variable "acm_cert_arn" {
  description = "ACM certificate ARN for the internal ALB HTTPS listener. The platform root passes either a reader-supplied cert or a generated self-signed cert. When null the ALB serves plain HTTP on port 80 (acceptable only because the ALB is internal / private)."
  type        = string
  default     = null
}

variable "waf_acl_arn" {
  description = "ARN of a REGIONAL AWS WAFv2 WebACL to associate with the Ingress ALB (via alb.ingress.kubernetes.io/wafv2-acl-arn). Used to restrict the LiteLLM admin UI to VPC source IPs while keeping /v1/* public. Null = no WAF."
  type        = string
  default     = null
}

variable "ingress_group_name" {
  description = "alb.ingress.kubernetes.io/group.name value, letting multiple Ingresses share one ALB. Null derives it from name_prefix."
  type        = string
  default     = null
}

variable "healthcheck_path" {
  description = "ALB target group health check path."
  type        = string
  default     = "/health/liveliness"
}

variable "alb_name" {
  description = "Deterministic internal ALB name (<=32 chars) set via load-balancer-name so the caller can resolve the ARN via a data source. Null derives it from name_prefix."
  type        = string
  default     = null
}
