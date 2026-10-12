#!/usr/bin/env bash
set -euo pipefail

#
# render-ingress.sh — Fill the Terraform-owned values into the Ingress manifest
#
# PETPLAT-30. k8s/base/ingress/ingress.yaml.tpl carries two placeholders —
# <ACM_CERTIFICATE_ARN> and <ALB_SECURITY_GROUP_ID> — because both are created
# by Terraform, neither is imported, and so both change on every full rebuild of
# an environment. This script reads them from the environment's Terraform
# outputs and writes the manifest kubectl applies.
#
# Why a script rather than a note telling you to paste two values by hand: a
# stale value here does not fail. `<ACM_CERTIFICATE_ARN>` is a valid YAML scalar
# and metadata.annotations is an unconstrained string map, so `kubectl apply`
# succeeds either way — with the previous rebuild's certificate and security
# group. The error surfaces later as reconcile errors on the Ingress, which
# reads as a load-balancer problem rather than a stale copy-paste. Reading the
# outputs at render time removes the step where that mistake happens.
#
# The rendered file is gitignored: it carries the account ID and resource IDs of
# whichever environment rendered it last. The .tpl is the tracked artifact.
#
# Usage:
#   ./scripts/render-ingress.sh
#   ./scripts/render-ingress.sh --env prod
#   ./scripts/render-ingress.sh --dry-run
#

ENV="dev"
DRY_RUN="false"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

TEMPLATE="${REPO_ROOT}/k8s/base/ingress/ingress.yaml.tpl"
OUTPUT="${REPO_ROOT}/k8s/base/ingress/ingress.yaml"

usage() {
  cat <<'EOF'
Usage: render-ingress.sh [options]

Reads the acm_certificate_arn and alb_sg_id Terraform outputs for an
environment and substitutes them into k8s/base/ingress/ingress.yaml.tpl,
writing k8s/base/ingress/ingress.yaml.

Options:
  --env <dev|prod>   Environment whose Terraform outputs are read
                     (default: dev)
  --dry-run          Print the rendered manifest without writing it
  -h, --help         Show this help

Examples:
  ./scripts/render-ingress.sh
  ./scripts/render-ingress.sh --env prod
  ./scripts/render-ingress.sh --dry-run

After rendering:
  kubectl apply -f k8s/base/ingress/ingress.yaml
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --env)
      [[ $# -ge 2 ]] || { echo "Error: --env requires a value" >&2; exit 1; }
      ENV="$2"; shift 2 ;;
    --dry-run)
      DRY_RUN="true"; shift ;;
    -h|--help)
      usage; exit 0 ;;
    *)
      echo "Error: unknown option '$1'" >&2
      echo >&2
      usage >&2
      exit 1 ;;
  esac
done

if [[ "$ENV" != "dev" && "$ENV" != "prod" ]]; then
  echo "Error: --env must be 'dev' or 'prod', got '${ENV}'" >&2
  exit 1
fi

if [[ ! -f "$TEMPLATE" ]]; then
  echo "Error: template not found at ${TEMPLATE}" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Refuse prod
# ---------------------------------------------------------------------------
#
# The template pins `namespace: petclinic-dev`, because an Ingress has to live
# in the namespace of the Service it targets and there is one template rather
# than one per environment. Rendering it for prod would therefore produce a
# manifest that applies cleanly, lands in petclinic-dev, and carries prod's
# certificate — an Ingress in the wrong namespace, pointing at a Service that
# may not exist there, which is exactly the class of silent misconfiguration
# this script exists to remove. Refusing is better than a warning nobody reads.
#
# The template's own header says prod needs its own copy. When that copy exists
# (petclinic.gannet.click, its own certificate, namespace petclinic-prod), this
# guard is the thing to replace — with a check that the template's namespace
# matches the requested environment, so it keeps holding for both.
if [[ "$ENV" != "dev" ]]; then
  cat >&2 <<EOF
Error: there is no Ingress template for the ${ENV} environment.

k8s/base/ingress/ingress.yaml.tpl pins namespace: petclinic-dev, so rendering
it for ${ENV} would produce a manifest in the wrong namespace. Prod needs its
own template first — see the "Namespace" note in that file's header.
EOF
  exit 1
fi

TF_DIR="${REPO_ROOT}/terraform/environments/${ENV}"
if [[ ! -d "$TF_DIR" ]]; then
  echo "Error: no Terraform root module at ${TF_DIR}" >&2
  exit 1
fi

