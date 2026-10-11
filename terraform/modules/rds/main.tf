# main.tf — rds module
#
# Shared MySQL 8.0 instance for the three database-backed services
# (E-5 Database). Owned by PETPLAT-22 (module), PETPLAT-23 (credentials in
# Secrets Manager) and PETPLAT-24 (schema initialization strategy).
#
# Design — docs/technical-spec.md → "RDS Database":
#   * One instance, one database (`petclinic`) shared by the customers, visits
#     and vets services. They cannot be split across databases: visits.pet_id
#     is a foreign key to pets.id, and MySQL foreign keys do not cross schemas.
#   * The instance lives in the public subnets (ADR-0001) but is NOT publicly
#     accessible — it has no public address, and only the EKS node security
#     group reaches 3306. The subnet is not the boundary here; the security
#     group is.
#   * Master credentials are generated here, never supplied, and are stored in
#     Secrets Manager under petclinic/{env}/rds-credentials for the External
#     Secrets Operator to read into the cluster (E-7).
#
# NOTE on `sensitive = true`: PETPLAT-23 asks for the secret value to be kept
# out of Terraform state by marking it sensitive. It does not do that — the
# `sensitive` flag redacts a value in CLI output and plan diffs only; the value
# is still written to state. What protects it is the state bucket's encryption
# at rest together with the IAM policy governing who may read that bucket — the
# bucket policy itself only denies non-TLS transport. Treat the state file as a
# secret store, and grant read on it accordingly.

locals {
  # Naming convention: petclinic-{env}-{resource}
  name_prefix = "${var.project}-${var.environment}"

  identifier = "${local.name_prefix}-mysql"

  # Required tags are also applied by the provider's default_tags block in the
  # environment roots. They are repeated here, and given precedence over
  # `var.tags`, so a caller can add tags but can never silently drop the tags
  # this project depends on for cost allocation and drift detection.
  common_tags = merge(
    var.tags,
    {
      Project     = var.project
      Environment = var.environment
      ManagedBy   = "terraform"
      Component   = "database"
    },
  )

  # The name the ExternalSecret in k8s/base/external-secrets/rds-credentials.yaml
  # looks up. Renaming it here without renaming it there silently breaks
  # credential delivery to every database-backed service.
  secret_name = "${var.project}/${var.environment}/rds-credentials"
}

# ---------------------------------------------------------------------------
# Master credentials — PETPLAT-23
# ---------------------------------------------------------------------------

# Generated rather than supplied, so the password never exists in a tfvars
# file, a CI log, or a human's memory.
#
# `override_special` deliberately narrows random_password's default alphabet.
# RDS rejects '/', '"', '@' and space in a master password. Of those, the
# provider's default set (!@#$%&*()-_=+[]{}<>:?) contains '@' — so leaving it
# alone produces an instance that fails to create intermittently, depending on
# whether the generator happened to draw an '@' that run, with a validation
# error that never points back at the password. The replacement set keeps the
# remaining specials and drops '@'.
resource "random_password" "master" {
  length  = 32
  special = true

  override_special = "!#$%&*()-_=+"

  min_lower   = 1
  min_upper   = 1
  min_numeric = 1
  min_special = 1
}

resource "aws_secretsmanager_secret" "rds_credentials" {
  name = local.secret_name

  # See the variable description: dev sets 0 so a re-apply after a teardown is
  # not blocked by a name still inside its recovery window.
  recovery_window_in_days = var.secret_recovery_window_in_days

  tags = merge(local.common_tags, { Name = local.secret_name })
}

resource "aws_secretsmanager_secret_version" "rds_credentials" {
  secret_id = aws_secretsmanager_secret.rds_credentials.id

  # The exact JSON shape the ExternalSecret expects: it maps the `username` and
  # `password` properties of this object onto the rds-credentials Kubernetes
  # Secret. Adding or renaming a key here requires the same change there.
  secret_string = jsonencode({
    username = var.master_username
    password = random_password.master.result
  })
}

