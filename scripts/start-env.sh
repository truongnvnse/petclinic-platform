#!/usr/bin/env bash
set -euo pipefail

#
# start-env.sh — Resume your AWS environment after stopping it
#
# Starts RDS and scales the EKS node group back up to the values Terraform
# declares. Waits for both to be ready before declaring success.
#
# Usage:
#   ./scripts/start-env.sh dev
#   ./scripts/start-env.sh prod
#
# ---------------------------------------------------------------------------
# Where the node counts come from
#
# Not from constants in this file. stop-env.sh scales the node group to zero,
# and the values to restore it to are declared in the environment's root module
# (terraform/environments/{env}/main.tf → module "eks" → node_min_size and
# friends). That is the only place they live. This script reads them back from
# the node_group_scaling output, so editing the Terraform config changes what
# the next start restores — rather than leaving this script to fight it with a
# stale copy, which is what it used to do.
#
# The consequence worth knowing: this script now needs the environment to have
# been applied, because that is what makes the output exist. It says so plainly
# rather than guessing when it does not.
# ---------------------------------------------------------------------------

REGION="${AWS_DEFAULT_REGION:-eu-central-1}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

usage() {
  echo "Usage: $0 <environment>"
  echo "  environment: dev | prod"
  echo ""
  echo "Examples:"
  echo "  $0 dev      # Start dev environment"
  echo "  $0 prod     # Start prod environment"
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
echo "  Starting environment: ${ENV}"
echo "  Region: ${REGION}"
echo "============================================"
echo ""

# --- Start RDS Instance ---
echo "[1/2] Starting RDS instance: ${RDS_INSTANCE_ID}"

RDS_STATUS=$(aws rds describe-db-instances \
  --db-instance-identifier "${RDS_INSTANCE_ID}" \
  --region "${REGION}" \
  --query 'DBInstances[0].DBInstanceStatus' \
  --output text 2>/dev/null || echo "not-found")

case "${RDS_STATUS}" in
  stopped)
    aws rds start-db-instance \
      --db-instance-identifier "${RDS_INSTANCE_ID}" \
      --region "${REGION}" > /dev/null
    echo "  -> RDS start initiated. Waiting for it to become available..."
    echo "     (This typically takes 3-8 minutes)"
    aws rds wait db-instance-available \
      --db-instance-identifier "${RDS_INSTANCE_ID}" \
      --region "${REGION}" 2>/dev/null || true
    echo "  -> RDS is available."
    ;;
  available)
    echo "  -> RDS is already running. No action needed."
    ;;
  starting)
    echo "  -> RDS is already starting. Waiting..."
    aws rds wait db-instance-available \
      --db-instance-identifier "${RDS_INSTANCE_ID}" \
      --region "${REGION}" 2>/dev/null || true
    echo "  -> RDS is available."
    ;;
  not-found)
    echo "  -> RDS instance not found. Skipping."
    ;;
  *)
    echo "  -> RDS is in '${RDS_STATUS}' state. Cannot start now."
    ;;
esac

echo ""

# --- Scale EKS Node Group Back Up ---
echo "[2/2] Scaling EKS node group: ${NODEGROUP_NAME}"

NODEGROUP_EXISTS=$(aws eks describe-nodegroup \
  --cluster-name "${CLUSTER_NAME}" \
  --nodegroup-name "${NODEGROUP_NAME}" \
  --region "${REGION}" \
  --query 'nodegroup.status' \
  --output text 2>/dev/null || echo "not-found")

if [[ "${NODEGROUP_EXISTS}" == "not-found" ]]; then
  # A destroyed environment lands here, and the scaling values are not needed:
  # there is no group to restore. This is also why the Terraform read below sits
  # inside the else branch rather than before it — a full rebuild does not need
  # the outputs, so it should not fail for want of them.
  echo "  -> Node group not found. Skipping."
else
  # The target values, from the root module that declares them.
  if ! command -v terraform >/dev/null 2>&1; then
    cat >&2 <<EOF
Error: terraform is not on PATH, and it is where the node counts live.

This script restores the node group to the values in
terraform/environments/${ENV}/main.tf rather than to a copy of them kept here,
so it needs to read them back:

  cd terraform/environments/${ENV} && terraform output -raw node_group_scaling