if ! command -v terraform >/dev/null 2>&1; then
  echo "Error: terraform is not on PATH; it is what supplies the two values." >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Read the two outputs
# ---------------------------------------------------------------------------

# `terraform output` exits non-zero when the output does not exist, which is the
# case before the module that declares it has been applied — hence `|| true` and
# the emptiness checks below rather than a bare assignment under `set -e`.
read_output() {
  (cd "$TF_DIR" && terraform output -raw "$1" 2>/dev/null || true)
}

echo "==> Reading Terraform outputs from terraform/environments/${ENV}"
ACM_ARN="$(read_output acm_certificate_arn)"
ALB_SG_ID="$(read_output alb_sg_id)"

# `terraform output -raw` prints the literal string "None" for a null value, so
# emptiness alone is not enough to tell "not applied" from "applied as null".
# A string rather than an array on purpose: macOS ships bash 3.2, where `set -u`
# makes `"$arr"` on an empty array an unbound-variable error, and this script has
# to run before the user has any reason to have installed a newer one.
missing=""
if [[ -z "$ACM_ARN" || "$ACM_ARN" == "None" ]]; then
  missing="acm_certificate_arn"
fi
if [[ -z "$ALB_SG_ID" || "$ALB_SG_ID" == "None" ]]; then
  missing="${missing:+${missing}, }alb_sg_id"
fi

if [[ -n "$missing" ]]; then
  cat >&2 <<EOF
Error: these Terraform outputs are not available: ${missing}

They are created by the dns and vpc modules, so the environment has to be
applied before this script can render anything:

  cd terraform/environments/${ENV}
  terraform init
  terraform plan -out plan.out
  terraform apply plan.out

Rendering with either value empty would produce a manifest that applies
cleanly and then never provisions the ALB, which is the failure this script
exists to prevent.
EOF
  exit 1
fi

echo "    acm_certificate_arn = ${ACM_ARN}"
echo "    alb_sg_id           = ${ALB_SG_ID}"

# ---------------------------------------------------------------------------
# Substitute
# ---------------------------------------------------------------------------

CONTENT="$(cat "$TEMPLATE")"

# Parameter expansion rather than sed: the ARN contains '/' and ':', so sed
# would need a delimiter it does not appear in, and the value would still have
# to be escaped for '&' and '\'. Here the replacement is literal.
CONTENT="${CONTENT//<ACM_CERTIFICATE_ARN>/$ACM_ARN}"
CONTENT="${CONTENT//<ALB_SECURITY_GROUP_ID>/$ALB_SG_ID}"

# Belt and braces: the two lines above are the only substitution this script
# performs, so anything still in angle brackets means the template gained a
# placeholder that nothing fills. Writing the file anyway would produce exactly
# the silently-broken manifest described in the header.
if [[ "$CONTENT" == *"<ACM_CERTIFICATE_ARN>"* || "$CONTENT" == *"<ALB_SECURITY_GROUP_ID>"* ]]; then
  echo "Error: a placeholder survived substitution — this is a bug in the script." >&2
  exit 1
fi

BANNER="# GENERATED FILE — do not edit.
#
# Rendered from k8s/base/ingress/ingress.yaml.tpl by scripts/render-ingress.sh
# for the ${ENV} environment. Edit the .tpl instead, then re-render:
#
#   ./scripts/render-ingress.sh --env ${ENV}
#
# This file is gitignored because it carries ${ENV}'s account ID and resource
# IDs. Every time the environment is rebuilt the certificate and the security
# group are recreated, so a copy kept from a previous rebuild is stale — and a
# stale copy applies without error.
"

RENDERED="${BANNER}${CONTENT}"

if [[ "$DRY_RUN" == "true" ]]; then
  echo
  echo "==> --dry-run: not writing ${OUTPUT#"${REPO_ROOT}"/}"
  echo
  printf '%s\n' "$RENDERED"
  exit 0
fi

printf '%s\n' "$RENDERED" > "$OUTPUT"

echo
echo "==> Wrote ${OUTPUT#"${REPO_ROOT}"/}"
echo
echo "Next:"
echo
echo "  kubectl apply -f k8s/base/ingress/ingress.yaml"
echo "  kubectl get ingress api-gateway -n petclinic-${ENV} --watch"
echo
echo "Then read the ALB hostname for the Route 53 record (PETPLAT-31):"
echo
echo "  kubectl get ingress api-gateway -n petclinic-${ENV} \\"
echo "    -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'"
