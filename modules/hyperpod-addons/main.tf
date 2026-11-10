# Cluster add-ons for SageMaker HyperPod inference on EKS.
#
# Installs, on an already-provisioned EKS cluster:
#   - The HyperPod Inference Operator managed EKS add-on (with an IRSA role).
#   - Prerequisite managed add-ons: Mountpoint-S3 CSI, FSx CSI, and metrics-server.
#   - cert-manager (Helm) - required by the inference operator webhooks.
#   - AWS Load Balancer Controller (Helm) with an IRSA role and its recommended IAM policy.
#
# This module assumes the caller has already configured the aws, helm, and kubernetes providers
# (auth against the target cluster). It contains NO provider blocks by design.

data "aws_caller_identity" "current" {}

locals {
  # Strip any leading scheme so the OIDC condition keys are built consistently.
  oidc_provider = replace(var.oidc_provider, "https://", "")

  # EKS cluster + access-entry ARNs the operator manages (used to scope the EksAccessEntries statement).
  eks_cluster_arn      = "arn:aws:eks:${var.region}:${data.aws_caller_identity.current.account_id}:cluster/${var.cluster_name}"
  eks_access_entry_arn = "arn:aws:eks:${var.region}:${data.aws_caller_identity.current.account_id}:access-entry/${var.cluster_name}/*"

  # Model-weights read scope: explicit bucket ARNs (+ objects). Fail closed -- when no ARNs are
  # provided the ModelWeightsRead statement is omitted entirely rather than falling back to "*", so an
  # unconfigured deployment grants no account-wide S3 read. The in-repo caller (regional-stack) always
  # passes this region's model-storage bucket ARN.
  model_weights_resources = concat(
    var.model_weights_bucket_arns,
    [for a in var.model_weights_bucket_arns : "${a}/*"]
  )
}

# --------------------------------------------------------------------------------------------------
# IRSA role: HyperPod inference operator
# --------------------------------------------------------------------------------------------------

data "aws_iam_policy_document" "operator_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [var.oidc_provider_arn]
    }

    # Scoped to the exact controller-manager service account that carries this execution role. The
    # add-on also creates inference-gateway and keda service accounts, but those are annotated with
    # their own separate IRSA roles (inferenceGateway/keda roleArn), not this one, so a namespace
    # wildcard would needlessly let them assume this role. This matches the trust policy in "Setting
    # up your HyperPod clusters for model deployment" (SageMaker Developer Guide), which scopes :sub
    # to system:serviceaccount:hyperpod-inference-system:hyperpod-inference-controller-manager.
    condition {
      test     = "StringEquals"
      variable = "${local.oidc_provider}:sub"
      values   = ["system:serviceaccount:${var.operator_namespace}:${var.operator_service_account}"]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_provider}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "operator" {
  name               = "${var.name_prefix}-hp-inference-operator"
  assume_role_policy = data.aws_iam_policy_document.operator_assume.json
  tags               = merge(var.tags, { Name = "${var.name_prefix}-hp-inference-operator" })
}

# S3 bucket the operator uses to store the Inference Gateway TLS certificates. The add-on schema
# requires a bucket whose name contains "tls".
resource "random_id" "tls_suffix" {
  byte_length = 4
}

resource "aws_s3_bucket" "operator_tls" {
  bucket        = "${var.name_prefix}-tls-certs-${random_id.tls_suffix.hex}"
  force_destroy = true
  tags          = merge(var.tags, { Name = "${var.name_prefix}-tls-certs" })
}

resource "aws_s3_bucket_public_access_block" "operator_tls" {
  bucket                  = aws_s3_bucket.operator_tls.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "operator_tls" {
  bucket = aws_s3_bucket.operator_tls.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "aws:kms"
    }
    bucket_key_enabled = true
  }
}

