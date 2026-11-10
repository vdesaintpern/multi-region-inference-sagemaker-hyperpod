# IAM roles for the SageMaker HyperPod cluster.
#
#  - cluster role: assumed by the SageMaker HyperPod service; used for cluster operations and, when
#    autoscaling is enabled, for the managed Karpenter control loop (EC2/EKS describe + node provisioning).
#  - instance execution role: attached to HyperPod instance-group nodes. Because those nodes join the
#    EKS cluster as workers, this role carries the standard EKS worker/CNI/ECR/SSM permissions plus read
#    access to the lifecycle-script bucket.
#
# NOTE: validate the exact permission set against "Create an IAM role for HyperPod autoscaling with
# Karpenter" in the SageMaker docs before a production deployment; the inline policy below is scoped for
# this sample but AWS may publish a managed policy that supersedes it.

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

# ---------------------------- Cluster / autoscaling role ----------------------------

data "aws_iam_policy_document" "hyperpod_cluster_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type = "Service"
      # sagemaker.amazonaws.com: cluster create/update + native (baseline) node provisioning.
      # hyperpod.sagemaker.amazonaws.com: the MANAGED KARPENTER autoscaling principal -- REQUIRED or
      # BatchAddClusterNodes from autoscaling fails to assume this role and nodes never provision
      # (surfaces as "no allocatable instanceTypes" / empty HyperpodNodeClass capacity).
      identifiers = ["sagemaker.amazonaws.com", "hyperpod.sagemaker.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "hyperpod_cluster" {
  name               = "${var.name_prefix}-hp-cluster"
  assume_role_policy = data.aws_iam_policy_document.hyperpod_cluster_assume.json
  tags               = merge(var.tags, { Name = "${var.name_prefix}-hp-cluster" })
}

data "aws_iam_policy_document" "hyperpod_cluster" {
  # checkov:skip=CKV_AWS_356: The read-only statements below (ec2/eks/sagemaker Describe* and List*)
  # use actions that do not support resource-level permissions in IAM, so "*" is required. Every
  # mutating action (sagemaker:BatchAdd/DeleteClusterNodes) is scoped to this account's SageMaker
  # clusters in the dedicated "AutoscalingNodeProvisioning" statement.
  statement {
    sid    = "ClusterOps"
    effect = "Allow"
    actions = [
      "eks:DescribeCluster",
      "ec2:DescribeInstances",
      "ec2:DescribeSubnets",
      "ec2:DescribeSecurityGroups",
      "ec2:DescribeInstanceTypes",
      "ec2:DescribeAvailabilityZones",
    ]
    resources = ["*"]
  }

  # Mutating autoscaling actions, scoped to HyperPod clusters in this account/region. The exact
  # cluster ARN cannot be referenced here: the cluster consumes this role at create time, which would
  # create a dependency cycle. The account+region cluster wildcard is the tightest non-cyclic scope.
  statement {
    sid    = "AutoscalingNodeProvisioning"
    effect = "Allow"
    actions = [
      "sagemaker:BatchAddClusterNodes",
      "sagemaker:BatchDeleteClusterNodes",
    ]
    resources = ["arn:aws:sagemaker:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:cluster/*"]
  }

  # Read-only autoscaling status (not resource-scopeable; see the checkov:skip above).
  statement {
    sid    = "AutoscalingReads"
    effect = "Allow"
    actions = [
      "sagemaker:DescribeCluster",
      "sagemaker:DescribeClusterNode",
      "sagemaker:ListClusterNodes",
    ]
    resources = ["*"]
  }

  statement {
    sid       = "LifecycleBucketRead"
    effect    = "Allow"
    actions   = ["s3:GetObject", "s3:ListBucket"]
    resources = [aws_s3_bucket.lifecycle.arn, "${aws_s3_bucket.lifecycle.arn}/*"]
  }
}

# Managed Karpenter launches autoscaled nodes with KMS-encrypted EBS; the autoscaling principal
# (hyperpod.sagemaker.amazonaws.com) must be able to create a grant for the node's volume key or the
# launch fails and surfaces as "insufficient capacity / no allocatable instanceTypes". Kept as its
# own inline policy (per "Create an IAM role for HyperPod autoscaling with Karpenter").
data "aws_iam_policy_document" "hyperpod_karpenter_kms" {
  statement {
    sid       = "AutoscalingNodeEbsKmsGrant"
    effect    = "Allow"
    actions   = ["kms:CreateGrant", "kms:DescribeKey"]
    resources = ["*"]
    condition {
      test     = "StringLike"
      variable = "kms:ViaService"
      values   = ["sagemaker.*.amazonaws.com"]
    }
  }
}

resource "aws_iam_role_policy" "hyperpod_cluster" {
  name   = "cluster-ops"
  role   = aws_iam_role.hyperpod_cluster.id
  policy = data.aws_iam_policy_document.hyperpod_cluster.json
}

