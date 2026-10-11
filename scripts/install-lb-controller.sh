#!/usr/bin/env bash
set -euo pipefail

#
# install-lb-controller.sh — Install the AWS Load Balancer Controller on EKS
#
# PETPLAT-29. Installs the controller that watches Ingress resources and
# provisions ALBs — in this platform, the internet-facing ALB in front of the
# api-gateway. The controller runs in kube-system and authenticates to AWS with
# IRSA: the service account is annotated with the role ARN that Terraform
# created in the eks module (petclinic-{env}-lb-controller-role), and the pod
# exchanges a projected token for temporary credentials. No node-level AWS
# credentials are used.
#
# Usage:
#   ./scripts/install-lb-controller.sh
#   ./scripts/install-lb-controller.sh --cluster petclinic-prod --env prod
#   ./scripts/install-lb-controller.sh --role-arn arn:aws:iam::123456789012:role/petclinic-dev-lb-controller-role
#   ./scripts/install-lb-controller.sh --dry-run
#
# The role ARN is resolved in this order:
#   1. --role-arn
#   2. LB_CONTROLLER_ROLE_ARN in the environment
#   3. `terraform output -raw lb_controller_role_arn` in terraform/environments/{env}
#
# The VPC ID is resolved in this order:
#   1. --vpc-id
#   2. LB_CONTROLLER_VPC_ID in the environment
#   3. `aws eks describe-cluster --name <cluster>` → cluster.resourcesVpcConfig.vpcId
#
# The VPC ID is not optional and cannot be left to the controller: it would read
# it from the EC2 instance metadata service, which the node launch template
# deliberately blocks (http_put_response_hop_limit = 1). Without it the pod
# CrashLoopBackOffs with "failed to fetch VPC ID from instance metadata". Do not
# "fix" that by raising the hop limit — see the VPC ID section below.
#
# Requires: aws CLI v2, kubectl, helm v3+. kubectl must already point at the
# cluster — run `aws eks update-kubeconfig --name <cluster> --region <region>`
# first (Terraform exports the exact command as kubeconfig_command).
#
# ---------------------------------------------------------------------------
# Version scheme — read before bumping either version
#
# The controller and its Helm chart are versioned independently, and the two
# numbers do NOT track each other:
#
#   chart 3.6.0  ↔  app v3.6.0     (current scheme — same number, different tag)
#   chart 1.17.1 ↔  app v2.17.1    (older scheme — numbers deliberately differ)
#
# CRDs are fetched from GitHub, which tags releases by *application* version,
# so the URL must use APP_VERSION (v3.6.0). Passing the chart version (3.6.0,
# no "v") or an app version that does not exist yet returns a 404 from
# raw.githubusercontent.com and the install fails before Helm ever runs. The
# script checks each CRD URL up front and says exactly which tag failed.
#
# Chart and app versions must be bumped together to a pair that upstream ships.
# List valid pairs with:
#   helm search repo eks/aws-load-balancer-controller --versions
#
# ---------------------------------------------------------------------------

APP_VERSION="v3.6.0"
CHART_VERSION="3.6.0"

CLUSTER="petclinic-dev"
REGION="eu-central-1"
ENV="dev"
ROLE_ARN="${LB_CONTROLLER_ROLE_ARN:-}"
VPC_ID="${LB_CONTROLLER_VPC_ID:-}"
NAMESPACE="kube-system"
RELEASE="aws-load-balancer-controller"
SA_NAME="aws-load-balancer-controller"
DRY_RUN="false"

REPO_NAME="eks"
REPO_URL="https://aws.github.io/eks-charts"
GITHUB_REPO="https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller"

# The CRDs the controller needs for Ingress support. albtargetcontrolconfigs
# is newer than the other two and is only published from app v2.13.0 onward, so
# a pin older than that will 404 on it.
CRD_FILES=(
  "elbv2.k8s.aws_ingressclassparams.yaml"
  "elbv2.k8s.aws_targetgroupbindings.yaml"
  "elbv2.k8s.aws_albtargetcontrolconfigs.yaml"
)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

