# outputs.tf — vpc module outputs
#
# Interface defined in docs/technical-spec.md → "Terraform Modules" → Module: vpc.
# Consumed by the eks, rds, and dns modules.

output "vpc_id" {
  description = "VPC ID"
  value       = aws_vpc.this.id
}

output "public_subnet_ids" {
  description = "Public subnet IDs, in the order the subnet CIDRs were supplied"
  value       = aws_subnet.public[*].id
}

output "eks_cluster_sg_id" {
  description = "EKS control plane security group ID"
  value       = aws_security_group.eks_cluster.id
}

output "eks_node_sg_id" {
  description = "EKS worker node security group ID"
  value       = aws_security_group.eks_nodes.id
}

output "rds_sg_id" {
  description = "RDS security group ID"
  value       = aws_security_group.rds.id
}

output "alb_sg_id" {
  description = "Application Load Balancer security group ID"
  value       = aws_security_group.alb.id
}
