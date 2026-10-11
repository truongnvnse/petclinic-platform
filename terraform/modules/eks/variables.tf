# variables.tf — eks module inputs
#
# Interface defined in docs/technical-spec.md → "Terraform Modules" → Module: eks.
#
# Two defaults intentionally differ from the spec table because the values the
# spec names are no longer available in eu-central-1. Each is documented on the
# variable itself:
#
#   * cluster_version — the spec's "1.29" is past end of extended support and
#     can no longer be created. AWS now offers 1.31 (extended support) at the
#     oldest, with 1.34–1.37 in standard support.
#   * node_ami_type   — EKS stopped publishing AL2 AMIs on 2025-11-26, so
#     AL2_ARM_64 has no AMI for Kubernetes 1.33 and later.

variable "project" {
  description = "Project name used for resource naming and tagging"
  type        = string
  default     = "petclinic"
}

variable "environment" {
  description = "Environment name — must be 'dev' or 'prod'"
  type        = string

  validation {
    condition     = contains(["dev", "prod"], var.environment)
    error_message = "The environment must be either 'dev' or 'prod'."
  }
}

variable "cluster_version" {
  description = "Kubernetes version for the EKS control plane. Changing this also requires updating the add-on versions below, which are built per Kubernetes minor version."
  type        = string
  default     = "1.36"

  # EKS requires a 1.x minor version. The lower bound is 1.31 because older
  # versions are past end of extended support and can no longer be created in
  # eu-central-1 — a cluster asking for 1.29 or 1.30 fails at apply time.
  validation {
    condition     = can(regex("^1\\.(3[1-9]|[4-9][0-9])$", var.cluster_version))
    error_message = "cluster_version must be an EKS minor version of the form 1.x, 1.31 or later (earlier versions can no longer be created in eu-central-1)."
  }
}

variable "subnet_ids" {
  description = "Subnet IDs the cluster and node group are placed in (all-public design — see ADR-0001). EKS requires at least two subnets in different availability zones."
  type        = list(string)

  validation {
    condition     = length(var.subnet_ids) >= 2
    error_message = "At least two subnets in different availability zones are required — EKS will not create a cluster with fewer."
  }
}

variable "cluster_sg_id" {
  description = "Security group ID attached to the EKS control plane ENIs (from the vpc module: eks_cluster_sg_id)"
  type        = string
}

variable "node_sg_id" {
  description = "Security group ID attached to the worker nodes (from the vpc module: eks_node_sg_id). The RDS and ALB security groups grant access to this group by reference, so it must be the same group the nodes actually use."
  type        = string
}

variable "node_instance_types" {
  description = "EC2 instance types for the node group. Default is Graviton (ARM64) — the AMI type must match the architecture."
  type        = list(string)
  default     = ["t4g.small"]

  validation {
    condition     = length(var.node_instance_types) > 0
    error_message = "At least one instance type is required."
  }
}

variable "node_ami_type" {
  description = "EKS-optimized AMI type for the node group. Defaults to AL2023 ARM64 standard: the spec's AL2_ARM_64 has no published AMI for Kubernetes 1.33+, and AL2023 is the AWS-recommended successor."
  type        = string
  default     = "AL2023_ARM_64_STANDARD"
}

variable "node_capacity_type" {
  description = "Capacity type for the node group — ON_DEMAND or SPOT. Both environments default to ON_DEMAND to use the Graviton free trial."
  type        = string
  default     = "ON_DEMAND"

  validation {
    condition     = contains(["ON_DEMAND", "SPOT"], var.node_capacity_type)
    error_message = "node_capacity_type must be either 'ON_DEMAND' or 'SPOT'."
  }
}

variable "node_min_size" {
  description = "Minimum number of worker nodes"
  type        = number
  default     = 2
}

variable "node_max_size" {
  description = "Maximum number of worker nodes"
  type        = number
  default     = 4
}

variable "node_desired_size" {
  description = "Desired number of worker nodes"
  type        = number
  default     = 2
}

variable "node_disk_size" {
  description = "Root EBS volume size in GiB for each worker node. Applied through the node group's launch template, not the node group's disk_size argument — AWS rejects disk_size when a launch template is used."
  type        = number
  default     = 20

  validation {
    condition     = var.node_disk_size >= 20
    error_message = "node_disk_size must be at least 20 GiB — smaller than the EKS-optimized AL2023 AMI's snapshot size."
  }
}

variable "node_labels" {
  description = "Additional Kubernetes labels applied to the worker nodes. The environment and managed-by labels required by the spec are added automatically."
  type        = map(string)
  default     = {}
}

variable "node_taints" {
  description = "Kubernetes taints applied to the node group, e.g. [{ key = \"dedicated\", value = \"genai\", effect = \"NO_SCHEDULE\" }]"
  type = list(object({
    key    = string
    value  = string
    effect = string
  }))
  default = []

  validation {
    condition = alltrue([
      for t in var.node_taints :
      contains(["NO_SCHEDULE", "NO_EXECUTE", "PREFER_NO_SCHEDULE"], t.effect)
    ])
    error_message = "Each taint effect must be one of NO_SCHEDULE, NO_EXECUTE, or PREFER_NO_SCHEDULE."
  }
}

variable "cluster_endpoint_public_access" {
  description = "Whether the Kubernetes API server endpoint is reachable from the internet. The spec requires a public endpoint; restrict the source addresses with cluster_endpoint_public_access_cidrs."
  type        = bool
  default     = true
}

