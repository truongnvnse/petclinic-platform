#!/usr/bin/env bash
set -euo pipefail

#
# bootstrap-state.sh — Provision the Terraform remote state backend
#
# Creates the two resources Terraform cannot create for itself:
#
#   S3 bucket       petclinic-terraform-state-{account-id}
#                   versioned, SSE-S3 encrypted, all public access blocked,
#                   HTTPS-only bucket policy
#
#   DynamoDB table  petclinic-terraform-locks
#                   LockID (String) partition key, on-demand billing
#
# Why outside Terraform? The state bucket would have to store its own state —
# a chicken-and-egg problem. This is a ONE-TIME setup, run before the first
# `terraform init` in terraform/environments/{dev,prod}/.
#
# The script is idempotent: re-running it re-applies the configuration and
# leaves existing resources untouched, so it is safe to run again after a
# partial failure or to verify drift.
#
# Usage:
#   ./scripts/bootstrap-state.sh
#   ./scripts/bootstrap-state.sh --region eu-central-1
#   ./scripts/bootstrap-state.sh --help
#
# Prerequisites: AWS CLI v2, credentials with permission to create S3 buckets
# and DynamoDB tables (see docs/onboarding.md).
#

REGION="${AWS_DEFAULT_REGION:-eu-central-1}"

usage() {
  cat <<'EOF'
Usage: bootstrap-state.sh [--region <aws-region>]

Provisions the S3 bucket and DynamoDB table used for Terraform remote state.
Safe to run multiple times.

Options:
  -r, --region <region>   AWS region (default: eu-central-1, or $AWS_DEFAULT_REGION)
  -h, --help              Show this help

Examples:
  ./scripts/bootstrap-state.sh
  ./scripts/bootstrap-state.sh --region eu-central-1
EOF
}

# --- Parse arguments ---------------------------------------------------------

while [[ $# -gt 0 ]]; do
  case "$1" in
    -r|--region)
      if [[ $# -lt 2 || -z "${2:-}" ]]; then
        echo "Error: --region requires a value" >&2
        usage >&2
        exit 1
      fi
      REGION="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Error: unknown argument '$1'" >&2
      usage >&2
      exit 1
      ;;
  esac
done

# --- Resolve resource names --------------------------------------------------
#
# The bucket name embeds the account ID so it is globally unique without
# hardcoding a value that changes per student. The lock table is shared by
# both environments — the state key prefix is what separates dev from prod.

if ! command -v aws >/dev/null 2>&1; then
  echo "Error: AWS CLI not found. Install it and configure credentials first." >&2
  exit 1
fi

ACCOUNT_ID=$(aws sts get-caller-identity --query 'Account' --output text)

BUCKET_NAME="petclinic-terraform-state-${ACCOUNT_ID}"
TABLE_NAME="petclinic-terraform-locks"

echo "============================================"
echo "  Terraform state bootstrap"
echo "  Account:  ${ACCOUNT_ID}"
echo "  Region:   ${REGION}"
echo "  Bucket:   ${BUCKET_NAME}"
echo "  Table:    ${TABLE_NAME}"
echo "============================================"
echo ""

# --- S3 bucket ---------------------------------------------------------------

echo "[1/6] S3 bucket"

# head-bucket returns 404 when the bucket does not exist, 403 when it exists
# but belongs to another account. Distinguish the two so we never try to
# "create" a bucket name that is already taken by someone else.
if aws s3api head-bucket --bucket "${BUCKET_NAME}" --region "${REGION}" 2>/dev/null; then
  echo "  -> already exists, skipping creation"
else
  HEAD_ERR=$(aws s3api head-bucket --bucket "${BUCKET_NAME}" --region "${REGION}" 2>&1 || true)
  if [[ "${HEAD_ERR}" != *"404"* && "${HEAD_ERR}" != *"Not Found"* ]]; then
    echo "Error: cannot access bucket '${BUCKET_NAME}':" >&2
    echo "  ${HEAD_ERR}" >&2
    echo "  If it exists in another account, choose a different bucket name." >&2
    exit 1
  fi

  # us-east-1 is the only region that must NOT send a LocationConstraint.
  if [[ "${REGION}" == "us-east-1" ]]; then
    aws s3api create-bucket \
      --bucket "${BUCKET_NAME}" \
      --region "${REGION}"
  else
    aws s3api create-bucket \
      --bucket "${BUCKET_NAME}" \
      --region "${REGION}" \
      --create-bucket-configuration "LocationConstraint=${REGION}"
  fi
  echo "  -> created"
fi

echo "[2/6] S3 versioning"

# Versioning is what lets you recover a corrupted or truncated state file:
# every `terraform apply` overwrites the state object, and without versioning
# the previous state is gone.
aws s3api put-bucket-versioning \
  --bucket "${BUCKET_NAME}" \
  --region "${REGION}" \
  --versioning-configuration Status=Enabled
echo "  -> enabled"

echo "[3/6] S3 default encryption (SSE-S3 / AES256)"

# Applies to every object written without explicit encryption headers —
# Terraform does not set any, so all state objects are encrypted at rest.
aws s3api put-bucket-encryption \
  --bucket "${BUCKET_NAME}" \
  --region "${REGION}" \
  --server-side-encryption-configuration \
  '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'
echo "  -> enabled"

echo "[4/6] S3 public access block (all 4 settings)"

# State files contain every resource attribute Terraform manages, including
# passwords in plaintext. Blocking all four settings makes public exposure
# impossible even if a future bucket policy tries to allow it.
aws s3api put-public-access-block \
  --bucket "${BUCKET_NAME}" \
  --region "${REGION}" \
  --public-access-block-configuration \
  'BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true'
echo "  -> blocked"

echo "[5/6] S3 HTTPS-only policy + tags"

# Security controls require HTTPS in transit for the state bucket.
# This is a Deny-only policy: it grants nothing, so it is not a "public"
# policy and is compatible with BlockPublicPolicy above.
BUCKET_POLICY=$(cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "DenyUnencryptedTransport",
      "Effect": "Deny",
      "Principal": "*",
      "Action": "s3:*",
      "Resource": [
        "arn:aws:s3:::${BUCKET_NAME}",
        "arn:aws:s3:::${BUCKET_NAME}/*"
      ],
      "Condition": {
        "Bool": { "aws:SecureTransport": "false" }
      }
    }
  ]
}
EOF
)

