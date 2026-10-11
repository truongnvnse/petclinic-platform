# Technical Specification — Petclinic Platform

> **Purpose:** Single source of truth for all infrastructure values. Jira stories reference sections of this document via anchor links. Read the relevant section before implementing any story.
>
> **Convention:** Dev environment is built during the course. Prod values are defined here but implementation is a **student assignment** unless noted otherwise.

---

## Table of Contents

1. [General Project Parameters](#general-project-parameters)
2. [Terraform State Backend](#terraform-state-backend)
3. [VPC Network Design](#vpc-network-design)
4. [Security Groups](#security-groups)
5. [EKS Cluster](#eks-cluster)
6. [ECR Container Registry](#ecr-container-registry)
7. [RDS Database](#rds-database)
8. [Secrets Management](#secrets-management)
9. [DNS and Ingress](#dns-and-ingress)
10. [Application Services](#application-services)
11. [Kubernetes Manifests](#kubernetes-manifests)
12. [Kubernetes Overlays](#kubernetes-overlays)
13. [CI/CD Pipeline](#cicd-pipeline)
14. [Observability](#observability)
15. [IRSA Roles](#irsa-roles)
16. [Security Controls](#security-controls)
17. [Scaling and Cost](#scaling-and-cost)
18. [Docker Build](#docker-build)
19. [Terraform Modules](#terraform-modules)
20. [Helm Charts](#helm-charts)
21. [GitOps with ArgoCD](#gitops-with-argocd)
22. [Karpenter (Node Autoscaling)](#karpenter-node-autoscaling)
23. [ADR Index](#adr-index)

---

## General Project Parameters

| Parameter | Value |
|-----------|-------|
| AWS Region | `eu-central-1` |
| Availability Zones | `eu-central-1a`, `eu-central-1b` |
| Project Name | `petclinic` |
| Naming Convention | `petclinic-{env}-{resource}` (e.g., `petclinic-dev-vpc`, `petclinic-prod-eks`) |
| Environments | `dev`, `prod` |
| Terraform Version | `>= 1.6.0` |
| AWS Provider Version | `~> 5.0` |
| Spring Boot Version | `4.0.1` (parent POM: `org.springframework.boot:spring-boot-starter-parent`) |
| Spring Cloud Version | `2025.1.0` (Oakwood) |
| Java Version | `17` |

### Required Tags (All AWS Resources)

| Tag Key | Value | Purpose |
|---------|-------|---------|
| `Project` | `petclinic` | Cost allocation, resource grouping |
| `Environment` | `dev` or `prod` | Environment identification |
| `ManagedBy` | `terraform` | Drift detection, ownership |

These tags are applied via `default_tags` in the AWS provider configuration. Modules accept an additional `tags` variable to merge service-specific tags.

### Optional Tags

| Tag Key | Example | When Used |
|---------|---------|-----------|
| `Service` | `customers-service` | Per-service resources (ECR repos, log groups) |
| `Component` | `networking`, `compute` | Module-level classification |

---

## Terraform State Backend

| Parameter | Value |
|-----------|-------|
| Backend Type | S3 with DynamoDB locking |
| S3 Bucket | `petclinic-terraform-state-{account-id}` |
| S3 Encryption | AES256 (SSE-S3) |
| S3 Versioning | Enabled |
| S3 Public Access | All blocked (4 settings) |
| DynamoDB Table | `petclinic-terraform-locks` |
| DynamoDB Partition Key | `LockID` (String) |

### Per-Environment State Keys

| Environment | State Key | Purpose |
|-------------|-----------|---------|
| Dev | `petclinic/dev/terraform.tfstate` | Dev infrastructure state |
| Prod | `petclinic/prod/terraform.tfstate` | Prod infrastructure state |

### Bootstrap Script

`scripts/bootstrap-state.sh` provisions the S3 bucket and DynamoDB table. It is:
- Idempotent (safe to run multiple times)
- Accepts `--region` parameter (default: `eu-central-1`)
- Run once before `terraform init`

---

## VPC Network Design

### Architecture Decision

All-public subnet design. No NAT Gateway, no private subnets, no VPC endpoints. Security groups are the perimeter. Saves ~$35-65/month per student. See [ADR-0001](#adr-index).

### CIDR Allocation

| Parameter | Dev | Prod |
|-----------|-----|------|
| VPC CIDR | `10.0.0.0/16` (65,536 IPs) | `10.1.0.0/16` (65,536 IPs) |
| Public Subnet 1 (AZ a) | `10.0.1.0/24` (251 usable) | `10.1.1.0/24` (251 usable) |
| Public Subnet 2 (AZ b) | `10.0.2.0/24` (251 usable) | `10.1.2.0/24` (251 usable) |

CIDRs are non-overlapping to allow future VPC peering if needed.

### VPC Settings

| Setting | Value |
|---------|-------|
| DNS Support | `true` |
| DNS Hostnames | `true` |
| Internet Gateway | 1 per VPC, attached |
| Route Table | 1 public route table, `0.0.0.0/0` → IGW |
| NAT Gateway | None (intentional) |
| VPC Endpoints | None (not needed with public subnets) |

### Subnet Settings

| Setting | Value |
|---------|-------|
| `map_public_ip_on_launch` | `true` |
| AZ distribution | 2 subnets across 2 AZs |

### EKS Subnet Tags (Required)

| Tag Key | Value | Purpose |
|---------|-------|---------|
| `kubernetes.io/cluster/petclinic-{env}` | `shared` | EKS cluster association |
| `kubernetes.io/role/elb` | `1` | ALB subnet discovery |

---

## Security Groups

Four security groups per environment. Security groups are the **primary access control boundary** in this all-public design.

### EKS Cluster Security Group

| Rule | Type | Protocol | Port | Source/Destination |
|------|------|----------|------|--------------------|
| API Server access from nodes | Ingress | TCP | 443 | EKS Node SG |
| API Server access from nodes | Egress | All | All | `0.0.0.0/0` |

### EKS Node Security Group

| Rule | Type | Protocol | Port | Source/Destination |
|------|------|----------|------|--------------------|
| All from cluster SG | Ingress | All | All | EKS Cluster SG |
| Inter-node communication | Ingress | All | All | Self (EKS Node SG) |
| Kubelet API from cluster | Ingress | TCP | 10250 | EKS Cluster SG |
| NodePort services | Ingress | TCP | 30000-32767 | ALB SG |
| Health checks from ALB | Ingress | TCP | 8080 | ALB SG |
| All outbound | Egress | All | All | `0.0.0.0/0` |

### RDS Security Group

| Rule | Type | Protocol | Port | Source/Destination |
|------|------|----------|------|--------------------|
| MySQL from nodes | Ingress | TCP | 3306 | EKS Node SG |
| No other ingress | — | — | — | — |
| All outbound | Egress | All | All | `0.0.0.0/0` |

**Critical:** RDS SG allows `3306` from EKS Node SG **only**. Never `0.0.0.0/0`.

### ALB Security Group

| Rule | Type | Protocol | Port | Source/Destination |
|------|------|----------|------|--------------------|
| HTTP from internet | Ingress | TCP | 80 | `0.0.0.0/0` |
| HTTPS from internet | Ingress | TCP | 443 | `0.0.0.0/0` |
| To nodes (target group) | Egress | TCP | 30000-32767 | EKS Node SG |
| Health checks to nodes | Egress | TCP | 8080 | EKS Node SG |

---

## EKS Cluster

### Cluster Configuration

| Parameter | Dev | Prod |
|-----------|-----|------|
| Cluster Name | `petclinic-dev` | `petclinic-prod` |
| Kubernetes Version | `1.29` | `1.29` |
| API Server Endpoint | Public | Public |
| Authentication Mode | `API_AND_CONFIG_MAP` | `API_AND_CONFIG_MAP` |
| Cluster Logging | `api`, `audit`, `authenticator` | `api`, `audit`, `authenticator` |
| Subnets | Public (AZ a + b) | Public (AZ a + b) |

### Cluster IAM Role

| Policy | Type |
|--------|------|
| `AmazonEKSClusterPolicy` | AWS Managed |

### OIDC Provider

Created from EKS cluster identity issuer URL. Required for IRSA (IAM Roles for Service Accounts).

### Managed Node Group

| Parameter | Dev | Prod |
|-----------|-----|------|
| Node Group Name | `petclinic-dev-nodes` | `petclinic-prod-nodes` |
| Instance Types | `["t4g.medium"]` | `["t4g.small"]` — **needs correcting, see below** |
| Architecture | ARM64 (Graviton) | ARM64 (Graviton) |
| Capacity Type | `ON_DEMAND` (free trial until Dec 2026) | `ON_DEMAND` (free trial until Dec 2026) |
| Min Size | 2 | 2 |
| Max Size | 4 | 4 |
| Desired Size | 2 | 2 |
| Disk Size | 20 GB | 20 GB |
| AMI Type | `AL2_ARM_64` | `AL2_ARM_64` |

> **Cost note:** t4g.small instances (2 vCPU, 2 GiB) are eligible for the AWS Graviton free trial (750 hrs/month until 31 Dec 2026). t4g.medium is **not** trial-eligible. The 750 hours are a monthly total rather than per instance, so two t4g.small nodes running 24/7 consume 1460 hours and are not fully free — see the cost table below.

> **Sizing correction (2026-10-11).** Dev originally used `["t4g.small"]` as this table said, and it could not run the eight services. Two independent limits, both measured on a live cluster:
>
> 1. **Pod cap.** A t4g.small node accepts 11 pods — 3 ENIs × 4 IPv4 gives `(3 × (4 − 1)) + 2 = 11`, and the node reported `allocatable.pods: 11`. Two nodes is 22 slots, and the system pods take 15 (kube-system 12 + external-secrets 3), leaving 7 for 8 services. `admin-server` sat `Pending` with `0/2 nodes are available: 2 Too many pods` while both nodes sat at 48% CPU. This table's arithmetic had left the system pods out.
> 2. **Memory.** A t4g.small node reports 1365 MiB allocatable. The 128Mi request is far below what a Spring Boot service holds resident (~350 MiB), so the scheduler packed four JVMs onto one node believing there was room. That node's kubelet stopped posting status and never recovered; the EC2 instance stayed `running` with both status checks ok. Requests fit at 988Mi/1365Mi — the resident set did not.
>
> Dev is now `["t4g.medium"]`: 17 pods per node (3 ENIs × 6 IPv4) so 34 slots against the 23 needed, and 4096 MiB per node. Same 2 vCPU — the cost buys memory and pod slots, not compute. Prefix delegation would raise the pod cap for free but does nothing for memory, which is the limit that actually killed the node.
>
> Prod is left at `["t4g.small"]` here only because it has not been deployed yet. It needs the same correction first: prod runs 16 service replicas, so 16 + 15 system pods = 31 against the same 22-slot ceiling. In production you would use larger instances (e.g., m7g.xlarge) regardless.

### Node IAM Role Policies

| Policy | Type |
|--------|------|
| `AmazonEKSWorkerNodePolicy` | AWS Managed |
| `AmazonEKS_CNI_Policy` | AWS Managed |
| `AmazonEC2ContainerRegistryReadOnly` | AWS Managed |

### EKS Managed Add-ons

| Add-on | Purpose | IRSA Required |
|--------|---------|---------------|
| `coredns` | Cluster DNS | No |
| `kube-proxy` | Network proxy | No |
| `vpc-cni` | Pod networking | No |
| `aws-ebs-csi-driver` | EBS PersistentVolumes (Prometheus, Grafana) | Yes (`AmazonEBSCSIDriverPolicy`) |

Add-on versions pinned (not `latest`). Resolve conflicts strategy: `OVERWRITE` for initial setup.

---

## ECR Container Registry

### Repository Configuration

| Parameter | Dev | Prod |
|-----------|-----|------|
| Registry Type | ECR Private | ECR Private |
| Terraform Resource | `aws_ecr_repository` | `aws_ecr_repository` |
| Region | `eu-central-1` (same as infra) | `eu-central-1` |
| Tag Mutability | `MUTABLE` | `IMMUTABLE` |
| Image Scanning | Scan-on-push enabled | Scan-on-push enabled |
| Encryption | AES256 (default) | AES256 (default) |

### Repositories (8 per environment)

| Repository Name | Service | Image URI Pattern |
|-----------------|---------|-------------------|
| `petclinic-{env}/config-server` | Config Server | `{account}.dkr.ecr.eu-central-1.amazonaws.com/petclinic-{env}/config-server:{tag}` |
| `petclinic-{env}/discovery-server` | Discovery Server | `{account}.dkr.ecr.eu-central-1.amazonaws.com/petclinic-{env}/discovery-server:{tag}` |
| `petclinic-{env}/api-gateway` | API Gateway | `{account}.dkr.ecr.eu-central-1.amazonaws.com/petclinic-{env}/api-gateway:{tag}` |
| `petclinic-{env}/customers-service` | Customers Service | `{account}.dkr.ecr.eu-central-1.amazonaws.com/petclinic-{env}/customers-service:{tag}` |
| `petclinic-{env}/visits-service` | Visits Service | `{account}.dkr.ecr.eu-central-1.amazonaws.com/petclinic-{env}/visits-service:{tag}` |
| `petclinic-{env}/vets-service` | Vets Service | `{account}.dkr.ecr.eu-central-1.amazonaws.com/petclinic-{env}/vets-service:{tag}` |
| `petclinic-{env}/genai-service` | GenAI Service | `{account}.dkr.ecr.eu-central-1.amazonaws.com/petclinic-{env}/genai-service:{tag}` |
| `petclinic-{env}/admin-server` | Admin Server | `{account}.dkr.ecr.eu-central-1.amazonaws.com/petclinic-{env}/admin-server:{tag}` |

### ECR Authentication

```bash
# Login (same region as infra)
aws ecr get-login-password --region eu-central-1 | docker login --username AWS --password-stdin {account}.dkr.ecr.eu-central-1.amazonaws.com

# Push
docker push {account}.dkr.ecr.eu-central-1.amazonaws.com/petclinic-{env}/{service}:{tag}
```

### Image Tag Strategy

| Context | Tag Format | Example |
|---------|------------|---------|
| CI/CD builds | Short commit SHA (7 chars) | `a1b2c3d` |
| Initial manual push | Semantic version | `v1.0.0` |
| Never used | `latest` | — |

### Lifecycle Policies

```json
{
  "rules": [
    {
      "rulePriority": 1,
      "description": "Keep last 10 images",
      "selection": {
        "tagStatus": "any",
        "countType": "imageCountMoreThan",
        "countNumber": 10
      },
      "action": { "type": "expire" }
    }
  ]
}
```

### Cost

ECR Private: 500 MB free tier, then $0.10/GB/month. With 8 services at ~200 MB each, total storage is ~8-10 GB = **~$1/month** beyond free tier. Negligible cost that buys production-correct patterns: private images, lifecycle policies, scan-on-push, tag immutability.

---

## RDS Database

### Instance Configuration

| Parameter | Dev | Prod |
|-----------|-----|------|
| Engine | MySQL 8.0 | MySQL 8.0 |
| Instance Class | `db.t4g.micro` | `db.t4g.micro` |
| Multi-AZ | `false` | `false` (single-AZ, cost optimization for learning) |
| Allocated Storage | 20 GB | 20 GB |
| Max Allocated Storage (autoscaling) | 100 GB | 100 GB |
| Storage Type | `gp2` | `gp2` |
| Storage Encrypted | `true` (AWS default KMS key) | `true` (AWS default KMS key) |
| Backup Retention | 7 days | 30 days |
| Skip Final Snapshot | `true` | `false` |
| Deletion Protection | `false` | `false` |
| DB Identifier | `petclinic-dev-mysql` | `petclinic-prod-mysql` |
| Master Username | `petclinic` | `petclinic` |
| Master Password | Generated via `random_password` | Generated via `random_password` |

> **Cost note:** db.t4g.micro (2 vCPU, 1 GiB) is AWS RDS free tier eligible (750 hrs/month for 12 months, 20 GB gp2 storage). Both dev and prod use identical sizing — this is a cost optimization for a learning project. In production, you would use db.r7g.large or higher with Multi-AZ, gp3 storage, 30-day backups, deletion protection, and a final snapshot. Students should understand these implications.

> **Max Allocated Storage:** this table previously specified 20 GB, equal to the allocated storage. RDS rejects that — the maximum storage threshold must be at least 10% above the allocated storage, or instance creation fails with `Invalid max storage size for engine_name`. It was raised to 100 GB, which also satisfies PETPLAT-22's "autoscaling enabled" criterion. The ceiling costs nothing on its own: storage is billed on what is allocated, not on the maximum, so this bounds a runaway rather than reserving capacity.

> **Backup Retention / Skip Final Snapshot:** this table previously read 7 days / `true` for prod, which disagreed with the PETPLAT-22 acceptance criteria (30 days, `false`). The acceptance criteria govern, and the module was built to them, so the table now matches what is deployed. `terraform/modules/rds/variables.tf` records the same resolution.

### Parameter Group

| Parameter | Value | Purpose |
|-----------|-------|---------|
| `character_set_server` | `utf8mb4` | Full Unicode support |
| `collation_server` | `utf8mb4_unicode_ci` | Unicode collation |

### Database Schema

All three database services use a shared `petclinic` database. Each service's schema.sql begins with `CREATE DATABASE IF NOT EXISTS petclinic; USE petclinic;`.

#### Tables (7 total across 3 services)

**Customers Service** — 3 tables:

| Table | Columns | Foreign Keys |
|-------|---------|-------------|
| `types` | `id` (PK, AUTO_INCREMENT), `name` | None |
| `owners` | `id` (PK), `first_name`, `last_name`, `address`, `city`, `telephone` | None |
| `pets` | `id` (PK), `name`, `birth_date`, `type_id`, `owner_id` | `owner_id` → `owners(id)`, `type_id` → `types(id)` |

**Vets Service** — 3 tables:

| Table | Columns | Foreign Keys |
|-------|---------|-------------|
| `vets` | `id` (PK, AUTO_INCREMENT), `first_name`, `last_name` | None |
| `specialties` | `id` (PK), `name` | None |
| `vet_specialties` | `vet_id`, `specialty_id` | `vet_id` → `vets(id)`, `specialty_id` → `specialties(id)` |

**Visits Service** — 1 table:

| Table | Columns | Foreign Keys |
|-------|---------|-------------|
| `visits` | `id` (PK, AUTO_INCREMENT), `pet_id`, `visit_date`, `description` | `pet_id` → `pets(id)` |

#### Schema Initialization Order

**Critical:** The `visits` table has `FOREIGN KEY (pet_id) REFERENCES pets(id)`, which is in the customers service schema. Initialization order:

1. **Customers Service** schema — creates `types`, `owners`, `pets`
2. **Vets Service** schema — creates `vets`, `specialties`, `vet_specialties` (independent)
3. **Visits Service** schema — creates `visits` (depends on `pets` from step 1)

**Strategy:** Let Spring Boot auto-initialize schemas on first startup with `spring.sql.init.mode=always` and `mysql` profile. The init order is enforced by deploying customers-service before visits-service.

### Connection String Format

```
jdbc:mysql://{rds-endpoint}:3306/petclinic
```

Example: `jdbc:mysql://petclinic-dev-mysql.abc123.eu-central-1.rds.amazonaws.com:3306/petclinic`

---

## Secrets Management

### Why AWS Secrets Manager

AWS Secrets Manager is purpose-built for storing secrets (database credentials, API keys). It provides built-in rotation, cross-account access, and fine-grained IAM policies. At $0.40/secret/month (~$1.20/month for 3 secrets), the cost is minimal and teaches students the industry-standard approach.

### Secrets

| Secret Name | Type | Content | Created By |
|-------------|------|---------|------------|
| `petclinic/{env}/rds-credentials` | JSON (`{"username":"...","password":"..."}`) | RDS master credentials | RDS module (PETPLAT-23) |
| `petclinic/{env}/openai-api-key` | Plaintext | OpenAI API key value | Secrets module (PETPLAT-33) |

> **Note:** Secret names use forward-slash convention (`petclinic/{env}/...`). All secrets are encrypted with the default AWS KMS key (`aws/secretsmanager`).

RDS credentials are created by the RDS module with `random_password` (16+ chars, special characters) and stored as a JSON object. The secrets module handles non-RDS secrets only.

### External Secrets Operator (ESO)

| Parameter | Value |
|-----------|-------|
| Version | `v2.12.0` (pinned) |
| Installation | `scripts/install-eso.sh` — downloads the upstream release bundle, renders it with Kustomize, applies with `kubectl apply --server-side` |
| Namespace | `external-secrets` |
| CRD API Version | `external-secrets.io/v1` |
| Store Type | `ClusterSecretStore` |
| Provider | AWS Secrets Manager |
| Auth | IRSA (see [IRSA Roles](#irsa-roles)) |

Two installation details are load-bearing and both fail in ways that do not name their cause:

- **`--server-side` is required.** `clustersecretstores.external-secrets.io` and `secretstores.external-secrets.io` are ~720 KB each, over the 262,144-byte annotation cap that client-side apply uses for `kubectl.kubernetes.io/last-applied-configuration`. Without the flag the apply aborts partway with `metadata.annotations: Too long`, leaving a half-installed operator. Upstream's own docs mandate server-side apply for this reason.
- **The release bundle hardcodes `namespace: default` in 19 places** — 16 YAML fields (rewritten by Kustomize's namespace transformer) and 3 container args (`--service-namespace`, `--secret-namespace`, `--dns-name`) that no namespace transformer can see, because they are not namespace fields. `kubectl apply -n external-secrets` does not override them; it errors. Leaving the args in place stops the cert-controller and webhook pods from ever becoming Ready. `scripts/install-eso.sh` substitutes all three and asserts the result.

**API version:** `v1`, not `v1beta1`. The operator this project pins declares `v1beta1: served: false`, so a manifest written against the older version fails with `no matches for kind ... ensure CRDs are installed first` even though the CRDs are installed and healthy.

### ClusterSecretStore Configuration

```yaml
apiVersion: external-secrets.io/v1
kind: ClusterSecretStore
metadata:
  name: aws-secrets-manager
spec:
  conditions:
    - namespaceRegexes:
        - "^petclinic-dev$"
        - "^petclinic-prod$"
  provider:
    aws:
      service: SecretsManager
      region: eu-central-1
      auth:
        jwt:
          serviceAccountRef:
            name: external-secrets-sa
            namespace: external-secrets
```

`spec.conditions` restricts which namespaces may reference the store. A `ClusterSecretStore` is cluster-scoped, so without it any namespace in the cluster — including one created by a compromised workload — can read the RDS master password and the OpenAI key. `namespaceRegexes` is used rather than `namespaceSelector` because the `petclinic-{env}` namespaces are created out of band and carry only the automatic `kubernetes.io/metadata.name` label.

### ExternalSecret Manifests

**RDS Credentials** (`k8s/base/external-secrets/rds-credentials.yaml`):

| Field | Value |
|-------|-------|
| `secretStoreRef.name` | `aws-secrets-manager` |
| `secretStoreRef.kind` | `ClusterSecretStore` |
| `refreshInterval` | `1h` |
| `target.name` | `rds-credentials` |
| `data[0].secretKey` | `username` |
| `data[0].remoteRef.key` | `petclinic/{env}/rds-credentials` |
| `data[0].remoteRef.property` | `username` |
| `data[1].secretKey` | `password` |
| `data[1].remoteRef.key` | `petclinic/{env}/rds-credentials` |
| `data[1].remoteRef.property` | `password` |

**OpenAI API Key** (`k8s/base/external-secrets/openai-api-key.yaml`):

| Field | Value |
|-------|-------|
| `secretStoreRef.name` | `aws-secrets-manager` |
| `secretStoreRef.kind` | `ClusterSecretStore` |
| `refreshInterval` | `1h` |
| `target.name` | `openai-api-key` |
| `data[0].secretKey` | `OPENAI_API_KEY` |
| `data[0].remoteRef.key` | `petclinic/{env}/openai-api-key` |
| `data[0].remoteRef.property` | *(absent — the remote value is plaintext)* |

`remoteRef.property` is present on the RDS entries and absent here, and that is determined by the shape of the remote secret, not by preference: the RDS secret is a JSON object with two fields, the OpenAI secret is a single plaintext string. The two mistakes are not symmetric — a `property` on a plaintext secret fails loudly (ESO reports it cannot parse the value as JSON), while omitting `property` on a JSON secret fails **quietly**, copying the whole blob into the key so the application receives JSON where it expects a credential.

---

## DNS and Ingress

### ACM Certificate

| Parameter | Value |
|-----------|-------|
| Domain | `*.{domain}` (wildcard) |
| Validation Method | DNS (Route 53) |
| Region | `eu-central-1` (same as ALB) |

### Route 53

| Parameter | Value |
|-----------|-------|
| Hosted Zone | `{domain}` (provided as variable) |
| Dev Record | `petclinic-dev.{domain}` → ALB (A record, alias) |
| Prod Record | `petclinic.{domain}` → ALB (A record, alias) |

### AWS Load Balancer Controller

| Parameter | Value |
|-----------|-------|
| Installation | Helm chart (`aws-load-balancer-controller` from `eks.amazonaws.com/charts`) |
| Namespace | `kube-system` |
| Auth | IRSA (see [IRSA Roles](#irsa-roles)) |
| IngressClass | `alb` |

### Ingress Resource Annotations

```yaml
kubernetes.io/ingress.class: alb
alb.ingress.kubernetes.io/scheme: internet-facing
alb.ingress.kubernetes.io/target-type: ip
alb.ingress.kubernetes.io/certificate-arn: "{acm-certificate-arn}"
alb.ingress.kubernetes.io/listen-ports: '[{"HTTP": 80}, {"HTTPS": 443}]'
alb.ingress.kubernetes.io/ssl-redirect: "443"
alb.ingress.kubernetes.io/healthcheck-path: /actuator/health
alb.ingress.kubernetes.io/healthcheck-port: "8080"
```

### Ingress Routing

| Path | Backend Service | Port |
|------|-----------------|------|
| `/` | `api-gateway` | 8080 |

All routing to backend services is handled by the API Gateway (Spring Cloud Gateway), not by the ALB Ingress.

---

## Application Services

### Service Inventory

| Service | Spring Name | Port | MySQL | Config Server | Discovery | Startup Order |
|---------|-------------|------|-------|---------------|-----------|---------------|
| Config Server | `config-server` | 8888 | No | Self (Git backend) | No | 1st (must be healthy first) |
| Discovery Server | `discovery-server` | 8761 | No | Yes | Self (Eureka) | 2nd (depends on Config) |
| API Gateway | `api-gateway` | 8080 | No | Yes | Yes | 3rd+ |
| Customers Service | `customers-service` | 8081 | Yes | Yes | Yes | 3rd+ (before Visits) |
| Visits Service | `visits-service` | 8082 | Yes | Yes | Yes | After Customers (FK dependency) |
| Vets Service | `vets-service` | 8083 | Yes | Yes | Yes | 3rd+ |
| GenAI Service | `genai-service` | 8084 | Optional | Yes | Yes | 3rd+ |
| Admin Server | `admin-server` | 9090 | No | Yes | Yes | 3rd+ (Spring Boot Admin 3.4.1) |

### Spring Profiles

| Profile | Purpose | When Active |
|---------|---------|-------------|
| `docker` | Changes Config Server URL from `localhost` to `config-server` (Docker DNS) | Set in Dockerfile: `SPRING_PROFILES_ACTIVE=docker` |
| `mysql` | Switches from HSQLDB to MySQL | Added for RDS-backed services: `SPRING_PROFILES_ACTIVE=docker,mysql` |
| `production` | Default active profile for vets-service and genai-service. **Required for vets-service Caffeine cache** — the `CacheConfig` class is gated on `@Profile("production")` so caching only works when this profile is active. | Set in application.yml |
| `chaos-monkey` | Chaos engineering (latency, exceptions) | Optional, testing only |
| `native` | Config Server uses local filesystem instead of Git repo | Config Server only, requires `GIT_REPO` env var |

### Config Server Details

| Parameter | Value |
|-----------|-------|
| Git URI | `https://github.com/spring-petclinic/spring-petclinic-microservices-config` |
| Default Label (branch) | `main` |
| Config Import | All services use `optional:configserver:${CONFIG_SERVER_URL:http://localhost:8888/}` |
| Docker Profile Override | `configserver:http://config-server:8888` |

### API Gateway Routes

| Route ID | Path | Target | Filters |
|----------|------|--------|---------|
| `vets-service` | `/api/vet/**` | `lb://vets-service` | `StripPrefix=2` |
| `visits-service` | `/api/visit/**` | `lb://visits-service` | `StripPrefix=2` |
| `customers-service` | `/api/customer/**` | `lb://customers-service` | `StripPrefix=2` |
| `genai-service` | `/api/genai/**` | `lb://genai-service` | `StripPrefix=2`, CircuitBreaker |

Default filters on all routes: `CircuitBreaker` (with `/fallback` URI), `Retry` (1 retry on `SERVICE_UNAVAILABLE`). Resilience4j `TimeLimiter` is configured with a 10-second timeout.

The API Gateway also serves an **AngularJS frontend** (static files: AngularJS 1.8.3, Bootstrap 5.3.3, Font Awesome 4.7.0) — this is the only user-facing service. All backend service API calls go through the gateway routes above.

### GenAI Service Configuration

| Parameter | Value |
|-----------|-------|
| AI Provider | OpenAI (default) |
| Model | `gpt-4o-mini` |
| Temperature | 0.7 |
| Spring AI Version | `2.0.0-M1` (milestone release) |
| API Key Env Var | `OPENAI_API_KEY` (defaults to `demo` if not set) |
| Alternate Provider | Azure OpenAI (`AZURE_OPENAI_KEY`, `AZURE_OPENAI_ENDPOINT`) |
| Application Type | Reactive (WebFlux) |
| Database | Has JPA + MySQL dependencies but no schema files. Includes `vectorstore.json` (124KB pre-populated vet embeddings for RAG) |
| Config Import Extra | Also imports `optional:classpath:/creds.yaml` (not present by default, used for local credential overrides) |

---

## Kubernetes Manifests

### Namespaces

| Namespace | Environment | PSA Labels |
|-----------|-------------|------------|
| `petclinic-dev` | Dev | `pod-security.kubernetes.io/enforce: baseline`, `pod-security.kubernetes.io/warn: restricted` |
| `petclinic-prod` | Prod | `pod-security.kubernetes.io/enforce: baseline`, `pod-security.kubernetes.io/warn: restricted` |

### Standard Labels (All Resources)

```yaml
app.kubernetes.io/name: "{service-name}"
app.kubernetes.io/part-of: petclinic
app.kubernetes.io/managed-by: Helm
app.kubernetes.io/component: "{server|service|gateway|admin}"
```

### Health Probes (All Services)

| Probe | Path | Port | Period | Timeout | Failure Threshold |
|-------|------|------|--------|---------|-------------------|
| Startup | `/actuator/health` | Service port | 10s | 5s | 30 (allows up to 5 min) |
| Readiness | `/actuator/health/readiness` | Service port | 10s | 5s | 3 |
| Liveness | `/actuator/health/liveness` | Service port | 15s | 5s | 3 |

The startupProbe runs first and disables readiness and liveness checks until Spring Boot has fully initialized. Once startup passes, readiness and liveness take over. Config Server uses `/actuator/health` for all three probes.

### Resource Requests and Limits

| Service | CPU Request | CPU Limit | Memory Request | Memory Limit |
|---------|-------------|-----------|----------------|--------------|
| config-server | 100m | 500m | 128Mi | 512Mi |
| discovery-server | 100m | 500m | 128Mi | 512Mi |
| api-gateway | 200m | 1000m | 128Mi | 512Mi |
| customers-service | 100m | 500m | 128Mi | 512Mi |
| visits-service | 100m | 500m | 128Mi | 512Mi |
| vets-service | 100m | 500m | 128Mi | 512Mi |
| genai-service | 100m | 500m | 128Mi | 512Mi |
| admin-server | 100m | 500m | 128Mi | 512Mi |

API Gateway gets higher CPU (200m/1000m) because it handles all incoming traffic routing. Spring Boot services idle around 200-300 MiB — the 512Mi limit provides headroom for spikes.

**The 128Mi request is a scheduling hint, not a usage estimate, and the gap between the two is load-bearing.** The scheduler places pods by request, so 128Mi tells it a node can hold many more services than the node can actually keep resident. On t4g.small that gap is what lost a node: four JVMs were packed onto one 1365 MiB node on the strength of `4 × 128Mi = 512Mi`, while their resident set was closer to 1.4 GiB. Raising the request toward the real figure (~350Mi) would make the scheduler spread correctly, at the cost of fitting fewer services per node — which is why the fix applied was larger nodes rather than a larger request.

This is also why the request must not be read as "these services fit on 2 GiB nodes". They do not; see the sizing correction under "Managed Node Group".

### Pod Placement (Topology Spread)

Because the request above understates real usage, the scheduler cannot be trusted to balance the eight services by itself — and on 2026-10-11 it did not: it placed seven of them on one node and one on the other. `helm/petclinic-service/` therefore carries a topology spread constraint:

```yaml
topologySpreadConstraints:
  - maxSkew: 1
    topologyKey: kubernetes.io/hostname
    whenUnsatisfiable: ScheduleAnyway
    labelSelector:
      matchLabels:
        app.kubernetes.io/part-of: petclinic
```

The `labelSelector` is what makes it work, and it is deliberately not the chart's per-service selector. A spread constraint counts only the pods its own selector matches, and dev runs one replica per service — a selector naming just this Deployment would count a single pod, always find a skew of zero, and do nothing at all. `part-of: petclinic` puts all eight services on one budget, which is the constraint actually being expressed.

`ScheduleAnyway` rather than `DoNotSchedule`: a hard constraint leaves pods Pending whenever the node count is not what the chart assumes, turning a placement preference into an outage. A soft one is a hint the scheduler can always satisfy.

Note what this does and does not fix. It balances pod *count*, which is the thing requests cannot do; it does not make the requests honest, and a node holding four JVMs still reports itself as well under 20% requested. It is also the behaviour prod wants, where it is what separates a service's two replicas onto different nodes.

### Environment Variables per Service

**All services:**

| Variable | Value | Source |
|----------|-------|--------|
| `SPRING_PROFILES_ACTIVE` | `docker` (non-DB) or `docker,mysql` (DB services) | Deployment spec |
| `CONFIG_SERVER_URL` | `http://config-server:8888` | ConfigMap |

**DB services (customers, visits, vets) — additional:**

| Variable | Value | Source |
|----------|-------|--------|
| `SPRING_DATASOURCE_URL` | `jdbc:mysql://{rds-endpoint}:3306/petclinic` | ConfigMap |
| `SPRING_DATASOURCE_USERNAME` | From secret | K8s Secret (ESO) |
| `SPRING_DATASOURCE_PASSWORD` | From secret | K8s Secret (ESO) |

**GenAI service — additional:**

| Variable | Value | Source |
|----------|-------|--------|
| `OPENAI_API_KEY` | From secret | K8s Secret (ESO) |

### Init Containers (Startup Order Enforcement)

Services that depend on Config Server use an init container that waits for Config Server to be healthy:

```yaml
initContainers:
  - name: wait-for-config-server
    image: busybox:1.36
    command: ['sh', '-c', 'until wget -qO- http://config-server:8888/actuator/health; do sleep 5; done']
```

Services that depend on Discovery Server (all except Config Server) add a second init container:

```yaml
  - name: wait-for-discovery-server
    image: busybox:1.36
    command: ['sh', '-c', 'until wget -qO- http://discovery-server:8761/actuator/health; do sleep 5; done']
```

### SecurityContext (All Deployments)

```yaml
securityContext:
  runAsNonRoot: true
  runAsUser: 1000
  fsGroup: 1000
containers:
  - securityContext:
      allowPrivilegeEscalation: false
      capabilities:
        drop: ["ALL"]
      readOnlyRootFilesystem: false  # Spring Boot needs /tmp for file uploads and caching
```

### Manifest File Structure

Each service directory contains:

| File | Content |
|------|---------|
| `deployment.yaml` | Deployment with probes, resources, env vars, init containers |
| `service.yaml` | ClusterIP Service exposing the service port |
| `configmap.yaml` | Environment-specific configuration (URLs, non-secret settings) |
| `serviceaccount.yaml` | ServiceAccount (annotated with IRSA role ARN where needed) |

---

## Kubernetes Overlays

### Dev Overlay (`k8s/overlays/dev/`)

| Parameter | Value |
|-----------|-------|
| Namespace | `petclinic-dev` |
| Replicas (all services) | 1 |
| Image Tag | Commit SHA (CI updates `helm-values/{service}.yaml`, ArgoCD deploys) |

### Prod Overlay (`k8s/overlays/prod/`)

| Service | Replicas | Notes |
|---------|----------|-------|
| config-server | 2 | HA for config distribution |
| discovery-server | 2 | HA for service registry |
| api-gateway | 2 | HA, public-facing entry point |
| customers-service | 2 | HA |
| visits-service | 2 | HA |
| vets-service | 2 | HA |
| genai-service | 1 | Lower priority, cost saving |
| admin-server | 1 | Monitoring tool, single replica sufficient |

### Horizontal Pod Autoscaler (Prod only)

| Service | Min | Max | CPU Target |
|---------|-----|-----|------------|
| api-gateway | 2 | 6 | 70% |
| customers-service | 2 | 4 | 70% |
| visits-service | 2 | 4 | 70% |
| vets-service | 2 | 4 | 70% |
| genai-service | 1 | 3 | 70% |

HPA requires Metrics Server to be installed (PETPLAT-72).

### Pod Disruption Budgets (Prod only)

| Service | minAvailable |
|---------|-------------|
| config-server | 1 |
| discovery-server | 1 |
| api-gateway | 1 |
| customers-service | 1 |
| visits-service | 1 |
| vets-service | 1 |

### Resource Quotas

| Parameter | Dev | Prod |
|-----------|-----|------|
| Max CPU | 4 | 4 |
| Max Memory | 4Gi | 4Gi |
| Max Pods | 30 | 30 |

### Helm Values Structure (replaces Kustomize overlays)

Environment-specific configuration is managed via Helm values files in `helm-values/`:
- `helm-values/dev.yaml` — dev overrides (replicas=1, no HPA, no PDB)
- `helm-values/prod.yaml` — prod overrides (replicas=2, HPA enabled, PDB enabled)
- Per-service files hold service-specific config (ports, env vars, init containers)
- ArgoCD merges service + environment values when deploying

> **Note:** Manifests that are not Helm-managed live under `k8s/base/` — the External Secrets CRs (`ClusterSecretStore`, `ServiceAccount`, and the two `ExternalSecret`s) in `k8s/base/external-secrets/`, and the ALB Ingress in `k8s/base/ingress/`. There is no `k8s/overlays/`; per-environment variation is handled by Helm values files, not Kustomize overlays. See [Helm Charts](#helm-charts) for the full chart structure and [Secrets Management](#secrets-management) for the ExternalSecret manifests.

---

## CI/CD Pipeline

### Architecture: CI + GitOps

GitHub Actions handles **CI only** (build, test, push images). **ArgoCD handles CD** (deployment to EKS). The separation is:

| Concern | Tool | How |
|---------|------|-----|
| Build & Push images | GitHub Actions | `build-push.yml` — builds ARM64 images, pushes to ECR |
| Update image tags | GitHub Actions | `update-image-tags.yml` — commits new tag to `helm-values/` |
| Deploy to Kubernetes | ArgoCD | Watches Git, detects tag changes, syncs Helm releases |

### Workflows

| Workflow | File | Trigger | What it does |
|----------|------|---------|--------------|
| Build & Push | `.github/workflows/build-push.yml` | Push to `main` | Build ARM64 images, Trivy scan, push to ECR |
| Update Image Tags | `.github/workflows/update-image-tags.yml` | After build-push succeeds | Commits new image tag to `helm-values/` → ArgoCD picks up |

> **No deploy workflows.** ArgoCD watches the Git repo for changes to `helm-values/` and automatically syncs (dev) or waits for manual approval (prod).

### OIDC Federation (No Long-Lived Credentials)

| Parameter | Value |
|-----------|-------|
| OIDC Provider | `token.actions.githubusercontent.com` |
| Audience | `sts.amazonaws.com` |
| Subject Filter | `repo:{org}/{repo}:ref:refs/heads/main` |
| IAM Role | `petclinic-github-actions-role` |
| Permissions | ECR push only (`ecr:GetAuthorizationToken`, `ecr:BatchCheckLayerAvailability`, `ecr:PutImage`, layer upload actions) — no S3, no DynamoDB (CI workflows do not run Terraform) |

### GitHub Secrets

| Secret Name | Purpose |
|-------------|---------|
| `AWS_REGION` | `eu-central-1` |
| `AWS_ROLE_ARN` | OIDC role ARN for `aws-actions/configure-aws-credentials` |
| `AWS_ACCOUNT_ID` | AWS account ID (for ECR registry URL) |

### Build Steps (build-push.yml)

1. Checkout application repo
2. Set up JDK 17
3. Set up Docker Buildx + QEMU (for ARM64 cross-compilation)
4. Configure AWS credentials (OIDC)
5. Login to ECR: `aws ecr get-login-password --region eu-central-1`
6. Maven build: `./mvnw clean install -P buildDocker -Dcontainer.platform="linux/arm64"`
7. Trivy scan: fail on CRITICAL CVEs
8. Tag images with commit SHA (short, 7 chars): `${GITHUB_SHA::7}`
9. Push all 8 images to ECR

> **ARM cross-compilation:** GitHub Actions runners are x86_64. Building ARM64 images requires QEMU emulation via `docker/setup-qemu-action` and `docker/setup-buildx-action`. Build time increases from ~2 min to ~5 min per image, which is acceptable for a learning project.

### Update Image Tags Steps (update-image-tags.yml)

1. Checkout platform repo
2. Update image tag in `helm-values/{service}.yaml` — only for services in the `repository_dispatch` payload (not all 8 on every run)
3. Git commit + push: `"ci: update image tags to ${SHA} (${service-list})"`

ArgoCD detects the Git change and triggers sync automatically (dev) or queues for approval (prod).

### Image Tag Update Mechanism

```bash
# Update image tag only for services included in the repository_dispatch payload
SERVICES="${{ github.event.client_payload.services }}"  # e.g. "customers-service vets-service"
SHA="${{ github.event.client_payload.sha }}"

for service in ${SERVICES}; do
  yq -i ".image.tag = \"${SHA}\"" helm-values/${service}.yaml
done

# Commit and push
git add helm-values/
git commit -m "ci: update image tags to ${SHA} (${SERVICES})"
git push
```

---

## Observability

### Prometheus

| Parameter | Dev | Prod |
|-----------|-----|------|
| Namespace | `monitoring` | `monitoring` |
| Scrape Interval | 15s | 15s |
| Evaluation Interval | 15s | 15s |
| Retention | 7 days | 15 days |
| Storage | PersistentVolume (EBS, 10Gi) | PersistentVolume (EBS, 50Gi) |

#### Scrape Targets

| Job Name | Target | Metrics Path | Port |
|----------|--------|-------------|------|
| `config-server` | `config-server.petclinic-{env}:8888` | `/actuator/prometheus` | 8888 |
| `discovery-server` | `discovery-server.petclinic-{env}:8761` | `/actuator/prometheus` | 8761 |
| `api-gateway` | `api-gateway.petclinic-{env}:8080` | `/actuator/prometheus` | 8080 |
| `customers-service` | `customers-service.petclinic-{env}:8081` | `/actuator/prometheus` | 8081 |
| `visits-service` | `visits-service.petclinic-{env}:8082` | `/actuator/prometheus` | 8082 |
| `vets-service` | `vets-service.petclinic-{env}:8083` | `/actuator/prometheus` | 8083 |
| `genai-service` | `genai-service.petclinic-{env}:8084` | `/actuator/prometheus` | 8084 |
| `admin-server` | `admin-server.petclinic-{env}:9090` | `/actuator/prometheus` | 9090 |

### Grafana

| Parameter | Value |
|-----------|-------|
| Namespace | `monitoring` |
| Datasources | Prometheus (auto-configured), Loki (auto-configured) |
| Storage | PersistentVolume (EBS, 5Gi) |
| Admin Credentials | K8s Secret |
| Dashboards | Provisioned via ConfigMap |

#### Dashboard Set

| Dashboard | Key Metrics |
|-----------|-------------|
| Service Overview | All 8 services: up/down status, RPS, error rate |
| Per-Service (x8) | Request rate, error rate, p95/p99 latency |
| JVM Metrics | Heap usage, GC pauses, thread count |

### Alert Rules (Prometheus)

| Alert | Condition | Duration | Severity |
|-------|-----------|----------|----------|
| ServiceDown | `up == 0` for any target | 1m | `critical` |
| HighErrorRate | `rate(http_server_requests_seconds_count{status=~"5.."}[5m]) / rate(http_server_requests_seconds_count[5m]) > 0.05` | 5m | `warning` |
| HighLatency | `histogram_quantile(0.95, rate(http_server_requests_seconds_bucket[5m])) > 0.5` | 5m | `warning` |
| PodRestartLoop | `increase(kube_pod_container_status_restarts_total[15m]) > 3` | 0m | `critical` |
| HighMemoryUsage | `container_memory_working_set_bytes / container_spec_memory_limit_bytes > 0.8` | 5m | `warning` |

### Alertmanager

| Parameter | Value |
|-----------|-------|
| Namespace | `monitoring` |
| Notification Channel | Email (minimum), Slack (recommended) |
| Critical Routing | Immediate notification |
| Warning Routing | Batched (5m group interval) |

### FluentBit (Logging)

| Parameter | Dev | Prod |
|-----------|-----|------|
| Deployment | DaemonSet on all nodes | DaemonSet on all nodes |
| Output | Loki (`http://loki.monitoring:3100`) | Loki (`http://loki.monitoring:3100`) |
| Log Labels | `namespace`, `pod`, `container` | `namespace`, `pod`, `container` |
| Auth | None — Loki is in-cluster, no IAM role required |

### Loki (Log Aggregation)

| Parameter | Dev | Prod |
|-----------|-----|------|
| Namespace | `monitoring` | `monitoring` |
| Port | 3100 | 3100 |
| Image | `grafana/loki` | `grafana/loki` |
| Storage | PersistentVolume (EBS, 10Gi) | PersistentVolume (EBS, 50Gi) |
| Log Retention | 7 days | 30 days |

Loki receives logs from FluentBit and exposes them as a Grafana datasource. Log-based alert rules are defined as Loki alerting rules and routed through Alertmanager — same alert pipeline as Prometheus.

#### Loki Alert Rules

| Alert | LogQL Condition | Duration | Severity |
|-------|----------------|----------|----------|
| `LogErrorSpike` | `rate({namespace=~"petclinic-.*"} \|= "ERROR" [5m]) > 0.5` | 5m | `warning` |
| `JVMOutOfMemory` | `count_over_time({namespace=~"petclinic-.*"} \|= "OutOfMemoryError" [5m]) > 0` | 0m | `critical` |

### Zipkin (Tracing)

| Parameter | Value |
|-----------|-------|
| Namespace | `tracing` |
| Port | 9411 |
| Image | `openzipkin/zipkin` |
| Services send traces via | OpenTelemetry exporter (configured in Spring Cloud Config) |

---

## IRSA Roles

Five IAM Roles for Service Accounts, each with OIDC trust policy scoped to a specific Kubernetes ServiceAccount. FluentBit no longer requires an IRSA role — it sends logs to Loki in-cluster.

| Role Name Pattern | K8s ServiceAccount | Namespace | IAM Policy | Used By |
|-------------------|--------------------|-----------|------------|---------|
| `petclinic-{env}-eso-role` | `external-secrets-sa` | `external-secrets` | `secretsmanager:GetSecretValue`, `secretsmanager:DescribeSecret` on `arn:aws:secretsmanager:eu-central-1:{account}:secret:petclinic/{env}/*` | ESO |
| `petclinic-{env}-lb-controller-role` | `aws-load-balancer-controller` | `kube-system` | AWS Load Balancer Controller IAM policy (managed) | ALB Controller |
| `petclinic-{env}-ebs-csi-role` | `ebs-csi-controller-sa` | `kube-system` | `AmazonEBSCSIDriverPolicy` (AWS managed) | EBS CSI Driver |
| `petclinic-{env}-argocd-role` | `argocd-server` | `argocd` | Minimal: only needed if ArgoCD accesses AWS resources directly (optional) | ArgoCD |
| `petclinic-{env}-karpenter-role` | `karpenter` | `kube-system` | Karpenter controller policy: `ec2:*`, `iam:PassRole`, `ssm:GetParameter`, `pricing:GetProducts`, `sqs:*`, `eks:DescribeCluster` (scoped) | Karpenter |

**ESO role scope.** The policy resource carries the environment segment — `petclinic/{env}/*`, not `petclinic/*`. Both environments live in a single AWS account, so the broader pattern would let the dev cluster's operator read prod's database password and OpenAI key, turning a dev-cluster compromise into a prod credential leak. The narrower form costs nothing, because no ExternalSecret in either environment reads the other's prefix.

Two permissions are deliberately absent:

- **`secretsmanager:ListSecrets`** — needed only for `dataFrom.find` lookups, which no manifest here uses; every ExternalSecret names its `remoteRef.key` explicitly. It is also not required for the ClusterSecretStore to report `Ready`: the store's validation path calls `Credentials.Retrieve()` and nothing else.
- **`kms:Decrypt`** — the secrets are encrypted with the AWS-managed `aws/secretsmanager` key, where the decrypt permission belongs to the service rather than the caller. Attaching it would widen the role for no effect. **If a customer-managed KMS key is ever introduced, this role needs `kms:Decrypt` on that key at the same time** — see [Security Controls](#security-controls) → Encryption Matrix.

### IRSA Trust Policy Template

```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {
      "Federated": "arn:aws:iam::{account}:oidc-provider/{oidc-provider}"
    },
    "Action": "sts:AssumeRoleWithWebIdentity",
    "Condition": {
      "StringEquals": {
        "{oidc-provider}:sub": "system:serviceaccount:{namespace}:{sa-name}",
        "{oidc-provider}:aud": "sts.amazonaws.com"
      }
    }
  }]
}
```

---

## Security Controls

### Encryption Matrix

| Resource | Encryption at Rest | Encryption in Transit | Key |
|----------|-------------------|----------------------|-----|
| RDS MySQL | KMS (AWS default key) | SSL available (not enforced by default) | AWS managed |
| S3 (state bucket) | SSE-S3 (AES256) | HTTPS enforced | AWS managed |
| EBS Volumes | Default encryption enabled | N/A | AWS managed |
| ECR Images | AES256 | HTTPS | AWS managed |
| Secrets Manager | KMS (AWS default `aws/secretsmanager` key) | HTTPS | AWS managed |
| ALB | N/A | TLS termination (ACM cert) | ACM |

### Kubernetes Network Policies

| Policy | Namespace | Effect |
|--------|-----------|--------|
| Default deny ingress | `petclinic-{env}` | Deny all ingress by default |
| Config Server allow | `petclinic-{env}` | Allow ingress to 8888 from all pods in namespace |
| Discovery Server allow | `petclinic-{env}` | Allow ingress to 8761 from all pods in namespace |
| API Gateway allow | `petclinic-{env}` | Allow ingress to 8080 from ALB (ingress controller) |
| Domain services allow | `petclinic-{env}` | Allow ingress to 8081-8084 from API Gateway pods only |
| Admin Server allow | `petclinic-{env}` | Allow ingress to 9090 from internal only |
| Egress allow | `petclinic-{env}` | Allow egress to Config Server, Discovery, RDS, DNS (53), HTTPS (443) |

### Pod Security Admission

| Namespace | Enforce | Warn | Audit |
|-----------|---------|------|-------|
| `petclinic-dev` | `baseline` | `restricted` | `restricted` |
| `petclinic-prod` | `baseline` | `restricted` | `restricted` |

---

## Scaling and Cost

### Monthly Cost Estimate (Free Tier Optimized)

This is a learning project. Instance choices maximize AWS free tier eligibility.

| Resource | Dev (~) | Prod (~) | Free Tier |
|----------|---------|----------|-----------|
| EKS Control Plane | $73 | $73 | None — unavoidable cost |
| EC2 Nodes — dev 2x t4g.medium | $56 | $56 | None — t4g.medium is not trial-eligible |
| EC2 Nodes — prod 2x t4g.small | $14 | $14 | Graviton free trial covers 750 of the 1460 hrs/mo; the remaining 710 hrs bill at $0.0192 |
| RDS MySQL (db.t4g.micro) | $0 | $0 | RDS free tier (750 hrs/mo, 12 months) |
| ALB | $0 | $0 | Free tier (750 hrs/mo, 12 months) |
| S3 + DynamoDB (state) | $1 | $1 | Mostly free tier |
| ECR Storage | ~$1 | ~$1 | 500 MB free, then $0.10/GB/month |
| EBS (PVs — Prometheus, Grafana, Loki) | $2 | $2 | 30 GB gp2 free (12 months) |
| Route 53 | $1 | $1 | $0.50/zone + queries |
| Secrets Manager | $1 | $1 | $0.40/secret/month (~3 secrets) |
| Data Transfer | $1 | $1 | 100 GB/mo free |
| **Total (24/7)** | **~$136/mo** | **~$94/mo** | EKS control plane plus nodes |

> **Students should `terraform destroy` after each session.** The figures above assume 24/7 operation, which is the worst case and not how this environment is meant to be used. Node cost scales with uptime alongside the control plane, and dev nodes are no longer free-tier eligible: at 10 hours/week (40 hrs/month) dev costs about $4.00 for the control plane plus $3.07 for 2× t4g.medium, against ~$136/month left running. The free trial still covers t4g.small up to 750 hrs/month, so an environment that keeps t4g.small nodes and runs part-time can stay at $0 for compute. Target: **entire course under $50 AWS spend.**

No NAT Gateway cost ($0 saved vs ~$35-65/mo with NAT).

### Spot Instance Configuration (Dev — Optional)

| Parameter | Value |
|-----------|-------|
| Instance Types (mixed) | `t4g.small`, `t4g.medium` |
| Capacity Type | `SPOT` (with on-demand fallback) |
| Savings | ~60-70% on compute (when free trial expires) |

> **Note:** While the Graviton free trial is active, spot instances provide no cost benefit. This configuration is documented for when the free trial expires or for production use with larger instances.

### Budget Alerts

| Environment | Monthly Budget | Alert at |
|-------------|---------------|----------|
| Dev | $100 | 50%, 80%, 100% |
| Prod | $100 | 50%, 80%, 100% |
| Notification | Email to configurable address | — |

---

## Docker Build

### Build Command

```bash
# Build all 8 Docker images for ARM64 (required for t4g Graviton nodes)
./mvnw clean install -P buildDocker -Dcontainer.platform="linux/arm64"
```

> **Important:** EKS nodes are ARM64 (Graviton). All Docker images MUST be built for `linux/arm64`. The base image `eclipse-temurin:17` supports multi-arch. Local builds on Apple Silicon (M1/M2/M3) produce ARM images natively. CI/CD builds on x86 GitHub Actions runners require `docker buildx` with QEMU emulation (see [CI/CD Pipeline](#cicd-pipeline)).

### Dockerfile Details

| Parameter | Value |
|-----------|-------|
| Dockerfile Location | `docker/Dockerfile` (shared by all services) |
| Base Image | `eclipse-temurin:17` |
| Build Strategy | Multi-stage (builder + runtime) |
| Layer Extraction | `java -Djarmode=layertools -jar application.jar extract` |
| Layers | `dependencies/`, `spring-boot-loader/`, `snapshot-dependencies/`, `application/` |
| Entrypoint | `java org.springframework.boot.loader.launch.JarLauncher` |
| Build Args | `ARTIFACT_NAME` (JAR name), `EXPOSED_PORT` (service port) |
| Default Profile | `SPRING_PROFILES_ACTIVE=docker` (ENV in Dockerfile) |
| Target Platform | `linux/arm64` (for Graviton t4g nodes) |
| Memory Limit | 512M (set in Docker Compose, enforce in K8s) |
| Local Image Prefix | `springcommunity/` (from Maven pom.xml, e.g., `springcommunity/spring-petclinic-api-gateway`) |

> **Note:** The Maven build produces images with the `springcommunity/` prefix (e.g., `springcommunity/spring-petclinic-customers-service`). The CI/CD pipeline re-tags and pushes to ECR using the `petclinic-{env}/{service}` naming convention.

> **Warning:** The `docker.image.exposed.port` property in each service's pom.xml is a build-time metadata value for the Dockerfile `EXPOSE` directive. Several services have **incorrect values** (copy-paste from template): API Gateway, Visits, Vets, and GenAI all show `8081` in their pom.xml. The actual runtime ports come from the Config Server's Git repository, not from this property. Do NOT rely on pom.xml exposed ports — use the Service Inventory table above.

### Artifact-to-Image Mapping

| Maven Module | JAR Artifact | ECR Repository |
|--------------|-------------|----------------|
| `spring-petclinic-config-server` | `spring-petclinic-config-server-*.jar` | `petclinic-{env}/config-server` |
| `spring-petclinic-discovery-server` | `spring-petclinic-discovery-server-*.jar` | `petclinic-{env}/discovery-server` |
| `spring-petclinic-api-gateway` | `spring-petclinic-api-gateway-*.jar` | `petclinic-{env}/api-gateway` |
| `spring-petclinic-customers-service` | `spring-petclinic-customers-service-*.jar` | `petclinic-{env}/customers-service` |
| `spring-petclinic-visits-service` | `spring-petclinic-visits-service-*.jar` | `petclinic-{env}/visits-service` |
| `spring-petclinic-vets-service` | `spring-petclinic-vets-service-*.jar` | `petclinic-{env}/vets-service` |
| `spring-petclinic-genai-service` | `spring-petclinic-genai-service-*.jar` | `petclinic-{env}/genai-service` |
| `spring-petclinic-admin-server` | `spring-petclinic-admin-server-*.jar` | `petclinic-{env}/admin-server` |

---

## Terraform Modules

### Module: `vpc`

**Path:** `terraform/modules/vpc/`

| Input Variable | Type | Description | Default |
|---------------|------|-------------|---------|
| `project` | string | Project name | `"petclinic"` |
| `environment` | string | Environment (dev/prod) | — |
| `vpc_cidr` | string | VPC CIDR block | — |
| `public_subnet_cidrs` | list(string) | Public subnet CIDRs | — |
| `availability_zones` | list(string) | AZs for subnets | — |
| `tags` | map(string) | Additional tags | `{}` |

| Output | Type | Description |
|--------|------|-------------|
| `vpc_id` | string | VPC ID |
| `public_subnet_ids` | list(string) | Public subnet IDs |
| `eks_cluster_sg_id` | string | EKS cluster security group ID |
| `eks_node_sg_id` | string | EKS node security group ID |
| `rds_sg_id` | string | RDS security group ID |
| `alb_sg_id` | string | ALB security group ID |

### Module: `eks`

**Path:** `terraform/modules/eks/`

| Input Variable | Type | Description | Default |
|---------------|------|-------------|---------|
| `project` | string | Project name | `"petclinic"` |
| `environment` | string | Environment | — |
| `cluster_version` | string | Kubernetes version | `"1.29"` |
| `subnet_ids` | list(string) | Subnet IDs for cluster | — |
| `cluster_sg_id` | string | Cluster security group ID | — |
| `node_sg_id` | string | Node security group ID | — |
| `node_instance_types` | list(string) | Instance types for nodes | `["t4g.small"]` |
| `node_ami_type` | string | AMI type for nodes | `"AL2_ARM_64"` |
| `node_min_size` | number | Min node count | `2` |
| `node_max_size` | number | Max node count | `4` |
| `node_desired_size` | number | Desired node count | `2` |
| `node_disk_size` | number | Disk size in GB | `20` |
| `tags` | map(string) | Additional tags | `{}` |

| Output | Type | Description |
|--------|------|-------------|
| `cluster_name` | string | EKS cluster name |
| `cluster_endpoint` | string | EKS API endpoint |
| `cluster_ca_certificate` | string | Cluster CA certificate (base64) |
| `oidc_provider_arn` | string | OIDC provider ARN |
| `oidc_provider_url` | string | OIDC provider URL |
| `node_group_name` | string | Managed node group name |
| `node_role_arn` | string | Node IAM role ARN |

### Module: `ecr`

**Path:** `terraform/modules/ecr/`

Uses `aws_ecr_repository` with lifecycle policies, scan-on-push, and configurable tag immutability.

| Input Variable | Type | Description | Default |
|---------------|------|-------------|---------|
| `project` | string | Project name | `"petclinic"` |
| `service_names` | list(string) | Service names for repos | — |
| `tags` | map(string) | Additional tags | `{}` |

| Output | Type | Description |
|--------|------|-------------|
| `environment` | string | Environment name | — |
| `image_tag_mutability` | string | Tag mutability | `"MUTABLE"` |

| Output | Type | Description |
|--------|------|-------------|
| `repository_urls` | map(string) | Map of service_name → ECR repository URL |
| `repository_arns` | map(string) | Map of service_name → ECR repository ARN |

> **Note:** ECR repos are created per environment (`petclinic-dev/`, `petclinic-prod/`). Tag mutability is MUTABLE for dev, IMMUTABLE for prod.

### Module: `rds`

**Path:** `terraform/modules/rds/`

| Input Variable | Type | Description | Default |
|---------------|------|-------------|---------|
| `project` | string | Project name | `"petclinic"` |
| `environment` | string | Environment | — |
| `subnet_ids` | list(string) | Subnet IDs for DB subnet group | — |
| `security_group_id` | string | RDS security group ID | — |
| `instance_class` | string | RDS instance class | `"db.t4g.micro"` |
| `allocated_storage` | number | Initial storage in GB | `20` |
| `max_allocated_storage` | number | Max autoscale storage in GB — RDS requires at least 10% above `allocated_storage` | `100` |
| `multi_az` | bool | Multi-AZ deployment | `false` |
| `backup_retention_period` | number | Backup retention in days | `7` |
| `skip_final_snapshot` | bool | Skip final snapshot on delete | `true` |
| `deletion_protection` | bool | Deletion protection | `false` |
| `tags` | map(string) | Additional tags | `{}` |

| Output | Type | Description |
|--------|------|-------------|
| `endpoint` | string | RDS endpoint hostname |
| `port` | number | RDS port (3306) |
| `db_instance_id` | string | RDS instance ID |
| `secret_arn` | string | Secrets Manager secret ARN for RDS credentials |

### Module: `dns`

**Path:** `terraform/modules/dns/`

| Input Variable | Type | Description | Default |
|---------------|------|-------------|---------|
| `domain_name` | string | Domain name for hosted zone | — |
| `tags` | map(string) | Additional tags | `{}` |

| Output | Type | Description |
|--------|------|-------------|
| `zone_id` | string | Route 53 hosted zone ID |
| `name_servers` | list(string) | NS records for delegation |
| `certificate_arn` | string | ACM certificate ARN |

### Module: `secrets`

**Path:** `terraform/modules/secrets/`

Uses `aws_secretsmanager_secret` and `aws_secretsmanager_secret_version` resources.

| Input Variable | Type | Description | Default |
|---------------|------|-------------|---------|
| `project` | string | Project name | `"petclinic"` |
| `environment` | string | Environment | — |
| `openai_api_key` | string | OpenAI API key value (≥20 chars). **`sensitive` + `ephemeral`** | `""` |
| `openai_api_key_version` | number | Revision counter; bump to push a changed key | `1` |
| `secret_recovery_window_in_days` | number | Recovery window; `0` deletes immediately | `0` |
| `tags` | map(string) | Additional tags | `{}` |

| Output | Type | Description |
|--------|------|-------------|
| `openai_secret_name` | string | Secrets Manager secret name (`petclinic/{env}/openai-api-key`) |
| `openai_secret_arn` | string | Secrets Manager ARN for OpenAI API key |
| `openai_secret_version_id` | string | Current secret version ID — confirms a rotation without printing the value |

**Requires Terraform ≥ 1.11.0**, higher than the other modules' 1.6.0 floor, because it uses write-only arguments.

**The key never reaches `terraform.tfstate` or `plan.out`.** The version resource writes `secret_string_wo` rather than `secret_string`: the value is handed to the provider during apply and then discarded, so neither file ever holds it. `sensitive = true` alone would not achieve this — it redacts a value from terminal output but still stores it verbatim in both files, and this project's documented workflow saves a plan and applies from it, so the key would otherwise sit in plaintext in `plan.out` for as long as that file exists. The variable is declared `ephemeral = true` at both the module and the environment root, so the value is not persisted at the root either.

The cost of that guarantee is that Terraform cannot read the value back and therefore cannot notice that it changed. **Rotating is a two-field edit:** the new value in `terraform.tfvars`, plus `openai_api_key_version` bumped in `terraform/environments/{env}/main.tf`. Changing the key alone produces an empty plan and leaves the old value in Secrets Manager. See `k8s/base/external-secrets/README.md` → Rotating a secret.

**A blank key is rejected at plan time, but teardown does not require one.** The check lives in a `lifecycle.precondition` on the secret version, not in the variable's `validation` block, and the variable defaults to `""`. The distinction is not stylistic: `terraform destroy` **evaluates variable validations and skips resource preconditions**, so a required variable — or a validation that rejects `""` — blocks destroying the entire environment over a value destroy never reads. Dev is torn down and rebuilt routinely to save cost, so that would tax the normal path. The precondition fires on create and update, where the guarantee matters, and is skipped on destroy.

`secret_recovery_window_in_days` overrides the AWS default of 30. A deleted secret is only *scheduled* for deletion, and its name cannot be reused until the window elapses — so the default breaks the dev destroy/rebuild cycle outright, and dev sets `0`. Prod sets `7`, where a rebuild is not routine and reversibility of a mistake is worth more.

Note: RDS credentials are NOT managed by this module — they are in the `rds` module (PETPLAT-23).

### Module: `karpenter`

**Path:** `terraform/modules/karpenter/`

Provisions the IAM roles, SQS queue, and EventBridge rules needed for Karpenter.

| Input Variable | Type | Description | Default |
|---------------|------|-------------|---------|
| `project` | string | Project name | `"petclinic"` |
| `environment` | string | Environment | — |
| `cluster_name` | string | EKS cluster name | — |
| `oidc_provider_arn` | string | OIDC provider ARN (for IRSA) | — |
| `node_role_arn` | string | Node IAM role ARN (for Karpenter-managed nodes) | — |
| `tags` | map(string) | Additional tags | `{}` |

| Output | Type | Description |
|--------|------|-------------|
| `karpenter_role_arn` | string | Karpenter controller IRSA role ARN |
| `karpenter_queue_name` | string | SQS interruption queue name |
| `karpenter_instance_profile_name` | string | Instance profile for Karpenter-launched nodes |

## Helm Charts

### Architecture Decision

Helm replaces plain K8s YAML + Kustomize overlays. A **single generic chart** (`helm/petclinic-service/`) is shared by all 8 services. Per-service and per-environment configuration is in `helm-values/`. See [ADR-0007](#adr-index).

### Chart Structure

```
helm/
└── petclinic-service/
    ├── Chart.yaml              # name: petclinic-service, version: 0.1.0
    ├── values.yaml             # Defaults (common to all services)
    └── templates/
        ├── deployment.yaml     # Deployment with probes, resources, env vars, init containers
        ├── service.yaml        # ClusterIP Service
        ├── configmap.yaml      # Non-secret configuration
        ├── serviceaccount.yaml # ServiceAccount with IRSA annotation
        ├── hpa.yaml            # HPA (conditional on .Values.autoscaling.enabled)
        ├── pdb.yaml            # PDB (conditional on .Values.podDisruptionBudget.enabled)
        └── _helpers.tpl        # Template helpers (labels, names, selectors)
```

### values.yaml Defaults

```yaml
replicaCount: 1
image:
  repository: ""   # Set per-service: {account}.dkr.ecr.eu-central-1.amazonaws.com/petclinic-{env}/{service}
  tag: "latest"    # Overridden by CI/CD
  pullPolicy: IfNotPresent

service:
  port: 8080       # Overridden per-service

resources:
  requests:
    cpu: 100m
    memory: 128Mi
  limits:
    cpu: 500m
    memory: 512Mi

probes:
  readiness:
    path: /actuator/health/readiness
    initialDelaySeconds: 30
    periodSeconds: 10
  liveness:
    path: /actuator/health/liveness
    initialDelaySeconds: 60
    periodSeconds: 15

env: []              # Additional env vars (set per-service)
initContainers: []   # Wait-for containers (set per-service)

autoscaling:
  enabled: false
  minReplicas: 1
  maxReplicas: 4
  targetCPUUtilizationPercentage: 70

podDisruptionBudget:
  enabled: false
  minAvailable: 1

securityContext:
  runAsNonRoot: true
  runAsUser: 1000
  fsGroup: 1000
```

### Per-Service Values (`helm-values/`)

```
helm-values/
├── config-server.yaml         # port: 8888, no init containers, no MySQL
├── discovery-server.yaml      # port: 8761, wait-for-config init container
├── api-gateway.yaml           # port: 8080, higher CPU (200m/1000m)
├── customers-service.yaml     # port: 8081, MySQL env vars, wait-for inits
├── visits-service.yaml        # port: 8082, MySQL env vars, wait-for inits
├── vets-service.yaml          # port: 8083, MySQL env vars, wait-for inits
├── genai-service.yaml         # port: 8084, OPENAI_API_KEY env var
├── admin-server.yaml          # port: 9090
├── dev.yaml                   # Dev overrides: replicas=1, no HPA, no PDB
└── prod.yaml                  # Prod overrides: replicas=2, HPA enabled, PDB enabled
```

### Helm Install / Upgrade Command

```bash
# Deploy a service (example: customers-service to dev)
helm upgrade --install customers-service helm/petclinic-service/ \
  -n petclinic-dev \
  -f helm-values/customers-service.yaml \
  -f helm-values/dev.yaml \
  --set image.tag=${SHA}
```

ArgoCD automates this — see [GitOps with ArgoCD](#gitops-with-argocd).

---

## GitOps with ArgoCD

### Architecture Decision

ArgoCD handles all deployments (CD). GitHub Actions is CI-only (build, push, commit image tags). ArgoCD watches the Git repo and syncs automatically (dev) or after manual approval (prod). See [ADR-0008](#adr-index).

### ArgoCD Installation

| Parameter | Value |
|-----------|-------|
| Namespace | `argocd` |
| Installation | `kubectl apply -n argocd -f k8s/argocd/install/` |
| Version | Latest stable (pinned in install manifests) |
| Access | `kubectl port-forward svc/argocd-server -n argocd 8443:443` |
| Admin password | Auto-generated, stored in `argocd-initial-admin-secret` |

### Application CRDs

Each service gets an ArgoCD `Application` CRD per environment:

```
k8s/argocd/applications/
├── dev/
│   ├── config-server.yaml
│   ├── discovery-server.yaml
│   ├── api-gateway.yaml
│   ├── customers-service.yaml
│   ├── visits-service.yaml
│   ├── vets-service.yaml
│   ├── genai-service.yaml
│   └── admin-server.yaml
└── prod/
    └── (same 8 files, different sync policy)
```

### Application CRD Template

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: "{service}-{env}"
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/{your-username}/petclinic-platform.git
    targetRevision: main
    path: helm/petclinic-service
    helm:
      valueFiles:
        - ../../helm-values/{service}.yaml
        - ../../helm-values/{env}.yaml
  destination:
    server: https://kubernetes.default.svc
    namespace: "petclinic-{env}"
  syncPolicy:
    automated:           # Dev: auto-sync
      prune: true
      selfHeal: true
    # Prod: remove automated block, require manual sync
```

### Sync Policies

| Environment | Auto-Sync | Prune | Self-Heal | Manual Approval |
|-------------|-----------|-------|-----------|-----------------|
| Dev | Yes | Yes | Yes | No |
| Prod | No | No | No | Yes (via ArgoCD UI/CLI) |

### GitOps Flow

```
Developer pushes code → GitHub Actions builds + pushes ARM64 images to ECR
  → GitHub Actions commits image tag to helm-values/{service}.yaml
    → ArgoCD detects Git change
      → Dev: auto-syncs immediately
      → Prod: queues sync, requires manual approval in ArgoCD UI
```

---

## Karpenter (Node Autoscaling)

### Architecture Decision

Karpenter replaces Cluster Autoscaler. It provisions nodes directly via EC2 Fleet API (faster scaling, better Spot diversification). See [ADR-0009](#adr-index).

### Prerequisites (Terraform)

| Resource | Purpose |
|----------|---------|
| Karpenter Controller IRSA Role | Permissions to manage EC2 instances |
| SQS Queue | Receives EC2 Spot interruption notices |
| EventBridge Rules | Routes Spot interruption, rebalance, and health events to SQS |
| Instance Profile | Attached to Karpenter-launched nodes |

### Karpenter Installation

| Parameter | Value |
|-----------|-------|
| Namespace | `kube-system` |
| Installation | Helm chart: `oci://public.ecr.aws/karpenter/karpenter` |
| ServiceAccount | `karpenter` (annotated with IRSA role) |

### NodePool (Kubernetes CRD)

```yaml
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: default
spec:
  template:
    spec:
      requirements:
        - key: kubernetes.io/arch
          operator: In
          values: ["arm64"]
        - key: karpenter.sh/capacity-type
          operator: In
          values: ["on-demand"]       # Use "spot" + "on-demand" when free trial expires
        - key: node.kubernetes.io/instance-type
          operator: In
          values: ["t4g.small", "t4g.medium"]
      nodeClassRef:
        group: karpenter.k8s.aws
        kind: EC2NodeClass
        name: default
  limits:
    cpu: "8"
    memory: "16Gi"
  disruption:
    consolidationPolicy: WhenEmptyOrUnderutilized
    consolidateAfter: 30s
```

### EC2NodeClass (Kubernetes CRD)

```yaml
apiVersion: karpenter.k8s.aws/v1
kind: EC2NodeClass
metadata:
  name: default
spec:
  amiSelectorTerms:
    - alias: al2023@latest
  subnetSelectorTerms:
    - tags:
        kubernetes.io/cluster/petclinic-{env}: "shared"
  securityGroupSelectorTerms:
    - tags:
        Name: "petclinic-{env}-node-sg"
  instanceProfile: "petclinic-{env}-karpenter-node-profile"
  blockDeviceMappings:
    - deviceName: /dev/xvda
      ebs:
        volumeSize: 20Gi
        volumeType: gp3
```

> **Note:** When the Graviton free trial is active, use `on-demand` only. After expiry, add `spot` to `capacity-type` for cost savings. Karpenter's Spot diversification picks the cheapest available instance type.

---

## ADR Index

Architecture Decision Records are stored in `docs/adr/`.

| ADR | Title | Status | Summary |
|-----|-------|--------|---------|
| ADR-0001 | All-public subnet design (no NAT Gateway) | Accepted | Cost optimization for student learning. SGs are the perimeter. Saves ~$35-65/mo. Trade-off: less defense-in-depth. |
| ADR-0002 | EKS over ECS | Accepted | EKS chosen for industry relevance and Kubernetes learning. ECS would be simpler but less transferable. |
| ADR-0003 | Shared RDS instance for all services | Accepted | Single `petclinic` database shared by 3 services. Matches app design (FK constraints cross-service). Simpler ops, lower cost. |
| ADR-0004 | Plain K8s YAML over Helm | Superseded by ADR-0007 | Originally chose Kustomize for transparency. Superseded by Helm for industry relevance. |
| ADR-0005 | GitHub Actions with OIDC federation | Accepted | No long-lived AWS credentials. OIDC federation is the AWS-recommended pattern. GitHub Actions for CI. |
| ADR-0006 | Single-AZ RDS for both environments | Accepted | Cost optimization for learning. Multi-AZ doubles RDS cost. Students learn when to enable it. |
| ADR-0007 | Helm over plain K8s YAML | Accepted | Generic Helm chart shared across 8 services. Per-service values files. Industry-standard packaging. Enables ArgoCD GitOps. Trade-off: Helm templating is less transparent than raw YAML. |
| ADR-0008 | ArgoCD for GitOps (CD) | Accepted | ArgoCD watches Git, syncs Helm releases. CI (GitHub Actions) pushes images and commits tags. CD is fully declarative. Dev auto-syncs, prod requires manual approval. |
| ADR-0009 | Karpenter over Cluster Autoscaler | Accepted | Faster node provisioning, better Spot diversification, EC2 Fleet API. Industry trend replacing CAS. Trade-off: more complex IAM setup. |
| ADR-0010 | ECR Private (production-correct pattern) | Accepted | Private ECR teaches the production pattern: IAM-controlled access, lifecycle policies, scan-on-push, tag immutability. Cost: ~$1/month — negligible. |
| ADR-0011 | Secrets Manager for secrets storage | Accepted | Industry-standard secrets management ($0.40/secret/month, ~$1.20 total). Built-in rotation capability, fine-grained IAM. Teaches students the production-grade approach. |
