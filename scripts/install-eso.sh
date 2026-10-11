#!/usr/bin/env bash
set -euo pipefail

#
# install-eso.sh — Install the External Secrets Operator on EKS
#
# PETPLAT-34. Installs the operator that syncs AWS Secrets Manager into
# Kubernetes Secrets, then wires up the three objects that make it usable:
# the external-secrets namespace, the external-secrets-sa service account, and
# the aws-secrets-manager ClusterSecretStore.
#
# Authentication is IRSA, not access keys: the service account is annotated with
# the role ARN Terraform created in the eks module (petclinic-{env}-eso-role),
# and the operator trades a token for temporary credentials through the
# cluster's OIDC provider. No AWS credential is stored in the cluster.
#
# Usage:
#   ./scripts/install-eso.sh
#   ./scripts/install-eso.sh --cluster petclinic-prod --env prod
#   ./scripts/install-eso.sh --role-arn arn:aws:iam::123456789012:role/petclinic-dev-eso-role
#   ./scripts/install-eso.sh --dry-run
#
# The role ARN is resolved in this order:
#   1. --role-arn
#   2. ESO_ROLE_ARN in the environment
#   3. `terraform output -raw eso_role_arn` in terraform/environments/{env}
#
# Requires: aws CLI v2, kubectl, curl. kubectl must already point at the
# cluster — run `aws eks update-kubeconfig --name <cluster> --region <region>`
# first (Terraform exports the exact command as kubeconfig_command).
#
# ---------------------------------------------------------------------------
# Helm install — the method actually in use since 2026-10-11
#
# The operator is installed with the upstream Helm chart. The commands, run
# against dev from the repository root:
#
#   helm repo add external-secrets https://charts.external-secrets.io
#   helm repo update
#
#   ESO_ROLE_ARN="$(terraform -chdir=terraform/environments/dev \
#     output -raw eso_role_arn)"
#
#   helm upgrade --install external-secrets external-secrets/external-secrets \
#     -n external-secrets --create-namespace \
#     --version 2.12.0 \
#     --take-ownership --force-conflicts \
#     --set serviceAccount.name=external-secrets-sa \
#     --set "serviceAccount.annotations.eks\.amazonaws\.com/role-arn=${ESO_ROLE_ARN}" \
#     --wait --timeout 5m
#
# Two of those flags only matter when adopting objects that already exist from
# an earlier bundle install, and they fix different things:
#
#   --take-ownership    bypasses Helm's own check for the
#                       meta.helm.sh/release-name annotation. Alone it is not
#                       enough.
#   --force-conflicts   resolves server-side-apply field-manager conflicts with
#                       the `kubectl` field manager. Without it the install
#                       stops with: Apply failed with 1 conflict: conflict with
#                       "kubectl": .metadata.labels.helm.sh/chart
#
# On a fresh cluster both are no-ops, so the command is safe to re-run after a
# destroy/rebuild. Note the chart renders the namespace from .Release.Namespace,
# so the entire class of bug described in the next two sections — the bundle's
# hardcoded `default` — cannot arise, and neither can the --server-side
# requirement: Helm 4 applies with server-side apply.
#
# installCRDs defaults to true and the chart keeps its CRDs in templates/crds/,
# NOT in crds/. They are therefore ordinary release resources. Do not
# `helm uninstall` this release to recover from a failed install — that deletes
# all 25 CRDs, and deleting a CRD deletes every ExternalSecret,
# ClusterSecretStore and SecretStore in the cluster. Recover by re-running
# `helm upgrade --install` with the flags above; the failed release is simply
# upgraded to the next revision.
#
# Verified 2026-10-11: release `external-secrets` rev 2 deployed, controller
# running as external-secrets-sa, both ExternalSecrets Ready=True, and a forced
# re-sync fetched petclinic/dev/openai-api-key from AWS with no errors.
#
# The sections below describe the release-bundle path this script still
# implements. That path is what the Helm install above replaced; it is kept
# because it is also where the namespace trap and the CRD size limit are
# written down.
#
# ---------------------------------------------------------------------------
# Why the release bundle is not applied as downloaded
#
# The published asset is a Helm-rendered bundle, and it is rendered against the
# chart's default namespace: all ten of its namespaced objects say
# `namespace: default`. Applying it unchanged puts the operator in `default`,
# not in `external-secrets`.
#
# Passing `-n external-secrets` does not fix it. kubectl refuses rather than
# overriding:
#
#   error: the namespace from the provided object "default" does not match the
#   namespace "external-secrets". You must pass '--namespace=default' to
#   perform this operation.
#
# So the bundle is rewritten before it is applied. `namespace: default` appears
# 16 times in v2.12.0 as a YAML field, in three shapes, and only one of them is
# metadata:
#
#   * metadata.namespace             — 10 namespaced objects
#   * subjects[].namespace           — the 2 ClusterRoleBindings and the
#                                      leaderelection RoleBinding, which grant
#                                      the operator its permissions
#   * webhooks[].clientConfig
#       .service.namespace           — the 3 ValidatingWebhookConfigurations,
#                                      which route admission requests
#
# A sed for `^  namespace: default` catches the first group and misses the other
# two, which is worse than not trying: the RBAC bindings would name a service
# account that does not exist and the webhooks would point at a service in
# another namespace. kustomize's namespace transformer knows the field specs for
# all three and rewrites them together.
#
# ---------------------------------------------------------------------------
# Three more `default` literals are NOT YAML namespace fields
#
# They are command-line arguments inside two container specs, so no namespace
# transformer can see them and the field-level check above cannot either:
#
#   --service-namespace=default   cert-controller Deployment
#   --secret-namespace=default    cert-controller Deployment
#   --dns-name=external-secrets-webhook.default.svc
#                                 webhook Deployment
#
# Leaving these is not cosmetic, and it is not a partial failure either. The
# cert-controller looks for the webhook's Service endpoints and TLS Secret in
# `default`, finds neither, and never becomes Ready; the webhook pod waits two
# minutes for a certificate that nothing writes and exits. So
# `kubectl rollout status deployment/external-secrets-webhook` — step 3 below —
# times out, and the error names a rollout, not a namespace. The fix is applied
# to the rendered output and asserted, like the field rewrite: a substitution
# that silently stopped matching is exactly the failure this is guarding.
#
# The bundle does not contain a Namespace object, so this script creates it.
#
# ---------------------------------------------------------------------------
# Version pinning
#
# ESO_VERSION is pinned to an exact release tag. The bundle is fetched from
# GitHub at install time, so the tag is what decides which code runs in the
# cluster; "latest" would make two installs a month apart behave differently.
#
# Releases also publish provenance.intoto.jsonl and sbom.spdx.json assets for
# each version. They are not checked here — doing so needs the cosign/gh
# attestation toolchain — but they exist if the install ever needs to be
# verified against a build record:
#
#   https://github.com/external-secrets/external-secrets/releases/tag/${ESO_VERSION}
#
# ---------------------------------------------------------------------------
# Why the apply is --server-side
#
# Client-side apply stores a copy of the whole object in the
# kubectl.kubernetes.io/last-applied-configuration annotation, and annotations
# are capped at 262,144 bytes. Two CRDs in this bundle are far past that:
#
#   clustersecretstores.external-secrets.io   720,156 bytes
#   secretstores.external-secrets.io          720,102 bytes
#
# Without --server-side the apply stops at the first of them with
#
#   metadata.annotations: Too long: must have at most 262144 bytes
#
# after having already created everything before it, which leaves a half
# installed operator. This is a known upstream constraint rather than a quirk of
# this version — the ESO install docs say plainly that "Our CRDs have reached
# the 256KB limit! You have to use server-side-apply in all locations to install
# them correctly", and its own Makefile applies the bundle with --server-side.
#
# Server-side apply sends the field ownership to the API server instead of
# storing it in an annotation, so object size stops mattering.
#
# ---------------------------------------------------------------------------

