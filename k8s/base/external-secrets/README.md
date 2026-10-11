# External Secrets

How AWS Secrets Manager reaches the application pods, and how to add a secret
that does not exist yet.

**Last updated:** 2026-10-10

## Contents

| File | Object | Purpose |
|------|--------|---------|
| `namespace.yaml` | Namespace `external-secrets` | Where the operator runs |
| `serviceaccount.yaml` | ServiceAccount `external-secrets-sa` | The identity the store authenticates as — **contains a placeholder, see below** |
| `clustersecretstore.yaml` | ClusterSecretStore `aws-secrets-manager` | The connection to AWS |
| `rds-credentials.yaml` | ExternalSecret `rds-credentials` | RDS master credentials → `petclinic-dev` |
| `openai-api-key.yaml` | ExternalSecret `openai-api-key` | OpenAI API key → `petclinic-dev` |

Installed by `scripts/install-eso.sh` (PETPLAT-34). The operator itself is not
in this directory — the script downloads the pinned upstream release bundle and
applies it.

**Do not `kubectl apply` `serviceaccount.yaml` by hand.** Its
`eks.amazonaws.com/role-arn` annotation is the literal string `<ESO_ROLE_ARN>`,
which the script substitutes at install time. Applying the file as-is does not
fail — nothing validates that annotation — so it quietly replaces a working role
ARN with a non-ARN, and the ClusterSecretStore goes `Ready=False` on the next
reconcile with nothing in the ServiceAccount to suggest why. If you need to
apply it manually, substitute the ARN first:

```bash
terraform -chdir=terraform/environments/dev output -raw eso_role_arn
```

## How it fits together

```
AWS Secrets Manager                 EKS cluster
┌────────────────────────┐          ┌──────────────────────────────────────┐
│ petclinic/dev/         │          │ external-secrets namespace           │
│   rds-credentials      │◄─────────┤   external-secrets-sa (IRSA)         │
│   openai-api-key       │  IRSA    │   ClusterSecretStore                 │
└────────────────────────┘          │     aws-secrets-manager              │
                                    └──────────────┬───────────────────────┘
                                                   │ references
                                    ┌──────────────▼───────────────────────┐
                                    │ petclinic-dev namespace              │
                                    │   ExternalSecret rds-credentials     │
                                    │     └─► Secret rds-credentials       │
                                    │   ExternalSecret openai-api-key      │
                                    │     └─► Secret openai-api-key        │
                                    └──────────────────────────────────────┘
```

Nothing in this repository contains a secret value. The value lives in Secrets
Manager; Terraform writes it there from a sensitive variable
(`terraform/modules/secrets/`), and the operator copies it into the cluster.

## Adding a new secret

Worked example: a `STRIPE_API_KEY` for a new payment service.

### 1. Create the secret in Secrets Manager

Add a resource to `terraform/modules/secrets/main.tf`, following the existing
`openai_api_key` block:

```hcl
resource "aws_secretsmanager_secret" "stripe_api_key" {
  name        = "${var.project}/${var.environment}/stripe-api-key"
  description = "Stripe API key for the ${local.name_prefix} payment-service"
  tags        = merge(local.common_tags, { Name = "..." })
}

resource "aws_secretsmanager_secret_version" "stripe_api_key" {
  secret_id                = aws_secretsmanager_secret.stripe_api_key.id
  secret_string_wo         = var.stripe_api_key
  secret_string_wo_version = var.stripe_api_key_version
}
```

Add the matching `variable "stripe_api_key"` with `sensitive = true`,
`ephemeral = true` and a default of `""`, a `stripe_api_key_version` number, an
output, and a line in each environment's `terraform.tfvars`. The write-only form and the
version counter go together: they are what keep the value out of `terraform.tfstate`
and `plan.out`, at the cost of Terraform being unable to notice a change on its
own — see the rotation section below.

Give it a default of `""` and put the "must be a real key" check in a
`lifecycle.precondition` on the secret version rather than in the variable's
`validation` block. Destroy evaluates validations but skips preconditions, so a
validation that rejects `""` makes `terraform destroy` fail on the whole
environment over a value it never reads.

