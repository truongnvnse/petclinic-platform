# variables.tf — ecr module inputs
#
# Interface defined in docs/technical-spec.md → "Terraform Modules" → Module: ecr.
#
# One ECR private repository per service, namespaced petclinic-{env}/ so dev and
# prod images never share a repository. Owned by PETPLAT-18 (module) and
# PETPLAT-19 (lifecycle policy and tag immutability).

variable "project" {
  description = "Project name used for resource naming and tagging. Becomes the first segment of every repository name (petclinic-dev/api-gateway), so it must satisfy ECR's repository-name rules."
  type        = string
  default     = "petclinic"

  validation {
    condition     = can(regex("^[a-z0-9]+(?:[._-][a-z0-9]+)*$", var.project))
    error_message = "The project name must be lowercase alphanumeric with optional . _ - separators — it is prefixed to every repository name, and ECR rejects uppercase and most punctuation."
  }
}

variable "environment" {
  description = "Environment name — must be 'dev' or 'prod'. Drives both the repository namespace (petclinic-{env}/) and the default tag mutability."
  type        = string

  validation {
    condition     = contains(["dev", "prod"], var.environment)
    error_message = "The environment must be either 'dev' or 'prod'."
  }
}

variable "service_names" {
  description = "Service names to create repositories for — one ECR repository each, under the petclinic-{env}/ namespace. The eight petclinic services are listed in docs/technical-spec.md → \"Application Services\"."
  type        = list(string)

  validation {
    condition     = length(var.service_names) > 0
    error_message = "At least one service name is required."
  }

  validation {
    condition     = length(var.service_names) == length(distinct(var.service_names))
    error_message = "service_names contains a duplicate — each service gets exactly one repository, and duplicates would collide on the same name."
  }

  validation {
    condition = alltrue([
      for s in var.service_names :
      can(regex("^[a-z0-9]+(?:[._-][a-z0-9]+)*$", s))
    ])
    error_message = "Service names must be lowercase alphanumeric with optional . _ - separators — ECR rejects uppercase and most punctuation in repository names."
  }
}

variable "image_tag_mutability" {
  description = "MUTABLE lets an existing tag be overwritten by a later push; IMMUTABLE rejects it. Leave null to take the per-environment default: MUTABLE in dev (rebuilding the same commit is routine while iterating) and IMMUTABLE in prod (a tag that reached production can never be silently replaced)."
  type        = string
  default     = null

  validation {
    condition     = var.image_tag_mutability == null || contains(["MUTABLE", "IMMUTABLE"], var.image_tag_mutability)
    error_message = "image_tag_mutability must be MUTABLE, IMMUTABLE, or null to take the per-environment default."
  }
}

variable "scan_on_push" {
  description = "Scan each image for known CVEs automatically when it is pushed. Enabled in both environments per the spec — the findings feed PETPLAT-69."
  type        = bool
  default     = true
}

variable "lifecycle_keep_last_tagged" {
  description = "How many tagged images to retain per repository; older ones expire. This is what bounds storage cost as builds accumulate."
  type        = number
  default     = 10

  validation {
    condition     = var.lifecycle_keep_last_tagged >= 1
    error_message = "Keep at least one tagged image — a value of 0 would let a push expire the image it just replaced, leaving nothing to roll back to."
  }
}

variable "lifecycle_expire_untagged_days" {
  description = "Age in days after which untagged images expire. Untagged layers are the main driver of ECR storage cost: re-pushing a tag leaves the previous manifest untagged but still billed."
  type        = number
  default     = 7

  validation {
    condition     = var.lifecycle_expire_untagged_days >= 1
    error_message = "lifecycle_expire_untagged_days must be at least 1 day."
  }
}

variable "force_delete" {
  description = "Allow repository deletion even when images are still present. Left false so a `terraform destroy` fails loudly rather than silently discarding pushed images."
  type        = bool
  default     = false
}

variable "tags" {
  description = "Additional tags merged onto every resource in this module"
  type        = map(string)
  default     = {}
}
