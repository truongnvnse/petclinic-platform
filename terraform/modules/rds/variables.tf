# variables.tf — rds module inputs
#
# Interface defined in docs/technical-spec.md → "Terraform Modules" → Module: rds.
#
# Defaults match the "RDS Database → Instance Configuration" table, with one
# deliberate exception documented on max_allocated_storage below.
#
# Where that table and the PETPLAT-22 acceptance criteria disagree, the
# acceptance criteria govern — they are what the story is verified against:
#   * backup retention — the table says 7/7; PETPLAT-22 says 7 dev, 30 prod
#   * skip final snapshot — the table says true/true; PETPLAT-22 says true dev,
#     false prod
# Both are set explicitly by the environment roots, not defaulted here.
#
# Both environments deliberately run free-tier sizing as a cost optimization
# for a learning project. deletion_protection is false in both, following the
# spec's cost note — it is not a dev/prod divergence.

variable "project" {
  description = "Project name used for resource naming and tagging. Becomes the first segment of the instance identifier (petclinic-dev-mysql), so it must be lowercase alphanumeric with hyphens only."
  type        = string
  default     = "petclinic"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]*$", var.project))
    error_message = "The project name must be lowercase alphanumeric with hyphens — RDS rejects uppercase and most punctuation in an instance identifier."
  }
}

variable "environment" {
  description = "Environment name — must be 'dev' or 'prod'. Drives the instance identifier and the Secrets Manager secret name. The per-environment settings themselves (backup retention, final snapshot, deletion protection) are set by the environment roots, not derived from this value."
  type        = string

  validation {
    condition     = contains(["dev", "prod"], var.environment)
    error_message = "The environment must be either 'dev' or 'prod'."
  }
}

variable "subnet_ids" {
  description = "Subnet IDs for the DB subnet group — supply the VPC module's public_subnet_ids. RDS needs subnets in at least two availability zones even when the instance itself is single-AZ, because a Multi-AZ conversion must not require a new subnet group."
  type        = list(string)

  validation {
    condition     = length(var.subnet_ids) >= 2
    error_message = "At least two subnets in different availability zones are required — RDS rejects a DB subnet group that spans fewer than two AZs."
  }
}

variable "security_group_id" {
  description = "RDS security group ID — supply the VPC module's rds_sg_id. That group admits 3306 from the EKS node security group and from nothing else; this module never creates or widens it, so the database's network perimeter stays owned by the VPC module where it is reviewable in one place."
  type        = string
}

variable "engine_version" {
  description = "MySQL engine version. A major version alone ('8.0') lets RDS pick the current minor release, which is what the spec asks for. The instance ignores post-creation changes to this value so an AWS automatic minor upgrade does not show up as perpetual drift."
  type        = string
  default     = "8.0"
}

variable "instance_class" {
  description = "RDS instance class. db.t4g.micro (2 vCPU, 1 GiB, ARM/Graviton) is free-tier eligible for 12 months and is what both environments use — see the cost note in docs/technical-spec.md → \"RDS Database\"."
  type        = string
  default     = "db.t4g.micro"
}

variable "allocated_storage" {
  description = "Initial storage in GB. 20 GB is the free-tier allowance and matches the spec for both environments."
  type        = number
  default     = 20

  validation {
    condition     = var.allocated_storage >= 20
    error_message = "MySQL requires at least 20 GB of allocated storage."
  }
}

variable "max_allocated_storage" {
  description = "Storage ceiling in GB for RDS storage autoscaling. RDS requires this to be at least 10% above allocated_storage and recommends 26% above, to avoid a recurring \"storage size approaching the maximum storage threshold\" event. 100 GB gives a 5x ceiling over the 20 GB free-tier allocation; the ceiling itself costs nothing, because storage is billed on what is allocated rather than on this maximum — it bounds a runaway, it does not reserve capacity. NOTE: the spec's Instance Configuration table sets this equal to allocated_storage (20/20), which RDS rejects outright, so the table is wrong and PETPLAT-22's \"autoscaling enabled\" criterion is what this default follows."
  type        = number
  default     = 100

  # Written as integer arithmetic because the obvious `>= allocated * 1.1` is a
  # float comparison: 20 * 1.1 is 22.000000000000004 in binary floating point,
  # so ceil() would demand 23 and silently forbid the legal minimum of 22.
  validation {
    condition     = var.max_allocated_storage * 10 >= var.allocated_storage * 11
    error_message = "RDS requires max_allocated_storage to be at least 10% above allocated_storage; a lower value fails instance creation with 'Invalid max storage size for engine_name'."
  }
}

