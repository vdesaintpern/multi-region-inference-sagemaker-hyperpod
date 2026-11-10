# The `region` root is applied once per region (including the primary). The default aws provider targets
# this region; aws.primary targets the primary region, where every region publishes its discovery entries
# (model ALB DNS, VPC id/cidr, route tables, AMP ARN) into SSM for the platform root to read.
#
# k8s/helm/kubectl authenticate to the EKS cluster created in THIS stack (module.cluster) via the exec
# plugin (`aws eks get-token`) so tokens are generated at apply time, not stored in state.
#
# First-apply note: because the providers reference the cluster's outputs (known only after the cluster
# exists), a clean apply needs the network AND cluster created first. Target BOTH - targeting only
# module.cluster skips the NAT gateways / private route tables (the cluster does not reference them), so
# the nodes get no outbound path and fail to join the cluster:
#   terraform apply -target=module.network -target=module.cluster -var-file=<region>.tfvars
#   terraform apply -var-file=<region>.tfvars
# On an already-created cluster a single `terraform apply` suffices.

provider "aws" {
  region = var.region
}

provider "aws" {
  alias  = "primary"
  region = var.primary_region
}

provider "kubernetes" {
  host                   = module.cluster.cluster_endpoint
  cluster_ca_certificate = base64decode(module.cluster.cluster_certificate_authority_data)
  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", module.cluster.cluster_name, "--region", var.region]
  }
}

provider "helm" {
  kubernetes {
    host                   = module.cluster.cluster_endpoint
    cluster_ca_certificate = base64decode(module.cluster.cluster_certificate_authority_data)
    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", module.cluster.cluster_name, "--region", var.region]
    }
  }
}

provider "kubectl" {
  host                   = module.cluster.cluster_endpoint
  cluster_ca_certificate = base64decode(module.cluster.cluster_certificate_authority_data)
  load_config_file       = false
  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", module.cluster.cluster_name, "--region", var.region]
  }
}
