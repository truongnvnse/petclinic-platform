# main.tf — Dev environment root module (PETPLAT-1)
#
# This root module composes the reusable modules in terraform/modules/.
# Module calls are added by the story that owns them:
#
#   module "vpc"     → wired, PETPLAT-9 (E-2 Networking)
#   module "eks"     → wired, PETPLAT-15 (E-3 EKS Cluster)
#   module "ecr"     → wired, PETPLAT-20 (E-4 Container Registry)
#   module "rds"     → wired, PETPLAT-25 (E-5 Database)
#   module "dns"     → wired, PETPLAT-32 (E-6 DNS & Ingress)
#   module "secrets" → wired, PETPLAT-33 (E-7 Secrets Management)
#   module "karpenter" → PETPLAT-73 (E-14 Scaling & Cost)
#
# Dev sizing: VPC CIDR 10.0.0.0/16, 1 replica per service, db.t4g.micro,
# single-AZ RDS. See docs/technical-spec.md for the full dev/prod matrix.

# ---------------------------------------------------------------------------
# E-2 Networking — PETPLAT-9
#
# All-public subnet design (ADR-0001): no NAT Gateway, no private subnets.
# Values from docs/technical-spec.md → "CIDR Allocation":
#   VPC 10.0.0.0/16, public subnets 10.0.1.0/24 (eu-central-1a) and
#   10.0.2.0/24 (eu-central-1b). Non-overlapping with prod (10.1.0.0/16).
# ---------------------------------------------------------------------------

module "vpc" {
  source = "../../modules/vpc"

  project     = var.project
  environment = var.environment

  vpc_cidr            = "10.0.0.0/16"
  public_subnet_cidrs = ["10.0.1.0/24", "10.0.2.0/24"]
  availability_zones  = ["eu-central-1a", "eu-central-1b"]
}

# ---------------------------------------------------------------------------
# E-3 EKS Cluster — PETPLAT-15
#
# Cluster name petclinic-dev, Kubernetes 1.36, two t4g.medium ARM nodes in the
# public subnets. Values from docs/technical-spec.md → "EKS Cluster":
#   min 2 / max 4 / desired 2, 20 GB disk, ON_DEMAND (Graviton).
#
# t4g.medium, not the t4g.small the spec names, and this is a measured
# correction rather than a preference. t4g.small does not run this workload, for
# two independent reasons — both observed on 2026-10-11 with all eight services
# deployed:
#
#   1. Pod cap. t4g.small is 3 ENIs x 4 IPv4 -> (3 x (4-1)) + 2 = 11 pods per
#      node, and the cluster reported exactly that (`allocatable.pods: 11`).
#      Two nodes is 22 slots; the system pods take 15 (kube-system 12 +
#      external-secrets 3), leaving 7 for 8 services. The eighth — admin-server
#      — sat Pending with "0/2 nodes are available: 2 Too many pods" while the
#      nodes were at 48% CPU and 72% memory. The spec's assumption that eight
#      services fit on two t4g.small nodes leaves the system pods out of the
#      arithmetic.
#   2. Memory. t4g.small reports 1365 MiB allocatable, and the 128Mi request is
#      far below what a Spring Boot service actually holds resident (~350 MiB),
#      so the scheduler packed four JVMs onto one node believing it had room.
#      That node's kubelet stopped posting status at 17:31:38 and never
#      recovered; the EC2 instance stayed `running` with both status checks ok
#      and no SSM agent to inspect it. Requests fit (988Mi/1365Mi), resident
#      set did not.
#
# t4g.medium is 3 ENIs x 6 IPv4 -> 17 pods per node, so 34 slots against the 23
# needed, and 4096 MiB per node against ~4.2 GiB of actual cluster-wide use. It
# is the same 2 vCPU as t4g.small — the extra cost buys memory and pod slots,
# not compute. Prefix delegation would fix the pod cap for free but not the
# memory, which is the constraint that actually killed the node.
#
# Note the spec still says ["t4g.small"] for both environments, and prod is left
# alone here. Prod needs 16 service replicas plus the same 15 system pods = 31
# pods, so it is further past the 22-slot limit than dev was; it will need the
# same correction before it is first deployed.
#
# The subnet and security group IDs come straight from the VPC module above —
# the node security group in particular is what the RDS security group admits
# 3306 from, so it must be the same group the nodes actually use.
#
# Add-on versions are pinned in the module and matched to Kubernetes 1.36; see
# docs/eks-operations.md → "Procedure: upgrade an EKS managed add-on".
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

  # Not the spec's ["t4g.small"] — see the sizing note above the module call.
  # 17 pods/node and 4 GiB instead of 11 and 2 GiB, at the same 2 vCPU.
  #
  # Three nodes, not two, since the observability stack landed. A t4g.medium
  # tops out at 17 pods — the ENI address ceiling, not CPU or memory — and the
  # cluster was already at 34/34 with the eight services, ArgoCD, External
  # Secrets and the kube-system add-ons. Prometheus, Loki, kube-state-metrics
  # and Zipkin then had nowhere to schedule and sat Pending while the rest of
  # the stack came up.
  #
  # The alternative was ENABLE_PREFIX_DELEGATION on the vpc-cni add-on, which
  # lifts the ceiling to ~110 pods/node for free. Chosen against here because it
  # is a cluster-wide networking change — the aws-node DaemonSet restarts and
  # every new pod draws its address from a delegated prefix — and a third node
  # is the reversible option: set this back to 2 and the node drains away.
  #
  # min_size stays 2 so a node can be lost without dropping below the count
  # that was sufficient before the observability stack; max_size 4 leaves room
  # for a rollout surge.
  node_instance_types = ["t4g.medium"]
  node_min_size       = 2
  node_max_size       = 4
  node_desired_size   = 3
  node_disk_size      = 20
}

