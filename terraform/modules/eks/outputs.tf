# outputs.tf — eks module outputs
#
# Interface defined in docs/technical-spec.md → "Terraform Modules" → Module: eks.
# Consumed by the karpenter module and by the K8s/Helm layers through the
# environment roots.

output "cluster_name" {
  description = "EKS cluster name (petclinic-{env})"
  value       = aws_eks_cluster.this.name
}

output "cluster_arn" {
  description = "EKS cluster ARN"
  value       = aws_eks_cluster.this.arn
}

output "cluster_endpoint" {
  description = "EKS API server endpoint"
  value       = aws_eks_cluster.this.endpoint
}

output "cluster_ca_certificate" {
  description = "Base64-encoded certificate authority data for the cluster, used to build kubeconfig"
  value       = aws_eks_cluster.this.certificate_authority[0].data
}

output "cluster_version" {
  description = "Kubernetes version the control plane is running"
  value       = aws_eks_cluster.this.version
}

output "cluster_security_group_id" {
  description = "Security group ID EKS created automatically for the control plane. Separate from the vpc module's eks_cluster_sg_id; both are attached to the cluster ENIs."
  value       = aws_eks_cluster.this.vpc_config[0].cluster_security_group_id
}

output "oidc_provider_arn" {
  description = "ARN of the IAM OIDC provider for the cluster — use as the Federated principal in IRSA trust policies"
  value       = aws_iam_openid_connect_provider.this.arn
}

output "oidc_provider_url" {
  description = "OIDC provider URL without the https:// scheme. Use as the condition key prefix in IRSA trust policies, appending :sub or :aud."
  value       = local.oidc_provider_url
}

output "node_group_name" {
  description = "Managed node group name (petclinic-{env}-nodes)"
  value       = aws_eks_node_group.this.node_group_name
}

output "node_group_arn" {
  description = "Managed node group ARN"
  value       = aws_eks_node_group.this.arn
}

output "node_group_scaling" {
  description = "Scaling config this module declares for the node group, as the string \"<min> <max> <desired>\" — scripts/start-env.sh reads it with `terraform output -raw` and splits on the spaces. Exported because that script has to restore the group to these values after stop-env.sh scales it to zero, and reading them from here is what keeps the numbers from being restated in the script."

  # The variables rather than aws_eks_node_group.this.scaling_config, and the
  # difference matters: a refresh reads the LIVE scaling config into state, so
  # after stop-env.sh has scaled the group to zero, the resource's own attribute
  # would report zero — the one value start-env.sh cannot restore anything from.
  # The variables are the declared intent and do not move when something edits
  # the group out of band, which is the whole point of exporting them.
  #
  # A string rather than an object because the consumer is a shell script, and
  # `terraform output -raw` refuses anything that is not a string. That refusal
  # is the feature: converting this to an object does not silently hand the
  # script a wrong number, it fails the script outright at the read.
  value = "${var.node_min_size} ${var.node_max_size} ${var.node_desired_size}"
}

output "node_role_arn" {
  description = "IAM role ARN shared by the worker nodes"
  value       = aws_iam_role.node.arn
}

output "ebs_csi_role_arn" {
  description = "IRSA role ARN assumed by the EBS CSI driver service account (kube-system/ebs-csi-controller-sa)"
  value       = aws_iam_role.ebs_csi.arn
}

output "lb_controller_role_arn" {
  description = "IRSA role ARN assumed by the AWS Load Balancer Controller service account (kube-system/aws-load-balancer-controller). Pass to scripts/install-lb-controller.sh via --role-arn or the LB_CONTROLLER_ROLE_ARN environment variable."
  value       = aws_iam_role.lb_controller.arn
}

output "eso_role_arn" {
  description = "IRSA role ARN assumed by the External Secrets Operator service account (external-secrets/external-secrets-sa). Annotate that service account with this value — scripts/install-eso.sh reads it via --role-arn, the ESO_ROLE_ARN environment variable, or `terraform output -raw eso_role_arn`."
  value       = aws_iam_role.eso.arn
}

output "kubeconfig_command" {
  description = "Command that points kubectl at this cluster. Run it after terraform apply, then verify with: kubectl get nodes"
  value       = "aws eks update-kubeconfig --name ${aws_eks_cluster.this.name} --region ${data.aws_region.current.name}"
}
