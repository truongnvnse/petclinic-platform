# main.tf — eks module
#
# EKS cluster, managed node group, OIDC provider, cluster access, and the
# managed add-ons (E-3 EKS Cluster).
# Owned by PETPLAT-12 (cluster + IAM roles), PETPLAT-13 (node group),
# PETPLAT-14 (kubectl access) and PETPLAT-84 (managed add-ons).
#
# Design — docs/technical-spec.md → "EKS Cluster":
#   * The cluster and its nodes live in the public subnets of the all-public
#     VPC (ADR-0001). There is no NAT Gateway, so nodes reach ECR and the AWS
#     APIs through the internet gateway and the security groups from the vpc
#     module are the access control boundary.
#   * Authentication is API_AND_CONFIG_MAP, which lets cluster access be
#     managed declaratively through EKS access entries instead of hand-editing
#     the aws-auth ConfigMap.
#   * Control plane logging is always on for api, audit and authenticator.

locals {
  # Naming convention: petclinic-{env}-{resource}
  name_prefix = "${var.project}-${var.environment}"

  partition  = data.aws_partition.current.partition
  account_id = data.aws_caller_identity.current.account_id
  caller_arn = data.aws_caller_identity.current.arn

  # Required tags are also applied by the provider's default_tags block in the
  # environment roots. They are repeated here, and given precedence over
  # `var.tags`, so a caller can add tags but can never silently drop the tags
  # this project depends on for cost allocation and drift detection.
  common_tags = merge(
    var.tags,
    {
      Project     = var.project
      Environment = var.environment
      ManagedBy   = "terraform"
      Component   = "compute"
    },
  )

  # The issuer URL carries the https:// scheme; IAM wants the provider URL and
  # the trust-policy condition keys without it.
  oidc_issuer       = aws_eks_cluster.this.identity[0].oidc[0].issuer
  oidc_provider_url = trimprefix(local.oidc_issuer, "https://")

  # Access entries are required, not optional: the cluster is created with
  # bootstrap_cluster_creator_admin_permissions = false so that access is
  # defined entirely in Terraform rather than partly by an implicit creator
  # entry. Falling back to the current session's principal is what keeps a
  # fresh apply reachable with kubectl.
  #
  # The fallback cannot use the caller ARN as-is. For anything that assumes a
  # role — SSO, CI OIDC, cross-account — aws_caller_identity reports a session
  # ARN of the form
  #   arn:aws:sts::123456789012:assumed-role/RoleName/session-name
  # and EKS access entries reject session ARNs, just as they reject the account
  # root ARN. Rebuilding the role ARN from it makes the fallback work for IAM
  # users and assumed roles alike. A role that carries a path keeps it
  # (assumed-role/team/RoleName/session-name), so only the trailing session
  # name is dropped.
  caller_is_assumed_role = can(regex("^arn:[^:]+:sts::[0-9]+:assumed-role/.+/[^/]+$", local.caller_arn))

  # Empty when the caller is not an assumed role. Both ternary branches have to
  # be evaluable, so this cannot be left to a bare regex() that would fail on an
  # IAM user ARN.
  caller_assumed_role_name = local.caller_is_assumed_role ? regex("^arn:[^:]+:sts::[0-9]+:assumed-role/(.+)/[^/]+$", local.caller_arn)[0] : ""

  caller_principal_arn = local.caller_is_assumed_role ? format(
    "arn:%s:iam::%s:role/%s",
    local.partition,
    local.account_id,
    local.caller_assumed_role_name,
  ) : local.caller_arn

  admin_principal_arns = length(var.cluster_admin_principal_arns) > 0 ? var.cluster_admin_principal_arns : [local.caller_principal_arn]
}

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}
data "aws_region" "current" {}

