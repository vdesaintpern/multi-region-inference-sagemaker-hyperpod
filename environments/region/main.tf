# Region root: VPC -> EKS + HyperPod -> regional serving stack (models + per-model internal ALBs).
# Applied once per region, including the primary. Publishes this region's discovery entries into the
# PRIMARY region's SSM (via the aws.primary provider) so the platform root can build the central
# LiteLLM's per-region deployments and the cross-region VPC peering without any hand-wiring.

module "network" {
  source = "../../modules/regional-network"

  name_prefix = var.name_prefix
  tags        = var.tags
  create_vpc  = true
  vpc_cidr    = var.vpc_cidr
  az_count    = var.az_count
}

module "cluster" {
  source = "../../modules/eks-hyperpod"

  name_prefix        = var.name_prefix
  tags               = var.tags
  vpc_id             = module.network.vpc_id
  private_subnet_ids = module.network.private_subnet_ids
  gpu_subnet_id      = module.network.gpu_subnet_id
  gpu_instance_type  = var.gpu_instance_type
  gpu_instance_types = var.gpu_instance_types
  gpu_instance_count = var.gpu_instance_count
}

module "platform" {
  source = "../../modules/regional-stack"

  name_prefix = var.name_prefix
  tags        = var.tags
  region      = var.region

  vpc_id             = module.network.vpc_id
  vpc_cidr           = module.network.vpc_cidr
  private_subnet_ids = module.network.private_subnet_ids

  cluster_name           = module.cluster.cluster_name
  oidc_provider_arn      = module.cluster.oidc_provider_arn
  oidc_provider          = module.cluster.oidc_provider
  node_security_group_id = module.cluster.node_security_group_id
  hyperpod_cluster_arn   = module.cluster.hyperpod_cluster_arn
  gpu_instance_type      = replace(var.gpu_instance_type, "ml.", "")

  models               = var.models
  hf_token_secret_arn  = var.hf_token_secret_arn
  enable_observability = var.enable_observability

  # The per-model internal ALBs accept this region's own VPC (health checks / local calls) plus any extra
  # client CIDRs - on a NON-primary region that is the primary VPC CIDR, so the central LiteLLM can reach
  # the model ALBs over VPC peering.
  model_alb_inbound_cidrs = concat([module.network.vpc_cidr], var.client_cidrs)
}

# --- Publish this region's discovery entries into the PRIMARY region's SSM ---
# The platform root reads ${ssm_prefix}/regions/<region>/* to build the LiteLLM deployments (model_albs),
# the Grafana data sources (amp_arn), and the cross-region VPC peering (vpc_id / vpc_cidr / route tables).
locals {
  discovery = {
    "regions/${var.region}/vpc_id"                  = module.network.vpc_id
    "regions/${var.region}/vpc_cidr"                = module.network.vpc_cidr
    "regions/${var.region}/private_route_table_ids" = join(",", module.network.private_route_table_ids)
    "regions/${var.region}/amp_arn"                 = module.platform.amp_workspace_arn == null ? "none" : module.platform.amp_workspace_arn
    # JSON map { model_key => internal ALB DNS }. The platform builds api_base = https://<dns>/v1 per model.
    "regions/${var.region}/model_albs" = jsonencode(module.platform.model_alb_hostnames)
  }
}

resource "aws_ssm_parameter" "discovery" {
  for_each = local.discovery
  provider = aws.primary

  name  = "${var.ssm_prefix}/${each.key}"
  type  = "String"
  value = each.value
  tags  = var.tags
}

# Customer-managed KMS key for the SecureString parameter below. Lives in the PRIMARY region (same as
# the parameter, written via aws.primary) because an SSM SecureString must use a key in its own region.
# Uses the default root-delegation key policy (as elsewhere in this sample); access is then governed by
# the deployer IAM policy, which grants the KMS actions the writer (encrypt) and platform reader (decrypt)
# need. A customer-managed key is required so the token is not encrypted under the shared aws/ssm key.
resource "aws_kms_key" "ssm" {
  provider = aws.primary

  description             = "Encrypts the ${var.region} model-ALB gateway token SecureString in SSM."
  enable_key_rotation     = true
  deletion_window_in_days = 7
  tags                    = merge(var.tags, { Name = "${var.name_prefix}-ssm-${var.region}" })
}

resource "aws_kms_alias" "ssm" {
  provider = aws.primary

  name          = "alias/${var.name_prefix}-ssm-${var.region}"
  target_key_id = aws_kms_key.ssm.key_id
}

# The model-ALB gateway token is a secret, so it is published separately as a SecureString. The platform
# root reads it (with decryption) and injects it into LiteLLM so only LiteLLM can reach the model ALBs.
resource "aws_ssm_parameter" "model_gw_token" {
  provider = aws.primary

  name   = "${var.ssm_prefix}/regions/${var.region}/model_gw_token"
  type   = "SecureString"
  value  = module.platform.model_gateway_token
  key_id = aws_kms_key.ssm.arn
  tags   = var.tags
}
