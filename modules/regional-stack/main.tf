# Regional SERVING composition: everything that runs inside one region on top of an already-created
# EKS + HyperPod cluster. The `region` root creates the VPC and the cluster (so the kubernetes/helm/
# kubectl providers can be configured from the cluster outputs) and passes those references in.
#
# This stack serves models only. The central LiteLLM gateway, its Aurora/Redis state, the entry ALB and
# WAF, and the cross-region peering all live in the `platform` root (primary region). Each region is
# self-contained: it ingests its own weights and exposes each model on an internal ALB that the central
# LiteLLM reaches over VPC peering.
#
# Ordering (via references + explicit depends_on):
#   storage (AWS) -> addons (operator, LB controller, cert-manager, CSI) -> node-pools ->
#   model ingestion -> inference endpoints -> per-model internal ALB.

data "aws_caller_identity" "current" {}

locals {
  inference_namespace = "default"
  ingestion_namespace = "model-ingestion"
  operator_namespace  = "hyperpod-inference-system"

  # Inference-endpoint view of the catalog (drop LiteLLM-only fields).
  inference_models = {
    for k, m in var.models : k => {
      source_type          = m.source_type
      served_model_name    = m.served_model_name
      instance_type        = m.instance_type
      instance_types       = m.instance_types
      model_id             = m.model_id
      s3_uri               = m.s3_uri
      tensor_parallel_size = m.tensor_parallel_size
      routing_strategy     = m.routing_strategy
      max_model_len        = m.max_model_len
      autoscaling          = m.autoscaling
    }
  }

  # Models that need weights staged into S3 before serving. Every region ingests its own weights (no
  # cross-region replication), so each region downloads non-JumpStart models from the source once.
  ingestion_models = { for k, m in var.models : k => m if m.source_type != "jumpstart" }
}

# --------------------------------------------------------------------------------------------------
# Data-plane state (pure AWS): model weights bucket (per region; no cross-region replication).
# --------------------------------------------------------------------------------------------------

module "model_storage" {
  source = "../model-storage"

  name_prefix = var.name_prefix
  tags        = var.tags
}

# --------------------------------------------------------------------------------------------------
# Cluster add-ons (operator, LB controller, cert-manager, CSI drivers, metrics-server).
# --------------------------------------------------------------------------------------------------

module "hyperpod_addons" {
  source = "../hyperpod-addons"

  name_prefix          = var.name_prefix
  tags                 = var.tags
  cluster_name         = var.cluster_name
  oidc_provider_arn    = var.oidc_provider_arn
  oidc_provider        = var.oidc_provider
  vpc_id               = var.vpc_id
  region               = var.region
  hyperpod_cluster_arn = var.hyperpod_cluster_arn
  # Scope the operator's model-weights read to this region's model-storage bucket.
  model_weights_bucket_arns = [module.model_storage.bucket_arn]
}

# --------------------------------------------------------------------------------------------------
# S3 Mountpoint CSI credentials for reading model weights, via EKS Pod Identity.
#
# HyperPod GPU nodes block pod access to IMDS, so the aws-mountpoint-s3-csi-driver cannot use the node
# role to reach the KMS-encrypted weights bucket (NoSigningCredentials). With authenticationSource:
# driver (the operator default), the CSI DRIVER supplies credentials to the mountpoint pods, so the
# fix must give the DRIVER's service account (kube-system/s3-csi-driver-sa) credentials. The add-on
# runs the driver in Pod Identity mode (the IRSA webhook skips it), so we use an EKS Pod Identity
# association -> a role scoped to the model bucket. See LESSONS-LEARNED.md section 4.1.
# --------------------------------------------------------------------------------------------------