**The name must start with `petclinic/{env}/`.** The ESO role's IAM policy grants
read on `secret:petclinic/{env}/*` for that environment and nothing else, so a
secret created under any other prefix is invisible to the operator — it applies
cleanly and then fails to sync. Note the environment segment: the dev role
cannot read `petclinic/prod/...`, so a prod secret is not reachable from a dev
ExternalSecret even though both environments share one AWS account.

Apply it:

```bash
cd terraform/environments/dev
terraform plan -out plan.out && terraform apply plan.out
```

### 2. Write the ExternalSecret

Copy `openai-api-key.yaml` — the plaintext case — or `rds-credentials.yaml` if
the secret is a JSON object with several fields. Change the metadata name, the
namespace, `target.name`, and the `remoteRef.key`.

The one thing to get right is `remoteRef.property`, and it depends on the shape
of the remote value:

| Remote value | Manifest |
|--------------|----------|
| Plaintext string | no `property`; one `data` entry |
| JSON object | one `data` entry per field, each with `property` |

A `property` on a plaintext secret fails loudly — ESO reports that it cannot
parse the value as JSON. Leaving `property` off a JSON secret fails **quietly**:
the whole JSON blob is copied into the key and the application receives it as
its credential. Prefer plaintext for single values so the two cases cannot be
confused.

### 3. Apply and verify

```bash
kubectl apply -f k8s/base/external-secrets/stripe-api-key.yaml
kubectl get externalsecret stripe-api-key -n petclinic-dev
kubectl get secret stripe-api-key -n petclinic-dev
```

`SecretSynced=True` is the whole check — ESO sets it only after the Kubernetes
Secret has been written.

### 4. Consume it

Reference the Secret from the service's Helm values as an environment variable
(`envFrom` or `valueFrom.secretKeyRef`), never as a literal. See
`.claude/rules/kubernetes.md` → Secrets.

## Troubleshooting

| Symptom | Cause |
|---------|-------|
| `SecretSynced=False`, `ResourceNotFoundException` | The remote secret does not exist, or the `remoteRef.key` has a typo. Check `aws secretsmanager describe-secret --secret-id <name>` |
| `SecretSynced=False`, `AccessDeniedException` | The secret name does not start with `petclinic/{env}/` for this environment, or it lives in another region |
| ClusterSecretStore `Ready=False` | The IRSA trust policy does not name `system:serviceaccount:external-secrets:external-secrets-sa`, or the service account's `eks.amazonaws.com/role-arn` annotation points at the wrong role |
| Pods in `CreateContainerConfigError` | The Deployment was applied before the ExternalSecret synced; the Secret it mounts does not exist yet |
| Secret does not update after a change | `refreshInterval` is 1h. Force it: `kubectl annotate externalsecret <name> -n <ns> force-sync=$(date +%s) --overwrite` |

Diagnostics:

```bash
kubectl describe clustersecretstore aws-secrets-manager
kubectl describe externalsecret <name> -n petclinic-dev
kubectl logs -n external-secrets deploy/external-secrets
```

## Rotating a secret

Update the value in Secrets Manager and the operator picks it up within
`refreshInterval` (1h). The running pods keep the old value until they restart —
Kubernetes does not restart a pod because a mounted Secret changed, so a rotation
is two steps: change the value, then `kubectl rollout restart` the consumers.

For a value managed by Terraform, change the variable and apply rather than
editing the console, so the state file and Secrets Manager agree.

**Changing the variable alone is not enough.** The module writes these values
through a write-only argument, which Terraform hands to AWS and then discards —
it can never read the value back, so editing `openai_api_key` in `terraform.tfvars`
produces an empty plan and leaves the old key in Secrets Manager. Rotating is
therefore two edits: the new value, and `openai_api_key_version` bumped in
`terraform/environments/{env}/main.tf`. That number is the only thing Terraform
diffs, and the plan will show the secret version being replaced.

To confirm the new value landed without printing it:

```bash
terraform output -raw openai_secret_version_id
```
