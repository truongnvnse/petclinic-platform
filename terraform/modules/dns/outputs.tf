# outputs.tf — dns module outputs
#
# Interface defined in docs/technical-spec.md → "Terraform Modules" → Module: dns,
# as amended by the PETPLAT-28 acceptance criteria.
#
# One naming divergence, resolved in favour of the acceptance criteria: the
# spec's table calls the name-server output `name_servers`, while PETPLAT-28
# names it `zone_name_servers`. The acceptance criteria govern here, matching
# the convention already recorded in the rds module — the story is what the
# work is verified against.

output "zone_id" {
  description = "Route 53 hosted zone ID of the looked-up domain zone. Used as the zone_id for the ALB alias record."
  value       = data.aws_route53_zone.this.zone_id
}

output "zone_name_servers" {
  description = "Name servers for the hosted zone, as NS records for delegation. Read from the existing zone rather than created by this module — if the domain was registered through Route 53 these already match the registration and need no action; if it was registered elsewhere, these are the values that must be set as the domain's NS records at the registrar."
  value       = data.aws_route53_zone.this.name_servers
}

output "certificate_arn" {
  description = "ARN of the validated wildcard ACM certificate. This is the value for the alb.ingress.kubernetes.io/certificate-arn annotation on the Ingress (PETPLAT-30). Emitted from the aws_acm_certificate_validation resource so a consumer never receives an ARN that is still pending validation."
  value       = aws_acm_certificate_validation.this.certificate_arn
}

output "certificate_domain_name" {
  description = "Primary domain on the certificate — the wildcard *.gannet.click. Note this does not cover the apex."
  value       = aws_acm_certificate.this.domain_name
}

output "alb_record_fqdn" {
  description = "Hostname the ALB alias record will serve, e.g. petclinic-dev.gannet.click. Populated whether or not the record itself exists yet, so it can be referenced before the ALB is created."
  value       = local.record_fqdn
}

output "alb_record_created" {
  description = "Whether the ALB alias record exists. False until alb_dns_name and alb_zone_id are supplied after the Ingress creates the ALB — see docs/technical-spec.md → \"DNS and Ingress\" and PETPLAT-31."
  value       = length(aws_route53_record.alb) > 0
}
