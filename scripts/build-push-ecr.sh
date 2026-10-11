#!/usr/bin/env bash
set -euo pipefail

#
# build-push-ecr.sh — Build the petclinic services as ARM64 images and push to ECR
#
# PETPLAT-85. Initial build and push of all eight services, and the repeatable
# path for any later manual push.
#
# Why this script instead of `./mvnw -P buildDocker`:
#
#   * The Maven profile defaults `container.platform` to linux/amd64, so a local
#     run produces images the Graviton (t4g, ARM64) nodes cannot execute. The
#     failure mode is an exec format error at pod start, well after the push.
#   * The profile reads `docker.image.exposed.port` from each module's pom.xml,
#     and several of those values disagree with the service inventory. EXPOSE is
#     only documentation, but wrong documentation is worse than none.
#   * CI builds with docker buildx, so building the same way locally keeps the
#     two paths honest.
#
# Maven is still what compiles and packages the JARs — only the image step is
# replaced. `./mvnw package` (no profile) produces the Spring Boot fat jar.
#
# Usage:
#   ./scripts/build-push-ecr.sh --tag v1.0.0
#   ./scripts/build-push-ecr.sh --tag v1.0.0 --env prod
#   ./scripts/build-push-ecr.sh --tag v1.0.0 --services api-gateway,vets-service
#   ./scripts/build-push-ecr.sh --tag v1.0.0 --no-push       # build locally only
#   ./scripts/build-push-ecr.sh --tag v1.0.0 --skip-maven    # reuse existing JARs
#   ./scripts/build-push-ecr.sh --tag v1.0.0 --dry-run
#
# Requires: aws CLI v2, docker with buildx, a JDK for Maven. On an x86_64 host,
# QEMU must be registered once for cross-building:
#   docker run --privileged --rm tonistiigi/binfmt --install arm64
#
# Portable across macOS and Linux, and deliberately bash 3.2 compatible (macOS
# ships bash 3.2, which has no associative arrays).
#

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PLATFORM_DIR=$(cd "${SCRIPT_DIR}/.." && pwd)
APP_DIR=$(cd "${PLATFORM_DIR}/../spring-petclinic-microservices" 2>/dev/null && pwd || true)

# service:maven-module:port
#
# Ports come from docs/technical-spec.md → "Application Services" (the service
# inventory), which is authoritative. Do not read them from the module poms:
# api-gateway, visits-service, vets-service and genai-service all disagree.
SERVICE_TABLE="config-server:spring-petclinic-config-server:8888
discovery-server:spring-petclinic-discovery-server:8761
api-gateway:spring-petclinic-api-gateway:8080
customers-service:spring-petclinic-customers-service:8081
visits-service:spring-petclinic-visits-service:8082
vets-service:spring-petclinic-vets-service:8083
genai-service:spring-petclinic-genai-service:8084
admin-server:spring-petclinic-admin-server:9090"

TAG=""
ENVIRONMENT="dev"
REGION="eu-central-1"
PROFILE=""
SERVICES_FILTER=""
TARGET_PLATFORM="linux/arm64"
SKIP_MAVEN="false"
NO_PUSH="false"
DRY_RUN="false"

usage() {
  cat <<'EOF'
Usage: build-push-ecr.sh [options]

Options:
  --tag <tag>          Image tag to build and push (default: the application
                       repo's short commit SHA, which is what CI uses)
  --env <dev|prod>     Target ECR namespace petclinic-<env> (default: dev)
  --services <list>    Comma-separated subset to build (default: all eight)
  --region <region>    AWS region of the registry (default: eu-central-1)
  --profile <name>     AWS CLI profile to use (default: ambient credentials)
  --platform <plat>    Target platform (default: linux/arm64 for Graviton)
  --skip-maven         Reuse the JARs already in each module's target/
  --no-push            Build locally only; no registry login, no push
  --dry-run            Print what would run without running it
  -h, --help           Show this help

Services:
  config-server, discovery-server, api-gateway, customers-service,
  visits-service, vets-service, genai-service, admin-server

Examples:
  ./scripts/build-push-ecr.sh --tag v1.0.0
  ./scripts/build-push-ecr.sh --tag v1.0.0 --env prod
  ./scripts/build-push-ecr.sh --tag v1.0.0 --services api-gateway,admin-server
  ./scripts/build-push-ecr.sh --tag v1.0.0 --no-push --skip-maven
EOF
}

die() { echo "Error: $*" >&2; exit 1; }

# Is $1 one of the newline-separated lines in $2?
#
# Deliberately not `... | grep -qx`: under `set -o pipefail` a grep that exits
# on its first match closes the pipe, whatever is still writing takes SIGPIPE,
# and the 141 fails the whole pipeline — turning "found it" into a hard error.
# A case match cannot do that.
contains_line() {
  case "
$2
" in
    *"
$1
"*) return 0 ;;
    *) return 1 ;;
  esac
}