variable "storage_type" {
  description = "EBS volume type for the instance. The spec specifies gp2 in both environments; gp3 would be cheaper per IOPS and is the modern default, but changing it is a deliberate cost decision rather than a silent improvement."
  type        = string
  default     = "gp2"

  validation {
    condition     = contains(["gp2", "gp3"], var.storage_type)
    error_message = "storage_type must be gp2 or gp3. The Provisioned IOPS types are excluded: io1 and io2 both require at least 100 GB of allocated storage — five times this module's free-tier default — and io2 additionally constrains the ratio of IOPS to allocated storage."
  }
}

variable "storage_encrypted" {
  description = "Encrypt the instance's storage at rest. Required by the project's security rules and true in both environments. Encryption uses the AWS-managed aws/rds key, which costs nothing; a customer-managed KMS key would add a monthly charge per key."
  type        = bool
  default     = true

  validation {
    condition     = var.storage_encrypted
    error_message = "Storage encryption cannot be disabled — the project's security rules require encryption at rest for all storage. Set storage_encrypted = true."
  }
}

variable "database_name" {
  description = "Name of the database created inside the instance. All three database-backed services (customers, visits, vets) share this one database — the visits table carries a foreign key to pets, which only resolves if both live in the same schema. See docs/technical-spec.md → \"Database Schema\"."
  type        = string
  default     = "petclinic"

  validation {
    condition     = can(regex("^[a-z][a-z0-9_]*$", var.database_name))
    error_message = "The database name must be lowercase alphanumeric with underscores — RDS rejects uppercase and hyphens in an initial database name."
  }
}

variable "master_username" {
  description = "Master username for the instance. The password is generated, never supplied — see PETPLAT-23. MySQL reserves a set of names (rdsadmin, admin, root, …); 'petclinic' avoids all of them."
  type        = string
  default     = "petclinic"

  validation {
    condition     = can(regex("^[a-z][a-z0-9_]*$", var.master_username))
    error_message = "The master username must begin with a letter and contain only lowercase letters, digits and underscores — RDS rejects uppercase, hyphens and most punctuation here."
  }

  validation {
    condition     = !contains(["admin", "root", "rdsadmin", "mysql", "guest"], lower(var.master_username))
    error_message = "The master username is reserved by MySQL or RDS — choose a different one."
  }
}

variable "multi_az" {
  description = "Run a synchronous standby in a second availability zone. False in both environments — Multi-AZ roughly doubles cost for a learning project. Enable it in any real production deployment: it is the difference between a failover measured in seconds and a restore measured in hours."
  type        = bool
  default     = false
}

variable "backup_retention_period" {
  description = "Automated backup retention in days. PETPLAT-22 asks for 7 in dev and 30 in prod — the spec's Instance Configuration table says 7/7, but the acceptance criteria govern, and the environment roots set the story's values explicitly. 0 disables automated backups entirely, which also disables point-in-time recovery."
  type        = number
  default     = 7

  validation {
    condition     = var.backup_retention_period >= 0 && var.backup_retention_period <= 35
    error_message = "backup_retention_period must be between 0 and 35 days."
  }
}

variable "skip_final_snapshot" {
  description = "Skip the final snapshot when the instance is destroyed. True in dev (the environment is disposable and a snapshot would outlive it), false in prod (a destroyed production database must leave a restorable artifact behind)."
  type        = bool
  default     = true
}

variable "deletion_protection" {
  description = "Refuse to delete the instance until this is disabled. False in both environments per the spec; a real production deployment would set it true so an errant destroy fails loudly."
  type        = bool
  default     = false
}

variable "apply_immediately" {
  description = "Apply modifications now instead of waiting for the next maintenance window. False by default so prod changes stay in the maintenance window; dev sets it true so a parameter or class change is visible without waiting."
  type        = bool
  default     = false
}

variable "secret_recovery_window_in_days" {
  description = "Days a deleted Secrets Manager secret can be recovered, 0 meaning it is deleted immediately. Dev sets 0: the secret is rebuilt by the next apply from the password already in state, and a non-zero window would block re-creating the same name until it elapsed — the same class of failure the ECR module documents for non-empty repositories. Prod sets 7 so a mistaken deletion is reversible."
  type        = number
  default     = 0

  validation {
    condition     = var.secret_recovery_window_in_days == 0 || (var.secret_recovery_window_in_days >= 7 && var.secret_recovery_window_in_days <= 30)
    error_message = "secret_recovery_window_in_days must be 0 (delete immediately) or between 7 and 30."
  }
}

variable "tags" {
  description = "Additional tags merged onto every resource in this module"
  type        = map(string)
  default     = {}
}
