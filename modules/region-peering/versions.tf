terraform {
  required_version = ">= 1.6"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.70"
      # Two aws providers: default = requester (primary region), aws.peer = accepter (remote region).
      configuration_aliases = [aws, aws.peer]
    }
  }
}