# ---------------------------------------------------------------------------
# E-4 Container Registry — PETPLAT-20
#
# One ECR repository per service under the petclinic-dev/ namespace. Tag
# mutability defaults to MUTABLE here (IMMUTABLE in prod) — see
# docs/technical-spec.md → "ECR Container Registry".
#
# Repositories are per-environment, so a dev push can never overwrite the tag a
# prod deployment is running. Lifecycle policy keeps the last 10 tagged images
# and expires untagged ones after 7 days, which is what bounds storage cost.
# ---------------------------------------------------------------------------

module "ecr" {
  source = "../../modules/ecr"

  project     = var.project
  environment = var.environment

  # Dev is disposable, so emptying these repositories is part of a normal
  # teardown rather than a loss — every image here is rebuildable in minutes
  # from the same commit. Without this, `terraform destroy` stops on the first
  # non-empty repository and strands the entire ECR module in state, which is
  # exactly what happened on 2026-10-04: EKS and the VPC were gone, and the
  # eight repositories blocked the rest of the run.
  #
  # Prod deliberately leaves this at its default of false — a tag that reached
  # production should not vanish because someone tore the environment down.
  force_delete = true

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
# E-5 Database — PETPLAT-25
#
# One shared MySQL 8.0 instance for the three database-backed services. Values
# from docs/technical-spec.md → "RDS Database → Instance Configuration":
#   db.t4g.micro (free tier), single-AZ, 20 GB gp2 with storage autoscaling to
#   a 100 GB ceiling, 7-day backups.
#
# The subnets and the security group both come from the VPC module above. That
# security group is the entire network perimeter for the database: it admits
# 3306 from the EKS node security group and from nothing else, which is what
# keeps a MySQL instance sitting in a public subnet off the internet.
#
# Dev deliberately diverges from prod on three settings — two about what
# survives a teardown, one about how quickly a change lands:
#   * skip_final_snapshot = true — the environment is disposable, and a final
#     snapshot would outlive it and accumulate storage charges.
#   * secret_recovery_window_in_days = 0 — the password is regenerated by the
#     next apply, and a 7-day recovery window would block re-creating the same
#     secret name until it elapsed.
#   * apply_immediately = true — a parameter change should be visible now, not
#     at the next maintenance window, while someone is iterating.
#
# backup_retention_period = 7 and deletion_protection = false are stated below
# for visibility, not because they diverge: 7 is the module default, and
# deletion protection is false in both environments per the spec's cost note.
#
# See docs/rds-operations.md for the schema initialization strategy (PETPLAT-24)
# and the connection and verification procedures (PETPLAT-26).
# ---------------------------------------------------------------------------

module "rds" {
  source = "../../modules/rds"

  project     = var.project
  environment = var.environment

  subnet_ids        = module.vpc.public_subnet_ids
  security_group_id = module.vpc.rds_sg_id

  instance_class = "db.t4g.micro"
  multi_az       = false

  backup_retention_period = 7
  skip_final_snapshot     = true
  deletion_protection     = false

  secret_recovery_window_in_days = 0
  apply_immediately              = true
}

# ---------------------------------------------------------------------------
# E-6 DNS & Ingress — PETPLAT-32
#
# Wildcard ACM certificate for *.gannet.click, DNS-validated through the
# existing Route 53 zone. Values from docs/technical-spec.md → "DNS and Ingress":
#   dev record petclinic-dev.{domain} → ALB (A record, alias)
#
# The zone is looked up, not created — Route 53 made it when the domain was
# registered and it already holds the registration's NS records. A second zone
# for the same name would be empty, so ACM's validation records would land
# somewhere public DNS never looks and the certificate would never issue.
#
# The ALB alias record is created on a *second* apply. The ALB is created by the
# AWS Load Balancer Controller in response to the Ingress (PETPLAT-30), so its
# DNS name does not exist yet at the time this module is first applied. Leave
# alb_dns_name and alb_zone_id unset now; after the Ingress is applied, read the
# values with:
#
#   kubectl get ingress api-gateway -n petclinic-dev \
#     -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'
#   aws elbv2 describe-load-balancers --region eu-central-1 \
#     --query "LoadBalancers[?DNSName=='<hostname>'].CanonicalHostedZoneId" --output text
#
# then set them in terraform.tfvars and re-apply. They are variables rather than
# values written in here because the ALB's hostname changes whenever the ALB is
# recreated, and until they are set the plan keeps showing
# alb_record_created = false, which is the visible signal that the record is
# still missing. See docs/technical-spec.md → "DNS and Ingress".
#
# The LB controller's IRSA role is not wired here: it is created inside the eks
# module above, which owns the OIDC provider the trust policy needs. Its ARN is
# exported as lb_controller_role_arn for scripts/install-lb-controller.sh.
# ---------------------------------------------------------------------------

module "dns" {
  source = "../../modules/dns"

