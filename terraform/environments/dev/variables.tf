# variables.tf — Input variables for the dev root module (PETPLAT-5)

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

variable "domain_name" {
  description = "Apex domain whose existing Route 53 hosted zone backs the dev record (petclinic-dev.{domain_name}). Deliberately has no default: the zone must already exist — it is created by registering the domain, not by Terraform — so pointing this at an unregistered domain would fail the apply rather than quietly create a second, empty zone. See docs/technical-spec.md → \"DNS and Ingress\"."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9.-]*[a-z0-9]$", var.domain_name)) && !endswith(var.domain_name, ".")
    error_message = "The domain name must be a lowercase DNS name without a trailing dot, e.g. \"gannet.click\"."
  }
}

# The two variables below carry values that do not exist until the Ingress has
# been applied, which is why they are set in terraform.tfvars on a second pass
# rather than being derived inside the module. Keeping them as variables means
# the ALB's address lives in configuration rather than in a hand-edited main.tf,
# and the "record not yet created" state stays visible in the plan as
# alb_record_created = false.

variable "alb_dns_name" {
  description = "DNS name of the ALB the AWS Load Balancer Controller created for the api-gateway Ingress. Empty until the Ingress is applied; set it afterwards to create the petclinic-dev.{domain_name} alias record. Read it with: kubectl get ingress api-gateway -n petclinic-dev -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'"
  type        = string
  default     = ""
}

variable "alb_zone_id" {
  description = "Route 53 hosted zone ID of that ALB — the load balancer's own zone, not the domain's. Set alongside alb_dns_name. Read it with: aws elbv2 describe-load-balancers --region eu-central-1 --query \"LoadBalancers[?DNSName=='<alb_dns_name>'].CanonicalHostedZoneId\" --output text"
  type        = string
  default     = ""
}

variable "openai_api_key" {
  description = "OpenAI API key for genai-service, stored in Secrets Manager at petclinic/dev/openai-api-key. Supplied through terraform.tfvars (gitignored) or the TF_VAR_openai_api_key environment variable — never committed to Git. Ephemeral as well as sensitive, so the value is redacted from output and written to neither the state file nor plan.out. To change it, bump openai_api_key_version as well — the module explains why."

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
