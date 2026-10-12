# EKS Cluster Operations

**Last Updated:** 2026-10-04

**Purpose:** How to reach the EKS clusters with kubectl, grant additional people access, and upgrade the control plane and managed add-ons. Covers the procedures required by PETPLAT-14 and PETPLAT-84.

## Table of Contents

1. [Cluster Reference](#cluster-reference)
2. [Procedure: connect kubectl to a cluster](#procedure-connect-kubectl-to-a-cluster)
3. [Procedure: grant a user or role access to a cluster](#procedure-grant-a-user-or-role-access-to-a-cluster)
4. [Procedure: update the API server allowlist](#procedure-update-the-api-server-allowlist)
5. [Procedure: upgrade an EKS managed add-on](#procedure-upgrade-an-eks-managed-add-on)
6. [Procedure: upgrade the Kubernetes version](#procedure-upgrade-the-kubernetes-version)
7. [Troubleshooting](#troubleshooting)

---

## Cluster Reference

| Setting | Dev | Prod |
|---------|-----|------|
| Cluster name | `petclinic-dev` | `petclinic-prod` |
| Region | `eu-central-1` | `eu-central-1` |
| Kubernetes version | `1.36` | `1.36` |
| Node group | `petclinic-dev-nodes` | `petclinic-prod-nodes` |
| Node instance type | `t4g.medium` (ARM64/Graviton) | `t4g.small` (ARM64/Graviton) — not yet corrected, see below |
| Node scaling | min 2 / max 4 / desired 2 | min 2 / max 4 / desired 2 |
| Node AMI type | `AL2023_ARM_64_STANDARD` | `AL2023_ARM_64_STANDARD` |
| Authentication mode | `API_AND_CONFIG_MAP` | `API_AND_CONFIG_MAP` |
| API server endpoint | Public, allowlisted to one `/32` | Public, allowlisted to one `/32` |
| Terraform module | `terraform/modules/eks/` | `terraform/modules/eks/` |

> **Node scaling note:** the values in that row are declared in
> `terraform/environments/{dev,prod}/main.tf` (`node_min_size`, `node_max_size`,
> `node_desired_size`) and exported as the `node_group_scaling` output.
> `scripts/start-env.sh` reads that output rather than keeping its own copy of
> the numbers, so editing the Terraform config is what changes what a restart
> restores. `scripts/stop-env.sh` scales the group to min 0 / desired 0 to stop
> paying for compute — a deliberate deviation from what Terraform declares, and
> the reason a later `terraform apply` scales the nodes back up and undoes the
> stop. `terraform plan` reports that as drift; it is not.

> **Kubernetes version note:** `docs/technical-spec.md` records `1.29`, which AWS no longer offers — the oldest version creatable in `eu-central-1` is `1.31` in extended support. Both environments run `1.36`, the current standard-support release at the time of writing. The same applies to the AMI type: EKS stopped publishing Amazon Linux 2 AMIs on 2025-11-26, so `AL2023_ARM_64_STANDARD` replaces the spec's `AL2_ARM_64`.

> **Node size note (2026-10-11):** dev runs `t4g.medium`, not the `t4g.small` the spec names, because `t4g.small` could not run the eight services. A t4g.small node caps at 11 pods (3 ENIs × 4 IPv4), so two nodes give 22 slots against the 23 needed once the 15 system pods are counted — `admin-server` never scheduled. It also reports only 1365 MiB allocatable, and four Spring Boot JVMs on one such node exceeded it; that node's kubelet stopped posting status and the node was lost. `t4g.medium` gives 17 pods per node and 4096 MiB at the same 2 vCPU. Prod still reads `t4g.small` here because it has not been deployed; it needs the same change before it is, since 16 prod replicas plus 15 system pods is 31 against the same 22-slot ceiling.

> **Changing the node instance type replaces the node group.** `instance_types` is ForceNew, so `terraform apply` destroys the node group and creates a new one — every node is terminated and every pod rescheduled. Deployments, Services and ConfigMaps live in etcd and survive; nothing needs reinstalling. Expect it to take longer than a normal apply if a node has an unhealthy kubelet, because the drain on that node cannot succeed and EKS waits for it to time out before forcing the delete.

Cluster access is managed by EKS **access entries**, not the `aws-auth` ConfigMap. Every principal that needs kubectl access is declared in Terraform, so access is reviewable in a pull request and cannot drift.

---

## Procedure: connect kubectl to a cluster

**When:** You need kubectl access to a cluster you have already been granted access to.
**Who:** Any engineer whose IAM principal is in `cluster_admin_principal_arns` for that environment.
**Time:** ~1 minute

**Steps:**

1. Confirm your identity — this must match the principal that was granted access:

   ```bash
   aws sts get-caller-identity
   ```

2. Point kubectl at the cluster:

   ```bash
   # Dev
   aws eks update-kubeconfig --name petclinic-dev --region eu-central-1

   # Prod
   aws eks update-kubeconfig --name petclinic-prod --region eu-central-1
   ```

3. Confirm you are talking to the right cluster:

   ```bash
   kubectl config current-context
   ```

   If you work with both environments, rename the contexts so they are unambiguous:

   ```bash
   kubectl config rename-context arn:aws:eks:eu-central-1:<account-id>:cluster/petclinic-dev petclinic-dev
   ```

**Verify:**

- `kubectl get nodes` lists two nodes in `Ready` state.
- `kubectl get pods -n kube-system` shows `coredns`, `kube-proxy` and `aws-ebs-csi-driver` pods running.

If the command returns `error: You must be logged in to the server (Unauthorized)`, your principal has no access entry — see the next procedure.

**Rollback:**

- Remove the context: `kubectl config delete-context petclinic-dev`

---

## Procedure: grant a user or role access to a cluster

**When:** A new engineer or CI role needs kubectl access, or an existing one needs it revoked.
**Who:** Engineer with `terraform apply` rights on the environment root module.
**Time:** ~5 minutes plus the time for a Terraform apply.

**Steps:**

1. Get the exact IAM ARN of the principal being added:

   ```bash
   aws iam get-user --user-name <user-name> --query 'User.Arn' --output text
   # or, for a role:
   aws iam get-role --role-name <role-name> --query 'Role.Arn' --output text
   ```

   The ARN must be an IAM user or role ARN (`arn:aws:iam::…`). A session ARN (`arn:aws:sts::…assumed-role/…`) is rejected by EKS access entries.

2. Add the ARN to `cluster_admin_principal_arns` in the environment's root module — `terraform/environments/dev/main.tf` or `terraform/environments/prod/main.tf`:

   ```hcl
   module "eks" {
     source = "../../modules/eks"
     # …
     cluster_admin_principal_arns = [
       "arn:aws:iam::550798137608:user/cloudautomator",
       "arn:aws:iam::550798137608:role/new-engineer-role",
     ]
   }
   ```

   When the list is left empty, the module falls back to the principal running `terraform apply`, so the deploying identity always keeps access.

3. Plan and apply, following the standard workflow:

   ```bash
   cd terraform/environments/dev
   terraform plan -out plan.out
   terraform apply plan.out
   ```

**Verify:**

- `terraform output` still returns the cluster outputs without error.
- The new principal runs `aws eks update-kubeconfig --name petclinic-dev --region eu-central-1` followed by `kubectl get nodes` and sees two nodes.
- In the EKS console, **Access** tab lists the new principal with `AmazonEKSClusterAdminPolicy`.

**Rollback:**

- Remove the ARN from `cluster_admin_principal_arns`, then `terraform plan -out plan.out && terraform apply plan.out`. The access entry and its policy association are deleted.

**Granting less than cluster-admin:**

Cluster-admin is the right default for a small team. For a read-only or namespace-scoped principal, do not add the ARN to `cluster_admin_principal_arns` — instead create a separate access entry with a narrower policy, using `AmazonEKSViewPolicy` or a namespace-scoped association:

```hcl
resource "aws_eks_access_entry" "readonly" {
  cluster_name  = module.eks.cluster_name
  principal_arn = "arn:aws:iam::550798137608:role/readonly-role"
  type          = "STANDARD"
}

resource "aws_eks_access_policy_association" "readonly" {
  cluster_name  = module.eks.cluster_name
  principal_arn = aws_eks_access_entry.readonly.principal_arn
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSViewPolicy"

  access_scope {
    type       = "namespace"
    namespaces = ["petclinic-dev"]
  }
}
```

---

## Procedure: update the API server allowlist

**When:** kubectl times out or is refused after your network's egress address changes — a new office, a new ISP, a VPN toggle. The public EKS endpoint only accepts traffic from the addresses in `cluster_endpoint_public_access_cidrs`.
**Who:** Engineer with `terraform apply` rights on the environment root module.
**Time:** ~5 minutes plus the time for a Terraform apply.

Both environments allowlist a single `/32`. The endpoint is public, so this list is what keeps the Kubernetes API off the open internet; IAM authentication and access entries are the second layer, not the first.

**Steps:**

1. Find the current egress address:

   ```bash
   curl -s https://checkip.amazonaws.com
   ```

2. Update the value in `terraform/environments/{dev,prod}/terraform.tfvars`:

   ```hcl
   cluster_endpoint_public_access_cidrs = ["203.0.113.10/32"]
   ```

   It is a variable rather than a literal in `main.tf` because this address
   changes on someone else's schedule. Both roots default it to `[]`, so a plan
   against a clone with no `terraform.tfvars` fails on the module's validation —
   *"must name at least one CIDR while the public endpoint is enabled"*. That
   message describes the endpoint, not the cause; the cause is the missing file.

3. Apply. Terraform talks to the AWS API rather than the EKS API, so this works even while kubectl is locked out:

   ```bash
   cd terraform/environments/dev
   terraform plan -out plan.out
   terraform apply plan.out
   ```

**Verify:**

- `kubectl get nodes` returns two `Ready` nodes.
- `aws eks describe-cluster --name petclinic-dev --region eu-central-1 --query 'cluster.resourcesVpcConfig.publicAccessCidrs'` lists the new address.

**Rollback:**

- Restore the previous CIDR and re-apply. If you are locked out and cannot determine the old address, set the list to `["0.0.0.0/0"]`, apply, then re-narrow once the new address is confirmed.

> **Note:** Widening this list to `0.0.0.0/0` makes the endpoint reachable from anywhere, which the project's security rules reserve for the ALB. Treat it as a temporary recovery step, not a resting state.

---

## Procedure: upgrade an EKS managed add-on

**When:** A new add-on version is available, or a CVE requires an update. The cluster manages `coredns`, `kube-proxy`, `vpc-cni` and `aws-ebs-csi-driver` through Terraform.
**Who:** Engineer with `terraform apply` rights on the environment root module.
**Time:** ~10 minutes (the apply is quick; the rolling update of the add-on takes a few minutes).

Add-on versions are pinned in `terraform/modules/eks/variables.tf` so that an upgrade is a visible diff rather than a silent change. Versions are **specific to a Kubernetes minor version** — the `kube-proxy` version, for example, embeds the cluster version (`v1.36.0-eksbuild.25`). Never set a version to `latest`.

**Steps:**

1. List the versions published for the current cluster version:

   ```bash
   aws eks describe-addon-versions \
     --addon-name coredns \
     --kubernetes-version 1.36 \
     --region eu-central-1 \
     --query 'addons[0].addonVersions[0:5].[addonVersion,compatibilities[0].defaultVersion]' \
     --output table
   ```

   Replace `coredns` with `kube-proxy`, `vpc-cni` or `aws-ebs-csi-driver` as needed.

2. Check whether any installed add-on has drifted from the pinned version:

   ```bash
   aws eks list-addons --cluster-name petclinic-dev --region eu-central-1 --output table

   aws eks describe-addon \
     --cluster-name petclinic-dev \
     --addon-name coredns \
     --region eu-central-1 \
     --query 'addon.[addonVersion,status]' \
     --output text
   ```

3. Update the pinned version — either the default in `terraform/modules/eks/variables.tf`, or per environment by passing the variable from `terraform/environments/{dev,prod}/main.tf`:

   ```hcl
   module "eks" {
     source = "../../modules/eks"
     # …
     addon_coredns_version = "v1.14.6-eksbuild.4"
   }
   ```

   Add-ons are applied with `resolve_conflicts_on_create` and `resolve_conflicts_on_update` set to `OVERWRITE`, so Terraform takes over configuration that EKS or a manual `aws eks update-addon` call previously set. That is what makes the first apply able to adopt the add-ons EKS installs at cluster creation.

4. Plan and apply. Check the plan shows exactly the add-on versions you intend to change and nothing else:

   ```bash
   cd terraform/environments/dev
   terraform plan -out plan.out
   terraform apply plan.out
   ```

5. Watch the add-on reach `ACTIVE`:

   ```bash
   aws eks describe-addon \
     --cluster-name petclinic-dev \
     --addon-name coredns \
     --region eu-central-1 \
     --query 'addon.[addonVersion,status]' \
     --output text
   ```

**Verify:**

- `kubectl get pods -n kube-system` — all add-on pods `Running` with no restarts beyond the rollout.
- `kubectl get nodes` — both nodes still `Ready`.
- For `aws-ebs-csi-driver`, confirm the driver assumed its IRSA role:

  ```bash
  kubectl -n kube-system logs deploy/ebs-csi-controller -c ebs-plugin --tail=20 | grep -i "assumed role"
  ```

- For `vpc-cni`, confirm pods still receive IP addresses:

  ```bash
  kubectl get pods -n kube-system -l k8s-app=aws-node
  ```

**Rollback:**

- Set the pinned version back to the previous value and `terraform plan -out plan.out && terraform apply plan.out`. Add-ons are versioned artefacts, so a downgrade is the same operation as an upgrade.

> **`vpc-cni` caveat:** the VPC CNI is a DaemonSet on the data path. Rolling it restarts pod networking on each node in turn; a version that is incompatible with the node AMI can leave nodes without pod IPs. Apply CNI changes to dev first, verify, and only then promote to prod.

---

## Procedure: upgrade the Kubernetes version

**When:** The cluster approaches the end of standard support for its current version.
**Who:** Engineer with `terraform apply` rights, coordinated with whoever owns the ArgoCD applications.
**Time:** ~30-45 minutes per environment.

Upgrade the control plane and the add-ons before the nodes — EKS will not let a node group run a version newer than the control plane.

**Steps:**

1. Confirm the current support status of every version in the region:

   ```bash
   aws eks describe-cluster-versions --region eu-central-1 \
     --query 'clusterVersions[].{version:clusterVersion,status:status,endOfStandardSupport:endOfStandardSupportDate}' \
     --output table
   ```

2. Check the upgrade path. EKS only supports moving one minor version at a time:

   ```bash
   aws eks describe-cluster-versions --region eu-central-1 \
     --cluster-version 1.36 \
     --query 'clusterVersions[0].version' --output text
   ```

3. Update the add-on versions first — they are per-minor-version, so the pins in `terraform/modules/eks/variables.tf` must match the *target* version. Follow the add-on procedure above to find valid versions.

4. Update `cluster_version` in `terraform/environments/{env}/main.tf` and apply:

   ```bash
   cd terraform/environments/dev
   terraform plan -out plan.out
   terraform apply plan.out
   ```

5. Update the node group version. The node group follows `cluster_version` through the module's `ami_type` and the pinned add-on versions; the `update_config { max_unavailable = 1 }` setting replaces one node at a time.

**Verify:**

- `aws eks describe-cluster --name petclinic-dev --region eu-central-1 --query 'cluster.[version,status]' --output text` returns the new version and `ACTIVE`.
- `kubectl get nodes` shows both nodes `Ready` with the new `VERSION` column.
- `kubectl get pods -A` shows no crash-looping system pods.
- ArgoCD reports all applications `Synced` and `Healthy`.

**Rollback:**

- EKS does not support downgrading a control plane version. Roll forward by fixing the problem, or restore from the documented disaster-recovery procedure. This is why the upgrade is applied to dev first and validated there before prod.

---

## Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| kubectl times out (`i/o timeout`, `no route to host`) but `aws eks describe-cluster` still works | The workstation's egress address changed and is no longer in `cluster_endpoint_public_access_cidrs` | Follow "Procedure: update the API server allowlist" — terraform still reaches the AWS API, so you are not locked out of the fix |
| `Unauthorized` from kubectl | Principal has no access entry | Add the IAM ARN to `cluster_admin_principal_arns` and apply |
| `Unauthorized` after confirming the access entry exists | Caller is an assumed role and the session ARN was used | Use the role ARN (`arn:aws:iam::…:role/…`), not the `arn:aws:sts::…` session ARN |
| Nodes never join the cluster | Node role missing a policy attachment | Confirm `AmazonEKSWorkerNodePolicy`, `AmazonEKS_CNI_Policy` and `AmazonEC2ContainerRegistryReadOnly` are attached |
| Pods stuck `Pending` | No capacity, or a taint with no matching toleration | `kubectl describe pod <pod>` and `kubectl get nodes -o wide`; check `node_taints` in the environment root |
| PVC stays `Pending`, event reads `no storage class is set` | The claim named no StorageClass and the cluster has no **default** StorageClass. EKS ships only a `gp2` class and does not mark it default, so the binder has nothing to provision with | Set `storageClassName` on the claim, or create a default StorageClass. Verified on the dev cluster 2026-10-04 — a claim naming `ebs.csi.aws.com` binds in ~10s |
| PVC stays `Pending` with a StorageClass named | EBS CSI driver unhealthy or its IRSA role cannot assume | Check the `ebs-csi-controller` pods and the `petclinic-{env}-ebs-csi-role` trust policy |
| `terraform apply` fails with `disk_size` and launch template | A `disk_size` argument was added back to the node group | AWS rejects `disk_size` whenever a launch template is set — the root volume belongs in `aws_launch_template.nodes` |
| Add-on apply fails with a version error | Pinned add-on version not published for the cluster's Kubernetes version | Re-run `describe-addon-versions` for the cluster version and update the pin |

## Related

- `terraform/modules/eks/` — the module these procedures operate on
- `docs/technical-spec.md` → "EKS Cluster", "IRSA Roles"
- ADR-0001 — all-public subnet design
- PETPLAT-12, PETPLAT-13, PETPLAT-14, PETPLAT-15, PETPLAT-16, PETPLAT-17, PETPLAT-84