# Execution-role permissions for the inference operator. Mutating actions are ARN-scoped (inference
# write -> cluster ARN; EKS access entries -> cluster + access-entry ARNs; model-weights read ->
# var.model_weights_bucket_arns). The remaining read-only Describe*/List* actions are not
# resource-scopeable in IAM, hence the suppressions below.
data "aws_iam_policy_document" "operator" {
  # checkov:skip=CKV_AWS_356: The read-only Describe*/List* statements (SageMaker, EKS, EC2, ELB, ACM)
  #   use actions that do not support resource-level permissions; "*" is required. All mutating actions
  #   are ARN-scoped.
  statement {
    sid    = "TlsBucket"
    effect = "Allow"
    actions = [
      "s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:ListBucket",
      "s3:PutObjectTagging", "s3:GetObjectTagging",
    ]
    resources = [aws_s3_bucket.operator_tls.arn, "${aws_s3_bucket.operator_tls.arn}/*"]
  }

  # Scoped to var.model_weights_bucket_arns. Omitted entirely when no ARNs are provided (fail closed).
  dynamic "statement" {
    for_each = length(local.model_weights_resources) > 0 ? [1] : []
    content {
      sid       = "ModelWeightsRead"
      effect    = "Allow"
      actions   = ["s3:GetObject", "s3:ListBucket"]
      resources = local.model_weights_resources
    }
  }

  # Mutating inference action, scoped to this HyperPod cluster.
  statement {
    sid       = "HyperPodInferenceWrite"
    effect    = "Allow"
    actions   = ["sagemaker:UpdateClusterInference"]
    resources = [var.hyperpod_cluster_arn]
  }

  # Read-only inference/cluster status (not resource-scopeable; see the checkov:skip on this document).
  statement {
    sid    = "HyperPodInferenceRead"
    effect = "Allow"
    actions = [
      "sagemaker:DescribeClusterInference",
      "sagemaker:DescribeCluster",
      "sagemaker:ListClusterNodes",
      "sagemaker:DescribeClusterNode",
    ]
    resources = ["*"]
  }

  # Enabling cluster inference manages EKS access entries for the inference components (discovered via
  # CloudTrail: AssociateAccessPolicy / ListAssociatedAccessPolicies were denied and caused EnableFailed).
  # Scoped to this cluster and its access entries.
  statement {
    sid    = "EksAccessEntries"
    effect = "Allow"
    actions = [
      "eks:CreateAccessEntry",
      "eks:DeleteAccessEntry",
      "eks:DescribeAccessEntry",
      "eks:ListAccessEntries",
      "eks:AssociateAccessPolicy",
      "eks:DisassociateAccessPolicy",
      "eks:ListAssociatedAccessPolicies",
    ]
    resources = [local.eks_cluster_arn, local.eks_access_entry_arn]
  }

  # The operator passes its own execution role to SageMaker when enabling cluster inference.
  statement {
    sid       = "PassExecutionRole"
    effect    = "Allow"
    actions   = ["iam:PassRole"]
    resources = [aws_iam_role.operator.arn]
    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["sagemaker.amazonaws.com"]
    }
  }

  statement {
    sid    = "Describe"
    effect = "Allow"
    actions = [
      "eks:DescribeCluster",
      "ec2:DescribeSubnets",
      "ec2:DescribeSecurityGroups",
      "ec2:DescribeVpcs",
      # Required by the intelligent-routing / kvCacheSpec deployment-sizing path: the operator calls
      # ec2:DescribeInstanceTypes to "find the smallest instance type" when building the serving
      # Deployment. Without it, endpoint create fails with "error finding smallest instance type ...
      # UnauthorizedOperation: ec2:DescribeInstanceTypes". (Not needed for a plain endpoint; only once
      # intelligentRoutingSpec/kvCacheSpec are set.)
      "ec2:DescribeInstanceTypes",
      "elasticloadbalancing:Describe*",
      "acm:DescribeCertificate",
      "acm:ListCertificates",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "operator" {
  name   = "operator"
  role   = aws_iam_role.operator.id
  policy = data.aws_iam_policy_document.operator.json
}

# --------------------------------------------------------------------------------------------------
# IRSA role + IAM policy: AWS Load Balancer Controller
# --------------------------------------------------------------------------------------------------

data "aws_iam_policy_document" "lb_controller_assume" {
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
      values   = ["system:serviceaccount:kube-system:aws-load-balancer-controller"]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_provider}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "lb_controller" {
  name               = "${var.name_prefix}-aws-lbc"
  assume_role_policy = data.aws_iam_policy_document.lb_controller_assume.json
  tags               = merge(var.tags, { Name = "${var.name_prefix}-aws-lbc" })
}

# Source: AWS Load Balancer Controller v2.x recommended IAM policy
# (kubernetes-sigs/aws-load-balancer-controller docs/install/iam_policy.json).
# Used when var.lb_controller_policy_json is not supplied by the caller.
resource "aws_iam_policy" "lb_controller" {
  name        = "${var.name_prefix}-aws-lbc"
  description = "IAM policy for the AWS Load Balancer Controller."
  policy      = var.lb_controller_policy_json != null ? var.lb_controller_policy_json : local.lb_controller_default_policy
  tags        = merge(var.tags, { Name = "${var.name_prefix}-aws-lbc" })
}

resource "aws_iam_role_policy_attachment" "lb_controller" {
  role       = aws_iam_role.lb_controller.name
  policy_arn = aws_iam_policy.lb_controller.arn
}

locals {
  # Reproduced UNMODIFIED from the AWS Load Balancer Controller v2.x recommended IAM policy
  # (kubernetes-sigs/aws-load-balancer-controller, docs/install/iam_policy.json). The `Resource: "*"`
  # statements (CreateSecurityGroup, security-group ingress, CreateListener/Rule, SetWebAcl, etc.) are
  # intentional and come from upstream: these ELBv2/EC2 APIs are scoped by the elbv2.k8s.aws/cluster
  # tag conditions the controller sets, not by static ARNs. Kept verbatim so it tracks the documented
  # upstream policy; a caller that needs tighter scoping can pass var.lb_controller_policy_json.
  lb_controller_default_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["iam:CreateServiceLinkedRole"]
        Resource = "*"
        Condition = {
          StringEquals = {
            "iam:AWSServiceName" = "elasticloadbalancing.amazonaws.com"
          }
        }
      },
      {
        Effect = "Allow"
        Action = [
          "ec2:DescribeAccountAttributes",
          "ec2:DescribeAddresses",
          "ec2:DescribeAvailabilityZones",
          "ec2:DescribeInternetGateways",
          "ec2:DescribeVpcs",
          "ec2:DescribeVpcPeeringConnections",
          "ec2:DescribeSubnets",
          "ec2:DescribeSecurityGroups",
          "ec2:DescribeInstances",
          "ec2:DescribeNetworkInterfaces",
          "ec2:DescribeTags",
          "ec2:GetCoipPoolUsage",
          "ec2:DescribeCoipPools",
          "elasticloadbalancing:DescribeLoadBalancers",
          "elasticloadbalancing:DescribeLoadBalancerAttributes",
          "elasticloadbalancing:DescribeListeners",
          "elasticloadbalancing:DescribeListenerCertificates",
          "elasticloadbalancing:DescribeSSLPolicies",
          "elasticloadbalancing:DescribeRules",
          "elasticloadbalancing:DescribeTargetGroups",
          "elasticloadbalancing:DescribeTargetGroupAttributes",
          "elasticloadbalancing:DescribeTargetHealth",
          "elasticloadbalancing:DescribeTags",
          "elasticloadbalancing:DescribeTrustStores"
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "cognito-idp:DescribeUserPoolClient",
          "acm:ListCertificates",
          "acm:DescribeCertificate",
          "iam:ListServerCertificates",
          "iam:GetServerCertificate",
          "waf-regional:GetWebACL",
          "waf-regional:GetWebACLForResource",
          "waf-regional:AssociateWebACL",
          "waf-regional:DisassociateWebACL",
          "wafv2:GetWebACL",
          "wafv2:GetWebACLForResource",
          "wafv2:AssociateWebACL",
          "wafv2:DisassociateWebACL",
          "shield:GetSubscriptionState",
          "shield:DescribeProtection",
          "shield:CreateProtection",
          "shield:DeleteProtection"
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "ec2:AuthorizeSecurityGroupIngress",
          "ec2:RevokeSecurityGroupIngress"
        ]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = ["ec2:CreateSecurityGroup"]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = ["ec2:CreateTags"]
        Resource = "arn:aws:ec2:*:*:security-group/*"
        Condition = {
          StringEquals = {
            "ec2:CreateAction" = "CreateSecurityGroup"
          }
          Null = {
            "aws:RequestTag/elbv2.k8s.aws/cluster" = "false"
          }
        }
      },
      {
        Effect = "Allow"
        Action = [
          "ec2:CreateTags",
          "ec2:DeleteTags"
        ]
        Resource = "arn:aws:ec2:*:*:security-group/*"
        Condition = {
          Null = {
            "aws:RequestTag/elbv2.k8s.aws/cluster"  = "true"
            "aws:ResourceTag/elbv2.k8s.aws/cluster" = "false"
          }
        }
      },
      {
        Effect = "Allow"
        Action = [
          "ec2:AuthorizeSecurityGroupIngress",
          "ec2:RevokeSecurityGroupIngress",
          "ec2:DeleteSecurityGroup"
        ]
        Resource = "*"
        Condition = {
          Null = {
            "aws:ResourceTag/elbv2.k8s.aws/cluster" = "false"
          }
        }
      },
      {
        Effect = "Allow"
        Action = [
          "elasticloadbalancing:CreateLoadBalancer",
          "elasticloadbalancing:CreateTargetGroup"
        ]
        Resource = "*"
        Condition = {
          Null = {
            "aws:RequestTag/elbv2.k8s.aws/cluster" = "false"
          }
        }
      },
      {
        Effect = "Allow"
        Action = [
          "elasticloadbalancing:CreateListener",
          "elasticloadbalancing:DeleteListener",
          "elasticloadbalancing:CreateRule",
          "elasticloadbalancing:DeleteRule"
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "elasticloadbalancing:AddTags",
          "elasticloadbalancing:RemoveTags"
        ]
        Resource = [
          "arn:aws:elasticloadbalancing:*:*:targetgroup/*/*",
          "arn:aws:elasticloadbalancing:*:*:loadbalancer/net/*/*",
          "arn:aws:elasticloadbalancing:*:*:loadbalancer/app/*/*"
        ]
        Condition = {
          Null = {
            "aws:RequestTag/elbv2.k8s.aws/cluster"  = "true"
            "aws:ResourceTag/elbv2.k8s.aws/cluster" = "false"
          }
        }
      },
      {
        Effect = "Allow"
        Action = [
          "elasticloadbalancing:AddTags",
          "elasticloadbalancing:RemoveTags"
        ]
        Resource = [
          "arn:aws:elasticloadbalancing:*:*:listener/net/*/*/*",
          "arn:aws:elasticloadbalancing:*:*:listener/app/*/*/*",
          "arn:aws:elasticloadbalancing:*:*:listener-rule/net/*/*/*",
          "arn:aws:elasticloadbalancing:*:*:listener-rule/app/*/*/*"
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "elasticloadbalancing:ModifyLoadBalancerAttributes",
          "elasticloadbalancing:SetIpAddressType",
          "elasticloadbalancing:SetSecurityGroups",
          "elasticloadbalancing:SetSubnets",
          "elasticloadbalancing:DeleteLoadBalancer",
          "elasticloadbalancing:ModifyTargetGroup",
          "elasticloadbalancing:ModifyTargetGroupAttributes",
          "elasticloadbalancing:DeleteTargetGroup"
        ]
        Resource = "*"
        Condition = {
          Null = {
            "aws:ResourceTag/elbv2.k8s.aws/cluster" = "false"
          }
        }
      },
      {
        Effect = "Allow"
        Action = ["elasticloadbalancing:AddTags"]
        Resource = [
          "arn:aws:elasticloadbalancing:*:*:targetgroup/*/*",
          "arn:aws:elasticloadbalancing:*:*:loadbalancer/net/*/*",
          "arn:aws:elasticloadbalancing:*:*:loadbalancer/app/*/*"
        ]
        Condition = {
          StringEquals = {
            "elasticloadbalancing:CreateAction" = [
              "CreateTargetGroup",
              "CreateLoadBalancer"
            ]
          }
          Null = {
            "aws:RequestTag/elbv2.k8s.aws/cluster" = "false"
          }
        }
      },
      {
        Effect = "Allow"
        Action = [
          "elasticloadbalancing:RegisterTargets",
          "elasticloadbalancing:DeregisterTargets"
        ]
        Resource = "arn:aws:elasticloadbalancing:*:*:targetgroup/*/*"
      },
      {
        Effect = "Allow"
        Action = [
          "elasticloadbalancing:SetWebAcl",
          "elasticloadbalancing:ModifyListener",
          "elasticloadbalancing:AddListenerCertificates",
          "elasticloadbalancing:RemoveListenerCertificates",
          "elasticloadbalancing:ModifyRule"
        ]
        Resource = "*"
      }
    ]
  })
}

