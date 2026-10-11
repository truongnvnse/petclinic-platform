#!/usr/bin/env bash
set -euo pipefail

#
# validate-helm.sh — lint, render and dry-run every Petclinic release
#
# The chart in helm/petclinic-service/ is generic: it names no service and no
# environment, and the eight services and two environments exist only as
# combinations of values files. That means a broken release is not something
# `helm lint helm/petclinic-service/` can find — the chart on its own renders
# `image: "/:"` and is perfectly valid YAML. Only the sixteen (service, env)
# pairs are real, so this script renders all sixteen and dry-runs each.
#
# For every pair it runs three checks, in order:
#
#   1. helm lint    — chart-level problems: unknown values, bad templates,
#                     missing files. Runs once per pair because the values files
#                     are half the input.
#   2. helm template — renders the manifests. This is where `required` and `tpl`
#                     failures surface, so it catches a release whose values
#                     files are individually valid but jointly incomplete.
#   3. kubectl apply --dry-run=client — schema-level problems: a field the API
#                     does not have, a bad label value, an unparseable quantity.
#
# Note what check 3 does NOT prove. `--dry-run=client` never contacts the API
# server, so it validates against kubectl's own knowledge of the built-in types
# and nothing else. It cannot tell you that a ServiceAccount does not exist, that
# a Secret has not synced, that a namespace is missing, or that the cluster is
# even reachable. A clean run means the YAML is well-formed and the manifests are
# internally consistent — it is not a deployment test.
#
# Usage:
#   ./scripts/validate-helm.sh                  # all 16 releases
#   ./scripts/validate-helm.sh --env dev        # the 8 dev releases
#   ./scripts/validate-helm.sh --service vets-service
#   ./scripts/validate-helm.sh --env prod --service api-gateway
#   ./scripts/validate-helm.sh --keep           # leave the rendered YAML behind
#
# Exit status is 0 only if every selected release passed every check. Failures
# are reported as they happen and the run continues, so one bad values file does
# not hide the state of the other fifteen.
#

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHART_DIR="${REPO_ROOT}/helm/petclinic-service"
VALUES_DIR="${REPO_ROOT}/helm-values"

# Order matters for readability of the output only — it is the startup order
# from docs/technical-spec.md, which is also the order you would install them in.
ALL_SERVICES=(
  config-server
  discovery-server
  api-gateway
  customers-service
  visits-service
  vets-service
  genai-service
  admin-server
)

ALL_ENVS=(dev prod)

usage() {
  cat <<'EOF'
Usage: validate-helm.sh [--env dev|prod] [--service <name>] [--keep]

  --env <env>        Validate one environment (default: both)
  --service <name>   Validate one service (default: all 8)
  --keep             Keep the rendered manifests in a temp dir and print its path
  -h, --help         Show this help

Services:
  config-server  discovery-server  api-gateway  customers-service
  visits-service  vets-service  genai-service  admin-server
EOF
}