# ---------------------------------------------------------------------------
# Networking
# ---------------------------------------------------------------------------

# RDS requires a subnet group spanning at least two AZs even for a single-AZ
# instance, so that a later Multi-AZ conversion does not need a new group.
# The subnets themselves come from the VPC module; this module never creates
# or widens the security group that guards them.
resource "aws_db_subnet_group" "this" {
  name       = "${local.name_prefix}-db-subnet-group"
  subnet_ids = var.subnet_ids

  tags = merge(local.common_tags, { Name = "${local.name_prefix}-db-subnet-group" })
}

# ---------------------------------------------------------------------------
# Parameter group
# ---------------------------------------------------------------------------

# `character_set_server = utf8mb4` restates MySQL 8.0's own default and so
# changes nothing today. It is pinned because the default is a property of the
# engine version rather than of this project — an upgrade, or a snapshot
# restored from an older engine, could otherwise reintroduce a latin1 default
# that silently mangles the accented characters the pet names allow.
#
# `collation_server = utf8mb4_unicode_ci` IS a change: MySQL 8.0 defaults to
# utf8mb4_0900_ai_ci, which sorts by Unicode code point. It is stated
# explicitly so the collation is a decision recorded here rather than an
# accident of whichever engine version the instance lands on.
resource "aws_db_parameter_group" "this" {
  name   = "${local.name_prefix}-mysql8"
  family = "mysql8.0"

  parameter {
    name  = "character_set_server"
    value = "utf8mb4"
  }

  parameter {
    name  = "collation_server"
    value = "utf8mb4_unicode_ci"
  }

  tags = merge(local.common_tags, { Name = "${local.name_prefix}-mysql8" })
}

# ---------------------------------------------------------------------------
# Instance
# ---------------------------------------------------------------------------

resource "aws_db_instance" "this" {
  identifier = local.identifier

  engine         = "mysql"
  engine_version = var.engine_version
  instance_class = var.instance_class

  allocated_storage     = var.allocated_storage
  max_allocated_storage = var.max_allocated_storage
  storage_type          = var.storage_type
  storage_encrypted     = var.storage_encrypted

  db_name  = var.database_name
  username = var.master_username
  password = random_password.master.result
  port     = 3306

  multi_az = var.multi_az

  db_subnet_group_name   = aws_db_subnet_group.this.name
  vpc_security_group_ids = [var.security_group_id]
  parameter_group_name   = aws_db_parameter_group.this.name

  # Stated explicitly even though false is the default: every subnet here is
  # public, so a reader could reasonably assume the database is too. It is not
  # — the instance takes no public address, and the RDS security group admits
  # 3306 from the EKS node security group and nothing else.
  publicly_accessible = false

  backup_retention_period = var.backup_retention_period
  skip_final_snapshot     = var.skip_final_snapshot

  # Only meaningful when a final snapshot is taken. Re-destroying the same
  # instance after a restore would collide on this name; delete the stale
  # snapshot first, or the destroy fails loudly rather than overwriting it.
  final_snapshot_identifier = var.skip_final_snapshot ? null : "${local.identifier}-final"

  deletion_protection = var.deletion_protection
  apply_immediately   = var.apply_immediately

  auto_minor_version_upgrade = true
  copy_tags_to_snapshot      = true

  tags = merge(local.common_tags, { Name = local.identifier })

  lifecycle {
    # engine_version is declared as a major version ("8.0"), so RDS resolves it
    # to whichever minor release is current, and auto_minor_version_upgrade
    # moves it forward on AWS's schedule. Without this, the first plan after an
    # AWS-side upgrade proposes to pin the version back — drift that is not
    # drift, and a change nobody asked for.
    #
    # The cost of ignoring it: a *deliberate* version change made by editing
    # var.engine_version is not proposed either. To move versions on purpose,
    # change the variable and apply with -replace, or lift this block for that
    # one change.
    ignore_changes = [engine_version]
  }
}
