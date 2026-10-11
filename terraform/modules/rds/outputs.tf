# outputs.tf — rds module outputs
#
# Interface defined in docs/technical-spec.md → "Terraform Modules" → Module: rds.
#
# Downstream consumers: the EKS/Helm values that need the JDBC URL (PETPLAT-24),
# and the External Secrets Operator configuration, whose ClusterSecretStore
# policy is scoped to the secret ARN (E-7, PETPLAT-33).
#
# The master password is deliberately not exported. Nothing outside this module
# needs it directly — the services read it from Secrets Manager at runtime —
# and an output is one more place it would be copied to.

output "endpoint" {
  description = "RDS endpoint hostname, WITHOUT the port. The spec's connection string format is jdbc:mysql://{endpoint}:3306/petclinic, so the port is published separately rather than pre-joined — a template that hardcodes :3306 next to a value that already ends in :3306 fails in a way that is easy to miss."
  value       = aws_db_instance.this.address
}

output "port" {
  description = "RDS port (3306 for MySQL)"
  value       = aws_db_instance.this.port
}

output "db_instance_id" {
  description = "RDS instance identifier (petclinic-{env}-mysql)"
  value       = aws_db_instance.this.identifier
}

output "secret_arn" {
  description = "Secrets Manager ARN holding the master credentials — scope the External Secrets Operator IAM policy to exactly this ARN."
  value       = aws_secretsmanager_secret.rds_credentials.arn
}

output "secret_name" {
  description = "Secrets Manager secret name (petclinic/{env}/rds-credentials) — the value the ExternalSecret's remoteRef.key must match."
  value       = aws_secretsmanager_secret.rds_credentials.name
}

output "database_name" {
  description = "Name of the shared database inside the instance (petclinic). All three database-backed services connect to this one database."
  value       = aws_db_instance.this.db_name
}

output "connection_string" {
  description = "JDBC connection string for the Spring services, in the spec's documented format. Contains no credentials — the username and password come from Secrets Manager at runtime, so this value is safe to place in a ConfigMap."
  value       = "jdbc:mysql://${aws_db_instance.this.address}:${aws_db_instance.this.port}/${var.database_name}"
}