# --------------------------------------------------------------------------------------------------
# cert-manager (Helm) - prerequisite for the HyperPod inference operator webhooks.
# Installed independently of, and before, the operator add-on.
# --------------------------------------------------------------------------------------------------

resource "helm_release" "cert_manager" {
  name             = "cert-manager"
  repository       = "https://charts.jetstack.io"
  chart            = "cert-manager"
  version          = var.cert_manager_version
  namespace        = "cert-manager"
  create_namespace = true

  set {
    name  = "installCRDs"
    value = "true"
  }
}

# --------------------------------------------------------------------------------------------------
# AWS Load Balancer Controller (Helm). Installed independently; pods pinned to system nodes.
# --------------------------------------------------------------------------------------------------

resource "helm_release" "aws_load_balancer_controller" {
  name       = "aws-load-balancer-controller"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  version    = var.lb_controller_chart_version
  namespace  = "kube-system"

  set {
    name  = "clusterName"
    value = var.cluster_name
  }

  set {
    name  = "region"
    value = var.region
  }

  set {
    name  = "vpcId"
    value = var.vpc_id
  }

  set {
    name  = "serviceAccount.create"
    value = "true"
  }

  set {
    name  = "serviceAccount.name"
    value = "aws-load-balancer-controller"
  }

  set {
    name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = aws_iam_role.lb_controller.arn
  }

  set {
    name  = "nodeSelector.workload"
    value = "system"
  }

  # We use Ingress (ALB), not Service type=LoadBalancer (NLB). Disabling the Service mutating webhook
  # avoids it intercepting (and failing) unrelated Service creations cluster-wide before the controller
  # has ready endpoints -- otherwise cert-manager/LiteLLM Service creates race the controller startup.
  set {
    name  = "enableServiceMutatorWebhook"
    value = "false"
  }

  # The HyperPod inference operator's init container looks for the ALB controller via the label
  # selector `app.kubernetes.io/name=alb`. The eks-charts default label is
  # `aws-load-balancer-controller`, which the check does not match. nameOverride=alb sets the
  # `app.kubernetes.io/name` label to `alb` so the operator discovers our separately-managed controller.
  set {
    name  = "nameOverride"
    value = "alb"
  }

  depends_on = [aws_iam_role_policy_attachment.lb_controller]
}

