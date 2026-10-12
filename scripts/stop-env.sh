#!/usr/bin/env bash
set -euo pipefail

#
# stop-env.sh — Pause your AWS environment to save costs
#
# Stops RDS and scales EKS node group to 0 nodes.
# EKS control plane stays running (~$3.30/day) but compute and DB stop.
# Saves approximately $3-8/day depending on instance sizes.
#
# Usage:
#   ./scripts/stop-env.sh dev
#   ./scripts/stop-env.sh prod
#
# ---------------------------------------------------------------------------
# This script deliberately puts the node group out of step with Terraform
#
# Terraform declares min 2 / desired 2 (terraform/environments/{env}/main.tf →
# module "eks"). Stopping means running below that, so the group is scaled to
# min 0 / desired 0 and the two now disagree. That is the point of the script,
# not a bug in it — but it has a consequence worth knowing before the next plan:
#
#   terraform plan  →  wants to set min_size back to 2 and desired_size to 2
#   terraform apply →  does exactly that, and the nodes come back
#
# So an apply silently undoes a stop. That is the intended reading of the two
# (Terraform owns the declared shape; stop-env.sh is a temporary deviation), and
# it is stated here because the plan output does not say it.
#
# maxSize is read from Terraform rather than set here, so the only values that
# differ after a stop are the two the stop is actually about.
# ---------------------------------------------------------------------------

REGION="${AWS_DEFAULT_REGION:-eu-central-1}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

usage() {
  echo "Usage: $0 <environment>"
  echo "  environment: dev | prod"
  echo ""
  echo "Examples:"
  echo "  $0 dev      # Stop dev environment"
  echo "  $0 prod     # Stop prod environment"
  exit 1
}

if [[ $# -ne 1 ]]; then
  usage
fi

ENV="$1"
if [[ "$ENV" != "dev" && "$ENV" != "prod" ]]; then
  echo "Error: environment must be 'dev' or 'prod'"
  usage
fi

CLUSTER_NAME="petclinic-${ENV}"
NODEGROUP_NAME="petclinic-${ENV}-nodes"
RDS_INSTANCE_ID="petclinic-${ENV}-mysql"
TF_DIR="${REPO_ROOT}/terraform/environments/${ENV}"

echo "============================================"
echo "  Stopping environment: ${ENV}"
echo "  Region: ${REGION}"
echo "============================================"
echo ""

# --- Stop RDS Instance ---
echo "[1/2] Stopping RDS instance: ${RDS_INSTANCE_ID}"

RDS_STATUS=$(aws rds describe-db-instances \
  --db-instance-identifier "${RDS_INSTANCE_ID}" \
  --region "${REGION}" \
  --query 'DBInstances[0].DBInstanceStatus' \
  --output text 2>/dev/null || echo "not-found")

case "${RDS_STATUS}" in
  available)
    aws rds stop-db-instance \
      --db-instance-identifier "${RDS_INSTANCE_ID}" \
      --region "${REGION}" > /dev/null
    echo "  -> RDS stop initiated. It will stop within a few minutes."
    echo "  -> Note: AWS auto-restarts stopped RDS instances after 7 days."
    ;;
  stopped)
    echo "  -> RDS is already stopped. No action needed."
    ;;
  stopping)
    echo "  -> RDS is already stopping. Please wait."
    ;;
  not-found)
    echo "  -> RDS instance not found. Skipping."
    ;;
  *)
    echo "  -> RDS is in '${RDS_STATUS}' state. Cannot stop now."
    ;;
esac

echo ""

# --- Scale EKS Node Group to 0 ---
echo "[2/2] Scaling EKS node group to 0: ${NODEGROUP_NAME}"

NODEGROUP_EXISTS=$(aws eks describe-nodegroup \
  --cluster-name "${CLUSTER_NAME}" \
  --nodegroup-name "${NODEGROUP_NAME}" \
  --region "${REGION}" \
  --query 'nodegroup.status' \
  --output text 2>/dev/null || echo "not-found")

