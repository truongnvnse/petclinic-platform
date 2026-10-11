# outputs.tf — github-oidc module outputs (PETPLAT-52)
#
# Downstream consumers: the AWS_ROLE_ARN GitHub secret (PETPLAT-52's secrets
# table), the app repo's build-push workflow, and any other environment that
# needs to reference the shared OIDC provider.

output "role_arn" {
  description = "ARN of the role GitHub Actions assumes. This is the value of the AWS_ROLE_ARN repository secret, and what aws-actions/configure-aws-credentials takes as role-to-assume."
  value       = aws_iam_role.github_actions.arn
}

output "role_name" {
  description = "Role name, e.g. petclinic-dev-github-actions-role"
  value       = aws_iam_role.github_actions.name
}

output "oidc_provider_arn" {
  description = "ARN of the GitHub OIDC provider. Pass this as existing_oidc_provider_arn to any other environment's module call — an AWS account may hold only one provider for this URL, so exactly one environment creates it."
  value       = local.oidc_provider_arn
}

output "github_subject" {
  description = "The subject claim the trust policy accepts, e.g. repo:truongnvnse@336541468/spring-petclinic-microservices@1400042382:ref:refs/heads/main. Exported so it can be compared against what GitHub actually sends, which is the first thing to check when a workflow gets AccessDenied on AssumeRoleWithWebIdentity. To read what GitHub actually sent, look the failure up in CloudTrail rather than guessing: the event's userIdentity.userName IS the subject claim."
  value       = local.github_subject
}

output "ecr_push_actions" {
  description = "The ECR actions granted, for audit. Deliberately excludes the pull actions and every other service's API."
  value       = local.ecr_push_actions
}
