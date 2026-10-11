# outputs.tf — secrets module outputs (PETPLAT-33)
#
# Interface defined in docs/technical-spec.md → "Terraform Modules" →
# Module: secrets.

output "openai_secret_arn" {
  description = "Secrets Manager ARN for the OpenAI API key. The ExternalSecret in k8s/base/external-secrets/openai-api-key.yaml references the secret by name rather than ARN, so nothing consumes this value automatically — it exists for IAM review and for confirming that the ARN sits under the secret:petclinic/{environment}/* prefix the ESO role's policy grants. See k8s/base/external-secrets/README.md for the rotation procedure."
  value       = aws_secretsmanager_secret.openai_api_key.arn
}

output "openai_secret_name" {
  description = "Name of the OpenAI API key secret (petclinic/{env}/openai-api-key). This is the value the ExternalSecret's remoteRef.key must match."
  value       = aws_secretsmanager_secret.openai_api_key.name
}

output "openai_secret_version_id" {
  description = "Version ID of the current secret value. Changes whenever openai_api_key is updated, which is what makes a rotation visible as a plan diff rather than a silent overwrite."
  value       = aws_secretsmanager_secret_version.openai_api_key.version_id
}
