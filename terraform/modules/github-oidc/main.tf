# main.tf — github-oidc module (PETPLAT-52)
#
# Federated identity for GitHub Actions: CI assumes a role with a short-lived
# token instead of holding an AWS access key.
#
# Design — docs/technical-spec.md → "CI/CD Pipeline" → "OIDC Federation":
#   * Provider  token.actions.githubusercontent.com, audience sts.amazonaws.com
#   * Subject   repo:{owner}@{owner_id}/{repo}@{repo_id}:ref:refs/heads/main
#               (the IDs are required — see github_subject in locals below)
#   * Role      petclinic-{env}-github-actions-role
#   * Rights    ECR push only — no S3, no DynamoDB, because CI never runs
#               Terraform (the spec says that explicitly)
#
# ---------------------------------------------------------------------------
# Why the subject names the APPLICATION repo and not this one
# ---------------------------------------------------------------------------
#
# It looks backwards, and it is the single most important line in this module.
# The pipeline is split across two repositories and only one half talks to AWS:
#
#   app repo       build-push.yml         builds ARM64 images, pushes to ECR
#   platform repo  update-image-tags.yml  edits YAML, pushes a commit
#
# Only the app repo's build workflow needs the role. update-image-tags.yml runs
# yq and `git push` and calls no AWS API at all, so it assumes nothing. Scoping
# the trust policy to the platform repo would therefore hand the role to the one
# workflow that never uses it and withhold it from the one that does — and the
# failure would be an AccessDenied inside the app repo's build, pointing at a
# policy that lives in a different repository.
#
# Note that build-push.yml is PETPLAT-49's deliverable and does not exist yet;
# the app repo currently carries maven-build.yml and check-pr-template.yml. This
# module is therefore ahead of the workflow that will use it, which is
# deliberate — the role has to exist before the workflow can be written against
# it. Two things must hold when it lands: it triggers on push to `main`, and it
# declares `permissions: id-token: write`. maven-build.yml also triggers on
# pull_request, and that trigger must NOT be copied over — a PR presents the
# subject `repo:...:pull_request`, which this policy refuses.
#
# The subject is derived from the app repo's origin remote rather than guessed:
#
#   git -C ../spring-petclinic-microservices remote get-url origin
#   -> https://github.com/truongnvnse/spring-petclinic-microservices.git
#
# The numeric IDs in that subject come from the API, and the origin remote does
# not carry them:
#
#   curl -sS https://api.github.com/repos/truongnvnse/spring-petclinic-microservices
#   -> owner.id = 336541468, id = 1400042382
#
# One thing this policy does not do, so it is not mistaken for a boundary it is
# not: it scopes to a repository and a branch, not to a workflow. Any workflow
# in that repository running on `main` with `id-token: write` can assume the
# role. Narrowing further would take a job_workflow_ref condition, which the
# app repo's single AWS-using workflow does not warrant today.
#
# ---------------------------------------------------------------------------
# Why the provider is conditional
# ---------------------------------------------------------------------------
#
# An AWS account may hold only one OIDC provider per URL. The provider here is
# therefore account-global even though this module is per-environment, and a
# second environment that also tried to create it would fail the apply with
# EntityAlreadyExists — not a clear error, and not one that re-running clears.
# create_oidc_provider makes the ownership explicit instead of leaving it to
# whichever environment happens to apply first.

locals {
  name_prefix = "${var.project}-${var.environment}"

  # Required tags are also applied by the provider's default_tags block in the
  # environment roots. Repeated here, and given precedence over var.tags, so a
  # caller can add tags but can never silently drop the ones this project
  # depends on.
  common_tags = merge(
    var.tags,
    {
      Project     = var.project
      Environment = var.environment
      ManagedBy   = "terraform"
      Component   = "ci"
    },
  )

  # The exact subject claim GitHub presents in the token.
  #
  # It carries NUMERIC IDs alongside the names, and that is not optional.
  # GitHub issues immutable subject claims — `repo:owner@owner_id/repo@repo_id:
  # ref:refs/heads/branch` — for every repository created after 2026-07-15, and
  # the IDs cannot be removed from the format. A name-only subject therefore
  # matches no token at all: the role applies cleanly, reads correctly in the
  # console, and fails only when a build runs, as `Not authorized to perform
  # sts:AssumeRoleWithWebIdentity`. That is what this module did until
  # 2026-10-11, and the diagnosis took a CloudTrail lookup because the error
  # names STS rather than the claim.
  #
  # The IDs are the point of the format. A repository name can be deleted and
  # recreated by whoever holds the account; the ID cannot be reused, so a
  # recreated repository gets a different ID and cannot assume this role. The
  # classic name-only form would have permitted exactly that, which is why it
  # is deliberately NOT accepted alongside this one — listing both would give
  # away the property the IDs exist to provide, in exchange for compatibility
  # with a format GitHub will not go back to.
  #
  # Both names still matter as well: the repository stops another project's
  # workflow assuming this role, and the ref stops another branch of the same
  # repository doing it. A pull request from a fork runs on the fork's own refs
  # and is refused here without any further condition.
  #
  # github_repository is validated as owner/name with exactly one slash, so
  # splitting it is safe.
  github_subject = format(
    "repo:%s@%d/%s@%d:ref:refs/heads/%s",
    split("/", var.github_repository)[0],
    var.github_owner_id,
    split("/", var.github_repository)[1],
    var.github_repository_id,
    var.github_branch,
  )

  # Actions needed to push an image. The pull half of the ECR API is
  # deliberately absent: a build role has no reason to read images back out, so
  # leaving BatchGetImage and GetDownloadUrlForLayer off means a compromised
  # build cannot exfiltrate artifacts that were pushed by earlier builds.
  ecr_push_actions = [
    "ecr:BatchCheckLayerAvailability",
    "ecr:InitiateLayerUpload",
    "ecr:UploadLayerPart",
    "ecr:CompleteLayerUpload",
    "ecr:PutImage",
  ]

  oidc_provider_arn = var.create_oidc_provider ? aws_iam_openid_connect_provider.github[0].arn : var.existing_oidc_provider_arn
}

