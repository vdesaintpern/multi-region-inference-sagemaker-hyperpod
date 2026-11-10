variable "name_prefix" {
  description = "Prefix for the central gateway resources (Aurora, Redis, LiteLLM, entry ALB, WAF, bastion)."
  type        = string
  default     = "sample-hpinf-gw"
}

variable "primary_region" {
  description = "Primary region: where the central gateway runs and where region roots publish SSM discovery. Must match the primary region root's region."
  type        = string
  default     = "us-east-1"
}

variable "regions" {
  description = "The set of regions whose clusters the gateway routes to (each must already be deployed via its region root and discoverable in SSM). Default is the primary + one added region. To add a region: deploy its region root, append it here, add an aws provider alias + a region-peering module block."
  type        = list(string)
  default     = ["us-east-1", "us-east-2"]
}

variable "ssm_prefix" {
  description = "SSM Parameter Store path prefix the region roots publish discovery under (read here)."
  type        = string
  default     = "/hpinf"
}

variable "tags" {
  description = "Common tags applied to every resource."
  type        = map(string)
  default     = {}
}

# ---- Remote state of the PRIMARY region root (rich cluster attach details) ----
variable "state_bucket" {
  description = "S3 bucket holding Terraform remote state (from 00-bootstrap). Used to read the primary region root's outputs."
  type        = string
}

variable "state_region" {
  description = "Region of the remote-state S3 bucket."
  type        = string
}

variable "primary_state_key" {
  description = "State key of the PRIMARY region root (e.g. region-us-east-1/terraform.tfstate)."
  type        = string
  default     = "region-us-east-1/terraform.tfstate"
}

# ---- Model catalog (served_model_name + litellm_alias per model key; MUST match the region roots) ----
variable "models" {
  description = "Model catalog. Keys + served_model_name + litellm_alias must match every region root's catalog so each region's model ALB lines up as a deployment under the alias."
  type = map(object({
    served_model_name = string
    litellm_alias     = string
  }))
}

# ---- Cross-region router behaviour (passed to the litellm module) ----
variable "routing_strategy" {
  description = "LiteLLM router strategy for NEW-session placement + spill across regions (session affinity pins cache-warm conversations first). least-busy | simple-shuffle | usage-based-routing-v2 | latency-based-routing | cost-based-routing."
  type        = string
  default     = "least-busy"
}

# ---- Entry ALB (internal) + TLS ----
variable "acm_certificate_arn" {
  description = "ACM certificate ARN for the internal entry ALB's HTTPS:443 listener. When null, the stack generates a self-signed cert for entry_domain and imports it into ACM."
  type        = string
  default     = null
}

variable "entry_domain" {
  description = "DNS name clients use for the entry ALB (CN of the self-signed cert when acm_certificate_arn is null). The ALB is internal; public exposure (and real DNS) is left to the reader."
  type        = string
  default     = "inference.hpinf.internal"
}

variable "admin_allowed_cidrs" {
  description = "Extra source CIDRs (beyond the primary VPC CIDR) allowed to reach the LiteLLM admin UI /ui through the entry ALB WAF. /v1/* is reachable from the whole private network."
  type        = list(string)
  default     = []
}

# ---- Bastion (SSM port-forward test host) ----
variable "enable_bastion" {
  description = "Create a temporary SSM bastion in the primary private subnet for testing the private entry ALB from local (aws ssm start-session port-forward). Default off."
  type        = bool
  default     = false
}

# ---- LiteLLM RBAC seed ----
variable "team_lead_email" {
  description = "Email for the seeded LiteLLM team lead."
  type        = string
  default     = "team-lead@example.com"
}

variable "developer_email" {
  description = "Email for the seeded LiteLLM developer (issued a virtual key)."
  type        = string
  default     = "developer@example.com"
}

variable "team_budget_usd" {
  description = "Monthly budget for the seeded LiteLLM team."
  type        = number
  default     = 100
}

variable "deletion_protection" {
  description = "Aurora deletion protection."
  type        = bool
  default     = false
}

variable "enable_grafana" {
  description = "Create a central Amazon Managed Grafana workspace with one AMP datasource per region (cross-region query). Default OFF: with AWS_SSO auth the workspace needs an AWS IAM Identity Center instance, and Identity Center is Region-scoped (an account instance cannot be called cross-Region), so enabling it couples the stack to a specific Identity Center Region. Turn on once that Region is settled, ideally creating the workspace in the same Region as your Identity Center instance. FIRST apply needs a two-phase bootstrap because the grafana provider's token comes from this same apply: `terraform apply -target=module.observability_global` then `terraform apply`. Subsequent applies are single-pass. Per-region AMP (enable_observability) is independent of this flag."
  type        = bool
  default     = false
}