ESO_VERSION="v2.12.0"

CLUSTER="petclinic-dev"
REGION="eu-central-1"
ENV="dev"
ROLE_ARN="${ESO_ROLE_ARN:-}"
NAMESPACE="external-secrets"
SA_NAME="external-secrets-sa"
STORE_NAME="aws-secrets-manager"
DRY_RUN="false"

RELEASE_BASE="https://github.com/external-secrets/external-secrets/releases/download"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
MANIFEST_DIR="${REPO_ROOT}/k8s/base/external-secrets"

usage() {
  cat <<'EOF'
Usage: install-eso.sh [options]

Options:
  --cluster <name>       EKS cluster name (default: petclinic-dev)
  --region <region>      AWS region (default: eu-central-1)
  --env <dev|prod>       Environment, used to locate the Terraform outputs when
                         --role-arn is not given (default: dev)
  --role-arn <arn>       IRSA role ARN for the operator service account.
                         Defaults to $ESO_ROLE_ARN, then to the eso_role_arn
                         Terraform output.
  --version <vX.Y.Z>     External Secrets Operator version (default: v2.12.0)
  --dry-run              Render everything without applying anything
  -h, --help             Show this help

Examples:
  ./scripts/install-eso.sh
  ./scripts/install-eso.sh --cluster petclinic-prod --env prod
  ./scripts/install-eso.sh --dry-run
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --cluster)
      [[ $# -ge 2 ]] || { echo "Error: --cluster requires a value" >&2; exit 1; }
      CLUSTER="$2"; shift 2 ;;
    --region)
      [[ $# -ge 2 ]] || { echo "Error: --region requires a value" >&2; exit 1; }
      REGION="$2"; shift 2 ;;
    --env)
      [[ $# -ge 2 ]] || { echo "Error: --env requires a value" >&2; exit 1; }
      ENV="$2"; shift 2 ;;
    --role-arn)
      [[ $# -ge 2 ]] || { echo "Error: --role-arn requires a value" >&2; exit 1; }
      ROLE_ARN="$2"; shift 2 ;;
    --version)
      [[ $# -ge 2 ]] || { echo "Error: --version requires a value" >&2; exit 1; }
      ESO_VERSION="$2"; shift 2 ;;
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

for cmd in kubectl curl; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Error: '$cmd' not found on PATH." >&2
    exit 1
  fi
done

if [[ ! -f "${MANIFEST_DIR}/clustersecretstore.yaml" ]]; then
  echo "Error: ${MANIFEST_DIR}/clustersecretstore.yaml not found." >&2
  echo "Run this script from a checkout of the repository." >&2
  exit 1
fi

echo "==> External Secrets Operator"
echo "    cluster:       ${CLUSTER}"
echo "    region:        ${REGION}"
echo "    namespace:     ${NAMESPACE}"
echo "    version:       ${ESO_VERSION}"
echo

# ---------------------------------------------------------------------------
# Resolve the IRSA role ARN
# ---------------------------------------------------------------------------

if [[ -z "$ROLE_ARN" ]]; then
  TF_DIR="${REPO_ROOT}/terraform/environments/${ENV}"
  if [[ -d "$TF_DIR" ]] && command -v terraform >/dev/null 2>&1; then
    echo "==> Resolving IRSA role ARN from terraform output in ${TF_DIR}"
    # `terraform output` exits non-zero when the output is absent, which is the
    # case before the eks module change that adds eso_role_arn has been applied.
    ROLE_ARN="$(cd "$TF_DIR" && terraform output -raw eso_role_arn 2>/dev/null || true)"
  fi
fi

if [[ -z "$ROLE_ARN" || "$ROLE_ARN" == "None" ]]; then
  cat >&2 <<EOF
Error: could not determine the IRSA role ARN.

Supply it explicitly, or apply the eks module first so the Terraform output
exists:

  cd terraform/environments/${ENV} && terraform apply plan.out
  terraform output -raw eso_role_arn

or:

  ./scripts/install-eso.sh --role-arn arn:aws:iam::<account>:role/petclinic-${ENV}-eso-role
EOF
  exit 1
fi

echo "    role ARN:      ${ROLE_ARN}"
echo

# ---------------------------------------------------------------------------
# Preflight: confirm kubectl is pointed at the cluster we think it is.
# Installing into the wrong cluster succeeds silently and is easy to miss.
#
# Skipped under --dry-run, which is precisely the check you want to run before
# the cluster is reachable.
# ---------------------------------------------------------------------------

if [[ "$DRY_RUN" != "true" ]]; then
  if ! kubectl version >/dev/null 2>&1; then
    echo "Error: kubectl cannot reach a cluster." >&2
    echo "Run: aws eks update-kubeconfig --name ${CLUSTER} --region ${REGION}" >&2
    exit 1
  fi

  CURRENT_CONTEXT="$(kubectl config current-context 2>/dev/null || echo '')"
  if [[ -n "$CURRENT_CONTEXT" && "$CURRENT_CONTEXT" != *"$CLUSTER"* ]]; then
    echo "Warning: current kubectl context is '${CURRENT_CONTEXT}', which does not" >&2
    echo "         mention the cluster '${CLUSTER}'. Ctrl-C now if that is wrong." >&2
    echo >&2
  fi
fi

# ---------------------------------------------------------------------------
# Fetch and namespace the release bundle
# ---------------------------------------------------------------------------

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "${WORK_DIR}"' EXIT

BUNDLE_URL="${RELEASE_BASE}/${ESO_VERSION}/external-secrets.yaml"
BUNDLE_FILE="${WORK_DIR}/external-secrets.yaml"

echo "==> Fetching ${BUNDLE_URL}"

# Check the URL before downloading so a bad version tag fails with a clear
# message rather than a truncated file that kubectl rejects later.
HTTP_CODE="$(curl -s -o /dev/null -w '%{http_code}' -L "$BUNDLE_URL" || echo '000')"
if [[ "$HTTP_CODE" != "200" ]]; then
  cat >&2 <<EOF
Error: bundle not found (HTTP ${HTTP_CODE}): ${BUNDLE_URL}

Check that --version is a real release tag, including the leading "v":

  https://github.com/external-secrets/external-secrets/releases
EOF
  exit 1
fi

curl -sL "$BUNDLE_URL" -o "$BUNDLE_FILE"

# A 200 with an empty or truncated body would otherwise fail much later, inside
# kubectl, with an error that does not mention the download.
if [[ ! -s "$BUNDLE_FILE" ]]; then
  echo "Error: downloaded bundle is empty: ${BUNDLE_FILE}" >&2
  exit 1
fi

# The kustomization exists to move every namespace reference in the bundle from
# `default` to `external-secrets` — see the header note on why this is not a
# sed. It lives in the temp directory next to the downloaded file, so the
# repository stays free of a generated artifact.
cat > "${WORK_DIR}/kustomization.yaml" <<EOF
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: ${NAMESPACE}
resources:
  - external-secrets.yaml
EOF

echo "==> Rendering with namespace ${NAMESPACE}"
RENDERED_FILE="${WORK_DIR}/rendered.yaml"
if ! kubectl kustomize "$WORK_DIR" > "$RENDERED_FILE"; then
  echo "Error: kustomize failed to render the bundle." >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Rewrite the three container args kustomize cannot see.
#
# Each is counted before substitution. A bundle whose args have been renamed or
# reshaped must fail loudly here: the substitution below would otherwise match
# nothing and report success, and the operator would install unable to find its
# own webhook — see the header note.
# ---------------------------------------------------------------------------

ARG_SERVICE="--service-namespace=default"
ARG_SECRET="--secret-namespace=default"
ARG_DNS="--dns-name=external-secrets-webhook.default.svc"

for arg in "$ARG_SERVICE" "$ARG_SECRET" "$ARG_DNS"; do
  FOUND="$(grep -c -F -- "$arg" "$RENDERED_FILE" || true)"
  if [[ "$FOUND" != "1" ]]; then
    cat >&2 <<EOF
Error: expected exactly 1 occurrence of '${arg}' in the rendered bundle,
found ${FOUND}.

This argument is what points the operator at its own namespace, and it is not a
YAML namespace field, so kustomize does not rewrite it. If the upstream bundle
changed shape, this script's substitution no longer applies and the operator
would install into 'default' without the check below noticing.

Inspect: ${BUNDLE_URL}
EOF
    exit 1
  fi
done

sed -i.bak \
  -e "s|${ARG_SERVICE}|--service-namespace=${NAMESPACE}|" \
  -e "s|${ARG_SECRET}|--secret-namespace=${NAMESPACE}|" \
  -e "s|${ARG_DNS}|--dns-name=external-secrets-webhook.${NAMESPACE}.svc|" \
  "$RENDERED_FILE"
rm -f "${RENDERED_FILE}.bak"

# ---------------------------------------------------------------------------
# Verify the rewrite actually happened — fields and args alike.
#
# This is the check that makes the render step trustworthy. A transformer or
# substitution that silently stopped matching — an upstream change to the
# bundle's shape, a different renderer — would leave the operator installing
# into `default`, which works well enough to look like success until the
# ClusterSecretStore cannot find its service account.
# ---------------------------------------------------------------------------

LEFTOVER="$(grep -c 'namespace: default' "$RENDERED_FILE" || true)"
if [[ "$LEFTOVER" != "0" ]]; then
  cat >&2 <<EOF
Error: ${LEFTOVER} references to namespace 'default' survived the rewrite.

The operator would be installed into 'default' instead of '${NAMESPACE}'.
This usually means the upstream bundle changed shape — inspect:

  ${BUNDLE_URL}

and check whether the namespace transformer in this script still covers every
place the namespace appears.
EOF
  exit 1
fi

# The three args are checked again after substitution. The loop above proves
# they were present; this proves they are gone.
for arg in "$ARG_SERVICE" "$ARG_SECRET" "$ARG_DNS"; do
  if grep -q -F -- "$arg" "$RENDERED_FILE"; then
    echo "Error: '${arg}' survived the substitution." >&2
    exit 1
  fi
done

# Assert the count rather than merely that it is non-zero. 16 is the number of
# YAML namespace fields in v2.12.0 — see the header.
#
# This is a shape check on the bundle, not a transformer check: kustomize sets
# the field even when the input lacks it, so a transformer that stopped covering
# one of the three shapes would still produce 16 and this would not notice. What
# it does catch is the bundle gaining or losing a namespaced object between
# versions, which is the moment to re-read the header note rather than assume
# the rewrite still covers everything.
EXPECTED_NS_FIELDS=16
MOVED="$(grep -c "namespace: ${NAMESPACE}" "$RENDERED_FILE" || true)"
if [[ "$MOVED" != "$EXPECTED_NS_FIELDS" ]]; then
  cat >&2 <<EOF
Error: expected ${EXPECTED_NS_FIELDS} namespace fields to be rewritten to
'${NAMESPACE}', found ${MOVED}.

Fewer means the bundle lost a namespaced object, more means it gained one. The
rewrite itself is not in question — kustomize re-adds fields it does not find —
but the count in this script is now stale, and the three container args in the
header note are the part worth re-reading before trusting the rest. Recheck:

  ${BUNDLE_URL}

and, if the count changed deliberately, update EXPECTED_NS_FIELDS to match.
Bundle in question:

  ${BUNDLE_URL}
EOF
  exit 1
fi

echo "    ${MOVED} namespace fields and 3 container args moved to ${NAMESPACE}"
echo

# ---------------------------------------------------------------------------
# Render the service account with the real role ARN.
#
# The placeholder in the file is replaced here rather than left for a manual
# edit, so the annotation and the Terraform role cannot drift apart.
# ---------------------------------------------------------------------------

RENDERED_SA="${WORK_DIR}/serviceaccount.yaml"
sed "s|<ESO_ROLE_ARN>|${ROLE_ARN}|" \
  "${MANIFEST_DIR}/serviceaccount.yaml" > "$RENDERED_SA"

if grep -q '<ESO_ROLE_ARN>' "$RENDERED_SA"; then
  echo "Error: failed to substitute the role ARN into serviceaccount.yaml" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Apply
#
# Order matters in one place: the ClusterSecretStore is validated by an
# admission webhook that this same install creates, with failurePolicy: Fail.
# Applying it before the webhook is serving would be rejected — or worse,
# accepted and never validated, depending on timing. So the operator goes in
# first and is allowed to become available before the store is applied.
# ---------------------------------------------------------------------------

if [[ "$DRY_RUN" == "true" ]]; then
  echo "==> Dry run — would apply, in this order:"
  echo "    1. kubectl apply -f ${MANIFEST_DIR}/namespace.yaml"
  echo "    2. kubectl apply --server-side -f <rendered bundle>   # operator ${ESO_VERSION}"
  echo "    3. kubectl apply -f <serviceaccount.yaml with role ARN>"
  echo "    4. kubectl apply -f ${MANIFEST_DIR}/clustersecretstore.yaml"
  echo
  echo "==> Dry run — service account that would be applied:"
  grep 'role-arn:' "$RENDERED_SA" | sed 's/^ */    /'
  echo
  echo "==> Dry run — objects in the rendered operator bundle:"
  # Pair each kind with the name that follows it. `paste - -` over two greps
  # would misalign on any document with more than one name field, which is most
  # of them once bindings and their subjects are counted.
  kubectl kustomize "$WORK_DIR" \
    | awk '/^kind: /{ k=$2 } /^  name: /{ if (k != "") { print "    " k "/" $2; k="" } }'
  echo
  echo "Dry run complete — nothing was applied."
  exit 0
fi

echo "==> Applying namespace"
kubectl apply -f "${MANIFEST_DIR}/namespace.yaml"

echo
echo "==> Applying operator ${ESO_VERSION}"
# Applies $RENDERED_FILE, not `-k $WORK_DIR`. The two are not interchangeable:
# `-k` re-renders from the kustomization, which reads the *downloaded* bundle,
# so it would discard the arg substitution above and put the operator back in
# `default` — while the verification loop, which reads $RENDERED_FILE, still
# passed. That mismatch is how the 2026-10-11 install shipped a cert-controller
# with --secret-namespace=default and a webhook that never got a certificate.
#
# --server-side is required, not preferred: two CRDs in this bundle exceed the
# 262,144-byte annotation limit that client-side apply stores the object in.
# See the header note.
kubectl apply --server-side -f "$RENDERED_FILE"

echo
echo "==> Applying service account ${SA_NAME}"
kubectl apply -f "$RENDERED_SA"

# ---------------------------------------------------------------------------
# Wait for the operator before applying the store.
# ---------------------------------------------------------------------------

echo
echo "==> Waiting for the operator to become available"
for deploy in external-secrets external-secrets-webhook external-secrets-cert-controller; do
  echo "    ${deploy}"
  kubectl -n "$NAMESPACE" rollout status "deployment/${deploy}" --timeout=300s
done

echo
echo "==> Applying ClusterSecretStore ${STORE_NAME}"
kubectl apply -f "${MANIFEST_DIR}/clustersecretstore.yaml"

# ---------------------------------------------------------------------------
# Verify
# ---------------------------------------------------------------------------

echo
echo "==> Operator pods"
kubectl -n "$NAMESPACE" get pods

echo
echo "==> Service account IRSA annotation"
kubectl -n "$NAMESPACE" get serviceaccount "$SA_NAME" \
  -o jsonpath='{.metadata.annotations.eks\.amazonaws\.com/role-arn}'
echo

# The store reports Ready only after it has successfully authenticated to AWS
# with the service account token. A store that applies cleanly but stays
# Ready=False is the signature of a trust-policy mismatch between the role and
# the service account — the exact failure the annotation above is there to
# catch — so this waits rather than reading the status once.
echo
echo "==> Waiting for the ClusterSecretStore to become Ready"
STORE_READY="false"
for _ in $(seq 1 30); do
  REASON="$(kubectl get clustersecretstore "$STORE_NAME" \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].reason}' 2>/dev/null || true)"
  STATUS="$(kubectl get clustersecretstore "$STORE_NAME" \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)"
  if [[ "$STATUS" == "True" ]]; then
    STORE_READY="true"
    break
  fi
  sleep 5
done

if [[ "$STORE_READY" == "true" ]]; then
  echo "    Ready"
else
  cat >&2 <<EOF
Warning: ClusterSecretStore ${STORE_NAME} did not report Ready within 150s.

Last condition reason: ${REASON:-<none>}

This is usually one of:

  * the IRSA trust policy does not name system:serviceaccount:${NAMESPACE}:${SA_NAME}
    — check terraform/modules/eks/main.tf → aws_iam_policy_document.eso_assume_role
  * the role ARN above is not the one that trust policy belongs to
  * the role's policy does not cover secret:${ENV}/*

The store is applied either way; diagnose with:

  kubectl describe clustersecretstore ${STORE_NAME}
  kubectl logs -n ${NAMESPACE} deploy/external-secrets
EOF
fi

cat <<EOF

Done. The External Secrets Operator ${ESO_VERSION} is installed in ${NAMESPACE}
and the ClusterSecretStore ${STORE_NAME} is available to every namespace.
EOF

# The ExternalSecret manifests in k8s/base/external-secrets/ are dev-only: they
# name namespace petclinic-dev and read petclinic/dev/... keys. Printing those
# commands after a prod install would send the operator to the wrong namespace
# and the wrong secrets, so prod gets the accurate statement instead of a
# copy-pasteable command that does the wrong thing.
if [[ "$ENV" == "prod" ]]; then
  cat <<EOF

There are no ExternalSecret manifests for prod in this repository yet. The two
under k8s/base/external-secrets/ both name namespace petclinic-dev and read
petclinic/dev/... keys, so applying them here would create dev secrets in the
dev namespace rather than prod secrets in petclinic-prod.

Prod needs its own copies with two changes each: metadata.namespace set to
petclinic-prod, and remoteRef.key set to petclinic/prod/... . The remote secrets
those keys point at must exist first — petclinic/prod/rds-credentials comes from
the rds module (PETPLAT-23) and petclinic/prod/openai-api-key from the secrets
module (PETPLAT-33). See k8s/base/external-secrets/README.md.

To check what this store can reach from prod once they exist:

  kubectl get clustersecretstore ${STORE_NAME} -o wide
EOF
else
  cat <<EOF

Next: apply the ExternalSecrets that use it (PETPLAT-35, PETPLAT-36). They
require the remote secrets to exist — petclinic/${ENV}/rds-credentials comes
from the rds module (PETPLAT-23) and petclinic/${ENV}/openai-api-key from the
secrets module (PETPLAT-33).

  kubectl apply -f k8s/base/external-secrets/rds-credentials.yaml
  kubectl apply -f k8s/base/external-secrets/openai-api-key.yaml

Then verify each one synced, and that the Kubernetes Secret it owns exists:

  kubectl get externalsecret -n petclinic-${ENV}
  kubectl get secret rds-credentials openai-api-key -n petclinic-${ENV}

An ExternalSecret reports SecretSynced=True only after the Secret has been
written, so a Ready=True row above is the whole check. To see what the Secret
contains without printing it to a terminal, compare key names only:

  kubectl get secret rds-credentials -n petclinic-${ENV} \\
    -o jsonpath='{.data}' | tr ',' '\n' | cut -d'"' -f2

For how to add a secret that does not exist yet, see
k8s/base/external-secrets/README.md.
EOF
fi