variable "cluster_endpoint_private_access" {
  description = "Whether the Kubernetes API server endpoint is reachable from inside the VPC. Worker nodes and in-cluster controllers use this path."
  type        = bool
  default     = true
}

variable "cluster_endpoint_public_access_cidrs" {
  description = "CIDR blocks allowed to reach the public API server endpoint. Required whenever cluster_endpoint_public_access is true. The default is deliberately empty rather than 0.0.0.0/0, so a caller that omits the argument fails at plan time instead of silently exposing the Kubernetes API to the internet. Both environment roots narrow this to the workstation's egress address — see docs/eks-operations.md → \"Procedure: update the API server allowlist\"."
  type        = list(string)
  default     = []

  # Conditional on the endpoint being public: a private-only endpoint takes no
  # CIDR list at all (the module passes null), so an empty list is only an
  # error in the case that would actually be reachable from the internet.
  validation {
    condition     = !var.cluster_endpoint_public_access || length(var.cluster_endpoint_public_access_cidrs) > 0
    error_message = "cluster_endpoint_public_access_cidrs must name at least one CIDR while the public endpoint is enabled — EKS rejects an empty list there. Narrow it to your egress address, or set cluster_endpoint_public_access = false for a private-only endpoint."
  }
}

variable "cluster_log_retention_days" {
  description = "Retention for the control plane CloudWatch log group. Logging itself is always enabled for api, audit and authenticator — only the retention period is configurable, to keep CloudWatch costs bounded."
  type        = number
  default     = 7

  validation {
    condition = contains(
      [1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1096, 1827, 2192, 2557, 2922, 3288, 3653],
      var.cluster_log_retention_days
    )
    error_message = "cluster_log_retention_days must be one of the retention values CloudWatch Logs accepts (1, 3, 5, 7, 14, 30, 60, 90, … 3653)."
  }
}

variable "cluster_admin_principal_arns" {
  description = "IAM principal ARNs granted cluster-admin through EKS access entries (PETPLAT-14). When empty, the deploying principal from the current AWS session is granted access, so a fresh apply is always reachable with kubectl. Pass role ARNs explicitly when deploying with an assumed role, because a session ARN (arn:aws:sts::…) is not accepted by access entries."
  type        = list(string)
  default     = []

  # EKS rejects session ARNs, the account root and federated-user ARNs at apply
  # time with an opaque error. Catching them here turns a five-minute failed
  # apply into a plan-time message naming the offending ARN.
  validation {
    condition = alltrue([
      for arn in var.cluster_admin_principal_arns :
      !can(regex(":assumed-role/|:federated-user/|:root$", arn))
    ])
    error_message = "Access entries accept IAM user and role ARNs only. Replace any session ARN (arn:aws:sts::…:assumed-role/…), account root (arn:aws:iam::…:root) or federated-user ARN with the underlying role ARN, e.g. arn:aws:iam::123456789012:role/MyRole."
  }
}

# Every add-on version is pinned, and "latest" is rejected outright: an
# add-on that tracks latest changes under Terraform's feet, so an upgrade would
# never appear in a plan. See docs/eks-operations.md → "Procedure: upgrade an
# EKS managed add-on".

variable "addon_coredns_version" {
  description = "Pinned coredns add-on version. Must be a version published for var.cluster_version — list them with: aws eks describe-addon-versions --addon-name coredns --kubernetes-version <version>"
  type        = string
  default     = "v1.14.6-eksbuild.4"

  validation {
    condition     = can(regex("^v[0-9]", var.addon_coredns_version))
    error_message = "Pin an explicit coredns version of the form v1.14.6-eksbuild.4 — 'latest' and an empty value would both make upgrades silent and unreproducible."
  }
}

variable "addon_kube_proxy_version" {
  description = "Pinned kube-proxy add-on version, matched to var.cluster_version — the add-on version carries the Kubernetes minor version."
  type        = string
  default     = "v1.36.0-eksbuild.25"

  validation {
    condition     = can(regex("^v[0-9]", var.addon_kube_proxy_version))
    error_message = "Pin an explicit kube-proxy version of the form v1.36.0-eksbuild.25 — 'latest' and an empty value would both make upgrades silent and unreproducible."
  }
}

variable "addon_vpc_cni_version" {
  description = "Pinned vpc-cni add-on version"
  type        = string
  default     = "v1.23.2-eksbuild.1"

  validation {
    condition     = can(regex("^v[0-9]", var.addon_vpc_cni_version))
    error_message = "Pin an explicit vpc-cni version of the form v1.23.2-eksbuild.1 — 'latest' and an empty value would both make upgrades silent and unreproducible."
  }
}

variable "addon_ebs_csi_version" {
  description = "Pinned aws-ebs-csi-driver add-on version. The driver backs the PersistentVolumes used by Prometheus and Grafana."
  type        = string
  default     = "v1.66.0-eksbuild.1"

  validation {
    condition     = can(regex("^v[0-9]", var.addon_ebs_csi_version))
    error_message = "Pin an explicit aws-ebs-csi-driver version of the form v1.66.0-eksbuild.1 — 'latest' and an empty value would both make upgrades silent and unreproducible."
  }
}

variable "tags" {
  description = "Additional tags merged onto every resource in this module"
  type        = map(string)
  default     = {}
}
