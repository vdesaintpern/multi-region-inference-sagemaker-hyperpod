# Central (global) Amazon Managed Grafana workspace for the HyperPod global inference sample.
#
# A single Grafana workspace (created in the primary region, us-east-2) aggregates metrics and logs from
# BOTH regional stacks: the per-region Amazon Managed Prometheus workspaces (inference/LiteLLM metrics)
# and CloudWatch (metrics + Logs Insights) across regions. Amazon Managed Grafana can query AMP/CloudWatch
# cross-region, so it does not need to live in any particular region.
#
# This module uses the caller's default aws provider (the primary region). It contains NO provider blocks.
#
# Datasources + dashboards ARE provisioned via Terraform, using the Grafana provider (configured in the
# global env root). To authenticate that provider without SSO, this module mints an ADMIN Grafana
# service-account token and exposes it (sensitive) alongside the workspace endpoint. The AMP datasource
# (SigV4, signed by this workspace's own IAM role) and the sample dashboards are then created as
# grafana_data_source / grafana_dashboard resources in the root.

locals {
  # Scope aps:* to the supplied workspace ARNs; fall back to "*" when none are provided
  # (e.g. before the regional workspaces exist). Prefer passing explicit ARNs in production.
  aps_resources = length(var.amp_workspace_arns) > 0 ? var.amp_workspace_arns : ["*"]
}

# --------------------------------------------------------------------------------------------------
# IAM role assumed by the Amazon Managed Grafana service (SERVICE_MANAGED permissions).
# --------------------------------------------------------------------------------------------------

data "aws_iam_policy_document" "grafana_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["grafana.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "grafana" {
  name               = "${var.name_prefix}-grafana"
  assume_role_policy = data.aws_iam_policy_document.grafana_assume.json
  tags               = merge(var.tags, { Name = "${var.name_prefix}-grafana" })
}

data "aws_iam_policy_document" "grafana" {
  # checkov:skip=CKV_AWS_356: The CloudWatch metrics (GetMetricData, ListMetrics, GetMetricStatistics)
  #   and CloudWatch Logs Insights (StartQuery, GetQueryResults, etc.) actions do not support
  #   resource-level permissions in IAM, so "*" is required. The AMP statement is workspace-scoped.
  # Amazon Managed Prometheus query access to the regional workspaces.
  # Note: aps:ListWorkspaces is an account-level action and effectively ignores resource scoping,
  # but is grouped here for a single readable data-source policy.
  statement {
    sid    = "AmpQuery"
    effect = "Allow"
    actions = [
      "aps:QueryMetrics",
      "aps:GetLabels",
      "aps:GetSeries",
      "aps:GetMetricMetadata",
      "aps:ListWorkspaces",
    ]
    resources = local.aps_resources
  }

  # CloudWatch metrics data source (across regions).
  statement {
    sid    = "CloudWatchMetrics"
    effect = "Allow"
    actions = [
      "cloudwatch:GetMetricData",
      "cloudwatch:ListMetrics",
      "cloudwatch:DescribeAlarms",
      "cloudwatch:GetMetricStatistics",
    ]
    resources = ["*"]
  }

  # CloudWatch Logs (Logs Insights) data source (across regions).
  statement {
    sid    = "CloudWatchLogs"
    effect = "Allow"
    actions = [
      "logs:GetLogEvents",
      "logs:GetLogGroupFields",
      "logs:GetLogRecord",
      "logs:GetQueryResults",
      "logs:StartQuery",
      "logs:StopQuery",
      "logs:DescribeLogGroups",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "grafana" {
  name   = "${var.name_prefix}-grafana-data-sources"
  role   = aws_iam_role.grafana.id
  policy = data.aws_iam_policy_document.grafana.json
}

# --------------------------------------------------------------------------------------------------
# Amazon Managed Grafana workspace.
#
# VERIFY: authentication_providers defaults to ["AWS_SSO"], which REQUIRES AWS IAM Identity Center
# (formerly AWS SSO) to be enabled in the account/organization before this workspace can be created.
# If Identity Center is not enabled, either enable it or override authentication_providers with
# ["SAML"] and configure an external IdP.
# --------------------------------------------------------------------------------------------------

resource "aws_grafana_workspace" "this" {
  name                     = "${var.name_prefix}-grafana"
  account_access_type      = "CURRENT_ACCOUNT"
  authentication_providers = var.authentication_providers
  permission_type          = "SERVICE_MANAGED"
  role_arn                 = aws_iam_role.grafana.arn
  data_sources             = ["PROMETHEUS", "CLOUDWATCH"]

  tags = merge(var.tags, { Name = "${var.name_prefix}-grafana" })
}

# --------------------------------------------------------------------------------------------------
# ADMIN service account + token used ONLY to let the Grafana provider (in the root) create the AMP
# datasource and the sample dashboards. SSO/SAML is for human UI login; this token is for Terraform.
# The token is stored (sensitive) in state; it is recreated automatically when it expires.
# --------------------------------------------------------------------------------------------------

resource "aws_grafana_workspace_service_account" "provisioner" {
  name         = "terraform-provisioner"
  grafana_role = "ADMIN"
  workspace_id = aws_grafana_workspace.this.id
}

resource "aws_grafana_workspace_service_account_token" "provisioner" {
  name               = "terraform-provisioner"
  service_account_id = aws_grafana_workspace_service_account.provisioner.service_account_id
  seconds_to_live    = var.provisioner_token_ttl_seconds
  workspace_id       = aws_grafana_workspace.this.id
}
