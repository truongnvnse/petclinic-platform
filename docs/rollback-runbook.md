# Rollback Runbook

**Last Updated:** 2026-10-11
**Purpose:** Recover a petclinic service from a bad deployment. CD is ArgoCD, so the durable rollback is always a Git change — the other two methods exist for the window before Git is fixed.
**Applies to:** `dev` and `prod`. Each procedure says where the two differ.

> **Not yet verified, and not yet runnable.** Three things are missing, and each one blocks a different part of this document:
>
> - **ArgoCD is not installed** — E-17 (PETPLAT-112…114). `k8s/argocd/` does not exist, so every `argocd` command below has nothing to talk to.
> - **The pipeline that produces image tags has never run.** `update-image-tags.yml` exists in this repo, but the workflow that fires it — `build-push.yml` in the app repo — is PETPLAT-49's deliverable and does not exist. No tag commit has ever been made by CI, so no tag has ever been reverted either.
> - **Prod has been planned but never applied.** `terraform/environments/prod/plan.out` exists; there is no apply log beside it, and no prod cluster. Every prod branch below is unrunnable today.
>
> Every command is therefore written against the documented behaviour of the tools, not against a rollback that has actually been performed. PETPLAT-54's acceptance criterion "rollback tested" is **not** satisfied by this document alone — run "Procedure: rehearse a rollback" on dev once E-17 lands, before relying on any of it.

## Table of Contents

