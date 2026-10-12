# main.tf — Prod environment root module (PETPLAT-1)
#
# This root module composes the reusable modules in terraform/modules/.
# Module calls are added by the story that owns them:
#
#   module "vpc"     → wired, PETPLAT-10 (E-2 Networking)
#   module "eks"     → wired, PETPLAT-17 (E-3 EKS Cluster)
#   module "ecr"     → wired, E-4 (Container Registry)
#   module "rds"     → wired, PETPLAT-27 (E-5 Database)
#   module "dns"     → E-6         (DNS & Ingress)
#   module "secrets" → wired, PETPLAT-33 (E-7 Secrets Management)
#   module "karpenter" → E-14      (Scaling & Cost)
#
# Prod sizing: VPC CIDR 10.1.0.0/16 (non-overlapping with dev), 2+ replicas
# per service with HPA, db.t4g.micro single-AZ. Deploys are gated by ArgoCD
# manual sync. See docs/technical-spec.md for the full dev/prod matrix.

# ---------------------------------------------------------------------------
# E-2 Networking — PETPLAT-10
#
# All-public subnet design (ADR-0001): no NAT Gateway, no private subnets.
# Values from docs/technical-spec.md → "CIDR Allocation":
#   VPC 10.1.0.0/16, public subnets 10.1.1.0/24 (eu-central-1a) and
#   10.1.2.0/24 (eu-central-1b). Non-overlapping with dev (10.0.0.0/16).
# ---------------------------------------------------------------------------

module "vpc" {
  source = "../../modules/vpc"

  project     = var.project
  environment = var.environment

  vpc_cidr            = "10.1.0.0/16"
  public_subnet_cidrs = ["10.1.1.0/24", "10.1.2.0/24"]
  availability_zones  = ["eu-central-1a", "eu-central-1b"]
}

# ---------------------------------------------------------------------------
# E-3 EKS Cluster — PETPLAT-17
#
# Cluster name petclinic-prod, Kubernetes 1.36, two t4g.small ARM nodes in the
# public subnets. Values from docs/technical-spec.md → "EKS Cluster":
#   min 2 / max 4 / desired 2, 20 GB disk, ON_DEMAND (Graviton free trial).
#
# Prod is deliberately sized identically to dev — the spec keeps both on the
# Graviton free trial and scales the workloads, not the nodes. Application
# scaling is handled by the HPA and, later, by Karpenter (E-14). Deployments to
# this cluster are gated by ArgoCD manual sync, not by GitHub Actions.
# ---------------------------------------------------------------------------

module "eks" {
  source = "../../modules/eks"

  project     = var.project
  environment = var.environment

  subnet_ids    = module.vpc.public_subnet_ids
  cluster_sg_id = module.vpc.eks_cluster_sg_id
  node_sg_id    = module.vpc.eks_node_sg_id

  cluster_version = "1.36"

  # The public API endpoint accepts traffic only from the workstation's egress
  # address, so the Kubernetes API is not reachable from the internet at large
  # even though the endpoint itself is public. When that address changes,
  # kubectl stops working while terraform keeps working — it talks to the AWS
  # API, not the EKS API — so update the variable in terraform.tfvars and
  # re-apply.
  # See docs/eks-operations.md → "Procedure: update the API server allowlist".
  cluster_endpoint_public_access_cidrs = var.cluster_endpoint_public_access_cidrs

  node_instance_types = ["t4g.small"]
  node_min_size       = 2
  node_max_size       = 4
  node_desired_size   = 2
  node_disk_size      = 20
}

# ---------------------------------------------------------------------------
# E-4 Container Registry
#
# Prod gets its own petclinic-prod/ namespace so a prod image tag can never be
# overwritten by a dev build, and tag mutability defaults to IMMUTABLE here:
# once a tag has been deployed, its meaning must not change underneath a
# running workload.
#
# The backlog carries no separate "wire ECR into prod" story (every other module
# has one — PETPLAT-10, -17, -27). Prod is wired here because the spec's
# dev/prod tag-mutability split is meaningless without prod repositories.
# ---------------------------------------------------------------------------

module "ecr" {
  source = "../../modules/ecr"

  project     = var.project
  environment = var.environment