resource "aws_iam_openid_connect_provider" "github" {
  count = var.create_oidc_provider ? 1 : 0

  url = "https://token.actions.githubusercontent.com"

  # The only audience GitHub Actions tokens carry for AWS. A token minted for a
  # different audience is refused by the provider itself, before the trust
  # policy is consulted at all.
  client_id_list = ["sts.amazonaws.com"]

  # thumbprint_list is deliberately not set. AWS resolves the thumbprint itself
  # for providers whose certificate chain ends in a trusted root CA, and pinning
  # one turns GitHub's next certificate rotation into an outage for every
  # pipeline that assumes the role — which is exactly what happened across the
  # industry in early 2023 when the previous thumbprint was retired.

  tags = merge(local.common_tags, { Name = "${local.name_prefix}-github-oidc" })
}

data "aws_iam_policy_document" "github_assume_role" {
  statement {
    sid    = "GitHubActionsAssumeRoleWithWebIdentity"
    effect = "Allow"

    # AssumeRoleWithWebIdentity, not AssumeRole. AssumeRole needs a principal
    # that already has AWS credentials, which is the thing federation exists to
    # avoid — the workflow would need a long-lived key to use it.
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [local.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    # Without this condition the role would be assumable by any GitHub
    # repository on the platform, because the OIDC provider is shared across all
    # of GitHub. This is the condition that scopes it to one repo and one branch.
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = [local.github_subject]
    }
  }
}

resource "aws_iam_role" "github_actions" {
  name        = "${local.name_prefix}-github-actions-role"
  description = "Assumed by GitHub Actions in ${var.github_repository} (${var.github_branch}) via OIDC, to push images to this environment's ECR repositories"

  assume_role_policy = data.aws_iam_policy_document.github_assume_role.json

  # The default is already 3600. Set explicitly so the session lifetime is a
  # decision recorded in configuration rather than a service default that could
  # change under it.
  max_session_duration = var.max_session_duration

  tags = merge(local.common_tags, { Name = "${local.name_prefix}-github-actions-role" })

  lifecycle {
    # A green `terraform validate` does not evaluate this; only plan does.
    precondition {
      condition     = local.oidc_provider_arn != ""
      error_message = "No OIDC provider to trust. Set create_oidc_provider = true in exactly one environment, and pass its github_oidc_provider_arn output as existing_oidc_provider_arn in any other — an AWS account may hold only one provider for this URL."
    }
  }
}

# ---------------------------------------------------------------------------
# ECR push policy
#
# Split from the pull half of the API on purpose; see ecr_push_actions above.
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "ecr_push" {
  # ecr:GetAuthorizationToken cannot be scoped to a repository — it returns a
  # registry-wide Docker credential, and AWS rejects any policy that names a
  # resource for it. This is the one wildcard in the module and it is forced by
  # the API rather than chosen. It grants nothing on its own: the token it
  # returns is still subject to the statement below.
  statement {
    sid       = "EcrGetAuthorizationToken"
    effect    = "Allow"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  statement {
    sid       = "EcrPushToThisEnvironmentsRepositories"
    effect    = "Allow"
    actions   = local.ecr_push_actions
    resources = var.repository_arns
  }
}

resource "aws_iam_role_policy" "ecr_push" {
  name   = "${local.name_prefix}-ecr-push"
  role   = aws_iam_role.github_actions.id
  policy = data.aws_iam_policy_document.ecr_push.json
}
