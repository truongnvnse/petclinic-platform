# CI Pipeline Operations

**Last Updated:** 2026-10-11

**Purpose:** How CI authenticates to AWS without long-lived credentials, which GitHub secrets the workflows read, and how to diagnose the failures that federation produces. Covers the procedures required by PETPLAT-52 and PETPLAT-87.

## Table of Contents

1. [Pipeline Reference](#pipeline-reference)
   - [The three files that make up the build half](#the-three-files-that-make-up-the-build-half)
   - [What the build actually builds](#what-the-build-actually-builds)
   - [Vulnerability scanning (PETPLAT-105)](#vulnerability-scanning-petplat-105)
2. [Procedure: create the OIDC federation](#procedure-create-the-oidc-federation)
3. [Procedure: set the GitHub secrets and variables](#procedure-set-the-github-secrets-and-variables)
4. [Procedure: verify the federation works](#procedure-verify-the-federation-works)
5. [Procedure: diagnose AccessDenied on AssumeRoleWithWebIdentity](#procedure-diagnose-accessdenied-on-assumerolewithwebidentity)
6. [Procedure: extend the federation to a second environment](#procedure-extend-the-federation-to-a-second-environment)
7. [Troubleshooting](#troubleshooting)

---

## Pipeline Reference

Two workflows, in two different repositories, and only one of them talks to AWS.

| Workflow | Repository | Trigger | Calls AWS? |
|---|---|---|---|
| `build-push.yml` | app repo (`spring-petclinic-microservices`) | push to `main` | **Yes** — assumes the role, pushes images to ECR |
| `update-image-tags.yml` | this repo | `repository_dispatch` (`app-image-built`) | No — runs `yq` and `git push` only |

That split is why the trust policy below names the **application** repo and not this one. The role exists for the workflow that assumes it, and the workflow that assumes it lives there.

`build-push.yml` now exists (PETPLAT-49), along with the reusable workflow and composite action it is built from (PETPLAT-53). Two things about it are load-bearing, and both are properties of the trust policy rather than of the workflow:

- It triggers on **push to `main`** and declares `permissions: id-token: write` on the build job only. The `changes` and `dispatch` jobs do not get an OIDC token, because neither talks to AWS.
- It does **not** copy `maven-build.yml`'s `pull_request` trigger, and that trigger must not be added. A PR run presents the subject `repo:...:pull_request`, which the trust policy refuses — so a PR-triggered AWS job fails with `AccessDenied` even though the same code passes on `main`.

`maven-build.yml` still runs the full eight-module test suite on the same push. That is not a duplicate of the build job, which passes `-DskipTests`: one produces a verdict, the other produces an image.

### The three files that make up the build half

| File | Repository | What it is |
|---|---|---|
| `.github/workflows/build-push.yml` | app repo | Orchestrator — detects changed services, fans out, dispatches |
| `.github/workflows/build-image.yml` | app repo | Reusable workflow — one service per matrix entry, start to push |
| `.github/actions/ecr-login/action.yml` | app repo | Composite action — OIDC, account assertion, ECR login |

The reusable workflow and the composite action are not interchangeable, and which one a shared step becomes is decided by whether its effect has to outlive the step:

- The **per-service build** is a workflow, because it wants a whole job: its own runner, JDK, buildx builder and timeout, and eight of them in parallel.
- The **login** is an action, because `docker login` writes a credential to the runner's docker config and a reusable workflow runs as a separate job whose runner is destroyed afterwards. Extracted as a workflow it would log in, succeed, and hand its caller nothing — the failure would surface later as a 401 from `docker push`, in a different job. A composite action runs inside the caller's job, so the credential is still there for the steps that follow.

### What the build actually builds

`dorny/paths-filter` maps each service to its directory (`spring-petclinic-vets-service/**` and so on), and only the services that matched reach the matrix. Two consequences worth knowing:

- **A change to a shared build input rebuilds all eight.** The root `pom.xml`, `docker/Dockerfile` and the Maven wrapper are inputs to every image, so the workflow carries an extra `shared` filter for them. Without it those edits would match no service directory, the matrix would be empty, and nothing would rebuild — the change would sit in git until some unrelated per-service commit happened to pick it up, so a Dockerfile fix would reach the eight images one at a time and possibly never.
- **A push touching more than 300 files under-detects.** `dorny/paths-filter` v3.0.4 resolves changed files through the REST compare API, which caps its file list at 300; it has no `use-git-diff` input to switch to git. A push large enough to hit that cap would silently build fewer services than it should. Routine commits are nowhere near it.

### Vulnerability scanning (PETPLAT-105)

Every image is scanned twice, before it is pushed, in the same job that built it — `aquasecurity/trivy-action` is a composite action, so it runs on the runner and can see the image that `docker/build-push-action` loaded into the local daemon with `load: true` / `push: false`. Nothing is re-tagged between the build and the push, so the artifact Trivy approved is the artifact ECR receives.

| Scan | Severity | Exit code | Purpose |
|---|---|---|---|
| Report | `CRITICAL,HIGH` | `0` | The artifact a human reads. HIGH never fails the build. |
| Gate | `CRITICAL` | `1` | What blocks the push. |

Both run; the gate is the second step, and a failed step ends the job, so the push below it is skipped. The reports upload as the artifact `trivy-{service}` with `if: always()`, because the runs whose report matters most are the ones where the gate failed.

Two details that are deliberate rather than incidental:

- **`ignore-unfixed: false`.** The common setting is `true`, which would make the gate's strength depend on whether a vendor has shipped a patch — so a vulnerability could pass simply by being neglected long enough. Unfixable findings are accepted one at a time in `.trivyignore`, in a commit, with a reason.
- **The gate is a separate Trivy invocation, not a parsed report.** Reading the CRITICAL count out of one JSON report would save about a minute, and would mean the gate's verdict depended on this pipeline's ability to parse Trivy's output — so a format change would silently turn the gate off. Two invocations cannot fail open.

**Reviewing scan results.** Open the run, download the `trivy-{service}` artifact, and read `trivy-{service}-gate.txt` — that file is exactly what the gate objected to, and it is also printed into the job log on failure. `trivy-{service}-report.txt` is the wider CRITICAL-and-HIGH view, which is where to look for HIGH findings worth fixing before they become CRITICAL.

**Adding to the allowlist.** `.trivyignore` in the app repo is the only way past the gate — there is no `continue-on-error` on the scan step and no second bypass. An entry is a decision to ship a known-vulnerable artifact, so the commit that adds one records why it cannot be fixed, what it actually exposes here, who accepted it by role and on what date, and when it gets looked at again. The file's own header has the format and a worked example. Trivy honours an entry forever; the review date is a promise, not a control, which is why the file says to move to `.trivyignore.yaml` (which has an enforced `expired_at`) once the list outgrows a handful of entries.

### Promotion: one tag, two registries

There is no promotion step from dev to prod, and it is worth being explicit about why, because the layout makes it look like there is one.

The values files split along a line that does not match the pipeline:

| Value | Lives in | Scope |
|---|---|---|
| `image.tag` | `helm-values/{service}.yaml` | **shared** — one tag for both environments |
| `image.registry` | `helm-values/{dev,prod}.yaml` | per environment — `…/petclinic-dev` vs `…/petclinic-prod` |

The chart concatenates them, so dev runs `petclinic-dev/{service}:{tag}` and prod runs `petclinic-prod/{service}:{tag}` — **the same tag string out of two different repositories**. And the dev role's policy is scoped to dev's repository ARNs, so a dev build cannot push to `petclinic-prod/*` at all.

The consequence: after a dev dispatch, the tag exists in `petclinic-dev/*` and nowhere else. Syncing prod's Application would have it ask `petclinic-prod/{service}` for a tag that was never pushed there — the `ImagePullBackOff` case in `docs/rollback-runbook.md`, on every service at once.

Nothing in the payload carries an environment, and `update-image-tags.yml` writes one commit that both Applications read. So the promotion model has to be decided before prod is applied, not during. The two shapes that fit the existing design:

- **Prod builds too.** A second workflow run — or a second job — pushes the same commit's SHA into `petclinic-prod/*`, then fires its own dispatch. Both dispatches write the same tag to the same file, so the second is a no-op and the shared-file layout stays correct. This needs prod's own role ARN as a second secret, since `AWS_ROLE_ARN` is currently a single value; the region and account ID would be reused as they are.
- **Separate tags per environment.** Correct, and a larger change: it means the tag stops being a property of the service file and becomes one of the env file, which is a rewrite of how the two overlays merge.

Whichever is chosen, it is a decision for the prod rollout, and the dev-only pipeline that exists today does not imply an answer.

### OIDC Federation

| Parameter | Value |
|---|---|
| Provider URL | `https://token.actions.githubusercontent.com` |
| Audience | `sts.amazonaws.com` |
| Subject | `repo:truongnvnse@336541468/spring-petclinic-microservices@1400042382:ref:refs/heads/main` |
| Role (dev) | `petclinic-dev-github-actions-role` |
| Module | `terraform/modules/github-oidc/` |
| Account / region | `550798137608` / `eu-central-1` |

The subject is a single value, not a wildcard. It admits one repository **and** one branch: a pull request, a tag, or a fork of that repo presents a different `sub` and is refused.

It also carries **numeric IDs**, and that is load-bearing. GitHub issues *immutable subject claims* for repositories created after 2026-07-15 — the default for new repos, and not removable from the format once in effect. A name-only subject therefore matches no token at all. The failure is nasty because nothing about it looks wrong: the role applies cleanly, reads correctly in the console, and fails only when a build runs, as `Not authorized to perform sts:AssumeRoleWithWebIdentity` — an error that names STS and never mentions the claim. The IDs are what make the claim immutable: a repository name can be deleted and recreated by whoever holds the account, but the ID cannot be reused. The name-only form is deliberately *not* accepted alongside the immutable one, because listing both would give away the property the IDs exist to provide.

The role's policy grants ECR push and nothing else — `ecr:GetAuthorizationToken` plus `BatchCheckLayerAvailability`, `InitiateLayerUpload`, `UploadLayerPart`, `CompleteLayerUpload` and `PutImage` on the eight repository ARNs. `ecr:GetAuthorizationToken` is the one action on `Resource: "*"`, because the ECR API rejects any attempt to scope it.

### GitHub secrets and variables

Set these on the **application** repository — that is where `build-push.yml` runs. Two are secrets and two are repository **variables**, which is a deliberate split rather than an inconsistency.

| Name | Kind | Value | Used for |
|---|---|---|---|
| `AWS_ROLE_ARN` | secret | the `github_actions_role_arn` output from the environment that owns the role | `role-to-assume` |
| `PLATFORM_REPO_TOKEN` | secret | a fine-grained PAT with `contents: write` on `truongnvnse/petclinic-platform` | The `repository_dispatch` |
| `AWS_REGION` | **variable** | `eu-central-1` | The region on the OIDC credential |
| `AWS_ACCOUNT_ID` | **variable** | `550798137608` | An assertion, not a URL — see below |

**Why region and account ID are variables and not secrets.** GitHub replaces a secret's value with `***` everywhere it appears in a log. Held as secrets, `AWS_ACCOUNT_ID` would blank the account out of every registry URL the build prints — `***.dkr.ecr.eu-central-1.amazonaws.com/petclinic-dev/vets-service:abc1234` — and `AWS_REGION` would blank the region out of every AWS CLI error message, which is precisely the text someone reads when the pipeline breaks. It would also defeat the account assertion below, whose entire job is to name the two account IDs when they disagree: as secrets, both would render as `***` and the message would name nothing at all.

Neither value is confidential — an account ID is not a credential, and the region is in every ARN in this repository. The role ARN stays a secret because there is no reason to echo it.

`build-push.yml` reads all four, passing `AWS_ROLE_ARN` as a secret and the region and account ID as inputs to the reusable workflow. `PLATFORM_REPO_TOKEN` is deliberately not among them: the build job is passed one named secret rather than `secrets: inherit`, so a job that runs eight times over application code never holds a token that can write to this repository.

**`AWS_ACCOUNT_ID` does not build the registry URL.** `ecr-login` reads the registry out of the login itself, so it cannot drift from the credentials in use. The account ID is compared against `aws sts get-caller-identity` before that login is used for anything. The check earns its place because the failure it catches is silent: a role in the wrong account logs in fine, pushes fine, and puts the images somewhere no cluster reads — the first symptom is `ImagePullBackOff` on every pod, in a cluster whose configuration never mentioned the account that was actually written to.

No access key and no secret key. There is no long-lived credential to AWS anywhere in this pipeline, which is the point of the federation: a leaked secret cannot be replayed, because there is no secret. `PLATFORM_REPO_TOKEN` is the one long-lived credential in the pipeline, and it reaches GitHub rather than AWS.

---

## Procedure: create the OIDC federation

**When:** First setup, or after rebuilding an environment whose state was lost.
**Who:** Engineer with AWS write access and permission to apply the dev root module.
**Time:** 10 minutes.

**Steps:**

1. Confirm the application repo's remote — the trust policy is derived from it, so a fork under a different account changes the subject:

   ```bash
   git -C ../spring-petclinic-microservices remote get-url origin
   ```

   Expect `https://github.com/truongnvnse/spring-petclinic-microservices.git`. If the username differs, update `github_repository` in the `module "github_oidc"` block of `terraform/environments/dev/main.tf` before applying.

2. Plan and apply the dev environment. The module is wired into the dev root module, so no separate apply is needed:

   ```bash
   cd terraform/environments/dev
   terraform init
   terraform plan -out plan.out
   terraform apply plan.out
   ```

3. Read the three outputs. All three are needed later:

   ```bash
   terraform output github_actions_role_arn
   terraform output github_oidc_provider_arn
   terraform output github_oidc_subject
   ```

   `github_oidc_subject` should read exactly `repo:truongnvnse@336541468/spring-petclinic-microservices@1400042382:ref:refs/heads/main` — names **and** numeric IDs. A value without the `@` IDs is wrong and the role will refuse every build.

**Verify:**

- The provider and the role both exist:
  ```bash
  aws iam list-open-id-connect-providers
  aws iam get-role --role-name petclinic-dev-github-actions-role \
    --query 'Role.AssumeRolePolicyDocument' --output json
  ```
- The trust policy's `sub` condition holds the full repo-and-branch string, not `*` and not the platform repo.
- `aws iam list-role-policies --role-name petclinic-dev-github-actions-role` returns exactly one policy, `petclinic-dev-ecr-push`.

**Rollback:**

- `terraform destroy` on the dev root module removes both. Do not do this casually — see the warning under the next procedure, because the provider is account-global.

---

## Procedure: set the GitHub secrets and variables

**When:** After the federation exists, or after the role ARN changes.
**Who:** Admin on the application repository.
**Time:** 5 minutes.

**Steps:**

1. Read the role ARN from the environment that owns it:

   ```bash
   cd terraform/environments/dev && terraform output -raw github_actions_role_arn
   ```

2. Set the region and the account ID as repository **variables**:

   ```bash
   gh variable set AWS_REGION     --repo truongnvnse/spring-petclinic-microservices --body "eu-central-1"
   gh variable set AWS_ACCOUNT_ID --repo truongnvnse/spring-petclinic-microservices --body "550798137608"
   ```

   `gh variable set`, not `gh secret set`. As secrets these two are masked to `***` in every log line they appear in, which censors the registry URLs the build echoes and turns the account assertion's message into `account ***, but AWS_ACCOUNT_ID is ***`. See "GitHub secrets and variables" above for the full reasoning.

3. Set the role ARN as a **secret**:

   ```bash
   gh secret set AWS_ROLE_ARN --repo truongnvnse/spring-petclinic-microservices --body "<role-arn-from-step-1>"
   ```

4. Create `PLATFORM_REPO_TOKEN` by hand. It cannot be generated by a command here, because it is a credential rather than a value: a fine-grained PAT scoped to `truongnvnse/petclinic-platform` with **Contents: Read and write** — the permission `repository_dispatch` requires. Classic PATs work too, with the `repo` scope, but that grants far more than this pipeline uses.

   ```bash
   gh secret set PLATFORM_REPO_TOKEN --repo truongnvnse/spring-petclinic-microservices --body "<the-pat>"
   ```

   It is set on the **application** repository, not this one: that is where the workflow that fires the dispatch runs. This repository only receives the event.

   GitHub sends a `repository_dispatch`-triggered workflow run within a few seconds. If the app repo's build is green and this repo shows no new run, the token is the first thing to check — a PAT without write access to this repository fails the dispatch step in the app repo, and the error names the permission rather than the workflow.

5. The workflow also needs `id-token: write` to request the OIDC token at all. Without it the token request fails before AWS is ever contacted, and the error mentions the token endpoint rather than the role:

   ```yaml
   permissions:
     id-token: write
     contents: read
   ```

**Verify:**

- Two secrets and two variables, and the listing commands differ because the two kinds are stored separately:

  ```bash
  gh secret list   --repo truongnvnse/spring-petclinic-microservices   # AWS_ROLE_ARN, PLATFORM_REPO_TOKEN
  gh variable list --repo truongnvnse/spring-petclinic-microservices   # AWS_REGION, AWS_ACCOUNT_ID
  ```

  Secret values are write-only and cannot be read back, so confirm those by running the workflow rather than by listing. Variables are readable, so listing them is a genuine check — and it is worth doing, because an unset `AWS_REGION` fails the build with a region error rather than a missing-variable one.

**Rollback:**

- `gh secret delete <NAME> --repo truongnvnse/spring-petclinic-microservices` for the two secrets; `gh variable delete <NAME> --repo truongnvnse/spring-petclinic-microservices` for the two variables.

---

## Procedure: verify the federation works

**When:** After creating the federation or changing the trust policy.
**Who:** Engineer with push access to the application repo.
**Time:** 15 minutes (mostly waiting for the ARM64 build).

**Steps:**

1. Push a commit to `main` in the application repo, or re-run the last `build-push` workflow from the Actions tab.

2. Confirm the credentials step assumed the role rather than a key. In the workflow log, the `configure-aws-credentials` step prints the assumed role ARN; it should read `arn:aws:iam::550798137608:role/petclinic-dev-github-actions-role`.

3. If the build succeeds, the app repo fires the dispatch and this repo's `update-image-tags` workflow runs. Confirm it committed:

   ```bash
   git -C ~/path/to/petclinic-platform log --oneline -3 -- helm-values/
   ```

   Expect a subject of the form `ci: update image tags to <sha> (<service-list>)`.

**Verify:**

- `aws ecr describe-images` shows an image carrying the new SHA tag in at least one `petclinic-dev/*` repository.
- The platform repo has a new commit touching `helm-values/`.

**Rollback:**

- Nothing to roll back on success. On failure, the diagnosis procedure below.

---

## Procedure: diagnose AccessDenied on AssumeRoleWithWebIdentity

**When:** `configure-aws-credentials` fails with `Not authorized to perform sts:AssumeRoleWithWebIdentity`.
**Who:** Engineer with push access to the application repo.
**Time:** 15 minutes.

AWS does not return *why* it refused, and the refusal is almost always one of two things: the subject does not match, or the audience does not match. Both are in the token — but read it from CloudTrail first, because the failed call is already recorded and the event names the exact subject GitHub sent.

**Steps:**

1. Read the subject out of CloudTrail. This needs no code change and no push, and it works on failures that have already happened — which matters when `main` is red and you would rather not add a commit to find out why:

   ```bash
   aws cloudtrail lookup-events \
     --lookup-attributes AttributeKey=EventName,AttributeValue=AssumeRoleWithWebIdentity \
     --max-results 20 --region eu-central-1 \
     --query 'Events[].CloudTrailEvent' --output json \
   | jq -r '.[] | fromjson | select(.errorCode == "AccessDenied") | .userIdentity.userName' \
   | head -1
   ```

   The output **is** the `sub` claim, verbatim. The same event also names the role that was requested, under `resources`, which is what separates "wrong subject" from "wrong role ARN in `AWS_ROLE_ARN`".

2. Compare it against the trust policy character by character. The usual mismatches:

   | Printed `sub` | Cause |
   |---|---|
   | `repo:...:pull_request` | The workflow ran on a PR rather than a push to `main` |
   | `repo:...:environment:prod` | The job declares an `environment:`, which changes the claim |
   | a different username or repo name | The fork was renamed, or the policy names the platform repo by mistake |
   | `repo:...:ref:refs/heads/master` | The branch is not `main` |
   | `repo:owner@1234/repo@5678:...` while the policy has no `@` | The token carries **immutable subject IDs** and the policy does not. GitHub issues these for repositories created after 2026-07-15 and they cannot be switched off. Fix the trust policy, not the workflow — see "OIDC Federation" above |

3. Compare `aud` against `sts.amazonaws.com`. A mismatch here means the workflow requested a different audience than the trust policy allows.

4. Only if CloudTrail holds no event — the run failed before reaching STS, or trail logging is off — fall back to printing the claims from inside the workflow. This needs `id-token: write`, which the workflow already has:

   ```yaml
   - name: Decode OIDC token claims (temporary diagnostic)
     run: |
       TOKEN=$(curl -sS \
         -H "Authorization: bearer ${ACTIONS_ID_TOKEN_REQUEST_TOKEN}" \
         "${ACTIONS_ID_TOKEN_REQUEST_URL}&audience=sts.amazonaws.com" | jq -r '.value')
       echo "${TOKEN}" | cut -d. -f2 | base64 -d 2>/dev/null | jq '{sub, aud, iss, ref, repository}'
   ```

5. Remove the diagnostic step once resolved. It prints a valid token to the workflow log, and while that token is short-lived and scoped to this role, leaving it in a public repository's logs is not worth the convenience.

**Verify:**

- `configure-aws-credentials` succeeds and `aws sts get-caller-identity` in a later step reports the expected role ARN.

**Rollback:**

- Remove the diagnostic step and commit.

---

## Procedure: extend the federation to a second environment

**When:** Bringing up prod, or any environment beyond the one that already created the provider.
**Who:** Engineer with permission to apply that environment's root module.
**Time:** 10 minutes.

**Read this first.** An AWS account may hold **only one** OIDC provider for a given URL, and the provider is account-global while the module is per-environment. Dev currently creates it. A second environment that also sets `create_oidc_provider = true` fails its apply with `EntityAlreadyExists`.

**Steps:**

1. Read the provider ARN from the environment that owns it:

   ```bash
   cd terraform/environments/dev && terraform output -raw github_oidc_provider_arn
   ```

2. In the second environment's root module, add the module with the flag inverted and the ARN passed in:

   ```hcl
   module "github_oidc" {
     source = "../../modules/github-oidc"

     project     = var.project
     environment = var.environment

     github_repository = "truongnvnse/spring-petclinic-microservices"
     github_branch     = "main"

     repository_arns = values(module.ecr.repository_arns)

     create_oidc_provider      = false
     existing_oidc_provider_arn = "<provider-arn-from-step-1>"
   }
   ```

3. Apply. Only the role and its policy are created; the provider is referenced, not managed.

**Verify:**

- `terraform state list | grep github_oidc` shows the role and policy but **not** `aws_iam_openid_connect_provider.github` — a second provider in state means the flag was not inverted.
- The new role's trust policy names the same provider ARN as dev's.

**Rollback:**

- Remove the module block and apply. The provider is untouched, because this environment never managed it.

> **The consequence to plan around:** the provider belongs to dev. `terraform destroy` on dev deletes it, and every other environment's CI stops being able to assume its role until dev is re-applied — an outage that looks like a broken prod pipeline but originates in dev. If that coupling becomes unacceptable, move the provider into its own root module that neither environment destroys.

---

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `EntityAlreadyExists` on apply | Two environments both set `create_oidc_provider = true` | Invert the flag in all but one; see the procedure above |
| `Not authorized to perform sts:AssumeRoleWithWebIdentity` | Subject or audience mismatch | Read the subject out of CloudTrail; see the diagnosis procedure. A token carrying `@` IDs that the policy lacks means immutable subject claims |
| `Credentials could not be loaded` / token request fails | Missing `id-token: write` | Add it to the workflow's `permissions:` block |
| `AccessDenied` on `ecr:PutImage` | The repository ARN is not in `repository_arns` | Confirm the service is in the ECR module's `service_names` |
| Push to ECR fails only for one service | That repository is missing from the ECR module | Add it to `service_names` and re-apply |
| `update-image-tags` runs but ArgoCD does not deploy | ArgoCD is not installed yet (E-17) | See `docs/rollback-runbook.md`; the commit is correct, there is no controller watching it |
| Prod pods go to `ImagePullBackOff` after a dev build | The tag was pushed to `petclinic-dev/*` only, but prod pulls from `petclinic-prod/*` | See "Promotion: one tag, two registries" above — prod needs its own build before its first sync |
| The build job is skipped entirely | Nothing buildable changed — a docs-only commit matches no filter | Expected. `changes` returns `[]` and an empty matrix is an error, so the job skips by design. No tag is dispatched. |
| A `pom.xml` or `docker/Dockerfile` change rebuilt all eight | The `shared` filter matched | Expected — those files are inputs to every image. See "What the build actually builds". |
| The Trivy gate fails the build | At least one CRITICAL in the image | Read `trivy-{service}-gate.txt` from the run artifact (it is also printed in the log). Fix it, or add a documented exception to `.trivyignore`. |
| `::warning::` about `client_payload.services` on every dispatch | `build-push.yml` pushes only changed services; `update-image-tags.yml` writes all eight | Not a random fault — it reports a known divergence, so it fires on almost every dispatch. That frequency is the problem, not a reassurance: a warning that is always present is one nobody reads. See the next row. |
| Pods go to `ImagePullBackOff` after a dispatch | The tag was written for a service the build never pushed | Those services are **down**, not merely behind — "expected" here means "predicted", never "harmless". It is the direct consequence of writing all eight files from a subset payload. `docs/rollback-runbook.md` → "Rollback: a tag that is not in ECR" is the recovery; the fix is to write only the services named in `client_payload.services`. |
| A pod starts and dies with `exec format error` | An amd64 image on a Graviton (t4g) node | The image was built without `platforms: linux/arm64`. Check the build job's platform, not the manifest. |
| `Assumed a role in account X, but AWS_ACCOUNT_ID is Y` | `AWS_ROLE_ARN` points at another account's role | Fix `AWS_ROLE_ARN`. The push would otherwise have succeeded into a registry nothing reads. |

## Related

**In this repository**

- `terraform/modules/github-oidc/` — the module, with the trust-policy reasoning inline
- `.github/workflows/update-image-tags.yml` — the workflow that consumes the dispatch
- `docs/rollback-runbook.md` — reverting a tag this pipeline committed
- `docs/ecr-operations.md` — what happens to the images once pushed
- `docs/technical-spec.md` → "CI/CD Pipeline"

**In the application repository** (`../spring-petclinic-microservices/`)

- `.github/workflows/build-push.yml` — the orchestrator
- `.github/workflows/build-image.yml` — the per-service build, with the reasoning for deviating from the spec's `-P buildDocker` route in its header. It sits at the top level of `.github/workflows/`, not in a `reusable/` subdirectory: GitHub does not support subdirectories there, and the only symptom is a red X on the `uses:` line after a push — **no local linter catches it, `actionlint` included**. That is not a guess: actionlint 1.7.12 flags a bogus job key and an undefined `${{ }}` in the same file, so it is reading it, yet it exits 0 on a `uses:` pointed at a subdirectory *and* 0 on one pointed at a file that does not exist. It does not resolve local `uses:` paths at all. Check it by pushing.
- `.github/actions/ecr-login/action.yml` — the login, and why it is an action and not a workflow
- `.trivyignore` — the only route past the gate, and what an entry has to record

PETPLAT-49, PETPLAT-50, PETPLAT-52, PETPLAT-53, PETPLAT-87, PETPLAT-105
