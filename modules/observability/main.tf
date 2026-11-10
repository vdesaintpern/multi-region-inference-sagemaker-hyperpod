# Per-region inference observability for the HyperPod global inference sample.
#
# Provisions, for a single region:
#   - An Amazon Managed Prometheus (AMP) workspace to store inference metrics.
#   - The SageMaker HyperPod observability managed EKS add-on.
#   - A Prometheus collector (Helm) that scrapes pods annotated prometheus.io/scrape
#     (e.g. the LiteLLM /metrics endpoint) and remote_writes to the AMP workspace.
#   - An IRSA role granting the collector aps:RemoteWrite to the AMP workspace ARN.
#
# This module assumes the caller has already configured the aws, helm, and kubernetes providers
# (auth against the target cluster). It contains NO provider blocks by design.

locals {
  # Strip any leading scheme so the OIDC condition keys are built consistently.
  oidc_provider = replace(var.oidc_provider, "https://", "")

  amp_alias = coalesce(var.amp_alias, var.name_prefix)
}

# --------------------------------------------------------------------------------------------------
# Amazon Managed Prometheus workspace (metrics backend for this region).
# --------------------------------------------------------------------------------------------------

resource "aws_prometheus_workspace" "this" {
  alias = local.amp_alias
  tags  = merge(var.tags, { Name = "${var.name_prefix}-amp" })
}

# --------------------------------------------------------------------------------------------------
# IRSA role: Prometheus/ADOT collector -> aps:RemoteWrite to the AMP workspace.
# --------------------------------------------------------------------------------------------------

data "aws_iam_policy_document" "collector_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [var.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_provider}:sub"
      values   = ["system:serviceaccount:${var.prometheus_namespace}:${var.prometheus_service_account}"]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_provider}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "collector" {
  name               = "${var.name_prefix}-amp-collector"
  assume_role_policy = data.aws_iam_policy_document.collector_assume.json
  tags               = merge(var.tags, { Name = "${var.name_prefix}-amp-collector" })
}

data "aws_iam_policy_document" "collector" {
  statement {
    sid       = "AmpRemoteWrite"
    effect    = "Allow"
    actions   = ["aps:RemoteWrite"]
    resources = [aws_prometheus_workspace.this.arn]
  }
}

resource "aws_iam_role_policy" "collector" {
  name   = "${var.name_prefix}-amp-remote-write"
  role   = aws_iam_role.collector.id
  policy = data.aws_iam_policy_document.collector.json
}

# --------------------------------------------------------------------------------------------------
# KEDA replica-autoscaling reads vLLM metrics from AMP. The operator renders the KEDA ScaledObject with
# identityOwner: operator, so KEDA signs AMP queries with the HyperPod inference OPERATOR role (not the
# collector role). Grant that role aps:QueryMetrics on this workspace. WITHOUT this the query is 403 and
# the HPA shows <unknown>/target, so no scale-up ever fires. Gated on operator_role_name being provided.
# --------------------------------------------------------------------------------------------------

data "aws_iam_policy_document" "operator_amp_query" {
  count = var.operator_role_name != null ? 1 : 0
  statement {
    sid       = "AmpQuery"
    effect    = "Allow"
    actions   = ["aps:QueryMetrics"]
    resources = [aws_prometheus_workspace.this.arn]
  }
}

resource "aws_iam_role_policy" "operator_amp_query" {
  count  = var.operator_role_name != null ? 1 : 0
  name   = "${var.name_prefix}-amp-query"
  role   = var.operator_role_name
  policy = data.aws_iam_policy_document.operator_amp_query[0].json
}

# --------------------------------------------------------------------------------------------------
# SageMaker HyperPod observability managed EKS add-on.
#
# VERIFY: The exact add-on name is assumed to be "amazon-sagemaker-hyperpod-observability".
# Confirm the published add-on name with `aws eks describe-addon-versions` before deploying;
# the HyperPod inference operator ships as "amazon-sagemaker-hyperpod-inference", so the
# observability variant is expected to follow the same naming convention.
#
# VERIFY: The configuration_values schema for this add-on is assumed to accept the AMP workspace
# endpoint and region. Confirm the actual config schema (add-on may instead discover the AMP
# workspace via tags or a separate scraper resource). Passed via jsonencode below.
# --------------------------------------------------------------------------------------------------

resource "aws_eks_addon" "hyperpod_observability" {
  cluster_name                = var.cluster_name
  addon_name                  = "amazon-sagemaker-hyperpod-observability"
  addon_version               = var.hyperpod_observability_addon_version
  service_account_role_arn    = aws_iam_role.collector.arn
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  # Schema: ampWorkspace.prometheusEndpoint (required). The add-on deploys its own metric collectors
  # and remote-writes to AMP, so no separate Prometheus install is needed.
  configuration_values = jsonencode({
    ampWorkspace = {
      prometheusEndpoint = aws_prometheus_workspace.this.prometheus_endpoint
      arn                = aws_prometheus_workspace.this.arn
    }
  })

  tags = merge(var.tags, { Name = "${var.name_prefix}-hp-observability" })
}

# NOTE: A separate prometheus-community Helm collector is intentionally NOT installed. The HyperPod
# observability add-on above deploys its own managed collectors that remote-write to AMP. To also
# scrape the LiteLLM /metrics endpoint, add it via the add-on's `customServiceScrapeTargets` config.
