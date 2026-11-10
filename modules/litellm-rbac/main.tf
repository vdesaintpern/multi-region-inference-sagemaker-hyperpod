# Seed LiteLLM RBAC after the proxy is deployed.
#
# Runs a one-shot Kubernetes Job that calls the in-cluster LiteLLM management API
# (http://<service>.<namespace>:<port>) with the master key to create:
#   - 1 team with a spend budget           (POST /team/new)
#   - 1 team lead as a team_admin user      (POST /user/new)
#   - 1 developer as an internal_user       (POST /user/new)
#   - 1 virtual key for the developer       (POST /key/generate)
# The generated developer key is written back to Secrets Manager so it can be surfaced securely
# (the Job assumes an IRSA role scoped to PutSecretValue on that one secret). The master key is read
# from the Kubernetes Secret created by the litellm module and never leaves the cluster.
#
# This module assumes the caller has already configured the aws and kubernetes providers. It
# contains NO provider blocks by design.

locals {
  # Strip any leading scheme so the OIDC condition keys are built consistently.
  oidc_provider = var.oidc_provider != null ? replace(var.oidc_provider, "https://", "") : null

  dev_key_secret_arn = var.create_dev_key_secret ? aws_secretsmanager_secret.dev_key[0].arn : var.dev_key_secret_arn
  irsa_role_arn      = var.create_irsa_role ? aws_iam_role.job[0].arn : var.irsa_role_arn

  litellm_base = "http://${var.litellm_service}.${var.namespace}:${var.litellm_port}"

  # POSIX-sh seeding script. All runtime values are passed as env vars (no Terraform interpolation
  # into the script body), so shell $VAR references are safe and quoting stays simple.
  job_script = <<-EOT
    set -eu

    echo "Installing curl, jq, aws-cli ..."
    apk add --no-cache curl jq aws-cli >/dev/null

    AUTH="Authorization: Bearer $LITELLM_MASTER_KEY"
    CT="Content-Type: application/json"

    # post PATH PAYLOAD [OK_CODE...] -> echoes response body. HTTP < 300 is success; any extra
    # OK_CODE (e.g. 409 "already exists") is treated as an idempotent no-op. This Job runs against a
    # PERSISTENT Aurora DB, so it must be safe to re-run: users/teams may already exist from a prior
    # apply.
    post() {
      _path=$1; _payload=$2; shift 2
      _resp=$(curl -s -w '\n%%{http_code}' -X POST "$LITELLM_BASE$_path" -H "$AUTH" -H "$CT" -d "$_payload")
      _code=$(echo "$_resp" | tail -n1)
      _body=$(echo "$_resp" | sed '$d')
      if [ "$_code" -lt 300 ]; then echo "$_body"; return 0; fi
      for _ok in "$@"; do
        if [ "$_code" = "$_ok" ]; then echo "  ($_path -> HTTP $_code, treating as already-applied)" >&2; return 0; fi
      done
      echo "  POST $_path failed (HTTP $_code): $_body" >&2
      return 1
    }

    echo "Waiting for LiteLLM proxy at $LITELLM_BASE ..."
    until curl -sf "$LITELLM_BASE/health/liveliness" >/dev/null; do
      echo "  proxy not ready, retrying in 5s"
      sleep 5
    done

    echo "Creating team $TEAM_NAME with budget $TEAM_BUDGET USD"
    TEAM_PAYLOAD=$(jq -n --arg alias "$TEAM_NAME" --argjson budget "$TEAM_BUDGET" '{team_alias:$alias, max_budget:$budget}')
    TEAM=$(post /team/new "$TEAM_PAYLOAD")
    TEAM_ID=$(echo "$TEAM" | jq -r '.team_id')
    echo "  team_id=$TEAM_ID"

    # LiteLLM has two role layers: a GLOBAL user_role on /user/new (proxy_admin, internal_user, ...)
    # and a per-TEAM role set via /team/member_add ("admin" or "user"). "team_admin" is NOT a valid
    # global user_role -- both users are created as internal_user, then added to the team with the
    # appropriate per-team role. 409 (user exists) and 400 (already a team member) are tolerated.
    echo "Creating team lead $TEAM_LEAD_EMAIL (internal_user; team admin)"
    LEAD_PAYLOAD=$(jq -n --arg email "$TEAM_LEAD_EMAIL" '{user_email:$email, user_role:"internal_user", auto_create_key:false}')
    post /user/new "$LEAD_PAYLOAD" 409 >/dev/null
    LEAD_MEMBER=$(jq -n --arg team "$TEAM_ID" --arg email "$TEAM_LEAD_EMAIL" '{team_id:$team, member:{role:"admin", user_email:$email}}')
    post /team/member_add "$LEAD_MEMBER" 400 409 >/dev/null

    echo "Creating developer $DEVELOPER_EMAIL (internal_user; team member)"
    DEV_PAYLOAD=$(jq -n --arg email "$DEVELOPER_EMAIL" '{user_email:$email, user_role:"internal_user", auto_create_key:false}')
    DEV=$(post /user/new "$DEV_PAYLOAD" 409)
    DEV_USER_ID=$(echo "$DEV" | jq -r '.user_id // empty')
    DEV_MEMBER=$(jq -n --arg team "$TEAM_ID" --arg email "$DEVELOPER_EMAIL" '{team_id:$team, member:{role:"user", user_email:$email}}')
    post /team/member_add "$DEV_MEMBER" 400 409 >/dev/null

    # Tie the key to the developer's user_id when we just created them; otherwise scope it to the team
    # (still enforces the team budget). Either way it is a usable virtual key.
    echo "Generating virtual key for the developer"
    if [ -n "$DEV_USER_ID" ]; then
      KEY_PAYLOAD=$(jq -n --arg team "$TEAM_ID" --arg uid "$DEV_USER_ID" '{team_id:$team, user_id:$uid}')
    else
      KEY_PAYLOAD=$(jq -n --arg team "$TEAM_ID" '{team_id:$team}')
    fi
    KEY_RESP=$(post /key/generate "$KEY_PAYLOAD")
    DEV_KEY=$(echo "$KEY_RESP" | jq -r '.key')

    echo "Storing developer key in Secrets Manager ($DEV_KEY_SECRET_ARN)"
    aws secretsmanager put-secret-value --secret-id "$DEV_KEY_SECRET_ARN" --secret-string "$DEV_KEY"

    echo "LiteLLM RBAC seeding complete."
  EOT
}