if [[ "${NODEGROUP_EXISTS}" == "not-found" ]]; then
  echo "  -> Node group not found. Skipping."
else
  # maxSize, from the module that declares it — see the header. Needed because
  # --scaling-config is passed whole, and the alternative (hardcoding it here)
  # is how this script came to hold a third, wrong opinion about the group's
  # shape: it said 3 for both environments, while dev and prod both declare 4.
  if ! command -v terraform >/dev/null 2>&1; then
    cat >&2 <<EOF
Error: terraform is not on PATH, and it is where maxSize comes from.

The scaling config is passed to AWS whole, and this script takes maxSize from
the module that declares it rather than keeping a copy:

  cd terraform/environments/${ENV} && terraform output -raw node_group_scaling

Install terraform, or scale the group by hand:

  aws eks update-nodegroup-config --cluster-name ${CLUSTER_NAME} \\
    --nodegroup-name ${NODEGROUP_NAME} --region ${REGION} \\
    --scaling-config minSize=0,maxSize=4,desiredSize=0
EOF
    exit 1
  fi

  SCALING="$(cd "$TF_DIR" && terraform output -raw node_group_scaling 2>/dev/null || true)"

  if [[ -z "${SCALING}" ]]; then
    cat >&2 <<EOF
Error: no node_group_scaling output in terraform/environments/${ENV}.

The environment has to be applied before this script can read the maxSize it
passes:

  cd terraform/environments/${ENV} && terraform apply plan.out

If the state exists but the output does not, the root module predates that
output: re-apply, or scale the group by hand.
EOF
    exit 1
  fi

  # Shape check — see the same block in start-env.sh for why this exists
  # alongside `terraform output -raw`, which already refuses a non-string.
  read -r _CONFIGURED_MIN MAX_NODES _CONFIGURED_DESIRED <<< "${SCALING}"
  if [[ ! "${MAX_NODES:-}" =~ ^[0-9]+$ ]]; then
    echo "Error: node_group_scaling should read \"<min> <max> <desired>\", got '${SCALING}'." >&2
    exit 1
  fi

  CURRENT_SCALING=$(aws eks describe-nodegroup \
    --cluster-name "${CLUSTER_NAME}" \
    --nodegroup-name "${NODEGROUP_NAME}" \
    --region "${REGION}" \
    --query 'nodegroup.scalingConfig.[minSize,maxSize,desiredSize]' \
    --output text)
  read -r CURRENT_MIN CURRENT_MAX CURRENT_DESIRED <<< "${CURRENT_SCALING}"

  if [[ "${CURRENT_MIN}" == "0" && "${CURRENT_DESIRED}" == "0" ]]; then
    echo "  -> Node group already at 0 nodes. No action needed."
  else
    echo "  -> Currently min ${CURRENT_MIN}, max ${CURRENT_MAX}, desired ${CURRENT_DESIRED} — scaling to 0."

    aws eks update-nodegroup-config \
      --cluster-name "${CLUSTER_NAME}" \
      --nodegroup-name "${NODEGROUP_NAME}" \
      --scaling-config "minSize=0,maxSize=${MAX_NODES},desiredSize=0" \
      --region "${REGION}" > /dev/null
    echo "  -> Scaled to 0. Nodes will terminate within a few minutes."
  fi
fi

echo ""
echo "============================================"
echo "  Environment ${ENV} is stopping."
echo ""
echo "  Still running (you pay for):"
echo "    - EKS control plane (~\$3.30/day)"
echo "    - Any EBS volumes attached to nodes"
echo ""
echo "  Stopped (no charge):"
echo "    - EC2 instances (node group)"
echo "    - RDS instance (when fully stopped)"
echo ""
echo "  Note: the node group is now below what Terraform declares (min 2 /"
echo "  desired 2). A 'terraform apply' will scale it back up and undo this stop."
echo ""
echo "  To fully destroy: terraform destroy"
echo "  To restart:       ./scripts/start-env.sh ${ENV}"
echo "============================================"
