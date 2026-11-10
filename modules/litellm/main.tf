# Central LiteLLM proxy (OpenAI-compatible gateway) deployed IN-CLUSTER on EKS, in the primary region.
#
#   - Runs on the CPU/system node tier (nodeSelector workload=system) via a Helm release.
#   - Fronted by an INTERNAL Application Load Balancer (scheme=internal, no public IP) created by a
#     Kubernetes Ingress that the AWS Load Balancer Controller reconciles - the private entry point.
#     Public exposure is left to the reader; test it via the SSM bastion port-forward.
#   - Routes each model across one deployment per region (api_base = that region's model ALB, reached
#     over VPC peering); session affinity + routing_strategy pick the region (see router_settings below).
#   - Connects to Aurora PostgreSQL (virtual keys, teams, budgets, spend) and ElastiCache Redis
#     (rate-limit counters + session-affinity pins). The master key, DB credentials, and Redis AUTH token
#     all originate in Secrets Manager.
#
# This module assumes the caller has already configured the aws, helm, and kubernetes providers
# (auth against the target cluster). It contains NO provider blocks by design.
#
# STATE CAVEAT: For sample simplicity this module reads the referenced Secrets Manager secrets via
# data sources and writes their values into a Kubernetes Secret. Those values therefore land in
# Terraform state. For production, prefer the Secrets Store CSI driver or External Secrets Operator
# so the values never enter Terraform state.

