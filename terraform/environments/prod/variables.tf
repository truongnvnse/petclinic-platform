# variables.tf — Input variables for the prod root module (PETPLAT-5)

variable "aws_region" {
  description = "AWS region all resources are deployed to"
  type        = string
  default     = "eu-central-1"
}

variable "environment" {
  description = "Environment name — must be 'dev' or 'prod'"

  type = string

  validation {
    condition     = contains(["dev", "prod"], var.environment)
    error_message = "The environment must be either 'dev' or 'prod'."
  }
}

variable "project" {
  description = "Project name used for resource naming and tagging"
  type        = string
  default     = "petclinic"
}

variable "openai_api_key" {
  description = "OpenAI API key for genai-service, stored in Secrets Manager at petclinic/prod/openai-api-key. Supplied through terraform.tfvars (gitignored) or the TF_VAR_openai_api_key environment variable — never committed to Git. Ephemeral as well as sensitive, so the value is redacted from output and written to neither the state file nor plan.out. To change it, bump openai_api_key_version as well — the module explains why."

  type      = string
  sensitive = true

  # Must match the module's variable, which is also ephemeral. Leaving it
  # non-ephemeral here would persist the value into plan.out at the root before
  # the module ever saw it, which is the thing this is here to prevent.
  ephemeral = true

  # Empty by default so that `terraform destroy` runs without a key. Destroy
  # evaluates variable validations but skips resource preconditions, so a
  # required variable here would block teardown of the whole environment over a
  # value destroy never reads. The module's precondition on the secret version
  # is what rejects a blank value when it is actually being written, so the
  # original guarantee is intact — see terraform/modules/secrets/variables.tf.
  default = ""

  # The module validates the value's shape; the rule is deliberately not
  # repeated here. Two copies of the same rule would drift, and the module is
  # the single place that defines what a usable key looks like.
}