# --------------------------------------------------------------------------------------------------
# Prerequisite managed EKS add-ons (install in parallel; no ordering dependency on cert-manager).
# NOTE: In production, the CSI drivers should be given a scoped IRSA role via service_account_role_arn.
# This sample relies on node-role permissions for brevity.
# --------------------------------------------------------------------------------------------------

resource "aws_eks_addon" "prerequisites" {
  for_each = toset([
    "aws-mountpoint-s3-csi-driver",
    "aws-fsx-csi-driver",
    "metrics-server",
  ])

  cluster_name                = var.cluster_name
  addon_name                  = each.value
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  tags = merge(var.tags, { Name = "${var.name_prefix}-${each.value}" })
}

# --------------------------------------------------------------------------------------------------
# HyperPod Inference Operator managed EKS add-on.
# Depends on cert-manager for its admission/conversion webhooks.
# --------------------------------------------------------------------------------------------------

resource "aws_eks_addon" "hyperpod_inference_operator" {
  cluster_name                = var.cluster_name
  addon_name                  = "amazon-sagemaker-hyperpod-inference"
  addon_version               = var.operator_addon_version
  service_account_role_arn    = aws_iam_role.operator.arn
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  # Required config: executionRoleArn + tlsCertificateS3Bucket (bucket name must contain "tls").
  # alb.enabled=false because we install the AWS Load Balancer Controller separately (above).
  configuration_values = jsonencode({
    executionRoleArn       = aws_iam_role.operator.arn
    tlsCertificateS3Bucket = aws_s3_bucket.operator_tls.id
    hyperpodClusterArn     = var.hyperpod_cluster_arn
    alb                    = { enabled = false }
    inferenceOperator      = { enabled = true }
    inferenceGateway       = { enabled = true }
  })

  tags = merge(var.tags, { Name = "${var.name_prefix}-hp-inference-operator" })

  depends_on = [
    helm_release.cert_manager,
    aws_iam_role_policy.operator,
    aws_s3_bucket.operator_tls,
  ]
}
