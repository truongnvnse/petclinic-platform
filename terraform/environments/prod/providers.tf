# providers.tf — AWS provider configuration, prod (PETPLAT-5)
#
# default_tags applies the three required tags to every resource created by
# this root module, including resources created by child modules. Modules
# accept an additional `tags` variable to merge service-specific tags on top.
# See docs/technical-spec.md → "Required Tags".

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = var.project
      Environment = var.environment
      ManagedBy   = "terraform"
    }
  }
}