# Echo a command and run it, or just echo it under --dry-run.
run() {
  echo "  \$ $*"
  if [[ "$DRY_RUN" == "false" ]]; then
    "$@"
  fi
}

# Same, but run in a given directory. Maven needs this: -pl resolves module
# names against the *current* directory, not against the location of mvnw, so
# invoking mvnw by absolute path from elsewhere fails with
# "Could not find the selected project in the reactor".
run_in() {
  local dir="$1"; shift
  echo "  \$ (cd ${dir} && $*)"
  if [[ "$DRY_RUN" == "false" ]]; then
    ( cd "$dir" && "$@" )
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tag)          [[ $# -ge 2 ]] || die "--tag requires a value";          TAG="$2"; shift 2 ;;
    --env)          [[ $# -ge 2 ]] || die "--env requires a value";          ENVIRONMENT="$2"; shift 2 ;;
    --services)     [[ $# -ge 2 ]] || die "--services requires a value";     SERVICES_FILTER="$2"; shift 2 ;;
    --region)       [[ $# -ge 2 ]] || die "--region requires a value";       REGION="$2"; shift 2 ;;
    --profile)      [[ $# -ge 2 ]] || die "--profile requires a value";      PROFILE="$2"; shift 2 ;;
    --platform)     [[ $# -ge 2 ]] || die "--platform requires a value";     TARGET_PLATFORM="$2"; shift 2 ;;
    --skip-maven)   SKIP_MAVEN="true"; shift ;;
    --no-push)      NO_PUSH="true"; shift ;;
    --dry-run)      DRY_RUN="true"; shift ;;
    -h|--help)      usage; exit 0 ;;
    *)              echo "Error: unknown option '$1'" >&2; echo >&2; usage >&2; exit 1 ;;
  esac
done

case "$ENVIRONMENT" in
  dev|prod) ;;
  *) die "--env must be 'dev' or 'prod', got '${ENVIRONMENT}'" ;;
esac

[[ -n "$APP_DIR" ]] || die "application repo not found at ../spring-petclinic-microservices (expected alongside this platform repo)"
[[ -f "${APP_DIR}/docker/Dockerfile" ]] || die "Dockerfile not found at ${APP_DIR}/docker/Dockerfile"

for cmd in docker; do
  command -v "$cmd" >/dev/null 2>&1 || die "'$cmd' not found on PATH"
done

# --- Resolve the tag -------------------------------------------------------
# A commit SHA is unique and never overwritten, so re-running the script is
# safe even against IMMUTABLE prod repositories. A semantic version such as
# v1.0.0 is the other accepted form — pass it with --tag.

if [[ -z "$TAG" ]]; then
  TAG=$(git -C "$APP_DIR" rev-parse --short=7 HEAD 2>/dev/null || true)
  [[ -n "$TAG" ]] || die "could not derive a tag from the application repo; pass --tag explicitly"
  echo "No --tag given; using the application repo commit SHA: ${TAG}"
fi

[[ "$TAG" =~ ^[A-Za-z0-9_][A-Za-z0-9._-]{0,127}$ ]] \
  || die "'${TAG}' is not a valid ECR tag (letters, digits, and . _ - only; max 128 chars)"

# --- Resolve the registry --------------------------------------------------

AWS_OPTS=(--region "$REGION")
if [[ -n "$PROFILE" ]]; then
  AWS_OPTS+=(--profile "$PROFILE")
fi

# Every repository is namespaced petclinic-{env}/ (see terraform/modules/ecr), so
# an image reference always carries that segment:
#   <registry>/petclinic-{env}/<service>:<tag>
# It is not optional. The repository is petclinic-dev/api-gateway, not
# api-gateway, so a reference without the namespace resolves to a repository
# that does not exist and the push is rejected.
NAMESPACE="petclinic-${ENVIRONMENT}"

if [[ "$NO_PUSH" == "true" ]]; then
  # Local-only build: no AWS call, so this works offline and without credentials.
  # There is no registry host to name, so the image is petclinic-{env}/<service>
  # — the same path shape minus the host.
  REGISTRY=""
  echo "--no-push: building local images named ${NAMESPACE}/<service>:${TAG}"
