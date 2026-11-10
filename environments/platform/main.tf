# Platform root (primary region): the regions-aware "central gateway".
# Reads each region's discovery from SSM (published by the region roots) + the primary region root's rich
# cluster details from remote state, then stands up:
#   - a single regional Aurora (keys/budgets/spend) + Redis (rate limits + session-affinity pins)
#   - the central LiteLLM proxy (one deployment per region per model; affinity-first load routing)
#   - the internal entry ALB (provided or self-signed TLS) + WAF + optional SSM bastion
#   - cross-region VPC peering (star: primary <-> each other region) so LiteLLM reaches the model ALBs.

data "aws_caller_identity" "current" {}

# Rich attach details for the PRIMARY cluster (where LiteLLM runs): endpoint/CA/OIDC/subnets/SG/VPC.
data "terraform_remote_state" "primary" {
  backend = "s3"
  config = {
    bucket = var.state_bucket
    key    = var.primary_state_key
    region = var.state_region
  }
}

# Per-region discovery published by the region roots into THIS region's SSM.
data "aws_ssm_parameters_by_path" "regions" {
  path      = "${var.ssm_prefix}/regions/"
  recursive = true
}

locals {
  _names  = data.aws_ssm_parameters_by_path.regions.names
  _values = nonsensitive(data.aws_ssm_parameters_by_path.regions.values)
  _params = { for i, n in local._names : n => local._values[i] }

  # Each name is "${ssm_prefix}/regions/<region>/<leaf>" (single-level leaves).
  _entries = [
    for n, v in local._params : {
      region = split("/", trimprefix(n, "${var.ssm_prefix}/regions/"))[0]
      leaf   = split("/", trimprefix(n, "${var.ssm_prefix}/regions/"))[1]
      value  = v
    }
  ]
  _region_names = toset([for e in local._entries : e.region])

  regions = {
    for r in local._region_names : r => {
      vpc_id          = try([for e in local._entries : e.value if e.region == r && e.leaf == "vpc_id"][0], null)
      vpc_cidr        = try([for e in local._entries : e.value if e.region == r && e.leaf == "vpc_cidr"][0], null)
      route_table_ids = try(split(",", [for e in local._entries : e.value if e.region == r && e.leaf == "private_route_table_ids"][0]), [])
      amp_arn         = try([for e in local._entries : e.value if e.region == r && e.leaf == "amp_arn"][0], "none")
      model_albs      = try(jsondecode([for e in local._entries : e.value if e.region == r && e.leaf == "model_albs"][0]), {})
      # SecureString leaf (decrypted by the data source); the header LiteLLM must send to reach this region's model ALBs.
      model_gw_token = try([for e in local._entries : e.value if e.region == r && e.leaf == "model_gw_token"][0], null)
    }
  }

  # Only route to regions the operator has opted into via var.regions (and that have published discovery).
  active_regions = { for r, info in local.regions : r => info if contains(var.regions, r) }

  # One LiteLLM deployment per (model, region): entries sharing litellm_alias form the cross-region group.
  deployments = flatten([
    for mkey, m in var.models : [
      for r, info in local.active_regions : {
        litellm_alias     = m.litellm_alias
        served_model_name = m.served_model_name
        api_base          = "https://${info.model_albs[mkey]}/v1"
        gateway_token     = info.model_gw_token
      } if try(info.model_albs[mkey], null) != null
    ]
  ])

  primary_vpc_id   = data.terraform_remote_state.primary.outputs.vpc_id
  primary_vpc_cidr = data.terraform_remote_state.primary.outputs.vpc_cidr
  primary_subnets  = data.terraform_remote_state.primary.outputs.private_subnet_ids
}

# --------------------------------------------------------------------------------------------------
# Central data tier: single regional Aurora (virtual keys/budgets/spend) + Redis (rate limits + the
# session-affinity pins that keep each conversation on its cache-warm region).
# --------------------------------------------------------------------------------------------------

module "litellm_state" {
  source = "../../modules/litellm-state"

  name_prefix                = var.name_prefix
  tags                       = var.tags
  vpc_id                     = local.primary_vpc_id
  private_subnet_ids         = local.primary_subnets
  allowed_security_group_ids = [data.terraform_remote_state.primary.outputs.node_security_group_id]
  allowed_cidr_blocks        = []
  deletion_protection        = var.deletion_protection
}

# --------------------------------------------------------------------------------------------------
# LiteLLM admin key.
# --------------------------------------------------------------------------------------------------

resource "random_password" "master_key" {
  length  = 40
  special = false
}

# Customer-managed KMS key for platform secrets (e.g. the LiteLLM admin key).
resource "aws_kms_key" "secrets" {
  description             = "Encrypts ${var.name_prefix} platform secrets (LiteLLM admin key)."
  enable_key_rotation     = true
  deletion_window_in_days = 30
  tags                    = merge(var.tags, { Name = "${var.name_prefix}-platform-secrets" })
}