resource "aws_iam_role_policy" "hyperpod_karpenter_kms" {
  name   = "hyperpod-karpenter-kms"
  role   = aws_iam_role.hyperpod_cluster.id
  policy = data.aws_iam_policy_document.hyperpod_karpenter_kms.json
}

# ---------------------------- Instance execution role ----------------------------

data "aws_iam_policy_document" "hyperpod_instance_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["sagemaker.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "hyperpod_instance" {
  name               = "${var.name_prefix}-hp-instance"
  assume_role_policy = data.aws_iam_policy_document.hyperpod_instance_assume.json
  tags               = merge(var.tags, { Name = "${var.name_prefix}-hp-instance" })
}

resource "aws_iam_role_policy_attachment" "instance_managed" {
  for_each = toset([
    # REQUIRED for EKS-orchestrated HyperPod instance groups. Without it, node creation fails with
    # "Execution role permissions are invalid" (visible only in HyperPod cluster Events). This is the
    # HyperPod-specific policy the service validates -- the generic EKS worker policies below are NOT
    # sufficient on their own.
    "arn:aws:iam::aws:policy/AmazonSageMakerClusterInstanceRolePolicy",
    "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy",
    "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy",
    "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly",
    "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore",
  ])
  role       = aws_iam_role.hyperpod_instance.name
  policy_arn = each.value
}

data "aws_iam_policy_document" "hyperpod_instance" {
  # checkov:skip=CKV_AWS_109: The EksOrchestrationEni statement grants the AWS VPC-CNI / HyperPod
  #   orchestration permissions, which act on ENIs created dynamically at pod-scheduling time and so
  #   cannot be pre-scoped to a known resource ARN. This matches the HyperPod prerequisite IAM docs
  #   linked in that statement.
  # checkov:skip=CKV_AWS_111: Same as above -- the VPC-CNI ENI write actions operate on ENIs that do
  #   not exist until runtime, so resource-level constraints are not expressible.
  # checkov:skip=CKV_AWS_356: The ec2/ecr/eks-auth actions in EksOrchestrationEni do not support
  #   resource-level permissions in IAM; "*" is required. All other statements are ARN-scoped.
  statement {
    sid       = "LifecycleBucketRead"
    effect    = "Allow"
    actions   = ["s3:GetObject", "s3:ListBucket"]
    resources = [aws_s3_bucket.lifecycle.arn, "${aws_s3_bucket.lifecycle.arn}/*"]
  }

  statement {
    sid       = "Logs"
    effect    = "Allow"
    actions   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents", "logs:DescribeLogStreams"]
    resources = ["arn:aws:logs:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:log-group:/aws/sagemaker/*"]
  }

  # EKS-orchestration inline policy required by the HyperPod docs (in addition to
  # AmazonSageMakerClusterInstanceRolePolicy): ENI management for the VPC-CNI, ECR image pulls, and
  # (optional) EKS Pod Identity. https://docs.aws.amazon.com/sagemaker/latest/dg/sagemaker-hyperpod-prerequisites-iam.html#sagemaker-hyperpod-prerequisites-iam-role-for-hyperpod
  statement {
    sid    = "EksOrchestrationEni"
    effect = "Allow"
    actions = [
      "ec2:AssignPrivateIpAddresses",
      "ec2:AttachNetworkInterface",
      "ec2:CreateNetworkInterface",
      "ec2:CreateNetworkInterfacePermission",
      "ec2:DeleteNetworkInterface",
      "ec2:DeleteNetworkInterfacePermission",
      "ec2:DescribeInstances",
      "ec2:DescribeInstanceTypes",
      "ec2:DescribeNetworkInterfaces",
      "ec2:DescribeTags",
      "ec2:DescribeVpcs",
      "ec2:DescribeDhcpOptions",
      "ec2:DescribeSubnets",
      "ec2:DescribeSecurityGroups",
      "ec2:DetachNetworkInterface",
      "ec2:ModifyNetworkInterfaceAttribute",
      "ec2:UnassignPrivateIpAddresses",
      "ecr:BatchCheckLayerAvailability",
      "ecr:BatchGetImage",
      "ecr:GetAuthorizationToken",
      "ecr:GetDownloadUrlForLayer",
      "eks-auth:AssumeRoleForPodIdentity",
    ]
    resources = ["*"]
  }

  statement {
    sid       = "EksOrchestrationEniTags"
    effect    = "Allow"
    actions   = ["ec2:CreateTags"]
    resources = ["arn:aws:ec2:*:*:network-interface/*"]
  }
}

resource "aws_iam_role_policy" "hyperpod_instance" {
  name   = "instance-extra"
  role   = aws_iam_role.hyperpod_instance.id
  policy = data.aws_iam_policy_document.hyperpod_instance.json
}