data "aws_iam_policy_document" "s3csi_mount_assume" {
  statement {
    actions = ["sts:AssumeRole", "sts:TagSession"]
    effect  = "Allow"
    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "s3csi_mount" {
  name               = "${var.name_prefix}-s3csi-mount"
  assume_role_policy = data.aws_iam_policy_document.s3csi_mount_assume.json
  tags               = merge(var.tags, { Name = "${var.name_prefix}-s3csi-mount" })
}

data "aws_iam_policy_document" "s3csi_mount" {
  statement {
    sid       = "ModelBucketRead"
    effect    = "Allow"
    actions   = ["s3:GetObject", "s3:ListBucket"]
    resources = [module.model_storage.bucket_arn, "${module.model_storage.bucket_arn}/*"]
  }
  statement {
    sid       = "ModelBucketKms"
    effect    = "Allow"
    actions   = ["kms:Decrypt", "kms:DescribeKey"]
    resources = [module.model_storage.kms_key_arn]
  }
}

resource "aws_iam_role_policy" "s3csi_mount" {
  name   = "model-bucket-read"
  role   = aws_iam_role.s3csi_mount.id
  policy = data.aws_iam_policy_document.s3csi_mount.json
}

# Bind the CSI driver's service account to the role via EKS Pod Identity. The driver then supplies
# these credentials to every mountpoint pod (authenticationSource: driver).
resource "aws_eks_pod_identity_association" "s3csi_mount" {
  cluster_name    = var.cluster_name
  namespace       = "kube-system"
  service_account = "s3-csi-driver-sa"
  role_arn        = aws_iam_role.s3csi_mount.arn
  tags            = var.tags

  depends_on = [module.hyperpod_addons]
}

# --------------------------------------------------------------------------------------------------
# Autoscaling NodePools (GPU + system).
# --------------------------------------------------------------------------------------------------

module "node_pools" {
  source = "../node-pools"

  name_prefix             = var.name_prefix
  gpu_instance_group_name = var.gpu_instance_group_name
  gpu_instance_type       = var.gpu_instance_type

  depends_on = [module.hyperpod_addons]
}

# --------------------------------------------------------------------------------------------------
# Observability (AMP + HyperPod observability add-on + metrics scrape).
# --------------------------------------------------------------------------------------------------

module "observability" {
  source = "../observability"
  count  = var.enable_observability ? 1 : 0

  name_prefix        = var.name_prefix
  tags               = var.tags
  cluster_name       = var.cluster_name
  oidc_provider_arn  = var.oidc_provider_arn
  oidc_provider      = var.oidc_provider
  region             = var.region
  operator_role_name = module.hyperpod_addons.operator_role_name

  depends_on = [module.hyperpod_addons]
}

# --------------------------------------------------------------------------------------------------
# Model ingestion: IRSA + one Job per non-JumpStart model, staging weights into the managed bucket.
# --------------------------------------------------------------------------------------------------

data "aws_iam_policy_document" "ingestion_assume" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    effect  = "Allow"
    principals {
      type        = "Federated"
      identifiers = [var.oidc_provider_arn]
    }
    condition {
      test     = "StringEquals"
      variable = "${var.oidc_provider}:sub"
      values   = ["system:serviceaccount:${local.ingestion_namespace}:model-ingestion"]
    }
    condition {
      test     = "StringEquals"
      variable = "${var.oidc_provider}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ingestion" {
  count              = length(local.ingestion_models) > 0 ? 1 : 0
  name               = "${var.name_prefix}-ingestion"
  assume_role_policy = data.aws_iam_policy_document.ingestion_assume.json
  tags               = merge(var.tags, { Name = "${var.name_prefix}-ingestion" })
}

data "aws_iam_policy_document" "ingestion" {
  count = length(local.ingestion_models) > 0 ? 1 : 0

  statement {
    sid       = "S3Write"
    effect    = "Allow"
    actions   = ["s3:PutObject", "s3:GetObject", "s3:ListBucket"]
    resources = [module.model_storage.bucket_arn, "${module.model_storage.bucket_arn}/*"]
  }

  # The weights bucket is KMS-encrypted; writing objects needs data-key generation + decrypt.
  statement {
    sid       = "S3BucketKms"
    effect    = "Allow"
    actions   = ["kms:GenerateDataKey", "kms:Decrypt"]
    resources = [module.model_storage.kms_key_arn]
  }

  dynamic "statement" {
    for_each = var.hf_token_secret_arn != null ? [1] : []
    content {
      sid       = "HFToken"
      effect    = "Allow"
      actions   = ["secretsmanager:GetSecretValue"]
      resources = [var.hf_token_secret_arn]
    }
  }
}

resource "aws_iam_role_policy" "ingestion" {
  count  = length(local.ingestion_models) > 0 ? 1 : 0
  name   = "ingestion"
  role   = aws_iam_role.ingestion[0].id
  policy = data.aws_iam_policy_document.ingestion[0].json
}

resource "kubernetes_namespace" "ingestion" {
  count = length(local.ingestion_models) > 0 ? 1 : 0
  metadata {
    name = local.ingestion_namespace
  }
  depends_on = [module.hyperpod_addons]
}

resource "kubernetes_service_account" "ingestion" {
  count = length(local.ingestion_models) > 0 ? 1 : 0
  metadata {
    name      = "model-ingestion"
    namespace = local.ingestion_namespace
    annotations = {
      "eks.amazonaws.com/role-arn" = aws_iam_role.ingestion[0].arn
    }
  }
  depends_on = [kubernetes_namespace.ingestion]
}

module "model_ingestion" {
  source   = "../model-ingestion"
  for_each = local.ingestion_models

  name_prefix         = "${var.name_prefix}-${each.key}"
  tags                = var.tags
  model_source_type   = each.value.source_type
  model_id            = each.value.model_id
  model_s3_uri        = each.value.s3_uri
  target_bucket       = module.model_storage.bucket_id
  hf_token_secret_arn = var.hf_token_secret_arn
  namespace           = local.ingestion_namespace
}

resource "kubectl_manifest" "ingestion_job" {
  for_each  = { for k, m in local.ingestion_models : k => k if module.model_ingestion[k].needs_ingestion }
  yaml_body = module.model_ingestion[each.key].job_manifest_yaml

  depends_on = [kubernetes_service_account.ingestion]
}

# --------------------------------------------------------------------------------------------------
# Dedicated L2 KV cache Redis (LMCache remote backend) - the plain redis:// URL injected into the CR
# carries no auth/TLS secret (operator limitation; see the kv-cache-redis module header). At-rest
# encryption uses a customer-managed KMS key. Network-locked to the nodes.
# --------------------------------------------------------------------------------------------------

module "kv_cache_redis" {
  source = "../kv-cache-redis"

  name_prefix                = var.name_prefix
  tags                       = var.tags
  vpc_id                     = var.vpc_id
  private_subnet_ids         = var.private_subnet_ids
  allowed_security_group_ids = [var.node_security_group_id]
}

# --------------------------------------------------------------------------------------------------
# Model serving: one InferenceEndpointConfig per model.
# --------------------------------------------------------------------------------------------------

module "inference_endpoints" {
  source = "../inference-endpoints"

  name_prefix                = var.name_prefix
  namespace                  = local.inference_namespace
  models                     = local.inference_models
  s3_bucket_name             = module.model_storage.bucket_id
  s3_bucket_region           = var.region
  cluster_name               = var.cluster_name
  region                     = var.region
  enable_intelligent_routing = true  # managed Intelligent Router + tiered KV cache (mutually exclusive with the gateway)
  enable_inference_gateway   = false # ignored when intelligent routing is on; set false for clarity
  enable_l2_cache            = true  # plan-time-known L2 toggle (we always create the kv_cache_redis module)
  l2_cache_redis_host        = module.kv_cache_redis.redis_host
  l2_cache_redis_port        = module.kv_cache_redis.redis_port

  # AMP endpoint for KEDA prometheus triggers (replica autoscaling). Null when observability is off,
  # which disables the prometheus trigger. trimsuffix drops the trailing slash the operator rejects.
  amp_server_address = var.enable_observability ? trimsuffix(one(module.observability[*].amp_prometheus_endpoint), "/") : null

  depends_on = [
    module.hyperpod_addons,
    module.node_pools,
    kubectl_manifest.ingestion_job,
    aws_eks_pod_identity_association.s3csi_mount,
  ]
}

# --------------------------------------------------------------------------------------------------
# TLS for the per-model internal ALBs: use the supplied ACM cert, or generate a self-signed cert and
# import it into ACM. TLS terminates at the ALB so the cross-region LiteLLM -> model-ALB hop (over VPC
# peering) is encrypted. With the self-signed default the central LiteLLM must skip verification.
# --------------------------------------------------------------------------------------------------

resource "tls_private_key" "model_alb" {
  count     = var.model_alb_certificate_arn == null ? 1 : 0
  algorithm = "RSA"
  rsa_bits  = 2048
}

resource "tls_self_signed_cert" "model_alb" {
  count           = var.model_alb_certificate_arn == null ? 1 : 0
  private_key_pem = tls_private_key.model_alb[0].private_key_pem

  subject {
    common_name = "${var.name_prefix}-model-alb.internal"
  }
  dns_names             = ["${var.name_prefix}-model-alb.internal"]
  validity_period_hours = 8760 # 1 year
  allowed_uses          = ["key_encipherment", "digital_signature", "server_auth"]
}

resource "aws_acm_certificate" "model_alb" {
  count            = var.model_alb_certificate_arn == null ? 1 : 0
  private_key      = tls_private_key.model_alb[0].private_key_pem
  certificate_body = tls_self_signed_cert.model_alb[0].cert_pem
  tags             = merge(var.tags, { Name = "${var.name_prefix}-model-alb" })

  lifecycle {
    create_before_destroy = true
  }
}

# Shared secret that gates the per-model ALBs. Auto-generated; bump gateway_token_version to rotate.
resource "random_password" "model_gw_token" {
  length  = 48
  special = false
  keepers = { version = var.gateway_token_version }
}

locals {
  # The ALB admits a request whose header matches ANY of these. During rotation the previous token is
  # carried in var.additional_accepted_gateway_tokens so both old and new are valid (zero downtime).
  accepted_gateway_tokens = compact(concat([random_password.model_gw_token.result], var.additional_accepted_gateway_tokens))

  model_alb_cert_arn = var.model_alb_certificate_arn != null ? var.model_alb_certificate_arn : aws_acm_certificate.model_alb[0].arn
}

# --------------------------------------------------------------------------------------------------
# Per-model internal ALB (AWS Load Balancer Controller Ingress), one per model.
#
# Each model's in-cluster routing-service (the Intelligent Router Service in the operator namespace) is
# fronted by its own scheme=internal ALB listening HTTPS:443 at path "/", so the backend sees the vLLM
# path unchanged (the ALB does NOT rewrite paths). The central LiteLLM in the primary region dials
# https://<model-alb-dns>/v1 over VPC peering; the ALB's DNS name resolves to private IPs that are
# routable across the peering connection. TLS terminates at the ALB (backend stays HTTP inside the
# cluster). inbound-cidrs restricts the ALB to the primary + local VPC CIDRs.
# --------------------------------------------------------------------------------------------------

resource "kubernetes_ingress_v1" "model" {
  for_each = var.models

  metadata {
    name      = "${var.name_prefix}-${each.key}-model"
    namespace = local.operator_namespace
    annotations = {
      "alb.ingress.kubernetes.io/scheme"             = "internal"
      "alb.ingress.kubernetes.io/target-type"        = "ip"
      "alb.ingress.kubernetes.io/listen-ports"       = jsonencode([{ HTTPS = 443 }])
      "alb.ingress.kubernetes.io/certificate-arn"    = local.model_alb_cert_arn
      "alb.ingress.kubernetes.io/ssl-policy"         = "ELBSecurityPolicy-TLS13-1-2-2021-06"
      "alb.ingress.kubernetes.io/healthcheck-path"   = "/health"
      "alb.ingress.kubernetes.io/group.name"         = "${var.name_prefix}-${each.key}-model"
      "alb.ingress.kubernetes.io/load-balancer-name" = substr("${var.name_prefix}-${each.key}-mdl", 0, 32)
      "alb.ingress.kubernetes.io/subnets"            = join(",", var.private_subnet_ids)
      "alb.ingress.kubernetes.io/inbound-cidrs"      = join(",", var.model_alb_inbound_cidrs)

      # Gate: forward to the routing-service ONLY when the request carries the gateway token header that
      # the central LiteLLM injects. Requests without it (any other in-VPC workload) fall through to the
      # ALB default action -> fixed 404. Expressed as an annotation action so the (long) routing-service
      # name stays in the annotation VALUE, keeping the annotation KEY short. Health checks hit the target
      # group directly, bypassing this listener rule, so they are unaffected.
      "alb.ingress.kubernetes.io/actions.${each.key}" = jsonencode({
        type = "forward"
        forwardConfig = {
          targetGroups = [{
            serviceName = "${var.name_prefix}-${each.key}-${local.inference_namespace}-routing-service"
            servicePort = "443"
          }]
        }
      })
      "alb.ingress.kubernetes.io/conditions.${each.key}" = jsonencode([{
        field = "http-header"
        httpHeaderConfig = {
          httpHeaderName = var.model_gateway_header_name
          values         = local.accepted_gateway_tokens
        }
      }])
    }
    labels = { "app.kubernetes.io/managed-by" = "terraform" }
  }

  spec {
    ingress_class_name = "alb"

    rule {
      http {
        path {
          path      = "/"
          path_type = "Prefix"
          backend {
            # Annotation-based forward action (see actions.${each.key} above): the real backend is the
            # intelligent-router Service; "use-annotation" tells the LB Controller to read it from there.
            service {
              name = each.key
              port {
                name = "use-annotation"
              }
            }
          }
        }
      }
    }
  }

  # Block until the LB Controller has provisioned the ALB, so status.hostname is populated and the
  # region root can publish it to SSM in the same apply.
  wait_for_load_balancer = true

  depends_on = [module.inference_endpoints]
}