else
  command -v aws >/dev/null 2>&1 || die "'aws' not found on PATH (or use --no-push)"
  ACCOUNT_ID=$(aws "${AWS_OPTS[@]}" sts get-caller-identity --query Account --output text)
  [[ -n "$ACCOUNT_ID" && "$ACCOUNT_ID" != "None" ]] \
    || die "could not determine the AWS account ID from the caller identity"
  REGISTRY="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com"
fi

# --- Resolve the service list ----------------------------------------------

SELECTED=""
if [[ -n "$SERVICES_FILTER" ]]; then
  SELECTED=$(echo "$SERVICES_FILTER" | tr ',' '\n' | tr -d ' ')
  while IFS= read -r requested; do
    [[ -z "$requested" ]] && continue
    if ! contains_line "$requested" "$(echo "$SERVICE_TABLE" | cut -d: -f1)"; then
      die "unknown service '${requested}'. Valid: $(echo "$SERVICE_TABLE" | cut -d: -f1 | tr '\n' ' ')"
    fi
  done <<EOF
$SELECTED
EOF
fi

# --- Cross-platform note ---------------------------------------------------

HOST_ARCH=$(uname -m)
case "$TARGET_PLATFORM" in
  linux/arm64) TARGET_ARCH="arm64" ;;
  linux/amd64) TARGET_ARCH="amd64" ;;
  *)           TARGET_ARCH="" ;;
esac
[[ "$HOST_ARCH" == "x86_64" ]] && HOST_ARCH="amd64"

if [[ -n "$TARGET_ARCH" && "$HOST_ARCH" != "$TARGET_ARCH" ]]; then
  echo "Note: building ${TARGET_PLATFORM} on a ${HOST_ARCH} host requires QEMU."
  echo "      If the build fails with an exec format error, run once:"
  echo "        docker run --privileged --rm tonistiigi/binfmt --install ${TARGET_ARCH}"
fi

# --- Registry login --------------------------------------------------------

if [[ "$NO_PUSH" == "false" ]]; then
  echo
  echo "==> Logging in to ${REGISTRY}"
  if [[ "$DRY_RUN" == "false" ]]; then
    aws "${AWS_OPTS[@]}" ecr get-login-password \
      | docker login --username AWS --password-stdin "$REGISTRY" >/dev/null
    echo "    logged in"
  else
    echo "  \$ aws ecr get-login-password | docker login --username AWS --password-stdin ${REGISTRY}"
  fi
fi

# --- Maven build -----------------------------------------------------------
# `package` with no profile: the springboot profile (activated by the presence
# of src/main/resources/application.yml) and spring-boot-starter-parent's
# pluginManagement bind spring-boot:repackage to the package phase, which is
# what produces the fat jar. The buildDocker profile is deliberately not used —
# it is the docker-exec path this script replaces.

if [[ "$SKIP_MAVEN" == "true" ]]; then
  echo
  echo "==> Skipping Maven (--skip-maven); reusing existing JARs"
else
  echo
  echo "==> Building JARs with Maven"

  MVN_ARGS=(-DskipTests package)
  if [[ -n "$SERVICES_FILTER" ]]; then
    MODULE_LIST=""
    while IFS=: read -r svc module port; do
      [[ -z "$svc" ]] && continue
      if contains_line "$svc" "$SELECTED"; then
        MODULE_LIST="${MODULE_LIST:+${MODULE_LIST},}${module}"
      fi
    done <<EOF
$SERVICE_TABLE
EOF
    # -am also builds the parent poms the selected modules inherit from.
    MVN_ARGS=(-pl "$MODULE_LIST" -am "${MVN_ARGS[@]}")
  fi

  run_in "$APP_DIR" ./mvnw "${MVN_ARGS[@]}"
fi

# --- Build and push each service -------------------------------------------

echo
echo "==> Building ${TARGET_PLATFORM} images"

BUILT=""
COUNT=0

