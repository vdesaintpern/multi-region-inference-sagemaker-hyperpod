terraform {
  required_version = ">= 1.6"

  # Remote state. Configure with: terraform init -backend-config=backend.hcl
  # Use a UNIQUE key per region (e.g. region-us-east-1/terraform.tfstate).
  backend "s3" {}

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.70"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.30"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.13"
    }
    kubectl = {
      source  = "gavinbunney/kubectl"
      version = ">= 1.14"
    }
    random = {
      source  = "hashicorp/random"
      version = ">= 3.5"
    }
  }
}
