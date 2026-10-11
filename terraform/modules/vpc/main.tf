# main.tf — vpc module
#
# All-public network for the petclinic platform (E-2 Networking).
# Owned by PETPLAT-6 (VPC, subnets, IGW) and PETPLAT-8 (baseline security groups).
#
# Design — ADR-0001, docs/technical-spec.md → "VPC Network Design":
#   * No NAT Gateway, no private subnets, no VPC endpoints. Every resource
#     (EKS nodes, RDS, ALB) lives in a public subnet and reaches the internet
#     through the Internet Gateway, which saves ~$35-65/month per student.
#   * Security groups are therefore the primary access control boundary and are
#     kept as restrictive as a private-subnet setup would be. See the rules at
#     the bottom of this file.

locals {
  # Naming convention: petclinic-{env}-{resource}
  name_prefix = "${var.project}-${var.environment}"

  # EKS discovers its subnets through this tag; the cluster name in the key
  # must match the EKS cluster name exactly (petclinic-{env}).
  eks_cluster_tag_key = "kubernetes.io/cluster/${local.name_prefix}"

  # Required tags are also applied by the provider's default_tags block in the
  # environment roots. They are repeated here, and given precedence over
  # `var.tags`, so a caller can add tags but can never silently drop the tags
  # this project depends on for cost allocation and drift detection.
  #
  # The security group rule resources at the bottom of this file are not tagged
  # individually — they inherit Project/Environment/ManagedBy from default_tags.
  common_tags = merge(
    var.tags,
    {
      Project     = var.project
      Environment = var.environment
      ManagedBy   = "terraform"
      Component   = "networking"
    },
  )
}

# ---------------------------------------------------------------------------
# VPC
# ---------------------------------------------------------------------------

resource "aws_vpc" "this" {
  cidr_block = var.vpc_cidr

  # Both are required by EKS: nodes resolve each other and the AWS service
  # endpoints by DNS name, and instances must receive DNS hostnames.
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = merge(local.common_tags, { Name = "${local.name_prefix}-vpc" })
}

# ---------------------------------------------------------------------------
# Public subnets — one per availability zone
#
# map_public_ip_on_launch gives every instance a public IP, so nodes can pull
# images from ECR and reach the AWS APIs without a NAT Gateway.
# ---------------------------------------------------------------------------

resource "aws_subnet" "public" {
  count = length(var.public_subnet_cidrs)

  vpc_id                  = aws_vpc.this.id
  cidr_block              = var.public_subnet_cidrs[count.index]
  availability_zone       = var.availability_zones[count.index]
  map_public_ip_on_launch = true

  # The two lists are paired by position, so a length mismatch would either fail
  # with an opaque "Invalid index" or silently drop zones. Fail with a readable
  # message instead. A cross-variable `validation` block would express this more
  # naturally but needs Terraform >= 1.9, and this module supports >= 1.6.
  lifecycle {
    precondition {
      condition     = length(var.public_subnet_cidrs) == length(var.availability_zones)
      error_message = "public_subnet_cidrs and availability_zones must have the same length — they are paired by position."
    }

    precondition {
      condition     = length(var.availability_zones) == length(distinct(var.availability_zones))
      error_message = "availability_zones must not contain duplicates — EKS and the ALB need subnets in distinct zones."
    }
  }

  tags = merge(
    local.common_tags,
    {
      Name = "${local.name_prefix}-public-${count.index + 1}"

      # EKS subnet discovery — see docs/technical-spec.md → "EKS Subnet Tags".
      # "shared" lets the cluster use subnets that are not exclusively its own.
      (local.eks_cluster_tag_key) = "shared"
      "kubernetes.io/role/elb"    = "1"
    },
  )
}

# ---------------------------------------------------------------------------
# Internet Gateway and public routing
#
# One route table for the whole VPC: 0.0.0.0/0 → IGW. There is deliberately
# no NAT Gateway and no private route table (ADR-0001).
# ---------------------------------------------------------------------------

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id

  tags = merge(local.common_tags, { Name = "${local.name_prefix}-igw" })
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id

  tags = merge(local.common_tags, { Name = "${local.name_prefix}-public-rt" })
}

resource "aws_route" "public_internet" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.this.id
}

