# SageMaker HyperPod cluster (EKS-orchestrated) provisioned via a CloudFormation-wrapped stack.
#
# Why CloudFormation and not the aws/awscc provider directly: the AutoScaling (managed Karpenter) and
# NodeProvisioningMode=Continuous fields are recent additions to AWS::SageMaker::Cluster. Wrapping the
# native CFN resource guarantees these fields are honoured regardless of provider schema lag. Swap to
# awscc_sagemaker_cluster once its schema fully covers AutoScaling/NodeProvisioningMode.

resource "random_id" "suffix" {
  byte_length = 4
}

# ---------------------------- Lifecycle-script bucket ----------------------------

resource "aws_s3_bucket" "lifecycle" {
  bucket        = "${var.name_prefix}-hp-lifecycle-${random_id.suffix.hex}"
  force_destroy = true
  tags          = merge(var.tags, { Name = "${var.name_prefix}-hp-lifecycle" })
}

resource "aws_s3_bucket_public_access_block" "lifecycle" {
  bucket                  = aws_s3_bucket.lifecycle.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "lifecycle" {
  bucket = aws_s3_bucket.lifecycle.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "aws:kms"
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_versioning" "lifecycle" {
  bucket = aws_s3_bucket.lifecycle.id
  versioning_configuration {
    status = "Enabled"
  }
}

# Minimal no-op on-create lifecycle script (EKS orchestration needs a valid script present).
resource "aws_s3_object" "on_create" {
  bucket  = aws_s3_bucket.lifecycle.id
  key     = "on_create.sh"
  content = "#!/bin/bash\n# No-op lifecycle script for the HyperPod inference sample.\nset -euo pipefail\necho \"on_create: nothing to do\"\n"
  tags    = var.tags
}

# ---------------------------- HyperPod EKS dependencies (REQUIRED prerequisite) ----------------------------
# HyperPod-on-EKS requires the SageMaker HyperPod dependency Helm chart (device plugins incl.
# nvidia-device-plugin, EFA/Neuron plugins, health-monitoring agent, deep-health-check, Kueue,
# Kubeflow training/MPI operators) installed BEFORE the HyperPod cluster is created. The chart is
# distributed only via git (github.com/aws/sagemaker-hyperpod-cli) with subchart dependencies, so we
# install it with a local-exec step using the local helm/git/aws tooling. It runs after the EKS
# managed node group exists (its controllers need schedulable nodes) and before the CFN cluster.
#
# Requires helm, git, and the AWS CLI on the machine running Terraform (see README prerequisites).
resource "terraform_data" "hyperpod_deps" {
  triggers_replace = [module.eks.cluster_name, var.hyperpod_cli_ref]

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -euo pipefail
      aws eks update-kubeconfig --name "${module.eks.cluster_name}" --region "${data.aws_region.current.name}"
      workdir="$(mktemp -d)"
      git clone --depth 1 --branch "${var.hyperpod_cli_ref}" https://github.com/aws/sagemaker-hyperpod-cli.git "$workdir/cli"
      cd "$workdir/cli/helm_chart"
      helm dependency update HyperPodHelmChart
      helm upgrade --install hyperpod-dependencies HyperPodHelmChart --namespace kube-system
      rm -rf "$workdir"
    EOT
  }

  depends_on = [module.eks]
}

# ---------------------------- HyperPod cluster (CFN) ----------------------------

locals {
  lifecycle_config = {
    SourceS3Uri = "s3://${aws_s3_bucket.lifecycle.id}"
    OnCreate    = "on_create.sh"
  }

  # GPU inference instance group. FLEXIBLE (InstanceRequirements with an ordered instance-type list)
  # so the HyperPod-managed Karpenter can autoscale it across types with available capacity. The model
  # pod pins a single type (the model's instance_type), which must be one of the types listed here.
  #
  # NOTE: the managed-Karpenter path only works once the INSTANCE EXECUTION ROLE has the correct
  # permissions (AmazonSageMakerClusterInstanceRolePolicy + the EKS ENI/ECR inline policy -- see
  # iam.tf). Without them, Karpenter never launches a node and HyperpodNodeClass.capacity.onDemand
  # stays empty, which looks like a capacity problem but is really IAM. See LESSONS-LEARNED.md.
  gpu_instance_group = {
    InstanceGroupName = "gpuauto"
    InstanceRequirements = {
      InstanceTypes = var.gpu_instance_types
    }
    InstanceCount   = var.gpu_instance_count
    ExecutionRole   = aws_iam_role.hyperpod_instance.arn
    ThreadsPerCore  = 1
    LifeCycleConfig = local.lifecycle_config
    # Span ALL private subnets (one per AZ) so HyperPod can place the node wherever there is capacity.
    OverrideVpcConfig = {
      SecurityGroupIds = [module.eks.node_security_group_id, module.eks.cluster_security_group_id]
      Subnets          = var.private_subnet_ids
    }
  }

  base_properties = {
    ClusterName  = "${var.name_prefix}-hp"
    ClusterRole  = aws_iam_role.hyperpod_cluster.arn
    NodeRecovery = "Automatic"
    Orchestrator = {
      Eks = { ClusterArn = module.eks.cluster_arn }
    }
    VpcConfig = {
      SecurityGroupIds = [module.eks.node_security_group_id, module.eks.cluster_security_group_id]
      Subnets          = [var.gpu_subnet_id]
    }
    InstanceGroups = [local.gpu_instance_group]

    # HyperPod-managed Karpenter autoscaling (service-managed controller) with continuous provisioning.
    NodeProvisioningMode = "Continuous"
    AutoScaling = {
      Mode           = "Enable"
      AutoScalerType = "Karpenter"
    }
  }

  cfn_template = jsonencode({
    Resources = {
      HyperPodCluster = {
        Type       = "AWS::SageMaker::Cluster"
        Properties = local.base_properties
      }
    }
    Outputs = {
      ClusterArn  = { Value = { "Ref" = "HyperPodCluster" } }
      ClusterName = { Value = "${var.name_prefix}-hp" }
    }
  })
}

resource "aws_cloudformation_stack" "hyperpod" {
  name          = "${var.name_prefix}-hyperpod"
  template_body = local.cfn_template
  tags          = var.tags

  # The stack was created with these IAM capabilities; declare them so Terraform does not try to drop
  # them (an UpdateStack on the live cluster stack) and so future template changes that touch named IAM
  # succeed. Harmless when the template creates no IAM resources.
  capabilities = ["CAPABILITY_IAM", "CAPABILITY_NAMED_IAM"]

  timeouts {
    create = "60m"
    update = "60m"
    delete = "60m"
  }

  # EKS + managed node group + the HyperPod dependency Helm chart must all be in place before the
  # HyperPod cluster is created, or CREATE fails with "missing one or more required dependencies".
  depends_on = [
    terraform_data.hyperpod_deps,
    aws_s3_object.on_create,
    aws_iam_role_policy.hyperpod_cluster,
    aws_iam_role_policy.hyperpod_instance,
    aws_iam_role_policy_attachment.instance_managed,
  ]
}
