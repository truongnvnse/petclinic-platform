# variables.tf — github-oidc module inputs (PETPLAT-52)

variable "project" {
  description = "Project name, used as the first part of every resource name and in the Project tag"
  type        = string
  default     = "petclinic"
}

variable "environment" {
  description = "Environment this role belongs to. Part of the role name because dev and prod each get their own role — a single shared role would let a dev build push to a prod repository."
  type        = string

  validation {
    condition     = contains(["dev", "prod"], var.environment)
    error_message = "environment must be \"dev\" or \"prod\"."
  }
}

variable "github_repository" {
  description = "GitHub repository allowed to assume this role, as owner/name. Must be the APPLICATION repo, not the platform repo — the app repo's build-push workflow is the one that pushes to ECR. See the note at the top of main.tf."
  type        = string

  validation {
    condition     = can(regex("^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$", var.github_repository))
    error_message = "github_repository must be owner/name, e.g. \"truongnvnse/spring-petclinic-microservices\"."
  }
}

variable "github_branch" {
  description = "Branch whose workflow runs may assume the role. Pinning this is what stops a token minted for any other branch of the same repository from assuming it."
  type        = string
  default     = "main"

  validation {
    # Worth validating because the failure is silent rather than loud: an empty
    # or padded value builds the subject `repo:owner/name:ref:refs/heads/` (or
    # one with a trailing space), which is syntactically fine, applies cleanly,
    # and simply never matches a real token. Branch names may contain slashes —
    # `release/1.x` is legitimate — so only whitespace and emptiness are refused.
    condition     = trimspace(var.github_branch) != "" && !can(regex("\\s", var.github_branch))
    error_message = "github_branch must be a non-empty branch name containing no whitespace, e.g. \"main\". An empty value would produce a subject no token can ever match."
  }
}

variable "github_owner_id" {
  description = "Numeric GitHub ID of the repository owner, as it appears in the OIDC subject claim. Not the username: see github_subject in main.tf. Read it from https://api.github.com/repos/OWNER/NAME — the owner.id field."
  type        = number

  validation {
    # Same class of failure as an empty github_branch, and the reason this is
    # validated rather than trusted: a wrong ID builds a subject that is
    # syntactically perfect, plans clean, applies clean, and simply never
    # matches a token. Nothing fails until a build runs, and then the error
    # names STS rather than this variable.
    condition     = var.github_owner_id > 0
    error_message = "github_owner_id must be the owner's numeric GitHub ID, greater than zero. A name, or 0, would build a subject no token can ever match."
  }
}

variable "github_repository_id" {
  description = "Numeric GitHub ID of the repository, as it appears in the OIDC subject claim. Read it from https://api.github.com/repos/OWNER/NAME — the id field. See github_owner_id."
  type        = number

  validation {
    condition     = var.github_repository_id > 0
    error_message = "github_repository_id must be the repository's numeric GitHub ID, greater than zero. A name, or 0, would build a subject no token can ever match."
  }
}

variable "repository_arns" {
  description = "ARNs of the ECR repositories CI may push to. Pass values(module.ecr.repository_arns) so the policy names eight repositories rather than a wildcard."
  type        = list(string)

  validation {
    # terraform validate does not evaluate this — only plan does. A green
    # validate is not evidence that this holds.
    condition     = length(var.repository_arns) > 0
    error_message = "repository_arns must not be empty: the role would still authenticate but could push to nothing, and the failure would surface as an opaque 403 inside the build rather than here."
  }
}

variable "create_oidc_provider" {
  description = "Whether this module should create the token.actions.githubusercontent.com provider. An AWS account may hold only ONE provider per URL, so exactly one environment may set this true; any other environment must pass existing_oidc_provider_arn instead. Defaults to false so that an environment which forgets the flag fails at plan time on the precondition, rather than at apply time on an AWS EntityAlreadyExists that re-running does not clear."
  type        = bool
  default     = false
}

variable "existing_oidc_provider_arn" {
  description = "ARN of an already-existing GitHub OIDC provider, for the environment that does not create it. Read it from the creating environment's github_oidc_provider_arn output — NOT from that environment's oidc_provider_arn, which is the EKS cluster's IRSA provider. Required when create_oidc_provider is false."
  type        = string
  default     = ""

  validation {
    # The URL suffix is required, not just the ARN shape. This account holds a
    # second OIDC provider for the EKS cluster, and the dev root exports it as
    # `oidc_provider_arn` while exporting this one as `github_oidc_provider_arn`
    # — two names one character of context apart. An ARN-shape-only check accepts
    # the EKS provider, the precondition passes because the string is non-empty,
    # plan and apply both succeed, and the resulting role is silently
    # unassumable. It surfaces later as an AccessDenied in the app repo's CI,
    # which is the hardest possible place to trace it back from.
    condition = var.existing_oidc_provider_arn == "" || can(regex(
      "^arn:aws:iam::[0-9]{12}:oidc-provider/token\\.actions\\.githubusercontent\\.com$",
      var.existing_oidc_provider_arn,
    ))
    error_message = "existing_oidc_provider_arn must be empty or the GitHub provider's ARN exactly — arn:aws:iam::<account>:oidc-provider/token.actions.githubusercontent.com. An ARN for a different provider (the EKS IRSA one, for instance) would produce a role nothing can assume."
  }
}

variable "max_session_duration" {
  description = "Maximum lifetime of an assumed-role session, in seconds. 3600 is the AWS default and already far longer than an image build needs; the ceiling is 43200."
  type        = number
  default     = 3600

  validation {
    condition     = var.max_session_duration >= 3600 && var.max_session_duration <= 43200
    error_message = "max_session_duration must be between 3600 and 43200 seconds, which is the range AWS accepts."
  }
}

variable "tags" {
  description = "Additional tags merged into every resource. Project, Environment and ManagedBy are applied regardless and take precedence over these."
  type        = map(string)
  default     = {}
}