  project     = var.project
  environment = var.environment

  domain_name = var.domain_name

  # Empty on the first apply, which skips the alias record; set after the
  # Ingress has created the ALB.
  alb_dns_name = var.alb_dns_name
  alb_zone_id  = var.alb_zone_id
}

# ---------------------------------------------------------------------------
# E-7 Secrets Management — PETPLAT-33
#
# Non-RDS secrets in AWS Secrets Manager. Values from docs/technical-spec.md →
# "Secrets Management":
#   petclinic/dev/openai-api-key — plaintext, consumed by genai-service
#
# The RDS credentials secret (petclinic/dev/rds-credentials) is deliberately not
# here. It is created by the rds module above, because the password and the
# instance that uses it are generated together — the module holds the
# random_password and writes both the instance and the secret from it. Creating
# it a second time in this module would give the same credential two owners and
# a rotation that could update one without the other.
#
# openai_api_key has no value in this file and no default in the module. It
# comes from terraform.tfvars, which is gitignored, or from the
# TF_VAR_openai_api_key environment variable — the latter being what CI would
# use. Supplying neither fails the plan rather than creating an empty secret.
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

  # 0, not the AWS default of 30. Dev is destroyed and rebuilt to save cost, and
  # a secret left scheduled for deletion blocks re-creating the same name until
  # the window elapses — which would turn every rebuild into a failure that
  # re-running does not clear. The value comes from a variable, so the rebuilt
  # secret is identical to the deleted one. The rds module sets the same value
  # for the same reason.
  secret_recovery_window_in_days = 0
}

# ---------------------------------------------------------------------------
# E-10 CI Pipeline — PETPLAT-52
#
# Federated identity so CI pushes images to ECR with a short-lived token rather
# than a long-lived access key. Values from docs/technical-spec.md →
# "CI/CD Pipeline" → "OIDC Federation": provider
# token.actions.githubusercontent.com, audience sts.amazonaws.com, subject
# repo:{org}/{repo}:ref:refs/heads/main, ECR push only.
#
# The subject names the APPLICATION repo fork, not this platform repo, and that
# is the point rather than a mix-up. Two workflows exist and only one of them
# calls an AWS API:
#
#   app repo       build-push.yml         builds ARM64 images, pushes to ECR
#   platform repo  update-image-tags.yml  runs yq and git push — assumes no role
#
# Scoping the trust policy to the platform repo would grant the role to the
# workflow that never uses it and withhold it from the one that does. The
# username below is read from the app repo's origin remote rather than guessed:
#
#   git -C ../spring-petclinic-microservices remote get-url origin
#   -> https://github.com/truongnvnse/spring-petclinic-microservices.git
#
# create_oidc_provider = true because an AWS account may hold only ONE provider
# per URL, so this is an account-global resource owned by a per-environment
# module. Dev owns it because dev is the environment that exists; prod will need
# create_oidc_provider = false and this module's github_oidc_provider_arn output
# passed as existing_oidc_provider_arn, or its apply fails with
# EntityAlreadyExists. The consequence worth knowing: destroying dev removes the
# provider, and prod's CI would stop being able to assume its role until dev is
# re-applied.
#
# See docs/rollback-runbook.md and PETPLAT-50 for the other half of the pipeline.
# ---------------------------------------------------------------------------

module "github_oidc" {
  source = "../../modules/github-oidc"

  project     = var.project
  environment = var.environment

  github_repository = "truongnvnse/spring-petclinic-microservices"
  github_branch     = "main"

  # The numeric IDs, because GitHub's subject claim carries them and the names
  # alone match nothing. Read from the API rather than the origin remote, which
  # does not contain them:
  #
  #   curl -sS https://api.github.com/repos/truongnvnse/spring-petclinic-microservices
  #   -> owner.id = 336541468, id = 1400042382
  #
  # Cross-checked against CloudTrail, which logs the subject GitHub actually
  # sent on the failed AssumeRoleWithWebIdentity calls.
  github_owner_id      = 336541468
  github_repository_id = 1400042382

  # values(), not the map itself: repository_arns is a map of service name → ARN
  # and the policy wants the ARNs alone. Scoped to the eight repositories the ECR
  # module above created, so no statement in this policy names "*" — except
  # ecr:GetAuthorizationToken, which the API refuses to scope.
  repository_arns = values(module.ecr.repository_arns)

  create_oidc_provider = true
}
