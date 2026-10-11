# variables.tf — dns module inputs
#
# Interface defined in docs/technical-spec.md → "Terraform Modules" → Module: dns,
# plus the ALB alias record from PETPLAT-31.
#
# The hosted zone is looked up with a data source rather than created. Route 53
# creates the zone automatically when the domain is registered, and that zone
# already holds the registration's NS and SOA records. Declaring an
# aws_route53_zone resource for the same name would create a *second*, empty
# zone with its own name servers; the ACM validation records would be written
# into that empty zone, which the public DNS never consults, so the certificate
# would sit in PENDING_VALIDATION until it timed out. Looking the zone up keeps
# the validation records in the zone that actually answers for the domain.

variable "project" {
  description = "Project name used for resource naming and tagging"
  type        = string
  default     = "petclinic"
}

variable "environment" {
  description = "Environment name — must be 'dev' or 'prod'. Drives the default record name (petclinic-{env}) and the certificate tag."
  type        = string

  validation {
    condition     = contains(["dev", "prod"], var.environment)
    error_message = "The environment must be either 'dev' or 'prod'."
  }
}

variable "domain_name" {
  description = "Apex domain whose existing Route 53 hosted zone is looked up, e.g. \"gannet.click\". The ACM certificate is requested for the wildcard \"*.{domain_name}\" so that a single certificate covers every environment's record. No trailing dot — aws_route53_zone matches the name with or without it, but the wildcard certificate must be built from a consistent form."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9.-]*[a-z0-9]$", var.domain_name)) && !endswith(var.domain_name, ".")
    error_message = "The domain name must be a lowercase DNS name without a trailing dot, e.g. \"gannet.click\"."
  }
}

variable "record_name" {
  description = "Host label for the ALB alias record, relative to domain_name. Defaults to petclinic-{environment}, giving petclinic-dev.{domain} in dev and petclinic.{domain} in prod per docs/technical-spec.md → \"DNS and Ingress\" → \"Route 53\". Leave null to use the default. This is a label, not a fully-qualified name: do not append domain_name and do not add a trailing dot."
  type        = string
  default     = null

  # The module builds the record as "${record_name}.${domain_name}", so a value
  # that already carries the domain — or a trailing dot — would silently produce
  # a doubled name like petclinic-dev.gannet.click.gannet.click: a record that
  # resolves nowhere but plans clean, so nothing surfaces the mistake until
  # someone tries the hostname. Only a single label is accepted, which rules
  # both out. The apex is rejected too: the certificate is a wildcard, which
  # does not cover the apex, so an apex record would serve a certificate
  # mismatch rather than the application.
  validation {
    condition     = var.record_name == null || can(regex("^[a-z0-9]([a-z0-9-]*[a-z0-9])?$", var.record_name))
    error_message = "The record name must be a single relative lowercase DNS label such as \"petclinic-dev\" — no dots, no trailing dot, and without domain_name appended. The apex (\"@\") is not supported because the wildcard certificate does not cover it."
  }
}

variable "alb_dns_name" {
  description = "DNS name of the ALB created by the AWS Load Balancer Controller, used as the alias target. The ALB does not exist until the Ingress from PETPLAT-30 is applied, so this defaults to empty and the alias record is skipped until a value is supplied. Read it after applying the Ingress with: kubectl get ingress api-gateway -n petclinic-dev -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'"
  type        = string
  default     = ""

  validation {
    condition     = var.alb_dns_name == "" || can(regex("^[a-z0-9][a-z0-9.-]*\\.elb\\.amazonaws\\.com$", var.alb_dns_name))
    error_message = "The ALB DNS name must be empty or an ELB hostname ending in .elb.amazonaws.com."
  }
}

variable "alb_zone_id" {
  description = "Route 53 hosted zone ID of the ALB, required for an alias record — this is the load balancer's own zone (e.g. Z215JYRZR1TBD5 for an ALB in eu-central-1), not the domain's. Look it up with: aws elbv2 describe-load-balancers --names <name> --query 'LoadBalancers[0].CanonicalHostedZoneId'. Ignored when alb_dns_name is empty."
  type        = string
  default     = ""

  validation {
    condition     = var.alb_zone_id == "" || can(regex("^Z[A-Z0-9]+$", var.alb_zone_id))
    error_message = "The ALB zone ID must be empty or a Route 53 zone ID of the form Z followed by uppercase alphanumerics."
  }
}

variable "alb_record_ttl" {
  description = "TTL in seconds for the non-alias records this module creates. Alias records ignore TTL, so this applies only to the ACM validation records. 60 seconds keeps a re-issued certificate propagating quickly during an environment rebuild."
  type        = number
  default     = 60
}

variable "tags" {
  description = "Additional tags merged into every resource. The required Project/Environment/ManagedBy tags are applied regardless and take precedence over any duplicate key supplied here."
  type        = map(string)
  default     = {}
}