ENV_FILTER=""
SERVICE_FILTER=""
KEEP=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --env)
      [[ $# -ge 2 ]] || { echo "Error: --env needs a value" >&2; usage; exit 1; }
      ENV_FILTER="$2"
      shift 2
      ;;
    --service)
      [[ $# -ge 2 ]] || { echo "Error: --service needs a value" >&2; usage; exit 1; }
      SERVICE_FILTER="$2"
      shift 2
      ;;
    --keep)
      KEEP=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Error: unknown argument '$1'" >&2
      usage
      exit 1
      ;;
  esac
done

if [[ -n "${ENV_FILTER}" && "${ENV_FILTER}" != "dev" && "${ENV_FILTER}" != "prod" ]]; then
  echo "Error: --env must be 'dev' or 'prod', got '${ENV_FILTER}'" >&2
  exit 1
fi

if [[ -n "${SERVICE_FILTER}" ]]; then
  found=0
  for s in "${ALL_SERVICES[@]}"; do
    [[ "${s}" == "${SERVICE_FILTER}" ]] && found=1
  done
  if [[ "${found}" -eq 0 ]]; then
    echo "Error: unknown service '${SERVICE_FILTER}'" >&2
    echo "Known services: ${ALL_SERVICES[*]}" >&2
    exit 1
  fi
fi

for tool in helm kubectl; do
  if ! command -v "${tool}" >/dev/null 2>&1; then
    echo "Error: ${tool} is not on PATH" >&2
    exit 1
  fi
done

if [[ ! -d "${CHART_DIR}" ]]; then
  echo "Error: chart not found at ${CHART_DIR}" >&2
  exit 1
fi

RENDER_DIR="$(mktemp -d "${TMPDIR:-/tmp}/petclinic-helm.XXXXXX")"
if [[ "${KEEP}" -eq 1 ]]; then
  echo "Rendered manifests: ${RENDER_DIR}"
else
  trap 'rm -rf "${RENDER_DIR}"' EXIT
fi

SERVICES=()
for s in "${ALL_SERVICES[@]}"; do
  [[ -n "${SERVICE_FILTER}" && "${s}" != "${SERVICE_FILTER}" ]] && continue
  SERVICES+=("${s}")
done

ENVS=()
for e in "${ALL_ENVS[@]}"; do
  [[ -n "${ENV_FILTER}" && "${e}" != "${ENV_FILTER}" ]] && continue
  ENVS+=("${e}")
done

TOTAL=$(( ${#SERVICES[@]} * ${#ENVS[@]} ))
PASSED=0
FAILED=0

echo "============================================"
echo "  Helm validation: ${TOTAL} release(s)"
echo "  Chart:  ${CHART_DIR#"${REPO_ROOT}/"}"
echo "  helm:   $(helm version --short)"
echo "============================================"
echo ""

for env in "${ENVS[@]}"; do
  ENV_FILE="${VALUES_DIR}/${env}.yaml"
  if [[ ! -f "${ENV_FILE}" ]]; then
    echo "Error: missing env values file ${ENV_FILE}" >&2
    exit 1
  fi

  for service in "${SERVICES[@]}"; do
    SERVICE_FILE="${VALUES_DIR}/${service}.yaml"
    if [[ ! -f "${SERVICE_FILE}" ]]; then
      echo "Error: missing service values file ${SERVICE_FILE}" >&2
      exit 1
    fi

    RELEASE="${service}-${env}"
    RENDERED="${RENDER_DIR}/${RELEASE}.yaml"

    echo "--- ${RELEASE} ---"

    if ! helm lint "${CHART_DIR}" \
        -f "${SERVICE_FILE}" \
        -f "${ENV_FILE}" >"${RENDER_DIR}/${RELEASE}.lint" 2>&1; then
      echo "  FAIL  lint"
      sed 's/^/        /' "${RENDER_DIR}/${RELEASE}.lint"
      FAILED=$((FAILED + 1))
      echo ""
      continue
    fi
    echo "  ok    lint"

    # --namespace is passed so the rendered manifests carry the environment's
    # namespace even where a template falls back to .Release.Namespace rather
    # than the values files. It is the same namespace those files declare.
    if ! helm template "${RELEASE}" "${CHART_DIR}" \
        --namespace "petclinic-${env}" \
        -f "${SERVICE_FILE}" \
        -f "${ENV_FILE}" >"${RENDERED}" 2>"${RENDER_DIR}/${RELEASE}.tmpl.err"; then
      echo "  FAIL  template"
      sed 's/^/        /' "${RENDER_DIR}/${RELEASE}.tmpl.err"
      FAILED=$((FAILED + 1))
      echo ""
      continue
    fi
    echo "  ok    template ($(grep -c '^kind:' "${RENDERED}") resources)"

    # helm template writes only the rendered manifests — NOTES.txt is not part
    # of its output — so the file is pure YAML and needs no trimming before
    # kubectl sees it.
    if ! kubectl apply --dry-run=client -f "${RENDERED}" \
        >"${RENDER_DIR}/${RELEASE}.dryrun" 2>&1; then
      echo "  FAIL  dry-run"
      sed 's/^/        /' "${RENDER_DIR}/${RELEASE}.dryrun"
      FAILED=$((FAILED + 1))
      echo ""
      continue
    fi
    echo "  ok    dry-run"

    PASSED=$((PASSED + 1))
    echo ""
  done
done

echo "============================================"
echo "  ${PASSED}/${TOTAL} release(s) passed"
if [[ "${FAILED}" -gt 0 ]]; then
  echo "  ${FAILED} FAILED"
  echo "============================================"
  exit 1
fi
echo "============================================"
