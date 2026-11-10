terraform {
  required_version = ">= 1.6"

  # Separate remote state from the main stack. Init with:
  #   terraform init -backend-config=backend.hcl
  backend "s3" {}

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.70"
    }
  }
}