# --------------------------------------------------------------------------------------------------
# Secrets Manager secret for the generated developer key.
# --------------------------------------------------------------------------------------------------

resource "aws_secretsmanager_secret" "dev_key" {
  count       = var.create_dev_key_secret ? 1 : 0
  name        = "${var.name_prefix}-litellm-dev-key"
  description = "LiteLLM virtual key issued to the developer by the RBAC seeding Job."
  kms_key_id  = var.kms_key_id
  # Sample is frequently torn down and redeployed; free the fixed name immediately on destroy so a
  # redeploy does not collide with a secret still inside its recovery window.
  recovery_window_in_days = 0
  tags                    = merge(var.tags, { Name = "${var.name_prefix}-litellm-dev-key" })
}

# --------------------------------------------------------------------------------------------------
# IRSA role for the Job: least-privilege write to the one dev-key secret.
# --------------------------------------------------------------------------------------------------

data "aws_iam_policy_document" "assume" {
  count = var.create_irsa_role ? 1 : 0

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
      values   = ["system:serviceaccount:${var.namespace}:${var.service_account_name}"]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_provider}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "job" {
  count              = var.create_irsa_role ? 1 : 0
  name               = "${var.name_prefix}-litellm-rbac-seeder"
  assume_role_policy = data.aws_iam_policy_document.assume[0].json
  tags               = merge(var.tags, { Name = "${var.name_prefix}-litellm-rbac-seeder" })
}

data "aws_iam_policy_document" "put_dev_key" {
  count = var.create_irsa_role ? 1 : 0

  statement {
    effect = "Allow"
    actions = [
      "secretsmanager:PutSecretValue",
      "secretsmanager:DescribeSecret",
    ]
    resources = [local.dev_key_secret_arn]
  }
}

resource "aws_iam_role_policy" "put_dev_key" {
  count  = var.create_irsa_role ? 1 : 0
  name   = "${var.name_prefix}-litellm-rbac-put-dev-key"
  role   = aws_iam_role.job[0].id
  policy = data.aws_iam_policy_document.put_dev_key[0].json
}

# --------------------------------------------------------------------------------------------------
# Service account (annotated with the IRSA role) + seeding Job.
# --------------------------------------------------------------------------------------------------

resource "kubernetes_service_account" "job" {
  metadata {
    name      = var.service_account_name
    namespace = var.namespace
    annotations = {
      "eks.amazonaws.com/role-arn" = local.irsa_role_arn
    }
    labels = { "app.kubernetes.io/managed-by" = "terraform" }
  }
}

resource "kubernetes_job_v1" "seed" {
  metadata {
    name      = "${var.name_prefix}-litellm-rbac"
    namespace = var.namespace
    labels    = { "app.kubernetes.io/managed-by" = "terraform" }
  }

  spec {
    backoff_limit = var.backoff_limit

    template {
      metadata {
        labels = { "app.kubernetes.io/name" = "litellm-rbac-seeder" }
      }

      spec {
        service_account_name = kubernetes_service_account.job.metadata[0].name
        restart_policy       = "OnFailure"
        node_selector        = var.system_node_selector

        container {
          name    = "seeder"
          image   = var.job_image
          command = ["/bin/sh", "-c", local.job_script]

          env {
            name = "LITELLM_MASTER_KEY"
            value_from {
              secret_key_ref {
                name = var.master_key_secret_name
                key  = var.master_key_secret_key
              }
            }
          }

          env {
            name  = "LITELLM_BASE"
            value = local.litellm_base
          }

          env {
            name  = "TEAM_NAME"
            value = var.team_name
          }

          env {
            name  = "TEAM_BUDGET"
            value = tostring(var.team_budget_usd)
          }

          env {
            name  = "TEAM_LEAD_EMAIL"
            value = var.team_lead_email
          }

          env {
            name  = "DEVELOPER_EMAIL"
            value = var.developer_email
          }

          env {
            name  = "DEV_KEY_SECRET_ARN"
            value = local.dev_key_secret_arn
          }

          dynamic "env" {
            for_each = var.region != null ? [var.region] : []
            content {
              name  = "AWS_REGION"
              value = env.value
            }
          }
        }
      }
    }
  }

  wait_for_completion = true

  timeouts {
    create = "10m"
    update = "10m"
  }

  depends_on = [
    kubernetes_service_account.job,
    aws_iam_role_policy.put_dev_key,
  ]
}