aws s3api put-bucket-policy \
  --bucket "${BUCKET_NAME}" \
  --region "${REGION}" \
  --policy "${BUCKET_POLICY}"

# These resources are created outside Terraform and shared by both
# environments, so they carry Project/ManagedBy/Purpose rather than the
# per-environment Environment tag used by Terraform-managed resources.
aws s3api put-bucket-tagging \
  --bucket "${BUCKET_NAME}" \
  --region "${REGION}" \
  --tagging "TagSet=[{Key=Project,Value=petclinic},{Key=ManagedBy,Value=bootstrap-state.sh},{Key=Purpose,Value=terraform-state}]"
echo "  -> applied"

# --- DynamoDB lock table -----------------------------------------------------

echo "[6/6] DynamoDB lock table"

if aws dynamodb describe-table \
     --table-name "${TABLE_NAME}" \
     --region "${REGION}" >/dev/null 2>&1; then
  echo "  -> already exists, verifying key schema"

  # A table with the wrong key silently fails every lock attempt, so fail
  # loudly here instead of during the next `terraform apply`.
  KEY_SCHEMA=$(aws dynamodb describe-table \
    --table-name "${TABLE_NAME}" \
    --region "${REGION}" \
    --query 'Table.KeySchema[?KeyType==`HASH`].AttributeName | [0]' \
    --output text)

  if [[ "${KEY_SCHEMA}" != "LockID" ]]; then
    echo "Error: table '${TABLE_NAME}' has partition key '${KEY_SCHEMA}', expected 'LockID'." >&2
    echo "  Terraform locking will not work against this table." >&2
    exit 1
  fi
  echo "  -> partition key is LockID"
else
  # LockID is the key Terraform's S3 backend hardcodes for lock records.
  # PAY_PER_REQUEST keeps a table that is idle 99% of the time free.
  aws dynamodb create-table \
    --table-name "${TABLE_NAME}" \
    --region "${REGION}" \
    --attribute-definitions AttributeName=LockID,AttributeType=S \
    --key-schema AttributeName=LockID,KeyType=HASH \
    --billing-mode PAY_PER_REQUEST \
    --tags Key=Project,Value=petclinic Key=ManagedBy,Value=bootstrap-state.sh Key=Purpose,Value=terraform-state \
    >/dev/null

  echo "  -> created, waiting for ACTIVE"
  aws dynamodb wait table-exists \
    --table-name "${TABLE_NAME}" \
    --region "${REGION}"
  echo "  -> ACTIVE"
fi

# --- Done --------------------------------------------------------------------

echo ""
echo "============================================"
echo "  Remote state backend is ready."
echo ""
echo "  Next: initialize both environments"
echo ""
echo "    cd terraform/environments/dev && terraform init"
echo "    cd terraform/environments/prod && terraform init"
echo "============================================"
