# ECR Container Registry Operations

**Last Updated:** 2026-10-04

**Purpose:** How to authenticate to the petclinic ECR registry, build and push service images, and verify that what landed in the registry will actually run on the Graviton nodes. Covers the procedures required by PETPLAT-21 and PETPLAT-85.

## Table of Contents

1. [Registry Reference](#registry-reference)
2. [Procedure: authenticate Docker to ECR](#procedure-authenticate-docker-to-ecr)
3. [Procedure: build and push images](#procedure-build-and-push-images)
4. [Procedure: build a single service](#procedure-build-a-single-service)
5. [Procedure: verify a pushed image is ARM64](#procedure-verify-a-pushed-image-is-arm64)
6. [Procedure: verify the lifecycle policy is working](#procedure-verify-the-lifecycle-policy-is-working)
7. [Troubleshooting](#troubleshooting)

---

## Registry Reference

| Setting | Dev | Prod |
|---------|-----|------|
| Registry | `{account}.dkr.ecr.eu-central-1.amazonaws.com` | same |
| Namespace | `petclinic-dev/` | `petclinic-prod/` |
| Repositories | 8, one per service | 8, one per service |
| Tag mutability | `MUTABLE` | `IMMUTABLE` |
| Scan on push | enabled | enabled |
| Encryption | `AES256` | `AES256` |
| Terraform module | `terraform/modules/ecr/` | `terraform/modules/ecr/` |

Repository names follow `petclinic-{env}/{service}`, so a dev push can never overwrite the tag a prod deployment is running.

| Service | Port | ECR repository |
|---------|------|----------------|
| config-server | 8888 | `petclinic-{env}/config-server` |
| discovery-server | 8761 | `petclinic-{env}/discovery-server` |
| api-gateway | 8080 | `petclinic-{env}/api-gateway` |
| customers-service | 8081 | `petclinic-{env}/customers-service` |
| visits-service | 8082 | `petclinic-{env}/visits-service` |
| vets-service | 8083 | `petclinic-{env}/vets-service` |
| genai-service | 8084 | `petclinic-{env}/genai-service` |
| admin-server | 9090 | `petclinic-{env}/admin-server` |

> **Ports:** taken from `docs/technical-spec.md` → Service Inventory. The `docker.image.exposed.port` property in each module's `pom.xml` is wrong for api-gateway, visits-service, vets-service and genai-service (all four carry a copy-pasted `8081`). The build script uses the table above and ignores the poms.

---

## Procedure: authenticate Docker to ECR

**When:** Before any push, and again whenever a push fails with `no basic auth credentials`. The ECR token is valid for 12 hours.
**Who:** Any engineer with ECR permissions on the target account.
**Time:** ~5 seconds

**Steps:**

1. Run the helper script. It resolves the account from the caller identity, so there is no account ID to keep in sync:

   ```bash
   ./scripts/ecr-login.sh
   ```

2. Or log in by hand, which is what the script does:

   ```bash
   aws ecr get-login-password --region eu-central-1 \
     | docker login --username AWS --password-stdin \
       "$(aws sts get-caller-identity --query Account --output text).dkr.ecr.eu-central-1.amazonaws.com"
   ```

**Verify:**

- `Login Succeeded` is printed.

**Rollback:**

- None needed. The token expires on its own; `docker logout {registry}` clears it sooner.

---

## Procedure: build and push images

**When:** The first time images are needed in a fresh environment, or for any manual push outside CI. CI handles all subsequent builds (E-16).
**Who:** Any engineer with ECR push permissions and Docker running locally.
**Time:** ~5 minutes for the Maven build, ~10–20 minutes for 8 ARM64 images plus the upload.

**Steps:**

1. Build and push all eight services, tagged with the initial semantic version:

   ```bash
   ./scripts/build-push-ecr.sh --tag v1.0.0 --env dev
   ```

   The script builds the JARs with Maven, then builds one `linux/arm64` image per service with `docker buildx` and pushes it. Pass `--env prod` to target `petclinic-prod/`.

2. Preview without building anything:

   ```bash
   ./scripts/build-push-ecr.sh --tag v1.0.0 --env dev --dry-run
   ```

3. Common variations:

   ```bash
   # Tag with the application repo's commit SHA instead (the CI convention)
   ./scripts/build-push-ecr.sh --env dev

   # Reuse JARs already in each module's target/ — skips the Maven build
   ./scripts/build-push-ecr.sh --tag v1.0.0 --env dev --skip-maven

   # Build locally without logging in or pushing anything
   ./scripts/build-push-ecr.sh --tag v1.0.0 --no-push
   ```

**Verify:**

- The script ends with `Pushed 8 image(s) at tag v1.0.0` and lists all eight image URIs.
- Confirm in the registry:

  ```bash
  aws ecr list-images --repository-name petclinic-dev/api-gateway \
    --region eu-central-1 --query 'imageIds[].imageTag' --output table
  ```

**Rollback:**

- Tag mutability is `MUTABLE` in dev, so a bad tag can be overwritten by re-running with the same tag.
- In prod, tags are `IMMUTABLE` and cannot be overwritten. Delete the bad image explicitly and re-push, or push a new tag:

  ```bash
  aws ecr batch-delete-image --repository-name petclinic-prod/api-gateway \
    --region eu-central-1 --image-ids imageTag=v1.0.0
  ```

> **Why not `./mvnw -P buildDocker`?** That profile defaults `container.platform` to `linux/amd64`, so it produces images the Graviton nodes cannot execute — and the failure only shows up as an exec format error at pod start, long after the push. It also reads the EXPOSE port from each `pom.xml`, several of which are wrong. The script builds the JARs with Maven and does the image step with `docker buildx --platform linux/arm64` instead, which is also what CI does.

> **Note on provenance:** `buildx` attaches a provenance attestation by default, so each tag is pushed as a small manifest list holding the image plus the attestation. Kubernetes resolves it by platform without issue. If you need a plain single manifest instead, add `--provenance=false` to the buildx invocation.

---

## Procedure: build a single service

**When:** Iterating on one service; you do not want to rebuild all eight.
**Who:** Any engineer with ECR push permissions.
**Time:** ~1–2 minutes

**Steps:**

1. Pass a comma-separated list to `--services`:

   ```bash
   ./scripts/build-push-ecr.sh --tag v1.0.0 --env dev --services api-gateway
   ```

   Maven is invoked with `-pl <module> -am`, so only that module and the parent POMs it inherits from are built.

2. Multiple services:

   ```bash
   ./scripts/build-push-ecr.sh --tag v1.0.0 --env dev --services api-gateway,vets-service
   ```

**Verify:**

- The script reports `Pushed 1 image(s)` (or however many you named).

**Rollback:**

- Same as the full push above.

---

## Procedure: verify a pushed image is ARM64

**When:** After any push, and immediately if a pod fails with `exec format error` or `CrashLoopBackOff` right after a deploy.
**Who:** Any engineer with read access to ECR.
**Time:** ~10 seconds

**Steps:**

1. Inspect the manifest in the registry:

   ```bash
   docker buildx imagetools inspect \
     "$(aws sts get-caller-identity --query Account --output text).dkr.ecr.eu-central-1.amazonaws.com/petclinic-dev/api-gateway:v1.0.0"
   ```

**Verify:**

- The output shows `Platform: linux/arm64`.

**Rollback:**

- An amd64 image in the registry is not fixable in place — rebuild it with the correct platform:

  ```bash
  ./scripts/build-push-ecr.sh --tag v1.0.0 --env dev --services api-gateway
  ```

---

## Procedure: verify the lifecycle policy is working

**When:** After the repositories have accumulated images, or when storage cost looks higher than expected.
**Who:** Any engineer with read access to ECR.
**Time:** ~1 minute

**Steps:**

1. Read the policy attached to a repository:

   ```bash
   aws ecr get-lifecycle-policy --repository-name petclinic-dev/api-gateway \
     --region eu-central-1 --query 'lifecyclePolicyText' --output text | python3 -m json.tool
   ```

2. List the images currently held:

   ```bash
   aws ecr describe-images --repository-name petclinic-dev/api-gateway \
     --region eu-central-1 \
     --query 'sort_by(imageDetails,&imagePushedAt)[].{tag:imageTags[0],pushed:imagePushedAt,size:imageSizeInBytes}' \
     --output table
   ```

**Verify:**

- The policy holds two rules: priority 1 expires images that are untagged **and were pushed more than 7 days ago**, priority 2 keeps the last 10 tagged images. Note the age is measured from push time, not from the moment an image lost its tag — a long-lived tagged image that is later untagged expires at the next daily evaluation rather than 7 days after that.
- After more than 10 tags exist, the oldest tagged images are gone. ECR evaluates the policy roughly once a day, so allow up to 24 hours before expecting a prune.
- The ECR scan-on-push findings for an image:

  ```bash
  aws ecr describe-image-scan-findings --repository-name petclinic-dev/api-gateway \
    --region eu-central-1 --image-id imageTag=v1.0.0 \
    --query 'imageScanFindings.findingSeverityCounts'
  ```

**Rollback:**

- The policy is managed by Terraform; re-applying restores it. Note that an expiry cannot be undone — the images are already deleted.

---

## Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| `no basic auth credentials` on push | The 12-hour ECR token expired, or you never logged in | Run `./scripts/ecr-login.sh` |
| Pod starts then dies with `exec format error` | The image was built for amd64, not the Graviton nodes | Rebuild with `./scripts/build-push-ecr.sh` (it pins `linux/arm64`); check with `docker buildx imagetools inspect` |
| `docker buildx build` fails with an exec format error during the build | Cross-building arm64 on an x86_64 host without QEMU | `docker run --privileged --rm tonistiigi/binfmt --install arm64` |
| `tag is immutable` on push | Prod repositories are `IMMUTABLE`; the tag already exists | Push a new tag, or delete the existing image first (see the rollback under "build and push images") |
| `no jar found in .../target` | Maven has not run, or was run with `clean` after the jars were removed | Run without `--skip-maven` |
| `is not a Spring Boot fat jar (no BOOT-INF/)` | A thin jar was picked up instead of the repackaged one | Run `./mvnw clean package` in the application repo, then re-run the script |
| Build succeeds but the image is far smaller than expected | The Dockerfile's `COPY ${ARTIFACT_NAME}.jar` matched the wrong file | Check the reported `jar:` line in the script output |
| Lifecycle policy apply fails with `InvalidParameterException` | A `tagged` rule without `tagPrefixList` or `tagPatternList` — AWS rejects it | The module already sets `tagPatternList = ["*"]`; do not remove it |
| `The repository with name '<service>' does not exist in the registry` | The image reference is missing the `petclinic-{env}/` namespace, or that environment's repositories have not been created yet | Confirm the repository exists: `aws ecr describe-repositories --region eu-central-1 --query 'repositories[].repositoryName' --output text`. If it is absent, apply the environment's ECR module first — prod repositories are wired but not applied until prod is built |