  # Stated rather than taken from the module's environment-derived default. This
  # is a security-relevant setting — it is what stops a deployed tag from being
  # overwritten — so it should be visible in the prod plan and in review, and it
  # should not depend on var.environment holding exactly the string "prod".
  image_tag_mutability = "IMMUTABLE"

  service_names = [
    "config-server",
    "discovery-server",
    "api-gateway",
    "customers-service",
    "visits-service",
    "vets-service",
    "genai-service",
    "admin-server",
  ]
}

# ---------------------------------------------------------------------------
# E-5 Database — PETPLAT-27
#
# Same module and the same instance class as dev — the spec keeps both
# environments on the free-tier Graviton sizing and teaches the difference
# through the settings below, not through instance size.
#
# The three settings that differ from dev all concern recoverability — what
# survives a mistake — and each is stated explicitly rather than left to a
# default so it is visible in the prod plan and in review:
#
#   * backup_retention_period = 30 — a month of point-in-time recovery, so a
#     corruption noticed weeks later is still recoverable.
#   * skip_final_snapshot = false — destroying this instance must leave a
#     restorable snapshot behind. Prod does NOT set the ECR module's
#     force_delete for the same reason.
#   * secret_recovery_window_in_days = 7 — a deleted secret is recoverable
#     rather than gone.
#
# multi_az stays false and deletion_protection stays false, both per the spec's
# "cost optimization for a learning project" note. In a real production
# deployment these are the first two settings to change: Multi-AZ turns a
# recovery measured in hours — restoring from a backup — into a failover
# measured in seconds, and deletion protection makes an errant destroy fail
# instead of succeeding.
#
# apply_immediately is left at its false default so modifications wait for the
# maintenance window rather than interrupting live traffic.
# ---------------------------------------------------------------------------

module "rds" {
  source = "../../modules/rds"

  project     = var.project
  environment = var.environment

  subnet_ids        = module.vpc.public_subnet_ids
  security_group_id = module.vpc.rds_sg_id

  instance_class = "db.t4g.micro"
  multi_az       = false

  backup_retention_period = 30
  skip_final_snapshot     = false
  deletion_protection     = false

  secret_recovery_window_in_days = 7
}

# ---------------------------------------------------------------------------
# E-7 Secrets Management — PETPLAT-33
#
# Non-RDS secrets in AWS Secrets Manager. Values from docs/technical-spec.md →
# "Secrets Management":
#   petclinic/prod/openai-api-key — plaintext, consumed by genai-service
#
# The RDS credentials secret (petclinic/prod/rds-credentials) is deliberately not
# here — the rds module above owns it, for the same reason as in dev: the
# password and the instance are generated together, and a second copy would give
# one credential two owners.
#
# openai_api_key has no value in this file. It comes from terraform.tfvars,
# which is gitignored, or from TF_VAR_openai_api_key. Supplying neither is not a
# missing-variable error — the root variable defaults to "" precisely so that
# `terraform destroy` runs without a key — it fails the precondition on the
# secret version, with a message that names the file to put it in. In this
# environment that failure is the point: an empty API key would apply cleanly
# and surface as a runtime authentication error from genai-service, long after
# the apply that caused it.
#
# The ESO IRSA role that reads this secret is created inside the eks module,
# which owns the OIDC provider its trust policy needs. Its ARN is exported as
# eso_role_arn for scripts/install-eso.sh. See
# docs/technical-spec.md → "IRSA Roles".
# ---------------------------------------------------------------------------

module "secrets" {
  source = "../../modules/secrets"

  project     = var.project
  environment = var.environment

  openai_api_key = var.openai_api_key

  # Bump this to push a changed openai_api_key into Secrets Manager. Terraform
  # cannot detect the change itself — the write-only argument is never read back
  # — so this number is the only thing that triggers an update. It lives here
  # rather than in tfvars so the rotation is recorded in Git.
  openai_api_key_version = 1

  # 7, not the AWS default of 30. Prod is not rebuilt on a schedule, so the
  # blocking behaviour that makes 0 right in dev costs nothing here, and a
  # mistaken deletion becomes reversible within the week. Above the 7-day floor
  # AWS enforces; the rds module sets the same value for the same reason.
  secret_recovery_window_in_days = 7
}
