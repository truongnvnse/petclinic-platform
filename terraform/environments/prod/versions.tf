# versions.tf — Terraform and provider version constraints (PETPLAT-5)
#
# Pins the CLI and provider versions so every engineer and CI runner resolves
# the same provider build. See docs/technical-spec.md → "General Project
# Parameters".

terraform {
  required_version = ">= 1.6.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
  }
}
