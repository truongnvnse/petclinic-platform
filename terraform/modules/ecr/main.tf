# main.tf — ecr module
#
# ECR private repositories for the microservices, with lifecycle policies,
# scan-on-push and per-environment tag immutability (E-4 Container Registry).
# Owned by PETPLAT-18 (module) and PETPLAT-19 (lifecycle policy, tag immutability).
#
# Design — docs/technical-spec.md → "ECR Container Registry":
#   * Repositories are namespaced petclinic-{env}/, so a dev image and a prod
#     image of the same service never share a repository or a tag namespace.
#   * Tag mutability is MUTABLE in dev and IMMUTABLE in prod. In prod the tag is
#     the identity of what was deployed, so overwriting one would make the image
#     running in the cluster unreproducible from its tag.
#   * Images are scanned on push; findings feed PETPLAT-69.

locals {
  name_prefix = "${var.project}-${var.environment}"

  # Required tags are also applied by the provider's default_tags block in the
  # environment roots. They are repeated here, and given precedence over
  # `var.tags`, so a caller can add tags but can never silently drop the tags
  # this project depends on for cost allocation and drift detection.
  common_tags = merge(
    var.tags,
    {
      Project     = var.project
      Environment = var.environment
      ManagedBy   = "terraform"
      Component   = "registry"
    },
  )

  tag_mutability = coalesce(
    var.image_tag_mutability,
    var.environment == "prod" ? "IMMUTABLE" : "MUTABLE",
  )

  # service name → repository name, e.g. api-gateway → petclinic-dev/api-gateway
  repository_names = { for service in var.service_names : service => "${local.name_prefix}/${service}" }
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

resource "aws_ecr_repository" "this" {
  for_each = local.repository_names

  name                 = each.value
  image_tag_mutability = local.tag_mutability

  # Left false by default: a destroy that would discard pushed images should
  # fail and make someone decide, not succeed quietly.
  force_delete = var.force_delete

  image_scanning_configuration {
    scan_on_push = var.scan_on_push
  }

  # The spec calls for AES256, which is also the service default — stated
  # explicitly so the choice is visible in review rather than implied by
  # omitting the block. A CMK would cost more than the images it protects.
  encryption_configuration {
    encryption_type = "AES256"
  }

  # Service is the spec's optional per-service tag, and an ECR repository is one
  # of the two resources it names as the use case — it is what makes per-service
  # cost allocation possible once the eight repositories are all billing.
  tags = merge(local.common_tags, { Name = each.value, Service = each.key })
}

# ---------------------------------------------------------------------------
# Lifecycle policy (PETPLAT-19)
#
# Two rules, evaluated in priority order. Rule 1 expires untagged images first,
# which is the rule that actually bounds cost — every re-push of a tag leaves
# the previous manifest untagged but still billed. Rule 2 then caps the number
# of tagged images, which is what keeps a rollback target available without
# keeping every build forever.
#
# tagStatus "tagged" requires a tagPrefixList or tagPatternList — AWS rejects the
# policy outright without one. tagPatternList ["*"] is the way to say "every
# tagged image" and keeps the rule self-describing.
# ---------------------------------------------------------------------------

resource "aws_ecr_lifecycle_policy" "this" {
  for_each = aws_ecr_repository.this

  repository = each.value.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        # countType is sinceImagePushed, so the age is measured from push time,
        # not from the moment an image lost its tag. Spelled out here because the
        # obvious phrasing ("expire untagged images after 7 days") would describe
        # a different, and wrong, rule.
        description = "Expire images that are untagged and were pushed more than ${var.lifecycle_expire_untagged_days} days ago"

        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = var.lifecycle_expire_untagged_days
        }

        action = { type = "expire" }
      },
      {
        rulePriority = 2
        description  = "Keep only the last ${var.lifecycle_keep_last_tagged} tagged images"

        selection = {
          tagStatus      = "tagged"
          tagPatternList = ["*"]
          countType      = "imageCountMoreThan"
          countNumber    = var.lifecycle_keep_last_tagged
        }

        action = { type = "expire" }
      },
    ]
  })
}
