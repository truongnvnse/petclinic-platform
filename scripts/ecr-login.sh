#!/usr/bin/env bash
set -euo pipefail

#
# ecr-login.sh — Authenticate Docker to the petclinic ECR registry
#
# PETPLAT-21. Wraps `aws ecr get-login-password` and pipes the token straight
# into `docker login`, so the credential never lands in the process table, a
# shell history file, or a log.
#
# Usage:
#   ./scripts/ecr-login.sh
#   ./scripts/ecr-login.sh --region eu-west-1
#   ./scripts/ecr-login.sh --profile petclinic-sso
#   ./scripts/ecr-login.sh --registry 123456789012.dkr.ecr.eu-central-1.amazonaws.com
#
# The account is discovered from the caller identity, so there is no account ID
# to keep in sync with the environment.
#
# Requires: aws CLI v2, docker. Portable across macOS and Linux — no GNU-only
# flags are used.
#

REGION="eu-central-1"
PROFILE=""
REGISTRY=""

usage() {
  cat <<'EOF'
Usage: ecr-login.sh [options]

Options:
  --region <region>    AWS region of the registry (default: eu-central-1)
  --profile <name>     AWS CLI profile to use (default: ambient credentials)
  --registry <uri>     Registry hostname to log in to (default: derived from
                       the caller identity and the region)
  -h, --help           Show this help

Examples:
  ./scripts/ecr-login.sh
  ./scripts/ecr-login.sh --region eu-west-1
  ./scripts/ecr-login.sh --profile petclinic-sso
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --region)
      [[ $# -ge 2 ]] || { echo "Error: --region requires a value" >&2; exit 1; }
      REGION="$2"; shift 2 ;;
    --profile)
      [[ $# -ge 2 ]] || { echo "Error: --profile requires a value" >&2; exit 1; }
      PROFILE="$2"; shift 2 ;;
    --registry)
      [[ $# -ge 2 ]] || { echo "Error: --registry requires a value" >&2; exit 1; }
      REGISTRY="$2"; shift 2 ;;
    -h|--help)
      usage; exit 0 ;;
    *)
      echo "Error: unknown option '$1'" >&2
      echo >&2
      usage >&2
      exit 1 ;;
  esac
done

for cmd in aws docker; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Error: '$cmd' not found on PATH." >&2
    exit 1
  fi
done

# Shared AWS CLI arguments. Always non-empty, so "${AWS_OPTS[@]}" is safe even
# under `set -u` on bash 3.2.
AWS_OPTS=(--region "$REGION")
if [[ -n "$PROFILE" ]]; then
  AWS_OPTS+=(--profile "$PROFILE")
fi

if [[ -z "$REGISTRY" ]]; then
  ACCOUNT_ID=$(aws "${AWS_OPTS[@]}" sts get-caller-identity --query Account --output text)
  if [[ -z "$ACCOUNT_ID" || "$ACCOUNT_ID" == "None" ]]; then
    echo "Error: could not determine the AWS account ID from the caller identity." >&2
    exit 1
  fi
  REGISTRY="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com"
fi

echo "Logging in to ${REGISTRY} (region ${REGION})..."

# --password-stdin keeps the token out of argv. The password is a 12-hour ECR
# authorization token, not an IAM credential.
aws "${AWS_OPTS[@]}" ecr get-login-password \
  | docker login --username AWS --password-stdin "$REGISTRY"

echo "Logged in to ${REGISTRY}."
