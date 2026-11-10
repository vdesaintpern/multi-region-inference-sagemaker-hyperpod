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
  description = "Kubernetes namespace the LiteLLM proxy (and this seeding Job) run in."
  type        = string
  default     = "litellm"
}

variable "litellm_service" {
  description = "Name of the in-cluster LiteLLM Service the Job calls."
  type        = string
  default     = "litellm"
}

variable "litellm_port" {
  description = "Port the LiteLLM Service listens on."
  type        = number
  default     = 4000
}

variable "master_key_secret_name" {
  description = "Name of the Kubernetes Secret (created by the litellm module) that holds the master key. The Job reads it to authenticate to the LiteLLM management API."
  type        = string
}

variable "master_key_secret_key" {
  description = "Key within master_key_secret_name that holds the master key value."
  type        = string
  default     = "LITELLM_MASTER_KEY"
}

variable "team_name" {
  description = "Alias of the team to create in LiteLLM."
  type        = string
  default     = "genai-team"
}

variable "team_budget_usd" {
  description = "Maximum spend budget (USD) applied to the team."
  type        = number
  default     = 100
}

variable "team_lead_email" {
  description = "Email of the team lead, created as a team_admin user."
  type        = string
}

variable "developer_email" {
  description = "Email of the developer, created as an internal_user (team member) and issued a virtual key."
  type        = string
}

# ------- Generated developer key -> Secrets Manager -------

variable "create_dev_key_secret" {
  description = "If true, this module creates the Secrets Manager secret that receives the generated developer key. If false, provide dev_key_secret_arn."
  type        = bool
  default     = true
}

variable "dev_key_secret_arn" {
  description = "Existing Secrets Manager secret ARN to store the generated developer key into. Required when create_dev_key_secret = false."
  type        = string
  default     = null
}

variable "kms_key_id" {
  description = "Optional KMS key ID/ARN to encrypt the created developer-key secret. Null uses the aws/secretsmanager managed key. Only used when create_dev_key_secret = true."
  type        = string
  default     = null
}

# ------- IRSA (lets the Job write the generated key to Secrets Manager) -------

variable "create_irsa_role" {
  description = "If true, create an IRSA role scoped to secretsmanager:PutSecretValue on the dev-key secret. If false, provide irsa_role_arn."
  type        = bool
  default     = true
}

variable "oidc_provider_arn" {
  description = "ARN of the EKS cluster IAM OIDC provider. Required when create_irsa_role = true."
  type        = string
  default     = null
}

variable "oidc_provider" {
  description = "EKS cluster OIDC provider URL WITHOUT the https:// scheme. Required when create_irsa_role = true."
  type        = string
  default     = null
}

variable "irsa_role_arn" {
  description = "Existing IRSA role ARN to annotate the Job service account with. Required when create_irsa_role = false. Must allow secretsmanager:PutSecretValue on the dev-key secret."
  type        = string
  default     = null
}

variable "service_account_name" {
  description = "Name of the Kubernetes ServiceAccount the seeding Job runs as."
  type        = string
  default     = "litellm-rbac-seeder"
}

# ------- Job runtime -------

variable "job_image" {
  description = "Container image for the seeding Job. VERIFY: the image must provide a POSIX shell plus curl, jq, and the AWS CLI. The default Alpine image installs them at runtime via apk (requires egress); for production build a purpose-built image and pin it."
  type        = string
  default     = "public.ecr.aws/docker/library/alpine:3.20"
}

variable "region" {
  description = "AWS region for the AWS CLI put-secret-value call. Null relies on AWS_REGION being injected by the IRSA/pod-identity webhook."
  type        = string
  default     = null
}

variable "system_node_selector" {
  description = "Node selector pinning the Job pod to the CPU/system node tier."
  type        = map(string)
  default     = { workload = "system" }
}

variable "backoff_limit" {
  description = "Number of retries before the Job is marked failed (the proxy may take time to become ready)."
  type        = number
  default     = 6
}