resource "aws_kms_alias" "secrets" {
  name          = "alias/${var.name_prefix}-platform-secrets"
  target_key_id = aws_kms_key.secrets.key_id
}

resource "aws_secretsmanager_secret" "master_key" {
  name        = "${var.name_prefix}-litellm-master-key"
  description = "LiteLLM proxy master key (admin)."
  kms_key_id  = aws_kms_key.secrets.arn
  # Free the fixed name immediately on destroy so a redeploy does not collide with a recovery-window secret.
  recovery_window_in_days = 0
  tags                    = merge(var.tags, { Name = "${var.name_prefix}-litellm-master-key" })
}

resource "aws_secretsmanager_secret_version" "master_key" {
  secret_id     = aws_secretsmanager_secret.master_key.id
  secret_string = "sk-${random_password.master_key.result}"
}

# --------------------------------------------------------------------------------------------------
# Entry ALB TLS: use the provided ACM cert, or generate a self-signed cert and import it into ACM.
# The ALB is scheme=internal; the self-signed cert is acceptable for a private entrypoint (the reader
# supplies a real cert / public exposure). Clients must trust the cert or skip verification (curl -k).
# --------------------------------------------------------------------------------------------------

resource "tls_private_key" "entry" {
  count     = var.acm_certificate_arn == null ? 1 : 0
  algorithm = "RSA"
  rsa_bits  = 2048
}

resource "tls_self_signed_cert" "entry" {
  count           = var.acm_certificate_arn == null ? 1 : 0
  private_key_pem = tls_private_key.entry[0].private_key_pem

  subject {
    common_name = var.entry_domain
  }
  dns_names             = [var.entry_domain]
  validity_period_hours = 8760 # 1 year
  allowed_uses          = ["key_encipherment", "digital_signature", "server_auth"]
}

resource "aws_acm_certificate" "entry" {
  count            = var.acm_certificate_arn == null ? 1 : 0
  private_key      = tls_private_key.entry[0].private_key_pem
  certificate_body = tls_self_signed_cert.entry[0].cert_pem
  tags             = merge(var.tags, { Name = var.entry_domain })

  lifecycle {
    create_before_destroy = true
  }
}

locals {
  entry_cert_arn = var.acm_certificate_arn != null ? var.acm_certificate_arn : aws_acm_certificate.entry[0].arn
}

# --------------------------------------------------------------------------------------------------
# REGIONAL WAFv2 on the entry ALB: admins (primary VPC CIDR + extra admin CIDRs, e.g. the bastion) may
# reach every path incl. /ui; /v1/* is reachable from the whole private network; everything else blocked.
# --------------------------------------------------------------------------------------------------

resource "aws_wafv2_ip_set" "admin_allow" {
  name               = "${var.name_prefix}-admin-allow"
  scope              = "REGIONAL"
  ip_address_version = "IPV4"
  addresses          = concat([local.primary_vpc_cidr], var.admin_allowed_cidrs)
  tags               = var.tags
}

resource "aws_wafv2_web_acl" "entry" {
  name  = "${var.name_prefix}-litellm"
  scope = "REGIONAL"
  tags  = var.tags

  default_action {
    block {}
  }

  # AWS managed "known bad inputs" rule group. Runs FIRST (lowest priority number) so malicious payloads
  # -- including the Log4j/Log4Shell JNDI lookup (CVE-2021-44228) -- are blocked even on the otherwise
  # allowed admin and /v1 paths, before the allow rules below can let the request through.
  rule {
    name     = "aws-known-bad-inputs"
    priority = 0
    override_action {
      none {}
    }
    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesKnownBadInputsRuleSet"
        vendor_name = "AWS"
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.name_prefix}-known-bad-inputs"
      sampled_requests_enabled   = true
    }
  }

  rule {
    name     = "allow-admin-source-ips"
    priority = 1
    action {
      allow {}
    }
    statement {
      ip_set_reference_statement {
        arn = aws_wafv2_ip_set.admin_allow.arn
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.name_prefix}-admin"
      sampled_requests_enabled   = true
    }
  }

  rule {
    name     = "allow-inference-v1"
    priority = 2
    action {
      allow {}
    }
    statement {
      byte_match_statement {
        positional_constraint = "STARTS_WITH"
        search_string         = "/v1"
        field_to_match {
          uri_path {}
        }
        text_transformation {
          priority = 0
          type     = "NONE"
        }
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.name_prefix}-v1"
      sampled_requests_enabled   = true
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "${var.name_prefix}-waf"
    sampled_requests_enabled   = true
  }
}

# --------------------------------------------------------------------------------------------------
# Central LiteLLM proxy (runs in the primary cluster) + RBAC seed.
# --------------------------------------------------------------------------------------------------

module "litellm" {
  source = "../../modules/litellm"

  name_prefix = var.name_prefix
  tags        = var.tags
  namespace   = "litellm"

