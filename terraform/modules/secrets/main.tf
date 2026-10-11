# main.tf — secrets module (PETPLAT-33)
#
# Non-RDS application secrets in AWS Secrets Manager (E-7).
#
# RDS credentials are NOT managed here. They are created by the rds module
# (PETPLAT-23) with a random_password and stored as a JSON object, because the
# password and the database instance that consumes it have to be created
# together. Duplicating them here would mean two sources of truth for the same
# credential and a rotation that updates only one of them.
#
# Secrets are encrypted with the AWS-managed `aws/secretsmanager` key, which is
# the default and needs no key resource — see docs/technical-spec.md →
# "Security Controls" → Encryption Matrix. That choice is also why the ESO IRSA
# role carries no kms:Decrypt permission: with an AWS-managed key the
# permission is the service's, not the caller's. Attaching it anyway would
# widen the role for no effect. If a customer-managed key is ever introduced,
# the role in terraform/modules/eks/ needs kms:Decrypt on that key at the same
# time.
#
# Secret names follow the forward-slash convention petclinic/{env}/... from
# docs/technical-spec.md → "Secrets Management". The naming matters beyond
# tidiness: the ESO IRSA policy grants read on `secret:petclinic/{env}/*`, so a
# secret created under a different prefix is invisible to the operator even
# though it exists.

locals {
  # Naming convention: petclinic-{env}-{resource}
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
      Component   = "secrets"
    },
  )

  # Slash-separated, not the petclinic-{env}-{resource} dash convention used for
  # AWS resource *names*. Secrets Manager names are a path, and this is the
  # shape the spec and the IAM policy pattern both assume.
  openai_secret_name = "${var.project}/${var.environment}/openai-api-key"
}

# ---------------------------------------------------------------------------
# OpenAI API key — consumed by genai-service
#
# Required, not optional. The precondition on the version resource below rejects
# a blank key at plan time, so this module cannot be applied without one. That is
# deliberate: a secret created empty applies cleanly and then surfaces as an
# authentication error from genai-service at runtime, long after the apply that
# caused it, and a secret with no version at all fails only at ESO sync time.
# Both are worse than a plan that stops and says why.
#
# The cost is that dev's destroy-and-rebuild cycle needs the key supplied even
# when the work at hand has nothing to do with genai-service. Export
# TF_VAR_openai_api_key, or uncomment it in terraform.tfvars. Note this is not
# only a plan-time requirement: the variable is ephemeral, so its value is absent
# from plan.out and must be re-supplied when applying a saved plan.
#
# A plaintext secret, not JSON: there is exactly one value and no second field
# to carry, so the ExternalSecret reads it with a bare remoteRef rather than a
# remoteRef.property. That difference is visible in
# k8s/base/external-secrets/openai-api-key.yaml and is deliberate — wrapping a
# single value in JSON would add a parsing step on both sides for nothing.
#
# The value arrives as an ephemeral, sensitive variable and is never written
# into this repository. terraform.tfvars is gitignored; the committed template
# carries a placeholder.
#
# It is also never written to terraform.tfstate or to plan.out. The version
# resource below uses the write-only form of the argument, which is the only
# way to get a value into Secrets Manager without Terraform persisting it:
# `sensitive` redacts a value from terminal output but still stores it in both
# files, and this project's documented workflow is to save a plan and apply
# from it. See terraform/modules/secrets/variables.tf → openai_api_key.
# ---------------------------------------------------------------------------

resource "aws_secretsmanager_secret" "openai_api_key" {
  name        = local.openai_secret_name
  description = "OpenAI API key for the ${local.name_prefix} genai-service"

  # Not left to the AWS default of 30 days. A deleted secret is only scheduled
  # for deletion, and while it is scheduled its name cannot be reused — the
  # next apply fails with "You can't create this secret because a secret with
  # this name is already scheduled for deletion" and no amount of re-running
  # fixes it until the window elapses. That breaks the dev destroy/rebuild
  # cycle outright, so dev sets 0. Prod sets 7, where the rebuild is not a
  # routine operation and reversibility of a mistake is worth more.
  recovery_window_in_days = var.secret_recovery_window_in_days

  tags = merge(local.common_tags, { Name = local.openai_secret_name })
}

resource "aws_secretsmanager_secret_version" "openai_api_key" {
  secret_id = aws_secretsmanager_secret.openai_api_key.id

  # The write-only argument, not secret_string. The value is passed to the
  # provider during apply and then discarded; it appears in neither the state
  # file nor a saved plan. Setting both forms at once is an error, so this is
  # either/or rather than an addition.
  #
  # The cost of that guarantee is that Terraform cannot read the value back, so
  # it cannot notice that it changed. Editing openai_api_key alone therefore
  # produces no diff and leaves the old value in Secrets Manager. The version
  # number is the only signal Terraform has, which is why rotating is a
  # two-field edit — see variables.tf.
  secret_string_wo         = var.openai_api_key
  secret_string_wo_version = var.openai_api_key_version

  lifecycle {
    # Rejects a blank key at plan time. This lives here rather than in the
    # variable's validation block because destroy skips preconditions and does
    # not skip validations — a validation that rejected "" would block teardown
    # of the whole environment. See variables.tf → openai_api_key.
    #
    # Referencing an ephemeral value from a precondition is permitted; only
    # error_message is barred from carrying one, and this message is static.
    precondition {
      condition     = length(trimspace(var.openai_api_key)) >= 20
      error_message = "openai_api_key is empty or shorter than 20 characters, so this would write a blank value to Secrets Manager and genai-service would fail to authenticate at runtime. Set it in terraform.tfvars or TF_VAR_openai_api_key — see terraform.tfvars.example."
    }
  }
}
