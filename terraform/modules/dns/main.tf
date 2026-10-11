# main.tf — dns module (PETPLAT-28, PETPLAT-31)
#
# Route 53 lookup and ACM certificate for the ALB that fronts the API Gateway.
# Values from docs/technical-spec.md → "DNS and Ingress":
#   * wildcard certificate for *.gannet.click, DNS-validated through Route 53
#   * certificate lives in eu-central-1, the same region as the ALB — an ACM
#     certificate is only usable by an ALB in the region that issued it, so a
#     us-east-1 certificate (the usual choice for CloudFront) would be invisible
#     to this load balancer
#   * dev record petclinic-dev.{domain}, prod record petclinic.{domain}
#
# The zone is *looked up*, never created — see the header of variables.tf for
# why an aws_route53_zone resource here would break certificate validation.

# ---------------------------------------------------------------------------
# Hosted zone (existing — created by domain registration, not by Terraform)
# ---------------------------------------------------------------------------

data "aws_route53_zone" "this" {
  name         = var.domain_name
  private_zone = false
}

# ---------------------------------------------------------------------------
# ACM certificate (PETPLAT-28)
#
# The wildcard covers every environment's record from a single certificate, so
# adding a staging environment later needs no new certificate and no new
# validation wait.
#
# DNS validation is chosen over email validation because it is the only method
# Terraform can complete unattended: the validation record is written into the
# zone above and ACM polls for it. Email validation would require someone to
# click a link in a mailbox, which stalls a rebuild until a human intervenes.
#
# A wildcard certificate does NOT cover the apex itself — *.gannet.click does
# not match gannet.click. Nothing in this platform serves the apex, so the
# certificate is requested for the wildcard alone.
# ---------------------------------------------------------------------------

resource "aws_acm_certificate" "this" {
  domain_name       = "*.${var.domain_name}"
  validation_method = "DNS"

  # The certificate is replaced rather than updated when the domain changes —
  # ACM has no in-place domain change — so create the replacement before
  # destroying the old one. Without this, a rename would briefly leave the ALB
  # with no valid certificate.
  lifecycle {
    create_before_destroy = true
  }

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-wildcard-cert"
  })
}

# ---------------------------------------------------------------------------
# DNS validation records
#
# One record per domain in the certificate's validation options. The for_each
# is keyed on the validated domain name rather than the option's index so that
# adding a subject alternative name later does not shift existing records in
# state and cause a spurious destroy/recreate of records ACM is already
# checking.
# ---------------------------------------------------------------------------

resource "aws_route53_record" "validation" {
  for_each = {
    for dvo in aws_acm_certificate.this.domain_validation_options :
    dvo.domain_name => dvo
  }

  zone_id = data.aws_route53_zone.this.zone_id
  name    = each.value.resource_record_name
  type    = each.value.resource_record_type
  records = [each.value.resource_record_value]
  ttl     = var.alb_record_ttl

  # The record may already exist — ACM writes one itself if "Create records in
  # Route 53" was ever clicked in the console — so overwrite rather than fail.
  #
  # There is deliberately no ignore_changes here. The for_each key is the
  # validated domain name, which does not change when the same wildcard is
  # re-requested, so replacing the certificate *updates* this record in place
  # rather than replacing it. Ignoring `records` would leave the previous
  # certificate's validation token sitting under the new certificate's record
  # name: ACM polls, finds the wrong value, and never validates — failing only
  # when aws_acm_certificate_validation times out, with an error that points at
  # ACM rather than at the stale record. The validation value is stable for the
  # life of a certificate and changes only when the certificate does, which is
  # exactly when it has to be rewritten.
  allow_overwrite = true
}

# Blocks the apply until ACM reports the certificate as ISSUED. Without this the
# module returns a certificate ARN that is still PENDING_VALIDATION, and an
# Ingress applied in the same breath would be rejected by the ALB controller
# because the certificate cannot yet be attached to a listener.
resource "aws_acm_certificate_validation" "this" {
  certificate_arn         = aws_acm_certificate.this.arn
  validation_record_fqdns = [for record in aws_route53_record.validation : record.fqdn]
}

# ---------------------------------------------------------------------------
# ALB alias record (PETPLAT-31)
#
# Created only once the ALB exists. The AWS Load Balancer Controller creates the
# ALB in response to the Ingress (PETPLAT-30), so its DNS name is not known when
# this module is first applied — the record is skipped while alb_dns_name is
# empty and created on the next apply once it has been supplied. This keeps
# `terraform plan` green both before and after the Ingress exists, which matters
# because a data source lookup would fail the whole plan in CI on a fresh
# environment.
#
# An alias (not a CNAME) is used because alias lookups to an ALB are free while
# CNAME queries are billed, and because an alias tracks the load balancer if its
# address changes. The record is a label under domain_name, not an apex record:
# the certificate is a wildcard, which does not cover the apex, so an apex
# record would present a certificate mismatch rather than serve traffic.
# ---------------------------------------------------------------------------

resource "aws_route53_record" "alb" {
  count = var.alb_dns_name != "" && var.alb_zone_id != "" ? 1 : 0

  zone_id = data.aws_route53_zone.this.zone_id
  name    = local.record_fqdn
  type    = "A"

  alias {
    name                   = var.alb_dns_name
    zone_id                = var.alb_zone_id
    evaluate_target_health = true
  }
}

locals {
  # Naming convention: petclinic-{env}-{resource}
  name_prefix = "${var.project}-${var.environment}"

  # The spec's Route 53 table names the dev record petclinic-dev.{domain} and
  # the prod record petclinic.{domain}. That is exactly petclinic-{environment}
  # in dev and the bare project name in prod, so prod is special-cased rather
  # than following the usual petclinic-{env} pattern.
  record_label = coalesce(var.record_name, var.environment == "prod" ? var.project : local.name_prefix)
  record_fqdn  = "${local.record_label}.${var.domain_name}"

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
      Component   = "dns"
    },
  )
}