resource "aws_route_table_association" "public" {
  count = length(aws_subnet.public)

  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# ---------------------------------------------------------------------------
# Baseline security groups (PETPLAT-8)
#
# Four groups, one per role. Rules are standalone aws_vpc_security_group_*_rule
# resources rather than inline `ingress`/`egress` blocks: the cluster and node
# groups reference each other, and inline rules would put a dependency cycle
# between the two aws_security_group resources.
#
# A security group created through the API starts with no rules at all (the
# allow-all egress rule only appears for groups made in the console), so every
# egress path below is declared explicitly.
# ---------------------------------------------------------------------------

resource "aws_security_group" "eks_cluster" {
  name        = "${local.name_prefix}-eks-cluster-sg"
  description = "EKS control plane - Kubernetes API server traffic from worker nodes"
  vpc_id      = aws_vpc.this.id

  tags = merge(local.common_tags, { Name = "${local.name_prefix}-eks-cluster-sg" })
}

resource "aws_vpc_security_group_ingress_rule" "eks_cluster_api_from_nodes" {
  security_group_id            = aws_security_group.eks_cluster.id
  description                  = "Kubernetes API server (443) from worker nodes"
  ip_protocol                  = "tcp"
  from_port                    = 443
  to_port                      = 443
  referenced_security_group_id = aws_security_group.eks_nodes.id
}

resource "aws_vpc_security_group_egress_rule" "eks_cluster_all" {
  security_group_id = aws_security_group.eks_cluster.id
  description       = "Control plane to worker nodes and AWS APIs"
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_security_group" "eks_nodes" {
  name        = "${local.name_prefix}-eks-node-sg"
  description = "EKS worker nodes - intra-cluster traffic and ALB NodePort access"
  vpc_id      = aws_vpc.this.id

  tags = merge(local.common_tags, { Name = "${local.name_prefix}-eks-node-sg" })
}

resource "aws_vpc_security_group_ingress_rule" "eks_nodes_from_cluster" {
  security_group_id            = aws_security_group.eks_nodes.id
  description                  = "All traffic from the EKS control plane"
  ip_protocol                  = "-1"
  referenced_security_group_id = aws_security_group.eks_cluster.id
}

resource "aws_vpc_security_group_ingress_rule" "eks_nodes_self" {
  security_group_id            = aws_security_group.eks_nodes.id
  description                  = "Inter-node traffic (pod networking, cluster DNS, service mesh)"
  ip_protocol                  = "-1"
  referenced_security_group_id = aws_security_group.eks_nodes.id
}

# Already covered by the allow-all rule above, but declared separately because
# docs/technical-spec.md → "EKS Node Security Group" lists the kubelet path
# explicitly, which makes it visible in the console and in security reviews.
resource "aws_vpc_security_group_ingress_rule" "eks_nodes_kubelet" {
  security_group_id            = aws_security_group.eks_nodes.id
  description                  = "Kubelet API (10250) from the control plane"
  ip_protocol                  = "tcp"
  from_port                    = 10250
  to_port                      = 10250
  referenced_security_group_id = aws_security_group.eks_cluster.id
}

resource "aws_vpc_security_group_ingress_rule" "eks_nodes_nodeport_from_alb" {
  security_group_id            = aws_security_group.eks_nodes.id
  description                  = "NodePort services (30000-32767) from the ALB"
  ip_protocol                  = "tcp"
  from_port                    = 30000
  to_port                      = 32767
  referenced_security_group_id = aws_security_group.alb.id
}

# Health checks from the ALB — docs/technical-spec.md → "EKS Node Security
# Group" lists this ingress as "Health checks from ALB | TCP | 8080 | ALB SG",
# and the ALB table declares the matching egress. The rule is required: the
# Ingress sets `target-type: ip` with `healthcheck-port: "8080"`
# (→ "Ingress Resource Annotations"), and with the default VPC CNI, traffic to
# a pod IP is governed by the node security group.
resource "aws_vpc_security_group_ingress_rule" "eks_nodes_healthcheck_from_alb" {
  security_group_id            = aws_security_group.eks_nodes.id
  description                  = "ALB target group health checks on the api-gateway port"
  ip_protocol                  = "tcp"
  from_port                    = 8080
  to_port                      = 8080
  referenced_security_group_id = aws_security_group.alb.id
}

resource "aws_vpc_security_group_egress_rule" "eks_nodes_all" {
  security_group_id = aws_security_group.eks_nodes.id
  description       = "Nodes pull images from ECR and reach AWS APIs through the internet gateway"
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_security_group" "rds" {
  name        = "${local.name_prefix}-rds-sg"
  description = "RDS MySQL - reachable only from the EKS worker nodes"
  vpc_id      = aws_vpc.this.id

  tags = merge(local.common_tags, { Name = "${local.name_prefix}-rds-sg" })
}

# The single most important rule in this file: 3306 is open to the node
# security group and to nothing else. Never 0.0.0.0/0.
resource "aws_vpc_security_group_ingress_rule" "rds_mysql_from_nodes" {
  security_group_id            = aws_security_group.rds.id
  description                  = "MySQL (3306) from EKS worker nodes only"
  ip_protocol                  = "tcp"
  from_port                    = 3306
  to_port                      = 3306
  referenced_security_group_id = aws_security_group.eks_nodes.id
}

# Outbound is unrestricted, as on the other baseline groups. The restriction
# that matters is the ingress rule above: nothing outside the node security
# group can reach 3306.
resource "aws_vpc_security_group_egress_rule" "rds_all" {
  security_group_id = aws_security_group.rds.id
  description       = "All outbound"
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_security_group" "alb" {
  name        = "${local.name_prefix}-alb-sg"
  description = "Application Load Balancer - public HTTP/HTTPS ingress"
  vpc_id      = aws_vpc.this.id

  tags = merge(local.common_tags, { Name = "${local.name_prefix}-alb-sg" })
}

# 0.0.0.0/0 is intentional here and only here: the ALB is the one public
# entry point. It forwards to the nodes, which stay closed to the internet.
resource "aws_vpc_security_group_ingress_rule" "alb_http" {
  security_group_id = aws_security_group.alb.id
  description       = "HTTP from the internet (redirected to HTTPS by the listener)"
  ip_protocol       = "tcp"
  from_port         = 80
  to_port           = 80
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_ingress_rule" "alb_https" {
  security_group_id = aws_security_group.alb.id
  description       = "HTTPS from the internet"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_egress_rule" "alb_to_nodes_nodeport" {
  security_group_id            = aws_security_group.alb.id
  description                  = "Forward traffic to NodePort services on the nodes"
  ip_protocol                  = "tcp"
  from_port                    = 30000
  to_port                      = 32767
  referenced_security_group_id = aws_security_group.eks_nodes.id
}

resource "aws_vpc_security_group_egress_rule" "alb_to_nodes_health" {
  security_group_id            = aws_security_group.alb.id
  description                  = "Target group health checks"
  ip_protocol                  = "tcp"
  from_port                    = 8080
  to_port                      = 8080
  referenced_security_group_id = aws_security_group.eks_nodes.id
}
