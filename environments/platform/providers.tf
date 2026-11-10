# The platform root runs in the PRIMARY region and ties the regions together: central LiteLLM + Aurora +
# Redis + entry ALB + bastion, and the cross-region VPC peering.
#
# - Default aws provider = primary region (where the central gateway + its own cluster live).
# - One aws.<region> ALIAS per OTHER candidate region, used ONLY for the peering accepter + its routes
#   (AWS-only, so no kubernetes chicken-and-egg). To add a region, add another alias here + a peering
#   module block in main.tf + the region to var.regions.
# - kubernetes/helm/kubectl attach to the ALREADY-EXISTING primary cluster (created by its region root),
#   read via terraform_remote_state. exec auth generates tokens at apply time.

provider "aws" {
  region = var.primary_region
}

# Peer-region alias for us-east-2 (the default second region). Add one alias per additional region.
provider "aws" {
  alias  = "use2"
  region = "us-east-2"
}

provider "kubernetes" {
  host                   = data.terraform_remote_state.primary.outputs.cluster_endpoint
  cluster_ca_certificate = base64decode(data.terraform_remote_state.primary.outputs.cluster_certificate_authority_data)
  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", data.terraform_remote_state.primary.outputs.cluster_name, "--region", var.primary_region]
  }
}

provider "helm" {
  kubernetes {
    host                   = data.terraform_remote_state.primary.outputs.cluster_endpoint
    cluster_ca_certificate = base64decode(data.terraform_remote_state.primary.outputs.cluster_certificate_authority_data)
    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", data.terraform_remote_state.primary.outputs.cluster_name, "--region", var.primary_region]
    }
  }
}

provider "kubectl" {
  host                   = data.terraform_remote_state.primary.outputs.cluster_endpoint
  cluster_ca_certificate = base64decode(data.terraform_remote_state.primary.outputs.cluster_certificate_authority_data)
  load_config_file       = false
  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", data.terraform_remote_state.primary.outputs.cluster_name, "--region", var.primary_region]
  }
}

# Grafana provider for the central Managed Grafana workspace's datasources. Its auth token comes from the
# observability_global module created in THIS apply, so on a clean deploy the workspace must exist first:
#   terraform apply -target=module.observability_global   # phase 1: workspace + token
#   terraform apply                                        # phase 2: datasources + everything else
# (Only needed on the first apply; subsequent applies are single-pass.)
# The grafana provider is configured only when enable_grafana=true (module.observability_global[0] exists).
# When Grafana is off, no grafana_* resources are created, but the provider block still gets configured, and
# the provider rejects an empty url - so fall back to a non-empty placeholder that is never actually used.
provider "grafana" {
  url  = try(module.observability_global[0].grafana_endpoint, "https://grafana.disabled.invalid")
  auth = try(module.observability_global[0].grafana_provisioner_token, "disabled")
}
