# outputs.tf — Values exported by the prod root module (PETPLAT-1)
#
# Module outputs (vpc_id, cluster_endpoint, …) are re-exported here as the
# modules are wired in. The values below come from the root configuration
# itself and are useful when verifying which environment a plan targets.

output "aws_region" {
  description = "AWS region the prod environment is deployed to"
  value       = var.aws_region
}

output "environment" {
  description = "Environment name"
  value       = var.environment
}

output "project" {
  description = "Project name used for resource naming and tagging"
  value       = var.project
}

# --- E-2 Networking (PETPLAT-10) -------------------------------------------

output "vpc_id" {
  description = "VPC ID (petclinic-prod-vpc)"
  value       = module.vpc.vpc_id
}

output "public_subnet_ids" {
  description = "Public subnet IDs, one per availability zone"
  value       = module.vpc.public_subnet_ids
}

output "eks_cluster_sg_id" {
  description = "EKS control plane security group ID"
  value       = module.vpc.eks_cluster_sg_id
}

output "eks_node_sg_id" {
  description = "EKS worker node security group ID"
  value       = module.vpc.eks_node_sg_id
}

output "rds_sg_id" {
  description = "RDS security group ID"
  value       = module.vpc.rds_sg_id
}

output "alb_sg_id" {
  description = "Application Load Balancer security group ID"
  value       = module.vpc.alb_sg_id
}

# --- E-3 EKS Cluster (PETPLAT-17) -------------------------------------------

output "cluster_name" {
  description = "EKS cluster name (petclinic-prod)"
  value       = module.eks.cluster_name
}

output "cluster_endpoint" {
  description = "EKS API server endpoint"
  value       = module.eks.cluster_endpoint
}

output "cluster_ca_certificate" {
  description = "Base64-encoded certificate authority data for the cluster"
  value       = module.eks.cluster_ca_certificate
}

output "cluster_version" {
  description = "Kubernetes version the control plane is running"
  value       = module.eks.cluster_version
}

output "oidc_provider_arn" {
  description = "IAM OIDC provider ARN — Federated principal for IRSA trust policies"
  value       = module.eks.oidc_provider_arn
}

output "oidc_provider_url" {
  description = "OIDC provider URL without the https:// scheme, used as the IRSA condition key prefix"
  value       = module.eks.oidc_provider_url
}

output "node_group_name" {
  description = "Managed node group name (petclinic-prod-nodes)"
  value       = module.eks.node_group_name
}

output "node_role_arn" {
  description = "IAM role ARN shared by the worker nodes"
  value       = module.eks.node_role_arn
}

output "ebs_csi_role_arn" {
  description = "IRSA role ARN for the EBS CSI driver service account"
  value       = module.eks.ebs_csi_role_arn
}

output "eso_role_arn" {
  description = "IRSA role ARN for the External Secrets Operator service account — pass to scripts/install-eso.sh, which annotates external-secrets-sa with it"
  value       = module.eks.eso_role_arn
}

output "kubeconfig_command" {
  description = "Run this to point kubectl at the prod cluster"
  value       = module.eks.kubeconfig_command
}

# --- E-4 Container Registry ------------------------------------------------

output "ecr_registry" {
  description = "ECR registry hostname for docker login, without any repository path"
  value       = module.ecr.ecr_registry
}

output "ecr_repository_urls" {
  description = "Map of service name → ECR repository URL (append :{tag} for a pullable reference)"
  value       = module.ecr.repository_urls
}

output "ecr_repository_arns" {
  description = "Map of service name → ECR repository ARN"
  value       = module.ecr.repository_arns
}

output "ecr_image_tag_mutability" {
  description = "Effective tag mutability for this environment's repositories"
  value       = module.ecr.image_tag_mutability
}

# --- E-5 Database (PETPLAT-27) ----------------------------------------------

output "rds_endpoint" {
  description = "RDS endpoint hostname, without the port (petclinic-prod-mysql)"
  value       = module.rds.endpoint
}

output "rds_port" {
  description = "RDS port (3306)"
  value       = module.rds.port
}

output "rds_db_instance_id" {
  description = "RDS instance identifier"
  value       = module.rds.db_instance_id
}

output "rds_database_name" {
  description = "Name of the shared database inside the instance"
  value       = module.rds.database_name
}

output "rds_connection_string" {
  description = "JDBC connection string for the Spring services — contains no credentials, so it is safe in a ConfigMap"
  value       = module.rds.connection_string
}

output "rds_secret_arn" {
  description = "Secrets Manager ARN for the RDS master credentials — scope the External Secrets Operator policy to this ARN"
  value       = module.rds.secret_arn
}

output "rds_secret_name" {
  description = "Secrets Manager secret name the ExternalSecret's remoteRef.key must match"
  value       = module.rds.secret_name
}

# --- E-7 Secrets Management (PETPLAT-33) ------------------------------------

output "openai_secret_name" {
  description = "Secrets Manager secret name the openai-api-key ExternalSecret's remoteRef.key must match"
  value       = module.secrets.openai_secret_name
}

output "openai_secret_arn" {
  description = "Secrets Manager ARN for the OpenAI API key — for IAM review; it sits under the secret:petclinic/prod/* prefix the ESO role's policy grants"
  value       = module.secrets.openai_secret_arn
}

output "openai_secret_version_id" {
  description = "Version id currently holding the OpenAI API key, useful for confirming a rotation landed"
  value       = module.secrets.openai_secret_version_id
}