  deployments      = local.deployments
  routing_strategy = var.routing_strategy

  master_key_secret_arn = aws_secretsmanager_secret.master_key.arn
  db_secret_arn         = module.litellm_state.db_secret_arn
  db_host               = module.litellm_state.cluster_writer_endpoint
  run_db_migrations     = true
  redis_host            = module.litellm_state.redis_primary_endpoint
  redis_port            = module.litellm_state.redis_port
  redis_auth_secret_arn = module.litellm_state.redis_auth_secret_arn

  subnet_ids   = local.primary_subnets
  acm_cert_arn = local.entry_cert_arn
  waf_acl_arn  = aws_wafv2_web_acl.entry.arn

  depends_on = [aws_wafv2_web_acl.entry]
}

module "litellm_rbac" {
  source = "../../modules/litellm-rbac"

  name_prefix            = var.name_prefix
  tags                   = var.tags
  namespace              = "litellm"
  master_key_secret_name = module.litellm.masterkey_secret_name
  master_key_secret_key  = "masterkey"
  team_budget_usd        = var.team_budget_usd
  team_lead_email        = var.team_lead_email
  developer_email        = var.developer_email
  oidc_provider_arn      = data.terraform_remote_state.primary.outputs.oidc_provider_arn
  oidc_provider          = data.terraform_remote_state.primary.outputs.oidc_provider
  region                 = var.primary_region

  depends_on = [module.litellm]
}

# --------------------------------------------------------------------------------------------------
# Temporary SSM bastion (private subnet, no SSH/public IP) for testing the internal entry ALB from local:
#   aws ssm start-session --target <id> --document-name AWS-StartPortForwardingSessionToRemoteHost \
#     --parameters '{"host":["<alb-dns>"],"portNumber":["443"],"localPortNumber":["8443"]}'
#   curl -k https://localhost:8443/v1/models -H "Authorization: Bearer <dev-key>"
# --------------------------------------------------------------------------------------------------

module "bastion" {
  source = "../../modules/jumpbox"
  count  = var.enable_bastion ? 1 : 0

  name_prefix = "${var.name_prefix}-bastion"
  vpc_id      = local.primary_vpc_id
  subnet_id   = local.primary_subnets[0]
  tags        = var.tags
}

# --------------------------------------------------------------------------------------------------
# Cross-region VPC peering (star): primary <-> each other region, so the central LiteLLM reaches that
# region's model ALBs privately. One block per peer region (static providers). To add a region: add an
# aws alias in providers.tf + another block here + the region to var.regions.
# --------------------------------------------------------------------------------------------------

module "peering_use2" {
  source = "../../modules/region-peering"
  count  = contains(var.regions, "us-east-2") && var.primary_region != "us-east-2" ? 1 : 0

  providers = {
    aws      = aws
    aws.peer = aws.use2
  }

  name_prefix = var.name_prefix
  tags        = var.tags

  requester_vpc_id          = local.primary_vpc_id
  requester_cidr            = local.primary_vpc_cidr
  requester_route_table_ids = data.terraform_remote_state.primary.outputs.private_route_table_ids

  peer_vpc_id          = try(local.regions["us-east-2"].vpc_id, null)
  peer_region          = "us-east-2"
  peer_cidr            = try(local.regions["us-east-2"].vpc_cidr, null)
  peer_route_table_ids = try(local.regions["us-east-2"].route_table_ids, [])
}

# --------------------------------------------------------------------------------------------------
# Central Amazon Managed Grafana: one workspace querying every region's AMP (cross-region). The AMP
# datasources are provisioned via the grafana provider, whose token comes from the module below - so a
# clean first apply is two-phase (see the note in providers.tf / var.enable_grafana).
# --------------------------------------------------------------------------------------------------

module "observability_global" {
  source = "../../modules/observability-global"
  count  = var.enable_grafana ? 1 : 0

  name_prefix        = var.name_prefix
  tags               = var.tags
  amp_workspace_arns = [for r, info in local.active_regions : info.amp_arn if info.amp_arn != "none"]
}

# One Prometheus (AMP) datasource per region, SigV4-signed by the workspace's own IAM role.
resource "grafana_data_source" "amp" {
  for_each = var.enable_grafana ? { for r, info in local.active_regions : r => info if info.amp_arn != "none" } : {}

  type       = "prometheus"
  name       = "AMP-${each.key}"
  url        = "https://aps-workspaces.${element(split(":", each.value.amp_arn), 3)}.amazonaws.com/workspaces/${element(split("/", each.value.amp_arn), 1)}/"
  is_default = each.key == var.primary_region

  json_data_encoded = jsonencode({
    httpMethod    = "POST"
    sigV4Auth     = true
    sigV4AuthType = "ec2_iam_role"
    sigV4Region   = element(split(":", each.value.amp_arn), 3)
  })

  depends_on = [module.observability_global]
}
