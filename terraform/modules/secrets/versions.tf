# versions.tf — secrets module provider constraints
#
# Kept in sync with the environment root modules so a module can never
# silently resolve a different AWS provider major version.

terraform {
  # 1.11.0, not the 1.6.0 the other modules ask for: this module uses write-only
  # arguments (secret_string_wo), which no earlier Terraform understands. The
  # floor is raised here rather than everywhere because the constraint is a
  # property of this module's implementation, and the environment roots inherit
  # it through this module.
  required_version = ">= 1.11.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}