locals {
  ingress_group_name = var.ingress_group_name != null ? var.ingress_group_name : "${var.name_prefix}-litellm"

  # Deterministic ALB name (<=32 chars) so the caller can resolve the ALB ARN via a data source.
  # The LB Controller names the ALB exactly this.
  alb_name = var.alb_name != null ? var.alb_name : substr("${var.name_prefix}-litellm", 0, 32)

  # DB credentials JSON: {username, password, dbname, port}. Password is URL-encoded for the DSN.
  db_creds     = jsondecode(data.aws_secretsmanager_secret_version.db.secret_string)
  database_url = "postgresql://${local.db_creds.username}:${urlencode(local.db_creds.password)}@${var.db_host}:${local.db_creds.port}/${local.db_creds.dbname}"

  # Master key: either the raw SecretString or a JSON field within it.
  master_key = var.master_key_json_key != null ? jsondecode(data.aws_secretsmanager_secret_version.master_key.secret_string)[var.master_key_json_key] : data.aws_secretsmanager_secret_version.master_key.secret_string

  # Static (known at plan) so it can gate a data-source count. The ARN itself is only known at apply.
  redis_enabled  = var.redis_auth_enabled
  redis_password = local.redis_enabled ? jsondecode(data.aws_secretsmanager_secret_version.redis_auth[0].secret_string).auth_token : null

  secret_name = "${var.name_prefix}-litellm-env"

  # Env loaded into the pod via envFrom: Redis auth, plus DISABLE_SCHEMA_UPDATE on non-migrating (secondary)
  # deployments so the proxy never attempts DDL against the shared global database.
  env_secret_data = merge(
    local.redis_enabled ? { REDIS_PASSWORD = local.redis_password } : {},
    var.run_db_migrations ? {} : { DISABLE_SCHEMA_UPDATE = "True" },
  )

  # LiteLLM proxy_config (rendered into the chart's config.yaml).
  # VERIFY: Confirm the chart key that accepts inline proxy config. The community chart uses
  # `proxy_config`; some forks use `proxyConfigMap` or a mounted ConfigMap. Adjust local.helm_values below.
  #
  # One model_list entry per (alias, region) deployment. Entries sharing model_name (= litellm_alias) form a
  # cross-region routing group: session affinity (router_settings below) pins a conversation to the region
  # that served it; routing_strategy only places new/spilled sessions across the group.
  model_list = [
    for d in var.deployments : {
      model_name = d.litellm_alias
      # extra_headers is forwarded by LiteLLM to the upstream on every call. It carries the gateway token
      # the region's model ALB requires, so a caller that bypasses LiteLLM (no token) is 404'd at the ALB.
      # VERIFY: confirm litellm_params.extra_headers is honored by the LiteLLM version you pin.
      litellm_params = merge(
        {
          model    = "openai/${d.served_model_name}"
          api_base = d.api_base
          api_key  = "dummy" # vLLM does not enforce an API key; LiteLLM requires the field to be set.
        },
        d.gateway_token != null ? { extra_headers = { (var.model_gateway_header_name) = d.gateway_token } } : {}
      )
    }
  ]

  # master_key + database_url are provided by the chart (PROXY_MASTER_KEY env + DATABASE_URL built from
  # db.endpoint/database/secret), so they are NOT set here.
  general_settings = {
    store_model_in_db = true
  }

  db_secret_name        = "${var.name_prefix}-litellm-db"
  masterkey_secret_name = "${var.name_prefix}-litellm-masterkey"

  # Affinity-first cross-region routing:
  #   - optional_pre_call_checks=[session_affinity] pins a conversation to its cache-warm region (runs BEFORE
  #     the strategy, narrowing candidates to the pinned deployment); shared across replicas via Redis.
  #   - routing_strategy places only NEW/spilled sessions; allowed_fails+cooldown_time shed a failing region
  #     (the pin is kept, so a recovered region reclaims its sessions); num_retries fails over the remaining.
  router_settings = merge(
    {
      routing_strategy = var.routing_strategy
      redis_host       = var.redis_host
      redis_port       = var.redis_port
      cooldown_time    = var.cooldown_time
      allowed_fails    = var.allowed_fails
      num_retries      = var.num_retries
    },
    merge([for _ in(var.enable_session_affinity ? [1] : []) : {
      optional_pre_call_checks           = ["session_affinity"]
      deployment_affinity_ttl_seconds    = var.session_affinity_ttl_seconds
      session_affinity_repin_on_failover = false
    }]...),
    # The litellm-state Redis is created with in-transit encryption (TransitEncryptionMode=required), so the
    # Router MUST connect over TLS or every Redis call times out ("Timeout reading from ...:6379"), the
    # circuit breaker opens, and session-affinity pins are never shared across replicas (affinity silently
    # degrades to per-replica, so conversations bounce between regions). Extra redis-py connection kwargs must
    # go under cache_kwargs - the Router forwards these into RedisCache; a top-level `ssl` key is ignored.
    # ElastiCache serves a publicly-trusted cert, so default verification succeeds (no need to weaken
    # ssl_cert_reqs). Built with the for-spread pattern (not a ternary) so the enabled/disabled object shapes
    # never have to type-unify - a `cond ? {redis_password=..., cache_kwargs={...}} : {}` fails to unify.
    merge([for _ in(local.redis_enabled ? [1] : []) : {
      redis_password = "os.environ/REDIS_PASSWORD"
      cache_kwargs   = { ssl = true }
    }]...)
  )

  proxy_config = {
    model_list       = local.model_list
    general_settings = local.general_settings
    router_settings  = local.router_settings
    # TLS verification for the model-ALB upstreams. False by default because the sample's model ALBs use
    # self-signed certs (see modules/regional-stack model_alb_certificate_arn). Set true with real certs.
    litellm_settings = {
      ssl_verify = var.model_upstream_ssl_verify
    }
  }

  # VERIFY: These are the community LiteLLM chart value keys as of chart ~0.x. Confirm against the
  # chart version you pin (replicaCount, image.tag, proxy_config, environmentSecrets, nodeSelector,
  # service.port). Adjust names if your chart differs.
  helm_values = {
    replicaCount = var.replicas
    image = {
      tag = var.image_tag
    }
    # Run the Prisma migration Job only where this deployment owns the schema (primary). Secondary regions
    # share the same Aurora global DB and must not race migrations (DISABLE_SCHEMA_UPDATE is also set below).
    migrationJob = {
      enabled = var.run_db_migrations
    }
    # Use external Aurora (chart builds DATABASE_URL from endpoint/database + the creds secret). Do NOT
    # deploy the chart's bundled Bitnami PostgreSQL.
    db = {
      deployStandalone = false
      useExisting      = true
      endpoint         = var.db_host
      database         = local.db_creds.dbname
      secret = {
        name = local.db_secret_name
        # Kubernetes Secret FIELD NAMES (which JSON key inside the Secret holds each value), NOT
        # credentials. The password itself lives in Secrets Manager and is injected at runtime. Sourced
        # from variables so no literal string sits on a password-shaped assignment (secret-scanner FP).
        usernameKey = var.db_secret_username_key
        passwordKey = var.db_secret_password_key
      }
    }
    postgresql = {
      enabled = false
    }
    # Master key sourced from our secret (chart wires it to PROXY_MASTER_KEY / the proxy master key).
    masterkeySecretName = local.masterkey_secret_name
    masterkeySecretKey  = "masterkey"

    proxy_config = local.proxy_config
    # environmentSecrets: existing Secret names loaded into the pod via envFrom.secretRef (Redis auth).
    environmentSecrets = [local.secret_name]
    nodeSelector       = var.system_node_selector
    service = {
      type = "ClusterIP"
      port = var.service_port
    }
  }

  # ALB Ingress annotations. Prefer HTTPS: when an ACM cert is supplied we listen on 443 (+80 for
  # redirect); otherwise HTTP-only (acceptable only for an internal ALB behind CloudFront).
  ingress_annotations = merge(
    {
      "alb.ingress.kubernetes.io/scheme"             = "internal"
      "alb.ingress.kubernetes.io/target-type"        = "ip"
      "alb.ingress.kubernetes.io/healthcheck-path"   = var.healthcheck_path
      "alb.ingress.kubernetes.io/group.name"         = local.ingress_group_name
      "alb.ingress.kubernetes.io/load-balancer-name" = local.alb_name
    },
    var.acm_cert_arn != null ? {
      "alb.ingress.kubernetes.io/listen-ports"    = jsonencode([{ HTTP = 80 }, { HTTPS = 443 }])
      "alb.ingress.kubernetes.io/certificate-arn" = var.acm_cert_arn
      "alb.ingress.kubernetes.io/ssl-redirect"    = "443"
      } : {
      "alb.ingress.kubernetes.io/listen-ports" = jsonencode([{ HTTP = 80 }])
    },
    length(var.subnet_ids) > 0 ? {
      "alb.ingress.kubernetes.io/subnets" = join(",", var.subnet_ids)
    } : {},
    var.waf_acl_arn != null ? {
      "alb.ingress.kubernetes.io/wafv2-acl-arn" = var.waf_acl_arn
    } : {}
  )
}