1. [Which method to use](#which-method-to-use)
2. [Prerequisites](#prerequisites)
3. [Procedure: rollback by reverting the image tag](#procedure-rollback-by-reverting-the-image-tag)
4. [Procedure: rollback with ArgoCD](#procedure-rollback-with-argocd)
5. [Procedure: emergency rollback with kubectl](#procedure-emergency-rollback-with-kubectl)
6. [Procedure: rollback when the tag is not in ECR](#procedure-rollback-when-the-tag-is-not-in-ecr)
7. [Procedure: rehearse a rollback](#procedure-rehearse-a-rollback)
8. [Troubleshooting](#troubleshooting)
9. [What a rollback does not cover](#what-a-rollback-does-not-cover)
10. [What limits a rollback here](#what-limits-a-rollback-here)

---

## Which method to use

| Situation | Method | Why |
|---|---|---|
| A bad image was deployed and Git is healthy | [Revert the image tag](#procedure-rollback-by-reverting-the-image-tag) | The only one that survives the next ArgoCD reconcile |
| Git is healthy, you want the previous sync without a commit | [ArgoCD rollback](#procedure-rollback-with-argocd) | Faster, but on dev it is undone by self-heal |
| ArgoCD is unreachable and the service is down | [kubectl rollout undo](#procedure-emergency-rollback-with-kubectl) | Buys time; does not fix Git, so the problem returns on the next sync |
| Pods are in `ImagePullBackOff` after a tag update | [Tag not in ECR](#procedure-rollback-when-the-tag-is-not-in-ecr) | Different cause: the tag was never pushed, so no pod can start — see that section before assuming the service is fine |

The order matters. In dev the ArgoCD Application is configured with `automated: {selfHeal: true, prune: true}` (PETPLAT-113), so **anything done outside Git is reverted automatically** — including an ArgoCD rollback and a `kubectl rollout undo`. Only the Git revert is durable there.

---

## Prerequisites

None of the procedures below work without these. Check them before an incident, not during one.

1. **kubectl connected to the cluster.** The API server allowlist is a `/32` — your current IP must be on it, or `kubectl` hangs until it times out rather than returning an error. This is the same dependency the ArgoCD UI has, so a stale allowlist takes out *both* the emergency path and the normal one. See `docs/eks-operations.md` → "Procedure: connect kubectl to a cluster" and "Procedure: update the API server allowlist".

2. **argocd CLI, logged in through a port-forward.** ArgoCD has no public endpoint:

   ```bash
   kubectl port-forward svc/argocd-server -n argocd 8443:443
   argocd login localhost:8443 --insecure
   ```

3. **yq**, for the rehearsal procedure only. Any v4 release.

4. **Know the port**, for the health check that ends every procedure:

   | Service | Port | Service | Port |
   |---|---|---|---|
   | `config-server` | 8888 | `visits-service` | 8082 |
   | `discovery-server` | 8761 | `vets-service` | 8083 |
   | `api-gateway` | 8080 | `genai-service` | 8084 |
   | `customers-service` | 8081 | `admin-server` | 9090 |

---

## Procedure: rollback by reverting the image tag

**When:** A deployment is bad and the cause is the image tag committed by `update-image-tags.yml`.
**Who:** Engineer with push access to the platform repo, plus ArgoCD sync permission for prod.
**Time:** 5 minutes for dev, 10–15 for prod (manual sync approval).

**Steps:**

1. Find the commit that set the bad tag. Every tag update has the same message shape, so the list is short:

   ```bash
   git -C ~/path/to/petclinic-platform log --oneline -20 -- helm-values/
   ```

   The commit you want is the one matching `ci: update image tags to {sha} ({service-list})`.

2. Read what it changed before reverting — a revert of the wrong commit is its own incident:

   ```bash
   git -C ~/path/to/petclinic-platform show <commit-sha> -- helm-values/
   ```

3. Revert it. `git revert` rather than editing the files by hand, so the history records that a rollback happened and the reverted commit stays auditable:

   ```bash
   git -C ~/path/to/petclinic-platform revert --no-edit <commit-sha>
   git -C ~/path/to/petclinic-platform push origin main
   ```

4. **dev** — nothing more. The Application auto-syncs within its polling interval (3 minutes by default, or immediately if a webhook is configured).

   **prod** — the Application has `syncPolicy: manual` (PETPLAT-114), so the revert alone changes nothing that is running. Approve the sync:

   ```bash
   argocd app sync {service}-prod
   ```

   Or use the ArgoCD UI and press **Sync**. Until someone does, prod keeps running the bad image.

5. If the revert conflicts because a newer tag update landed on top of it, do not force it. Revert the newest commit instead, or set the tag back by hand in `helm-values/{service}.yaml` and commit that — the goal is a correct value at HEAD, not a tidy history.

**Verify:**

- ArgoCD shows the app `Synced` and `Healthy`:
  ```bash
  argocd app get {service}-{env}
  ```
- The running pod's image carries the older tag:
  ```bash
  kubectl get pods -n petclinic-{env} -l app.kubernetes.io/name={service} \
    -o jsonpath='{.items[*].spec.containers[0].image}'
  ```
- The service answers:
  ```bash
  kubectl port-forward -n petclinic-{env} svc/{service} {port}:{port}
  curl -s http://localhost:{port}/actuator/health
  ```
  Expect `{"groups":["liveness","readiness"],"status":"UP"}`. For `config-server` expect a config document instead — its `/actuator/*` paths are served by the Config Server's own controller, not by Spring Boot's actuator. See `helm/petclinic-service/README.md` → "Probes".

**Rollback:**

- Of this procedure: the revert is itself a commit, so `git revert` that one to return to the bad tag — normally the wrong move, but it is the way back if the "bad" deployment turns out to have been correct.
- **There is no per-environment tag.** `helm-values/{service}.yaml` is merged into *both* Applications — ArgoCD combines it with `dev.yaml` for dev and with `prod.yaml` for prod, and only the env file differs. `image.tag` appears in the service file alone. So one tag serves dev and prod at once, and reverting it reverts both. Rolling back prod on its own means editing the values file in a way that diverges the two environments, which this layout does not support — expect to roll back both or neither.

---

## Procedure: rollback with ArgoCD

**When:** Git is healthy but you want the previous synced revision without writing a commit — typically while diagnosing.
**Who:** ArgoCD sync permission for the target Application.
**Time:** 2 minutes.

**Steps:**

1. List the sync history:

   ```bash
   argocd app history {service}-{env}
   ```

   The output has two columns that are easy to confuse, and only one of them works with `rollback`:

   - the **ID** column is ArgoCD's own counter, counting syncs of this Application — this is the number `argocd app rollback` takes;
   - the **revision** column is the Git commit that sync deployed.

   Passing a Git SHA to `rollback` fails, and passing an ID to a command expecting a revision does something else entirely. Read the column headers.

2. Roll back to the revision before the bad one:

   ```bash
   argocd app rollback {service}-{env} <revision-id>
   ```

   In the UI: open the Application, **History and rollback**, pick the revision, **Rollback**.

3. **On dev, expect this to be undone.** The Application has `selfHeal: true`, so the next reconcile compares the cluster against Git HEAD, finds the rolled-back state differs, and syncs forward again. That is not a bug — it is GitOps working. Treat the rollback as a stopgap and follow it with the Git revert above.

   On prod the Application is manual-sync, so a rollback persists until someone syncs to HEAD.

4. If the Application is stuck mid-operation — `argocd app get` shows an operation running that will not finish, usually because a sync is waiting on a resource that cannot become healthy — terminate it before retrying. A stuck operation holds the Application and a fresh `sync` is refused while it runs:

   ```bash
   argocd app terminate-op {service}-{env}
   ```

**Verify:**

- `argocd app get {service}-{env}` reports the expected revision as `Synced`.
- Watch it for a few minutes on dev. If it flips back to the bad revision on its own, self-heal is doing its job and the Git revert is the only fix.

**Rollback:**

- `argocd app sync {service}-{env}` returns the app to Git HEAD.

---

## Procedure: emergency rollback with kubectl

**When:** ArgoCD is unreachable, Git is not an option in the next few minutes, and the service is down.
**Who:** Cluster write access. This is the only procedure here that writes to the cluster directly.
**Time:** 2 minutes.

**Read this first:** if ArgoCD is unreachable because the EKS API allowlist no longer contains your IP, this procedure is unreachable too — `kubectl` talks to the same endpoint the ArgoCD UI does, and it fails by hanging rather than by erroring. Fix the allowlist (`docs/eks-operations.md` → "Procedure: update the API server allowlist") and use the normal path; reach for this one when the *cluster* is up and only ArgoCD is not.

**Steps:**

1. Check what is available to roll back to. The history is bounded by the Deployment's `revisionHistoryLimit`, which the chart does not set, so it is Kubernetes' default of 10:

   ```bash
   kubectl rollout history deployment/{service} -n petclinic-{env}
   ```

2. Roll back one revision:

   ```bash
   kubectl rollout undo deployment/{service} -n petclinic-{env}
   ```

   Or to a specific revision:

   ```bash
   kubectl rollout undo deployment/{service} -n petclinic-{env} --to-revision=<n>
   ```

3. Treat this as a bridge, not a fix. It restores a previous pod template, which references an older image tag — and that tag must still exist in ECR (see "What limits a rollback here"). Then do the Git revert, because:

   - on **dev**, `selfHeal: true` reverts this within one reconcile interval;
   - on **prod**, the next sync by anyone undoes it;
   - in both, Git still names the bad tag, so the problem returns.

**Verify:**

- `kubectl rollout status deployment/{service} -n petclinic-{env}` completes.
- The same health check as the GitOps procedure above.

**Rollback:**

- `kubectl rollout undo` again returns to the newer revision, provided it is still in the history window.

---

## Procedure: rollback when the tag is not in ECR

**When:** Pods sit in `ImagePullBackOff` or `ErrImagePull` right after a tag update, and `kubectl describe pod` shows a manifest-unknown or not-found error for the image.
**Who:** Engineer with push access to the platform repo, plus ECR read access.
**Time:** 10 minutes.

This is a distinct failure from a bad image, and it is easy to misread in both directions.

The Deployment **is** updated: the commit changed the pod template, ArgoCD synced it, and a new ReplicaSet exists asking for a tag that was never pushed. What cannot happen is a *pod* — the kubelet has nothing to pull. So there is no bad code running, and no new code either.

The consequence of that is the part worth understanding before you triage it. The chart sets `maxUnavailable: 0` and `maxSurge: 1`, so the old ReplicaSet keeps every pod it has, and the service keeps serving traffic normally. Nothing looks broken. But the new ReplicaSet can never become available, so there is no spare capacity and no replacement: the first node drain, eviction, OOM restart or cluster autoscaler scale-down that removes an old pod takes a replica with it permanently. The service is up on borrowed time, and the clock is not visible from the outside.

Treat it as an outage in progress rather than a failed deploy, and do not wait for someone to notice — nobody will.

**Steps:**

1. Confirm which services are affected and what tag they are asking for:

   ```bash
   kubectl get pods -n petclinic-{env} \
     -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.containers[0].image}{"\n"}{end}'
   ```

   Also confirm the old pods are still the ones serving, which is what makes the service look healthy:

   ```bash
   kubectl get rs -n petclinic-{env} -l app.kubernetes.io/name={service}
   ```

2. Check whether that tag exists in ECR:

   ```bash
   aws ecr describe-images --region eu-central-1 \
     --repository-name petclinic-{env}/{service} \
     --image-ids imageTag=<tag>
   ```

3. The likely cause is the assumption flagged in `.github/workflows/update-image-tags.yml`: that workflow writes the new SHA into **all eight** values files, which is only correct if `build-push.yml` pushed all eight images at that SHA. If the build only pushes the services whose directories changed, the others point at tags that do not exist. The workflow logs a `::warning::` annotation when the dispatch payload names a subset — check the failed-or-warned run before assuming anything else.

   The fix is to revert the tag update ([rollback by reverting the image tag](#procedure-rollback-by-reverting-the-image-tag)) so the unaffected services go back to a tag that exists, and then either change the build to push all eight or change the workflow to update only the services named in the dispatch payload.

4. If the tag *should* exist, re-run the build in the app repo rather than hand-pushing an image. A hand-pushed image is not reproducible from the commit and breaks the property that the tag identifies what was built.

**Verify:**

- The pods leave `ImagePullBackOff` and reach `Running`:
  ```bash
  kubectl get pods -n petclinic-{env} -w
  ```
- The Deployment reports its full replica count available, which is the check that actually distinguishes "recovered" from "still on the old ReplicaSet":
  ```bash
  kubectl rollout status deployment/{service} -n petclinic-{env} --timeout=5m
  ```

**Rollback:**

- Reverting the tag update is the rollback. If the revert itself is wrong, `git revert` the revert.

---

## Procedure: rehearse a rollback

**When:** Before trusting this runbook, and after any change to the ArgoCD Applications or the tag-update workflow. This is what satisfies PETPLAT-54's "rollback tested" criterion.
**Who:** Engineer with dev access. **Dev only** — never rehearse on prod.
**Time:** 20 minutes.

**Blocked until E-17.** ArgoCD is not installed, so the sync this procedure depends on never happens and the rehearsal proves nothing. Run it once `k8s/argocd/` exists and the dev Application is syncing.

**Read this before starting.** A rehearsal writes a bad tag into `helm-values/{service}.yaml`, and that file is the shared service file: ArgoCD merges it with `dev.yaml` for dev and with `prod.yaml` for prod. The commit therefore changes **prod's desired state too**. Dev self-heals into it within a reconcile; prod is manual-sync, so it will not deploy on its own — but prod's desired state is now the rehearsal tag, and the next person who syncs prod for any reason deploys it. The rehearsal is only safe while:

- nobody syncs prod for the duration, and
- the revert in step 4 is completed rather than abandoned.

If prod is live and you cannot guarantee both, rehearse with a service that prod does not run, or do not rehearse.

**Steps:**

1. Pick a service and record its current tag:

   ```bash
   grep -A3 '^image:' helm-values/{service}.yaml
   ```

2. Deploy a deliberately bad tag on dev by committing a tag that does not exist:

   ```bash
   yq -i '.image.tag = "rollback-rehearsal"' helm-values/{service}.yaml
   git commit -am "test: rollback rehearsal (revert me)" && git push
   ```

   Note what this exercises: a tag that is absent from ECR, which is the [tag-not-in-ECR](#procedure-rollback-when-the-tag-is-not-in-ecr) path. It does **not** exercise the bad-image path, which needs an image that pulls and then misbehaves — build one deliberately if you want to rehearse that, and expect the pods to reach `Running` first.

3. Wait for ArgoCD to sync and confirm the failure looks the way this runbook says it will:

   ```bash
   kubectl get pods -n petclinic-dev -l app.kubernetes.io/name={service}
   kubectl get rs -n petclinic-dev -l app.kubernetes.io/name={service}
   ```

   Check both the pods and the ReplicaSets. The claim to test is the one in the section above: the old pods are still serving and the new ReplicaSet never becomes available. If instead the service went down, this runbook is wrong and needs correcting before it is relied on.

4. Walk through the GitOps rollback procedure and time it.

5. Confirm the service recovers, then confirm Git is clean and the tag is back:

   ```bash
   git log --oneline -3 -- helm-values/
   yq '.image.tag' helm-values/{service}.yaml
   ```

**Verify:**

- The service returns to `1/1 Running` with the original tag.
- The rehearsal commits are visible in history and the final state matches the original tag.
- `git log` shows the revert landed — an abandoned rehearsal leaves a bad tag in prod's desired state.

**Rollback:**

- The procedure is itself a revert; nothing extra is needed beyond step 4. If you stop early, revert the rehearsal commit by hand before anyone syncs prod.

---

## Troubleshooting

| Symptom | Likely cause | Where to look |
|---|---|---|
| `argocd` commands hang or the UI will not load | Your IP is not in the EKS API allowlist | `docs/eks-operations.md` → "Procedure: update the API server allowlist" |
| `kubectl` hangs with no error | Same allowlist; the API endpoint is unreachable | As above |
| `argocd app rollback` rejects the revision | A Git SHA was passed where the history ID was wanted | Read the two columns from `argocd app history` — see the ArgoCD procedure |
| `argocd app sync` refuses to start | An earlier operation is still running | `argocd app terminate-op {service}-{env}` |
| Dev rolls back, then flips forward again within minutes | `selfHeal: true` reconciling against Git HEAD | Expected — the Git revert is the durable fix |
| Pods in `ImagePullBackOff` but the service is healthy | The tag was never pushed; old pods are still serving | [Tag not in ECR](#procedure-rollback-when-the-tag-is-not-in-ecr) — treat as an outage in progress |
| `kubectl rollout undo` reports no revision to undo to | The revision aged out of the 10-entry history window | Use the Git revert instead |
| Rollback succeeds but the service still misbehaves | The bad change was not the image tag | "What a rollback does not cover" below |

---

## What a rollback does not cover

Reverting an image tag reverts one thing: which image the pods run. Several other changes are deployed by the same ArgoCD Application and are **not** touched by any procedure above.

- **Chart changes.** `helm/petclinic-service/` is in the same Application. A bad probe timeout, resource limit or env var is a chart change, and reverting a tag commit does not undo it. Revert the chart commit.
- **Config-server's config source.** The Config Server serves configuration from an external Git repository — `https://github.com/spring-petclinic/spring-petclinic-microservices-config`, set in the application repo's own `application.yml`, not in `helm-values/`. A bad config commit there is live the moment Config Server refreshes, and no image tag rollback reaches it. Revert it in that repository.
- **Secret values.** The ExternalSecrets refresh on a 1-hour interval, so a rotated or corrupted value in AWS Secrets Manager is picked up by External Secrets Operator on its own schedule — not when you deploy. Rolling back the image tag leaves the new value in place, and pods restarted during the rollback come up holding it. Restore the previous value in Secrets Manager; see `k8s/base/external-secrets/README.md` → "Rotating a secret".
- **Terraform changes.** Infrastructure is applied by hand from `terraform/environments/{env}/`, not by ArgoCD. A rollback here does not touch it.

If the service is still wrong after a tag rollback, the cause is one of these four, not the image.

---

## What limits a rollback here

Four constraints are worth knowing before an incident, because each one can make the obvious rollback target unavailable:

- **ECR keeps only the last 10 tagged images per repository.** The lifecycle policy in `terraform/modules/ecr/` expires untagged images after 7 days and keeps the last 10 tagged ones. A rollback target older than ten builds is gone, and the rollback then fails at image pull rather than at sync.
- **Dev tags are MUTABLE, prod tags are IMMUTABLE.** Prod sets `image_tag_mutability = "IMMUTABLE"` explicitly; dev takes the module's environment-derived default of `MUTABLE`. In prod the tag is the identity of what was deployed, so a tag cannot be overwritten — which is what makes a rollback target trustworthy. In dev a re-push can move a tag under a rollback, so a dev rollback proves the mechanism, not the exact bits.
- **Dev is destroyed between sessions to save cost**, and dev sets the ECR module's `force_delete = true` so a teardown can empty the repositories. Prod deliberately leaves it false, so prod images survive a teardown. The consequence for a dev rollback: every image in `petclinic-dev/*` **is** gone along with the environment, not merely at risk. A dev rollback target from a previous session does not exist.
- **`revisionHistoryLimit` bounds the kubectl path only.** The chart does not set it, so it is the Kubernetes default of 10. Once a revision falls out of that window, `kubectl rollout undo` cannot reach it — the Git and ArgoCD paths are unaffected.

## Related

- `helm/petclinic-service/README.md` — probe paths, including why `config-server` differs
- `.github/workflows/update-image-tags.yml` — the workflow whose commits this runbook reverts
- `docs/ci-operations.md` — the pipeline that produces those commits, and how to diagnose it
- `docs/ecr-operations.md` — image lifecycle, tag immutability, and what is actually in the registry
- `docs/eks-operations.md` — the API allowlist that both the emergency and the normal paths depend on
- `k8s/base/external-secrets/README.md` — the secret values a tag rollback does not revert, and how to rotate them
- `docs/technical-spec.md` → "GitOps with ArgoCD", "CI/CD Pipeline"
- PETPLAT-50, PETPLAT-54, PETPLAT-87, PETPLAT-113, PETPLAT-114
