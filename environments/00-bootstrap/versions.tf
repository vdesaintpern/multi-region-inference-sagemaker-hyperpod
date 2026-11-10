terraform {
  required_version = ">= 1.6"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.70"
    }
    random = {
      source  = "hashicorp/random"
      version = ">= 3.6"
    }
  }

  # LOCAL backend on purpose. This stack BOOTSTRAPS the remote state backend
  # (S3 bucket + KMS key + DynamoDB lock table) that every other stack uses.
  # It cannot store its own state in a backend that does not exist yet, so its
  # state lives on disk here. Commit this state file's location to a safe place
  # (or migrate it into the created bucket afterwards with `terraform init
  # -migrate-state`). Do NOT commit terraform.tfstate to source control.
  backend "local" {
    path = "terraform.tfstate"
  }
}