# --------------------------------------------------------------------------------------------------
# Secrets sourced from Secrets Manager (see STATE CAVEAT in the header comment).
# --------------------------------------------------------------------------------------------------

data "aws_secretsmanager_secret_version" "master_key" {
  secret_id = var.master_key_secret_arn
}

data "aws_secretsmanager_secret_version" "db" {
  secret_id = var.db_secret_arn
}

data "aws_secretsmanager_secret_version" "redis_auth" {
  count     = local.redis_enabled ? 1 : 0
  secret_id = var.redis_auth_secret_arn
}

# --------------------------------------------------------------------------------------------------
# Namespace (created here so the env Secret exists before the Helm release schedules pods).
# The Helm release keeps create_namespace = false to avoid a duplicate-create conflict.
# --------------------------------------------------------------------------------------------------

resource "kubernetes_namespace" "this" {
  count = var.create_namespace ? 1 : 0
  metadata {
    name   = var.namespace
    labels = { "app.kubernetes.io/managed-by" = "terraform" }
  }
}

# --------------------------------------------------------------------------------------------------
# Environment secret consumed by the LiteLLM pods (envFrom).
# --------------------------------------------------------------------------------------------------

resource "kubernetes_secret" "env" {
  metadata {
    name      = local.secret_name
    namespace = var.namespace
    labels    = { "app.kubernetes.io/managed-by" = "terraform" }
  }

  type = "Opaque"

  # Redis auth (+ DISABLE_SCHEMA_UPDATE on secondary). DB creds and master key are provided via dedicated
  # secrets the chart references.
  data = local.env_secret_data

  depends_on = [kubernetes_namespace.this]
}

# DB credentials the chart reads (db.secret): username/password for the Aurora cluster.
resource "kubernetes_secret" "db" {
  metadata {
    name      = local.db_secret_name
    namespace = var.namespace
    labels    = { "app.kubernetes.io/managed-by" = "terraform" }
  }
  type = "Opaque"
  data = {
    username = local.db_creds.username
    password = local.db_creds.password
  }
  depends_on = [kubernetes_namespace.this]
}

# Master (admin) key the chart wires to PROXY_MASTER_KEY.
resource "kubernetes_secret" "masterkey" {
  metadata {
    name      = local.masterkey_secret_name
    namespace = var.namespace
    labels    = { "app.kubernetes.io/managed-by" = "terraform" }
  }
  type = "Opaque"
  data = {
    masterkey = local.master_key
  }
  depends_on = [kubernetes_namespace.this]
}

# --------------------------------------------------------------------------------------------------
# LiteLLM Helm release.
# --------------------------------------------------------------------------------------------------

resource "helm_release" "litellm" {
  name             = var.release_name
  repository       = var.repository
  chart            = var.chart
  version          = var.chart_version
  namespace        = var.namespace
  create_namespace = false # Namespace is managed by kubernetes_namespace.this above.

  values = [yamlencode(local.helm_values)]

  depends_on = [
    kubernetes_namespace.this,
    kubernetes_secret.env,
    kubernetes_secret.db,
    kubernetes_secret.masterkey,
  ]
}

# --------------------------------------------------------------------------------------------------
# Internal ALB Ingress (reconciled by the AWS Load Balancer Controller).
# This is the internal ALB the CloudFront VPC origin points at.
# --------------------------------------------------------------------------------------------------

resource "kubernetes_ingress_v1" "this" {
  metadata {
    name        = "${var.name_prefix}-litellm"
    namespace   = var.namespace
    annotations = local.ingress_annotations
    labels      = { "app.kubernetes.io/managed-by" = "terraform" }
  }

  spec {
    ingress_class_name = "alb"

    rule {
      http {
        path {
          path      = "/"
          path_type = "Prefix"
          backend {
            service {
              name = var.service_name
              port {
                number = var.service_port
              }
            }
          }
        }
      }
    }
  }

  # Block until the AWS Load Balancer Controller has provisioned the ALB and populated the Ingress status.
  # This makes ingress_hostname reliable AND lets the region root resolve the ALB ARN (for SSM discovery)
  # in the same apply, instead of racing the out-of-band ALB creation.
  wait_for_load_balancer = true

  depends_on = [helm_release.litellm]
}