while IFS=: read -r SERVICE MODULE PORT; do
  [[ -z "$SERVICE" ]] && continue

  if [[ -n "$SERVICES_FILTER" ]] && ! contains_line "$SERVICE" "$SELECTED"; then
    continue
  fi

  TARGET_DIR="${APP_DIR}/${MODULE}/target"
  [[ -d "$TARGET_DIR" ]] || die "${MODULE}/target does not exist — run without --skip-maven"

  # Pick the Spring Boot fat jar. `*.jar` never matches the `.jar.original`
  # backup repackage leaves behind, and the classifiers below are excluded so a
  # sources/javadoc jar can't be mistaken for the runnable one.
  JAR=""
  for candidate in "${TARGET_DIR}"/*.jar; do
    [[ -e "$candidate" ]] || continue
    case "$candidate" in
      *-sources.jar|*-javadoc.jar|*-plain.jar) continue ;;
    esac
    if [[ -n "$JAR" ]]; then
      die "${MODULE}/target holds more than one runnable jar (${JAR##*/}, ${candidate##*/}); clean the module and rebuild"
    fi
    JAR="$candidate"
  done
  if [[ -n "$JAR" ]]; then
    # Guard the exact failure the buildDocker profile would have hidden: a thin
    # jar (no BOOT-INF/) builds and pushes fine, then fails at pod start with
    # "no main manifest attribute". Fail here instead.
    #
    # The listing is captured before matching rather than piped into `grep -q`.
    # A 76 MB fat jar has a listing far larger than the pipe buffer, so grep
    # exits on its first match while unzip is still writing; unzip then takes
    # SIGPIPE and, under `set -o pipefail`, the pipeline reports 141 and this
    # guard rejects a perfectly good jar.
    if command -v unzip >/dev/null 2>&1; then
      JAR_ENTRIES=$(unzip -l "$JAR" 2>/dev/null || true)
      case "$JAR_ENTRIES" in
        *BOOT-INF/*) ;;
        *) die "${JAR##*/} is not a Spring Boot fat jar (no BOOT-INF/). Run without --skip-maven." ;;
      esac
    fi
    ARTIFACT_NAME=$(basename "$JAR" .jar)
  elif [[ "$DRY_RUN" == "true" ]]; then
    # Nothing has been built yet, but the point of --dry-run is to preview the
    # commands, so stand in the name Maven would have produced.
    ARTIFACT_NAME="${MODULE}-<version>"
    echo "    (dry-run: no jar in target/ yet, using placeholder name)"
  else
    die "no jar found in ${MODULE}/target — the Maven build did not produce one"
  fi
  # REGISTRY is empty under --no-push, so build the host prefix conditionally
  # rather than emitting a leading slash.
  if [[ -n "$REGISTRY" ]]; then
    IMAGE="${REGISTRY}/${NAMESPACE}/${SERVICE}:${TAG}"
  else
    IMAGE="${NAMESPACE}/${SERVICE}:${TAG}"
  fi

  echo
  echo "--- ${SERVICE} (port ${PORT})"
  echo "    jar:   ${ARTIFACT_NAME}.jar"
  echo "    image: ${IMAGE}"

  # The Dockerfile lives outside the build context (target/), so it is passed
  # with -f. It does COPY ${ARTIFACT_NAME}.jar application.jar, which is why the
  # context must be target/ and the artifact name must be the jar's basename.
  BUILD_ARGS=(
    buildx build
    --platform "$TARGET_PLATFORM"
    --build-arg "ARTIFACT_NAME=${ARTIFACT_NAME}"
    --build-arg "EXPOSED_PORT=${PORT}"
    --tag "$IMAGE"
    --file "${APP_DIR}/docker/Dockerfile"
  )
  if [[ "$NO_PUSH" == "true" ]]; then
    BUILD_ARGS+=(--load)
  else
    BUILD_ARGS+=(--push)
  fi

  run docker "${BUILD_ARGS[@]}" "$TARGET_DIR"

  BUILT="${BUILT}${IMAGE}
"
  COUNT=$((COUNT + 1))
done <<EOF
$SERVICE_TABLE
EOF

[[ "$COUNT" -gt 0 ]] || die "no services matched '${SERVICES_FILTER}'"

# --- Summary ---------------------------------------------------------------

echo
echo "==========================================================="
if [[ "$NO_PUSH" == "true" ]]; then
  echo "Built ${COUNT} image(s) locally at tag ${TAG} (not pushed):"
else
  echo "Pushed ${COUNT} image(s) at tag ${TAG}:"
fi
echo "$BUILT" | while IFS= read -r line; do
  [[ -n "$line" ]] && echo "  ${line}"
done

if [[ "$NO_PUSH" == "false" ]]; then
  echo
  echo "Point the Helm values at these tags to deploy:"
  echo "  helm-values/{service}.yaml → image.tag: ${TAG}"
fi
echo "==========================================================="
