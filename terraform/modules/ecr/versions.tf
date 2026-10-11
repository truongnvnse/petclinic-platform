# versions.tf — ecr module provider constraints
#
# Kept in sync with the environment root modules so a module can never
# silently resolve a different AWS provider major version.

terraform {
  required_version = ">= 1.6.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}