# ---------------------------------------------------------------------------
# Cluster IAM role
#
# The control plane assumes this role to manage the AWS resources that back
# the cluster — load balancers for services, EBS volumes, and the network
# interfaces of the control plane ENIs.
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "cluster_assume_role" {
  statement {
    sid     = "EKSClusterAssumeRole"
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["eks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "cluster" {
  name               = "${local.name_prefix}-eks-cluster-role"
  description        = "EKS control plane role for the ${local.name_prefix} cluster"
  assume_role_policy = data.aws_iam_policy_document.cluster_assume_role.json

  tags = merge(local.common_tags, { Name = "${local.name_prefix}-eks-cluster-role" })
}

resource "aws_iam_role_policy_attachment" "cluster" {
  role       = aws_iam_role.cluster.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/AmazonEKSClusterPolicy"
}

# ---------------------------------------------------------------------------
# Control plane logs
#
# Created explicitly so the retention period is bounded. Left to EKS, the log
# group is created with "never expire", and the audit log alone grows without
# limit.
# ---------------------------------------------------------------------------

resource "aws_cloudwatch_log_group" "cluster" {
  name              = "/aws/eks/${local.name_prefix}/cluster"
  retention_in_days = var.cluster_log_retention_days

  tags = merge(local.common_tags, { Name = "/aws/eks/${local.name_prefix}/cluster" })
}

# ---------------------------------------------------------------------------
# EKS cluster
# ---------------------------------------------------------------------------

resource "aws_eks_cluster" "this" {
  name     = local.name_prefix
  role_arn = aws_iam_role.cluster.arn
  version  = var.cluster_version

  # api (control plane requests), audit (who did what — required for the
  # compliance evidence in E-13) and authenticator (IAM identity mapping).
  enabled_cluster_log_types = ["api", "audit", "authenticator"]

  access_config {
    authentication_mode = "API_AND_CONFIG_MAP"

    # Access is granted explicitly below. Leaving this at true would make EKS
    # create its own creator access entry, which then collides with the
    # Terraform-managed entry for the same principal.
    bootstrap_cluster_creator_admin_permissions = false
  }

  vpc_config {
    subnet_ids = var.subnet_ids

    # The cluster security group from the vpc module, which already allows the
    # API server to be reached from the node security group on 443. EKS also
    # attaches its own auto-created cluster security group alongside this one.
    security_group_ids = [var.cluster_sg_id]

    endpoint_public_access  = var.cluster_endpoint_public_access
    endpoint_private_access = var.cluster_endpoint_private_access

    # Only meaningful when the public endpoint is enabled; passing null when it
    # is disabled leaves the attribute unmanaged rather than forcing a value
    # AWS will ignore.
    public_access_cidrs = var.cluster_endpoint_public_access ? var.cluster_endpoint_public_access_cidrs : null
  }

  tags = merge(local.common_tags, { Name = local.name_prefix })

  # The role must be able to assume its policies before the control plane is
  # created, and the log group must exist first so EKS does not create it with
  # unbounded retention.
  depends_on = [
    aws_iam_role_policy_attachment.cluster,
    aws_cloudwatch_log_group.cluster,
  ]
}

# ---------------------------------------------------------------------------
# OIDC provider — the trust anchor for every IRSA role
#
# thumbprint_list is deliberately not set: AWS stopped validating thumbprints
# for EKS OIDC providers, and the provider marks the attribute Optional +
# Computed, so omitting it is both correct and avoids pinning a certificate
# fingerprint that would need rotating.
# ---------------------------------------------------------------------------

resource "aws_iam_openid_connect_provider" "this" {
  url            = local.oidc_issuer
  client_id_list = ["sts.amazonaws.com"]

  tags = merge(local.common_tags, { Name = "${local.name_prefix}-oidc" })
}

# ---------------------------------------------------------------------------
# Cluster access (PETPLAT-14)
#
# One access entry per principal, each associated with the AWS-managed
# cluster-admin policy. Adding a teammate means adding their IAM ARN to
# cluster_admin_principal_arns — see docs/eks-operations.md.
# ---------------------------------------------------------------------------

resource "aws_eks_access_entry" "admin" {
  for_each = toset(local.admin_principal_arns)

  cluster_name  = aws_eks_cluster.this.name
  principal_arn = each.value
  type          = "STANDARD"

  # Named from the ARN's final segment rather than its position in the list, so
  # adding or removing one principal does not rewrite every other entry's tag.
  tags = merge(local.common_tags, { Name = "${local.name_prefix}-access-${basename(each.value)}" })
}

resource "aws_eks_access_policy_association" "admin" {
  for_each = aws_eks_access_entry.admin

  cluster_name  = aws_eks_cluster.this.name
  principal_arn = each.value.principal_arn
  policy_arn    = "arn:${local.partition}:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"

  access_scope {
    type = "cluster"
  }
}

# ---------------------------------------------------------------------------
# Node IAM role
#
# Grants the kubelet and the VPC CNI the permissions they need to join the
# cluster and hand out pod IPs. Pod-level AWS access does not use this role —
# it goes through the IRSA roles built on the OIDC provider above.
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "node_assume_role" {
  statement {
    sid     = "EKSNodeAssumeRole"
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "node" {
  name               = "${local.name_prefix}-eks-node-role"
  description        = "EKS worker node role for the ${local.name_prefix} cluster"
  assume_role_policy = data.aws_iam_policy_document.node_assume_role.json

  tags = merge(local.common_tags, { Name = "${local.name_prefix}-eks-node-role" })
}

resource "aws_iam_role_policy_attachment" "node" {
  for_each = toset([
    "AmazonEKSWorkerNodePolicy",
    "AmazonEKS_CNI_Policy",
    "AmazonEC2ContainerRegistryReadOnly",
  ])

  role       = aws_iam_role.node.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/${each.value}"
}

# ---------------------------------------------------------------------------
# Node launch template
#
# Managed node groups have no security_group_ids argument, so a launch template
# is the only way to put the nodes in the vpc module's node security group.
# That group is load-bearing: the RDS security group admits 3306 from it and
# the ALB security group forwards to it, so nodes that landed in the default
# cluster group instead would be unable to reach the database.
#
# The template carries the root volume rather than the node group's disk_size
# argument because AWS rejects disk_size outright whenever a launch template is
# set. Declaring the volume here also lets encryption be switched on
# explicitly, instead of depending on the account-level EBS encryption default.
# ---------------------------------------------------------------------------

resource "aws_launch_template" "nodes" {
  name        = "${local.name_prefix}-nodes"
  description = "Worker nodes for the ${local.name_prefix} EKS cluster"

  vpc_security_group_ids = [var.node_sg_id]

  # Enforce IMDSv2 so a compromised pod cannot use the instance metadata
  # service to steal the node role's credentials.
  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required"

    # The hop limit is what actually stops a pod: requests from a pod's network
    # namespace cross one extra hop, and IMDS answers only at hop limit 1. The
    # default is already 1, but pinning it keeps the guarantee above independent
    # of provider and AMI defaults.
    http_put_response_hop_limit = 1
  }

  block_device_mappings {
    device_name = "/dev/xvda"

    ebs {
      volume_size           = var.node_disk_size
      volume_type           = "gp3"
      encrypted             = true
      delete_on_termination = true
    }
  }

  tag_specifications {
    resource_type = "instance"

    tags = merge(local.common_tags, { Name = "${local.name_prefix}-node" })
  }

  tag_specifications {
    resource_type = "volume"

    tags = merge(local.common_tags, { Name = "${local.name_prefix}-node-volume" })
  }

  tags = merge(local.common_tags, { Name = "${local.name_prefix}-nodes" })
}

# ---------------------------------------------------------------------------
# Managed node group
# ---------------------------------------------------------------------------

resource "aws_eks_node_group" "this" {
  cluster_name    = aws_eks_cluster.this.name
  node_group_name = "${local.name_prefix}-nodes"
  node_role_arn   = aws_iam_role.node.arn

  # All-public design: the nodes sit in the same public subnets as the cluster.
  subnet_ids = var.subnet_ids

  ami_type       = var.node_ami_type
  capacity_type  = var.node_capacity_type
  instance_types = var.node_instance_types

  scaling_config {
    min_size     = var.node_min_size
    max_size     = var.node_max_size
    desired_size = var.node_desired_size
  }

  # Replace one node at a time during AMI and version rollouts, so a cluster
  # running on the minimum of two nodes never loses both at once.
  update_config {
    max_unavailable = 1
  }

  labels = merge(
    var.node_labels,
    {
      environment = var.environment
      managed-by  = "terraform"
    },
  )

  dynamic "taint" {
    for_each = var.node_taints

    content {
      key    = taint.value.key
      value  = taint.value.value
      effect = taint.value.effect
    }
  }

  launch_template {
    id      = aws_launch_template.nodes.id
    version = aws_launch_template.nodes.latest_version
  }

  tags = merge(local.common_tags, { Name = "${local.name_prefix}-nodes" })

  lifecycle {
    precondition {
      condition     = var.node_min_size <= var.node_desired_size && var.node_desired_size <= var.node_max_size
      error_message = "Node counts must satisfy min_size <= desired_size <= max_size."
    }
  }

  # The node role must hold its policies before the first instance launches,
  # otherwise the nodes come up but never join the cluster.
  depends_on = [aws_iam_role_policy_attachment.node]
}

# ---------------------------------------------------------------------------
# IRSA role for the EBS CSI driver (PETPLAT-84)
#
# The driver calls the EBS APIs to create and attach the volumes behind
# PersistentVolumeClaims — the ones Prometheus and Grafana will use. Trust is
# scoped to the driver's service account only, so no other pod in the cluster
# can assume it.
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "ebs_csi_assume_role" {
  statement {
    sid     = "EBSCSIAssumeRoleWithWebIdentity"
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.this.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_provider_url}:sub"
      values   = ["system:serviceaccount:kube-system:ebs-csi-controller-sa"]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_provider_url}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ebs_csi" {
  name               = "${local.name_prefix}-ebs-csi-role"
  description        = "IRSA role assumed by the EBS CSI driver service account in the ${local.name_prefix} cluster"
  assume_role_policy = data.aws_iam_policy_document.ebs_csi_assume_role.json

  tags = merge(local.common_tags, { Name = "${local.name_prefix}-ebs-csi-role" })
}

resource "aws_iam_role_policy_attachment" "ebs_csi" {
  role       = aws_iam_role.ebs_csi.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}

# ---------------------------------------------------------------------------
# AWS Load Balancer Controller IRSA role (PETPLAT-29)
#
# The controller watches Ingress resources and calls the ELB and EC2 APIs to
# provision the ALB in front of the API Gateway. It needs those AWS permissions
# from inside the cluster, and IRSA is how it gets them: the service account
# assumes this role through the cluster's OIDC provider, so no node-wide
# credentials are involved and no other pod can borrow the permissions.
#
# The policy is the controller's own published policy, vendored at
# lb-controller-iam-policy.json rather than referenced as an AWS managed
# policy — AWS publishes no managed policy for this controller, and fetching
# the document over the network during apply would make an apply depend on
# GitHub being reachable. The file is pinned to controller v3.6.0; when the
# chart version in scripts/install-lb-controller.sh is bumped, re-download it
# from
#   https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/<app-version>/docs/install/iam_policy.json
# using the *application* version tag (v3.6.0), not the Helm chart version —
# the two use different numbering schemes and the wrong tag returns a 404.
#
# ---------------------------------------------------------------------------
# ACCEPTED EXCEPTION to the project's "no wildcard IAM" rule
#
# This policy is upstream-verbatim and is deliberately NOT hand-trimmed, so it
# carries permissions wider than anything else in this repository:
#
#   * ec2:AuthorizeSecurityGroupIngress / ec2:RevokeSecurityGroupIngress on
#     Resource "*" with no condition. Under ADR-0001 security groups *are* the
#     perimeter, so this is the permission that could open the RDS security
#     group or the node security group to anywhere. A later statement in the
#     same file restricts security-group mutation to groups tagged
#     elbv2.k8s.aws/cluster, but that condition is undermined by this
#     unconditioned statement sitting alongside it.
#   * Listener, rule and certificate mutation (CreateListener, ModifyListener,
#     DeleteListener, CreateRule, ModifyRule, DeleteRule, AddListenerCertificates,
#     RemoveListenerCertificates) on any load balancer in the account, again
#     with no resource scope.
#
# It is kept verbatim on purpose. Trimming it would put this file out of step
# with the upstream document it is copied from, and the failure mode of a
# trimmed controller policy is not a plan error — it is a runtime reconcile
# failure on an Ingress, discovered later and hard to trace back to a missing
# action. Silent drift from the vendor's policy is the worse risk.
#
# What actually constrains it here:
#   * The role can only be assumed by the one service account named in the
#     trust policy below, through this cluster's OIDC provider — no other
#     workload and no other cluster can borrow these permissions.
#   * The Ingress pins alb.ingress.kubernetes.io/security-groups to Terraform's
#     ALB security group, so the controller does not create or manage a group of
#     its own — the node security group's rules for the ALB are the ones
#     Terraform wrote, and they are what admits traffic to the pods. Managing
#     security group *rules* on the backend would additionally require
#     enableManageBackendSecurityGroupRules, which the chart defaults to false
#     and scripts/install-lb-controller.sh does not enable. The
#     Authorize/RevokeSecurityGroupIngress statements above are therefore not
#     exercised in this deployment — see k8s/base/ingress/ingress.yaml.
#
# Re-read this note when the vendored file is bumped: upstream narrowing a
# statement is fine to adopt, but any change must come from re-downloading, not
# from editing this file.
# ---------------------------------------------------------------------------
#
# Trust is scoped to the controller's own service account. Without the :sub
# condition any service account in the cluster could assume the role and create
# load balancers against this account.
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "lb_controller_assume_role" {
  statement {
    sid     = "LBControllerAssumeRoleWithWebIdentity"
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.this.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_provider_url}:sub"
      values   = ["system:serviceaccount:kube-system:aws-load-balancer-controller"]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_provider_url}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "lb_controller" {
  name               = "${local.name_prefix}-lb-controller-role"
  description        = "IRSA role assumed by the AWS Load Balancer Controller service account in the ${local.name_prefix} cluster"
  assume_role_policy = data.aws_iam_policy_document.lb_controller_assume_role.json

  tags = merge(local.common_tags, { Name = "${local.name_prefix}-lb-controller-role" })
}

resource "aws_iam_policy" "lb_controller" {
  name        = "${local.name_prefix}-lb-controller-policy"
  description = "Permissions the AWS Load Balancer Controller needs to manage ALBs and their target groups for the ${local.name_prefix} cluster"

  # Round-tripped through jsondecode/jsonencode so the policy is sent to IAM
  # compactly. IAM's 6,144-character limit for a customer-managed policy
  # excludes whitespace, and this file is 8,955 bytes on disk but 5,196 compact
  # — measuring the raw file would overstate it and invite a false sense that a
  # future upstream bump has already overflowed. Keeping the file indented on
  # disk is worth the round trip; the limit itself is enforced against the
  # compact form either way.
  policy = jsonencode(jsondecode(file("${path.module}/lb-controller-iam-policy.json")))

  tags = merge(local.common_tags, { Name = "${local.name_prefix}-lb-controller-policy" })
}

resource "aws_iam_role_policy_attachment" "lb_controller" {
  role       = aws_iam_role.lb_controller.name
  policy_arn = aws_iam_policy.lb_controller.arn
}

# ---------------------------------------------------------------------------
# External Secrets Operator IRSA role (PETPLAT-37)
#
# ESO runs in the cluster and reads secrets out of Secrets Manager, so it needs
# AWS credentials from inside a pod. IRSA supplies them: the service account
# named in the trust policy below exchanges a projected token for temporary
# credentials through this cluster's OIDC provider. No node-wide credentials are
# involved, and no other pod can borrow the permissions.
#
# The role lives here rather than in the secrets module because the trust policy
# needs the OIDC provider, and the OIDC provider is owned by this module — the
# same reason the lb-controller and EBS CSI roles are here. The secrets module
# has no way to reference it without the environment root threading the provider
# ARN through, which would put half of a trust relationship in one module and
# half in another.
#
# The read permission is scoped to `secret:petclinic/{env}/*` in this account and
# region. That is three narrowing steps away from the story, each deliberate:
#
#   * The acceptance criteria write the resource as
#     `arn:aws:secretsmanager:*:*:secret:petclinic/*`. Region and account are
#     pinned here instead, per the project's least-privilege rule (CLAUDE.md →
#     Security Rules #5) and the more precise form in docs/technical-spec.md →
#     "IRSA Roles". A wildcard account would let the role read any account's
#     petclinic-prefixed secret it had been granted cross-account access to, and
#     a wildcard region would follow the operator to every region the account
#     uses.
#
#   * The environment segment narrows it again, to petclinic/${var.environment}/*.
#     Both environments live in one AWS account, so without this the dev
#     cluster's operator can read prod's database password and OpenAI key, and a
#     dev cluster compromise escalates to prod credentials. The spec and the AC
#     both say `petclinic/*` — this is a deliberate deviation, on the grounds
#     that no ExternalSecret in either environment reads the other's prefix, so
#     the narrower grant costs nothing. Reverting to the spec's value means
#     dropping `/${var.environment}` from the resource below.
#
# ListSecrets is deliberately absent. ESO's provider needs it only for
# `dataFrom.find` lookups, which resolve a key by path prefix; every
# ExternalSecret here names an exact key in remoteRef. It is not needed for the
# ClusterSecretStore to report Ready either — in v2.12.0 the store's Validate()
# calls only Credentials.Retrieve(), which is the STS token exchange the trust
# policy above already covers. Adding it would require a resource of "*", since
# ListSecrets takes no ARN to scope to.
#
# No kms:Decrypt statement. The story lists it as conditional on a custom KMS
# key, and these secrets use the AWS-managed `aws/secretsmanager` key — with an
# AWS-managed key the decrypt permission belongs to the service, not the caller.
# Adding it would widen the role without changing what it can read. A
# customer-managed key would need it added here at the same time as the key.
#
# The service account name is `external-secrets-sa`, not the chart's default
# `external-secrets`. The ClusterSecretStore in
# k8s/base/external-secrets/clustersecretstore.yaml names it explicitly, so the
# two have to agree — a mismatch produces an AccessDenied from STS at reconcile
# time, not at install time, which is the expensive way to find out.
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "eso_assume_role" {
  statement {
    sid     = "ESOAssumeRoleWithWebIdentity"
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.this.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_provider_url}:sub"
      values   = ["system:serviceaccount:external-secrets:external-secrets-sa"]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_provider_url}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "eso" {
  name               = "${local.name_prefix}-eso-role"
  description        = "IRSA role assumed by the External Secrets Operator service account in the ${local.name_prefix} cluster"
  assume_role_policy = data.aws_iam_policy_document.eso_assume_role.json

  tags = merge(local.common_tags, { Name = "${local.name_prefix}-eso-role" })
}

data "aws_iam_policy_document" "eso" {
  statement {
    sid    = "ReadPetclinicSecrets"
    effect = "Allow"

    actions = [
      "secretsmanager:GetSecretValue",
      "secretsmanager:DescribeSecret",
    ]

    resources = [
      "arn:${local.partition}:secretsmanager:${data.aws_region.current.name}:${local.account_id}:secret:${var.project}/${var.environment}/*",
    ]
  }
}

resource "aws_iam_policy" "eso" {
  name        = "${local.name_prefix}-eso-policy"
  description = "Read access to ${var.project}/${var.environment} secrets in Secrets Manager, for the External Secrets Operator in the ${local.name_prefix} cluster"
  policy      = data.aws_iam_policy_document.eso.json

  tags = merge(local.common_tags, { Name = "${local.name_prefix}-eso-policy" })
}

resource "aws_iam_role_policy_attachment" "eso" {
  role       = aws_iam_role.eso.name
  policy_arn = aws_iam_policy.eso.arn
}

# ---------------------------------------------------------------------------
# Managed add-ons (PETPLAT-84)
#
# Versions are pinned so an upgrade is a reviewable diff rather than a silent
# change. EKS installs vpc-cni, coredns and kube-proxy when the cluster is
# created, so the first apply takes them over with OVERWRITE; later applies
# reconcile drift in place.
# ---------------------------------------------------------------------------

locals {
  # The three add-ons that need no IAM permissions of their own.
  addon_versions = {
    coredns    = var.addon_coredns_version
    kube-proxy = var.addon_kube_proxy_version
    vpc-cni    = var.addon_vpc_cni_version
  }
}

resource "aws_eks_addon" "core" {
  for_each = local.addon_versions

  cluster_name  = aws_eks_cluster.this.name
  addon_name    = each.key
  addon_version = each.value

  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  tags = merge(local.common_tags, { Name = "${local.name_prefix}-${each.key}" })

  # coredns only becomes healthy once it can schedule onto a node.
  depends_on = [aws_eks_node_group.this]
}

# Declared separately from the group above because it is the one add-on that
# runs under an IRSA role rather than the node role.
resource "aws_eks_addon" "ebs_csi" {
  cluster_name  = aws_eks_cluster.this.name
  addon_name    = "aws-ebs-csi-driver"
  addon_version = var.addon_ebs_csi_version

  service_account_role_arn = aws_iam_role.ebs_csi.arn

  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  tags = merge(local.common_tags, { Name = "${local.name_prefix}-ebs-csi-driver" })

  depends_on = [aws_eks_node_group.this]
}
