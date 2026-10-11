# variables.tf — secrets module inputs (PETPLAT-33)
#
# Interface defined in docs/technical-spec.md → "Terraform Modules" →
# Module: secrets.

variable "project" {
  description = "Project name used for resource naming and tagging"
  type        = string
  default     = "petclinic"
}

variable "environment" {
  description = "Environment name — must be 'dev' or 'prod'"

  type = string

  validation {
    condition     = contains(["dev", "prod"], var.environment)
    error_message = "The environment must be either 'dev' or 'prod'."
  }
}

variable "openai_api_key" {
  description = "OpenAI API key value for the genai-service, stored in Secrets Manager at petclinic/{environment}/openai-api-key. Supplied through terraform.tfvars (gitignored) or TF_VAR_openai_api_key — never committed. Ephemeral as well as sensitive, so the value reaches Secrets Manager without being written to the state file or to a saved plan; bump openai_api_key_version to change it."

  type      = string
  sensitive = true

  # Ephemeral is what keeps this value out of terraform.tfstate and out of
  # plan.out. `sensitive` alone only redacts it from terminal output — the value
  # is still stored verbatim in both files, and the documented workflow saves a
  # plan and applies from it, so the key would sit in plan.out in plaintext for
  # as long as that file exists. Terraform permits this variable to be set from
  # terraform.tfvars or TF_VAR_ as usual; ephemeral governs where the value is
  # allowed to go afterwards, not where it comes from.
  ephemeral = true

  # Empty by default, and the default is load-bearing rather than lax.
  # `terraform destroy` evaluates input variables and their validation rules, but
  # it never evaluates a resource's lifecycle preconditions for a resource it is
  # destroying. A required variable — or one whose validation rejects "" —
  # therefore blocks teardown of the entire environment over a value that
  # destroy never reads. Dev is destroyed and rebuilt routinely here to save
  # cost, so that is a tax on the normal path, not an edge case.
  #
  # The protection against a blank key therefore moves to a precondition on
  # aws_secretsmanager_secret_version.openai_api_key in main.tf, which fires on
  # create and update and is skipped on destroy. That keeps the original
  # guarantee — a missing key fails at plan time instead of surfacing later as a
  # genai-service authentication error — without taxing teardown.
  default = ""

  # The length floor is a shape check, not a validity check: it catches obvious
  # placeholders left in tfvars and cannot tell a real key from a well-formed
  # wrong one. "" passes here deliberately, for the destroy reason above; the
  # precondition is what rejects it when the secret is actually being written.
  validation {
    condition     = var.openai_api_key == "" || length(trimspace(var.openai_api_key)) >= 20
    error_message = "The OpenAI API key must be at least 20 characters and not blank. Set it in terraform.tfvars or TF_VAR_openai_api_key — see terraform.tfvars.example."
  }
}

variable "openai_api_key_version" {
  description = "Revision counter for the OpenAI API key. Terraform cannot diff a write-only value — it is never read back — so changing openai_api_key alone is invisible to it and the secret keeps its old value. Increment this to write the new key. Rotating means changing both: the key and this number."

  type    = number
  default = 1

  validation {
    condition     = var.openai_api_key_version >= 1
    error_message = "openai_api_key_version starts at 1 and only ever increases."
  }
}

variable "secret_recovery_window_in_days" {
  description = "Days a deleted Secrets Manager secret can be recovered, 0 meaning it is deleted immediately. Dev sets 0: the secret is rebuilt by the next apply from the value already in the variable, and a non-zero window would block re-creating the same name until it elapsed. Prod sets 7 so a mistaken deletion is reversible. This is the same failure the rds module documents for its own secret — see terraform/modules/rds/variables.tf."
  type        = number
  default     = 0

  validation {
    condition     = var.secret_recovery_window_in_days == 0 || (var.secret_recovery_window_in_days >= 7 && var.secret_recovery_window_in_days <= 30)
    error_message = "secret_recovery_window_in_days must be 0 (delete immediately) or between 7 and 30."
  }
}

variable "tags" {
  description = "Additional tags merged into every resource this module creates"
  type        = map(string)
  default     = {}
}