Install terraform, or scale the group by hand:

  aws eks update-nodegroup-config --cluster-name ${CLUSTER_NAME} \\
    --nodegroup-name ${NODEGROUP_NAME} --region ${REGION} \\
    --scaling-config minSize=2,maxSize=4,desiredSize=2
EOF
    exit 1
  fi

  SCALING="$(cd "$TF_DIR" && terraform output -raw node_group_scaling 2>/dev/null || true)"

  if [[ -z "${SCALING}" ]]; then
    cat >&2 <<EOF
Error: no node_group_scaling output in terraform/environments/${ENV}.

The environment has to be applied before this script can read the node counts
it restores — the output is what carries them:

  cd terraform/environments/${ENV}
  terraform init
  terraform plan -out plan.out
  terraform apply plan.out

If the state exists but the output does not, the root module predates that
output: re-apply, or scale the group by hand.
EOF
    exit 1
  fi

  # Shape check before use. `terraform output -raw` already refuses a non-string
  # output, so this catches the other way the value can arrive wrong: a string
  # that is not three numbers. Without it, a malformed value would reach
  # --scaling-config and fail there, with an AWS error naming neither this
  # script nor the output it read.
  read -r MIN_NODES MAX_NODES DESIRED_NODES <<< "${SCALING}"
  for value in "${MIN_NODES:-}" "${MAX_NODES:-}" "${DESIRED_NODES:-}"; do
    if [[ ! "${value}" =~ ^[0-9]+$ ]]; then
      echo "Error: node_group_scaling should read \"<min> <max> <desired>\", got '${SCALING}'." >&2
      exit 1
    fi
  done

  echo "  -> Target from terraform/environments/${ENV}: min ${MIN_NODES}, max ${MAX_NODES}, desired ${DESIRED_NODES}"

  # --query with --output text rather than a JSON parser: the three values come
  # back tab-separated on one line, which `read` splits without needing jq. No
  # other script in this repo depends on jq, and this is not a good reason to
  # start.
  CURRENT_SCALING=$(aws eks describe-nodegroup \
    --cluster-name "${CLUSTER_NAME}" \
    --nodegroup-name "${NODEGROUP_NAME}" \
    --region "${REGION}" \
    --query 'nodegroup.scalingConfig.[minSize,maxSize,desiredSize]' \
    --output text)
  read -r CURRENT_MIN CURRENT_MAX CURRENT_DESIRED <<< "${CURRENT_SCALING}"

  # All three compared, not just desired. After a stop the group sits at
  # min 0 / desired 0, so desired alone would be enough to trigger the scale —
  # but a group whose desired count happens to match while its min or max does
  # not would be left that way, and the next terraform plan would report drift
  # this script claimed to have cleared.
  if [[ "${CURRENT_MIN}" == "${MIN_NODES}" &&
        "${CURRENT_MAX}" == "${MAX_NODES}" &&
        "${CURRENT_DESIRED}" == "${DESIRED_NODES}" ]]; then
    echo "  -> Already at min ${CURRENT_MIN}, max ${CURRENT_MAX}, desired ${CURRENT_DESIRED}. No action needed."
  else
    echo "  -> Currently min ${CURRENT_MIN}, max ${CURRENT_MAX}, desired ${CURRENT_DESIRED} — scaling."

    aws eks update-nodegroup-config \
      --cluster-name "${CLUSTER_NAME}" \
      --nodegroup-name "${NODEGROUP_NAME}" \
      --scaling-config "minSize=${MIN_NODES},maxSize=${MAX_NODES},desiredSize=${DESIRED_NODES}" \
      --region "${REGION}" > /dev/null
    echo "     (This typically takes 2-5 minutes)"

    # Wait for nodegroup to be ACTIVE
    aws eks wait nodegroup-active \
      --cluster-name "${CLUSTER_NAME}" \
      --nodegroup-name "${NODEGROUP_NAME}" \
      --region "${REGION}" 2>/dev/null || true
    echo "  -> Node group is active."
  fi
fi

echo ""
echo "============================================"
echo "  Environment ${ENV} is ready."
echo ""
echo "  Update kubeconfig:"
echo "    aws eks update-kubeconfig --name ${CLUSTER_NAME} --region ${REGION}"
echo ""
echo "  Verify:"
echo "    kubectl get nodes"
echo "    kubectl get pods -n petclinic-${ENV}"
echo "============================================"
