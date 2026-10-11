# versions.tf — rds module provider constraints
#
# Kept in sync with the environment root modules so a module can never
# silently resolve a different AWS provider major version.
#
# The random provider is needed here (and only here) because the master
# password is generated rather than supplied — see PETPLAT-23. It is declared
# in the environment roots as well so both resolve the same build.

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