usage() {
  cat <<'EOF'
Usage: install-lb-controller.sh [options]

Options:
  --cluster <name>         EKS cluster name (default: petclinic-dev)
  --region <region>        AWS region (default: eu-central-1)
  --env <dev|prod>         Environment, used to locate the Terraform outputs
                           when --role-arn is not given (default: dev)
  --role-arn <arn>         IRSA role ARN for the controller service account.
                           Defaults to $LB_CONTROLLER_ROLE_ARN, then to the
                           lb_controller_role_arn Terraform output.
  --vpc-id <vpc-id>        VPC the cluster runs in. Defaults to
                           $LB_CONTROLLER_VPC_ID, then to a lookup from the
                           cluster name. Required because pods cannot reach the
                           instance metadata service (see the note below).
  --namespace <ns>         Namespace to install into. Only kube-system is
                           accepted — the IRSA trust policy is scoped to the
                           service account in that namespace.
  --app-version <vX.Y.Z>   Controller application version, used for the CRD
                           URLs (default: v3.6.0)
  --chart-version <X.Y.Z>  Helm chart version (default: 3.6.0). Must be the
                           chart that ships the chosen app version.
  --dry-run                Render the manifests without applying anything
  -h, --help               Show this help

Examples:
  ./scripts/install-lb-controller.sh
  ./scripts/install-lb-controller.sh --cluster petclinic-prod --env prod
  ./scripts/install-lb-controller.sh --dry-run
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
    --vpc-id)
      [[ $# -ge 2 ]] || { echo "Error: --vpc-id requires a value" >&2; exit 1; }
      VPC_ID="$2"; shift 2 ;;
    --namespace)
      [[ $# -ge 2 ]] || { echo "Error: --namespace requires a value" >&2; exit 1; }
      NAMESPACE="$2"; shift 2 ;;
    --app-version)
      [[ $# -ge 2 ]] || { echo "Error: --app-version requires a value" >&2; exit 1; }
      APP_VERSION="$2"; shift 2 ;;
    --chart-version)
      [[ $# -ge 2 ]] || { echo "Error: --chart-version requires a value" >&2; exit 1; }
      CHART_VERSION="$2"; shift 2 ;;
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

# The IRSA trust policy Terraform created names this exact service account, and
# the namespace is part of that name. Installing anywhere else produces a
# controller that starts cleanly and then fails every AWS call with AccessDenied
# from STS, with nothing in the error pointing at the namespace as the cause.
# --namespace exists only to make the assumption explicit, so refuse any value
# other than the one the role trusts rather than accepting it and breaking IRSA.
if [[ "$NAMESPACE" != "kube-system" ]]; then
  cat >&2 <<EOF
Error: --namespace ${NAMESPACE} cannot work with the Terraform-created IRSA role.

The role's trust policy grants sts:AssumeRoleWithWebIdentity only to:

    system:serviceaccount:kube-system:aws-load-balancer-controller

A controller installed in '${NAMESPACE}' presents a different subject
('system:serviceaccount:${NAMESPACE}:${SA_NAME}'), so the token exchange is
denied and every AWS call fails with AccessDenied. Install into kube-system, or
change the trust policy in terraform/modules/eks/main.tf to match.
EOF
  exit 1
fi

for cmd in aws kubectl helm curl; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Error: '$cmd' not found on PATH." >&2
    exit 1
  fi
done

echo "==> AWS Load Balancer Controller"
echo "    cluster:       ${CLUSTER}"
echo "    region:        ${REGION}"
echo "    namespace:     ${NAMESPACE}"
echo "    app version:   ${APP_VERSION}"
echo "    chart version: ${CHART_VERSION}"
echo

# ---------------------------------------------------------------------------
# Resolve the IRSA role ARN
# ---------------------------------------------------------------------------

if [[ -z "$ROLE_ARN" ]]; then
  TF_DIR="${REPO_ROOT}/terraform/environments/${ENV}"
  if [[ -d "$TF_DIR" ]] && command -v terraform >/dev/null 2>&1; then
    echo "==> Resolving IRSA role ARN from terraform output in ${TF_DIR}"
    # `terraform output` exits non-zero when the output is absent, which is the
    # case before the eks module has been applied.
    ROLE_ARN="$(cd "$TF_DIR" && terraform output -raw lb_controller_role_arn 2>/dev/null || true)"
  fi
fi

if [[ -z "$ROLE_ARN" || "$ROLE_ARN" == "None" ]]; then
  cat >&2 <<EOF
Error: could not determine the IRSA role ARN.

Supply it explicitly, or apply the eks module first so the Terraform output
exists:

  cd terraform/environments/${ENV} && terraform apply plan.out
  terraform output -raw lb_controller_role_arn

or:

  ./scripts/install-lb-controller.sh --role-arn arn:aws:iam::<account>:role/petclinic-${ENV}-lb-controller-role
EOF
  exit 1
fi

echo "    role ARN:      ${ROLE_ARN}"
echo

# ---------------------------------------------------------------------------
# Resolve the VPC ID
#
# The controller resolves the VPC ID from the EC2 instance metadata service when
# it is not given one, and that lookup fails here by design: the node launch
# template sets http_put_response_hop_limit = 1
# (terraform/modules/eks/main.tf), which blocks pods from reaching IMDS — a
# request from a pod crosses one extra hop and IMDS only answers at hop limit 1.
# That setting is deliberate: IMDS is unauthenticated, so anything that can
# reach it can read the node role's credentials.
#
# The symptom is a CrashLoopBackOff, not a permission error:
#
#   unable to initialize AWS cloud: failed to get VPC ID: failed to fetch VPC ID
#   from instance metadata: error in fetching vpc id through ec2 metadata:
#   get mac metadata: operation error ec2imds: GetMetadata, canceled, context
#   deadline exceeded
#
# The fix is to supply the value, never to raise the hop limit. The chart's
# vpcId value exists for exactly this case.
# ---------------------------------------------------------------------------

if [[ -z "$VPC_ID" ]]; then
  echo "==> Resolving VPC ID from cluster ${CLUSTER}"
  VPC_ID="$(aws eks describe-cluster \
    --name "$CLUSTER" \
    --region "$REGION" \
    --query 'cluster.resourcesVpcConfig.vpcId' \
    --output text 2>/dev/null || true)"
fi

if [[ -z "$VPC_ID" || "$VPC_ID" == "None" ]]; then
  cat >&2 <<EOF
Error: could not determine the VPC ID for cluster ${CLUSTER}.

The controller cannot discover it at runtime — pods are blocked from the
instance metadata service by the node launch template's hop limit of 1 — so it
must be passed in.

  aws eks describe-cluster --name ${CLUSTER} --region ${REGION} \\
    --query 'cluster.resourcesVpcConfig.vpcId' --output text

or:

  ./scripts/install-lb-controller.sh --vpc-id vpc-xxxxxxxx
EOF
  exit 1
fi

echo "    VPC ID:        ${VPC_ID}"
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
# CRDs
#
# Applied before Helm so the CRDs exist when the controller starts and the
# webhook has something to validate against. They are also present in the
# chart's crds/ directory, but Helm only ever creates those on first install
# and never upgrades them — applying them here means a version bump actually
# updates the CRD schemas, which a chart upgrade alone would silently skip.
#
# The URLs are checked before anything is applied so a bad version tag fails
# with a clear message rather than a wall of kubectl noise.
# ---------------------------------------------------------------------------

CRD_BASE="${GITHUB_REPO}/${APP_VERSION}/config/crd/bases"

echo "==> Checking CRD URLs at ${APP_VERSION}"
for crd in "${CRD_FILES[@]}"; do
  url="${CRD_BASE}/${crd}"
  code="$(curl -s -o /dev/null -w '%{http_code}' -L "$url" || echo '000')"
  if [[ "$code" != "200" ]]; then
    cat >&2 <<EOF
Error: CRD not found (HTTP ${code}): ${url}

The controller's GitHub releases are tagged with the *application* version,
which is not the same as the Helm chart version:
    chart ${CHART_VERSION}  →  app ${APP_VERSION}

Check that --app-version is a real release tag (with the leading "v") and that
--chart-version is the chart that ships it:
    helm search repo ${REPO_NAME}/aws-load-balancer-controller --versions
EOF
    exit 1
  fi
  echo "    ok: ${crd}"
done
echo

if [[ "$DRY_RUN" == "true" ]]; then
  echo "==> Dry run — CRDs would be applied from:"
  for crd in "${CRD_FILES[@]}"; do
    echo "    kubectl apply -f ${CRD_BASE}/${crd}"
  done
else
  echo "==> Applying CRDs"
  for crd in "${CRD_FILES[@]}"; do
    kubectl apply -f "${CRD_BASE}/${crd}"
  done
  echo
fi

# ---------------------------------------------------------------------------
# Helm repository
# ---------------------------------------------------------------------------

echo "==> Adding Helm repository ${REPO_NAME}"
helm repo add "$REPO_NAME" "$REPO_URL" >/dev/null 2>&1 || true
helm repo update "$REPO_NAME" >/dev/null

# Fail early with a readable message if the chart version does not exist,
# rather than letting helm error out mid-install.
if ! helm search repo "${REPO_NAME}/aws-load-balancer-controller" --versions \
     | awk -v v="$CHART_VERSION" '$2 == v { found = 1 } END { exit !found }'; then
  echo "Error: chart version ${CHART_VERSION} not found in ${REPO_NAME}." >&2
  echo "Available versions:" >&2
  helm search repo "${REPO_NAME}/aws-load-balancer-controller" --versions | head -10 >&2
  exit 1
fi

echo "==> Installing chart ${CHART_VERSION} (controller ${APP_VERSION})"

# Flags shared by `helm upgrade --install` and `helm template`. The two
# subcommands take the same flags but not the same positional arguments, so the
# shared part is kept separate rather than trying to strip `upgrade --install`
# back out for the dry run.
HELM_COMMON_ARGS=(
  --namespace "$NAMESPACE"
  --version "$CHART_VERSION"
  --set "clusterName=${CLUSTER}"
  --set "region=${REGION}"
  # Supplied rather than discovered — see the VPC ID section above.
  --set "vpcId=${VPC_ID}"
  --set "serviceAccount.create=true"
  --set "serviceAccount.name=${SA_NAME}"
  --set "serviceAccount.annotations.eks\.amazonaws\.com/role-arn=${ROLE_ARN}"
  # The chart creates the IngressClass named "alb", which is what
  # k8s/base/ingress/ingress.yaml selects via spec.ingressClassName. Stated
  # explicitly so a future chart-default change cannot silently rename it.
  --set "createIngressClassResource=true"
  --set "ingressClass=alb"
)

if [[ "$DRY_RUN" == "true" ]]; then
  echo "==> Dry run — helm command:"
  printf '    helm upgrade --install %q %q' "$RELEASE" "${REPO_NAME}/aws-load-balancer-controller"
  printf ' %q' "${HELM_COMMON_ARGS[@]}"
  printf ' --wait --timeout 5m\n\n'

  echo "==> Dry run — rendered manifests (helm template):"
  helm template "$RELEASE" "${REPO_NAME}/aws-load-balancer-controller" \
    "${HELM_COMMON_ARGS[@]}" | head -60
  echo
  echo "Dry run complete — nothing was applied."
  exit 0
fi

helm upgrade --install "$RELEASE" "${REPO_NAME}/aws-load-balancer-controller" \
  "${HELM_COMMON_ARGS[@]}" \
  --wait \
  --timeout 5m

# ---------------------------------------------------------------------------
# Verify
# ---------------------------------------------------------------------------

echo
echo "==> Waiting for the controller to become available"
kubectl -n "$NAMESPACE" rollout status "deployment/${RELEASE}" --timeout=300s

echo
echo "==> Controller pods"
kubectl -n "$NAMESPACE" get pods -l "app.kubernetes.io/name=aws-load-balancer-controller"

echo
echo "==> IngressClass"
kubectl get ingressclass alb

echo
echo "==> Service account IRSA annotation"
kubectl -n "$NAMESPACE" get serviceaccount "$SA_NAME" \
  -o jsonpath='{.metadata.annotations.eks\.amazonaws\.com/role-arn}'
echo

cat <<EOF

Done. The AWS Load Balancer Controller is installed in ${NAMESPACE} and will
provision an ALB for any Ingress with ingressClassName: alb.

Next: apply the Ingress so the ALB is created (PETPLAT-30). Substitute the two
placeholders in k8s/base/ingress/ingress.yaml first:

  cd terraform/environments/${ENV}
  terraform output -raw acm_certificate_arn   # → <ACM_CERTIFICATE_ARN>
  terraform output -raw alb_sg_id             # → <ALB_SECURITY_GROUP_ID>

  kubectl apply -f k8s/base/ingress/ingress.yaml
  kubectl get ingress api-gateway -n petclinic-${ENV} --watch

Then read the ALB hostname for the Route 53 record (PETPLAT-31):

  kubectl get ingress api-gateway -n petclinic-${ENV} \\
    -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'
EOF
