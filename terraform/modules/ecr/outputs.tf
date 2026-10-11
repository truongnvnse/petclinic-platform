# outputs.tf — ecr module outputs
#
# Downstream consumers: the CI build-push workflow (repository URLs to push to),
# the Helm values (image repositories), and the IRSA/ECR-read policies that let
# nodes and pipelines pull (repository ARNs).

output "repository_urls" {
  description = "Map of service name → ECR repository URL, e.g. api-gateway → {account}.dkr.ecr.eu-central-1.amazonaws.com/petclinic-dev/api-gateway. Append :{tag} to get a pullable image reference."
  value       = { for service, repo in aws_ecr_repository.this : service => repo.repository_url }
}

output "repository_arns" {
  description = "Map of service name → ECR repository ARN. Use these to scope pull and push policies to exactly these repositories."
  value       = { for service, repo in aws_ecr_repository.this : service => repo.arn }
}

output "repository_names" {
  description = "Map of service name → repository name as it appears in ECR, e.g. api-gateway → petclinic-dev/api-gateway."
  value       = { for service, repo in aws_ecr_repository.this : service => repo.name }
}

output "registry_id" {
  description = "AWS account ID that owns the repositories"
  # Read from the caller identity rather than off one repository instance: the
  # value is identical, and it does not couple the output to service_names
  # ordering or to at least one repository existing.
  value = data.aws_caller_identity.current.account_id
}

output "ecr_registry" {
  description = "ECR registry hostname to pass to `docker login`, without any repository path"
  value       = "${data.aws_caller_identity.current.account_id}.dkr.ecr.${data.aws_region.current.name}.amazonaws.com"
}

output "environment" {
  description = "Environment these repositories belong to"
  value       = var.environment
}

output "image_tag_mutability" {
  description = "Effective tag mutability applied to every repository — MUTABLE in dev, IMMUTABLE in prod unless overridden"
  value       = local.tag_mutability
}
