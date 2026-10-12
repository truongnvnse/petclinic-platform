# outputs.tf — Values exported by the dev root module (PETPLAT-1)
#
# Module outputs (vpc_id, cluster_endpoint, …) are re-exported here as the
# modules are wired in. The values below come from the root configuration
# itself and are useful when verifying which environment a plan targets.

output "aws_region" {
  description = "AWS region the dev environment is deployed to"
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

# --- E-2 Networking (PETPLAT-9) --------------------------------------------

output "vpc_id" {
  description = "VPC ID (petclinic-dev-vpc)"
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

# --- E-3 EKS Cluster (PETPLAT-15) -------------------------------------------

output "cluster_name" {
  description = "EKS cluster name (petclinic-dev)"
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
  description = "Managed node group name (petclinic-dev-nodes)"
  value       = module.eks.node_group_name
}

output "node_group_scaling" {
  description = "Scaling config Terraform declares for the node group. scripts/start-env.sh reads this to restore the group after stop-env.sh scaled it to zero — the numbers live here rather than in the script so the two cannot disagree."
  value       = module.eks.node_group_scaling
}

output "node_role_arn" {
  description = "IAM role ARN shared by the worker nodes"
  value       = module.eks.node_role_arn
}

output "ebs_csi_role_arn" {
  description = "IRSA role ARN for the EBS CSI driver service account"
  value       = module.eks.ebs_csi_role_arn
}

output "lb_controller_role_arn" {
  description = "IRSA role ARN for the AWS Load Balancer Controller service account — pass to scripts/install-lb-controller.sh"
  value       = module.eks.lb_controller_role_arn
}

output "eso_role_arn" {
  description = "IRSA role ARN for the External Secrets Operator service account — pass to scripts/install-eso.sh, which annotates external-secrets-sa with it"
  value       = module.eks.eso_role_arn
}

output "kubeconfig_command" {
  description = "Run this to point kubectl at the dev cluster"
  value       = module.eks.kubeconfig_command
}

# --- E-4 Container Registry (PETPLAT-20) ------------------------------------

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

# --- E-5 Database (PETPLAT-25) ----------------------------------------------

output "rds_endpoint" {
  description = "RDS endpoint hostname, without the port (petclinic-dev-mysql)"
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

# --- E-6 DNS & Ingress (PETPLAT-32) -----------------------------------------

output "dns_zone_id" {
  description = "Route 53 hosted zone ID of the domain's existing zone"
  value       = module.dns.zone_id
}

output "dns_zone_name_servers" {
  description = "Name servers for the domain's hosted zone — these are the registration's NS records, not ones this module created"
  value       = module.dns.zone_name_servers
}

output "acm_certificate_arn" {
  description = "Validated wildcard ACM certificate ARN — substituted into the alb.ingress.kubernetes.io/certificate-arn annotation by scripts/render-ingress.sh, which reads this output rather than having you copy it"
  value       = module.dns.certificate_arn
}

output "alb_record_fqdn" {
  description = "Hostname the ALB alias record serves (petclinic-dev.{domain})"
  value       = module.dns.alb_record_fqdn
}

output "alb_record_created" {
  description = "False until alb_dns_name and alb_zone_id are supplied after the Ingress creates the ALB — see PETPLAT-31"
  value       = module.dns.alb_record_created
}

# --- E-7 Secrets Management (PETPLAT-33) ------------------------------------

output "openai_secret_name" {
  description = "Secrets Manager secret name the openai-api-key ExternalSecret's remoteRef.key must match"
  value       = module.secrets.openai_secret_name
}

output "openai_secret_arn" {
  description = "Secrets Manager ARN for the OpenAI API key — for IAM review; it sits under the secret:petclinic/dev/* prefix the ESO role's policy grants"
  value       = module.secrets.openai_secret_arn
}

output "openai_secret_version_id" {
  description = "Version id currently holding the OpenAI API key, useful for confirming a rotation landed"
  value       = module.secrets.openai_secret_version_id
}

# --- E-10 CI Pipeline (PETPLAT-52) ------------------------------------------

output "github_actions_role_arn" {
  description = "ARN of the role GitHub Actions assumes — this is the value of the AWS_ROLE_ARN repository secret, and role-to-assume for aws-actions/configure-aws-credentials in the app repo's build-push workflow"
  value       = module.github_oidc.role_arn
}

output "github_oidc_provider_arn" {
  description = "ARN of the GitHub OIDC provider. Pass this as existing_oidc_provider_arn in any other environment — an AWS account may hold only one provider for this URL, so exactly one environment creates it"
  value       = module.github_oidc.oidc_provider_arn
}

output "github_oidc_subject" {
  description = "The subject claim the trust policy accepts. Compare this against what GitHub actually sends when a workflow gets AccessDenied on AssumeRoleWithWebIdentity — a mismatch here is the usual cause"
  value       = module.github_oidc.github_subject
}
