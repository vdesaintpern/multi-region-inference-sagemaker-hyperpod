# EKS control plane + OIDC/IRSA. No managed node group: ALL worker nodes come from HyperPod instance
# groups (see hyperpod.tf) so the cluster uses HyperPod-managed Karpenter for every tier.
#
# Bootstrap ordering note: vpc-cni/kube-proxy/pod-identity are installed here (DaemonSets / no node
# dependency). CoreDNS is created in hyperpod.tf AFTER the HyperPod "system" instance group registers
# nodes, because CoreDNS is a Deployment that needs schedulable nodes.

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.31"

  cluster_name    = "${var.name_prefix}-eks"
  cluster_version = var.kubernetes_version

  # Public endpoint so operators can run kubectl from their workstation for this sample.
  # Restrict cluster_endpoint_public_access_cidrs in production, or make the endpoint private + use a bastion.
  cluster_endpoint_public_access  = true
  cluster_endpoint_private_access = true

  vpc_id = var.vpc_id
  # EKS control plane + system node group live in the first 2 AZs. An EKS cluster's AZ set is
  # IMMUTABLE after creation, so we pin it here rather than passing all private subnets -- otherwise
  # raising az_count later fails with "should belong to the exact set of AZs ...". The HyperPod GPU
  # instance group spans ALL private subnets via OverrideVpcConfig (hyperpod.tf): GPU worker nodes can
  # join from any VPC subnet regardless of the control-plane AZ set, which is what lets the g5 land in
  # whichever AZ has capacity.
  subnet_ids = slice(var.private_subnet_ids, 0, 2)

  enable_irsa = true

  # Grant the caller and any extra principals (e.g. the HyperPod operator role) cluster admin.
  enable_cluster_creator_admin_permissions = true
  authentication_mode                      = "API_AND_CONFIG_MAP"

  access_entries = {
    for idx, arn in var.cluster_admin_principal_arns : "admin-${idx}" => {
      principal_arn = arn
      policy_associations = {
        admin = {
          policy_arn   = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
          access_scope = { type = "cluster" }
        }
      }
    }
  }

  cluster_addons = {
    coredns                = {}
    kube-proxy             = {}
    vpc-cni                = {}
    eks-pod-identity-agent = {}
  }

  # Small managed node group = the CPU/system + bootstrap tier. It must exist before the HyperPod
  # dependency Helm chart and the HyperPod cluster are created (their controllers/CoreDNS need nodes).
  # It also hosts cert-manager, the AWS LB Controller, CSI drivers, the inference operator, and LiteLLM.
  # GPU capacity comes from the HyperPod GPU instance group (hyperpod.tf), scaled by HyperPod Karpenter.
  eks_managed_node_groups = {
    system = {
      instance_types = [var.system_node_instance_type]
      min_size       = var.system_node_desired_size
      max_size       = var.system_node_desired_size + 3
      desired_size   = var.system_node_desired_size
      labels         = { workload = "system" }

      # The GPU nodes are tainted (nvidia.com/gpu), so CPU pods - including the Intelligent Router's
      # multi-GB vLLM-based image - land on these system nodes. The default 20Gi root volume fills up
      # and triggers disk-pressure eviction loops, so give them a generous gp3 root volume.
      block_device_mappings = {
        xvda = {
          device_name = "/dev/xvda"
          ebs = {
            volume_size           = var.system_node_disk_gb
            volume_type           = "gp3"
            encrypted             = true
            delete_on_termination = true
          }
        }
      }
    }
  }

  tags = var.tags
}
