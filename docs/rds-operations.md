# RDS Database Operations

**Last Updated:** 2026-10-07

**Purpose:** How the shared `petclinic` MySQL database is provisioned, how its schemas get initialized, and how to connect to it and verify that the three database-backed services can reach it. Covers the procedures required by PETPLAT-23, PETPLAT-24 and PETPLAT-26.

## Table of Contents

1. [Instance Reference](#instance-reference)
2. [Schema Initialization Strategy](#schema-initialization-strategy)
3. [Procedure: retrieve credentials from Secrets Manager](#procedure-retrieve-credentials-from-secrets-manager)
4. [Procedure: connect to the database](#procedure-connect-to-the-database)
5. [Procedure: verify connectivity from an EKS pod](#procedure-verify-connectivity-from-an-eks-pod)
6. [Procedure: rotate the master password](#procedure-rotate-the-master-password)
7. [Troubleshooting](#troubleshooting)

---

## Instance Reference

| Setting | Dev | Prod |
|---------|-----|------|
| Instance identifier | `petclinic-dev-mysql` | `petclinic-prod-mysql` |
| Engine | MySQL 8.0 | MySQL 8.0 |
| Instance class | `db.t4g.micro` | `db.t4g.micro` |
| Multi-AZ | `false` | `false` |
| Storage | 20 GB `gp2`, encrypted | 20 GB `gp2`, encrypted |
| Storage autoscaling ceiling | 100 GB | 100 GB |
| Backup retention | 7 days | 30 days |
| Skip final snapshot | `true` | `false` |
| Deletion protection | `false` | `false` |
| Shared database | `petclinic` | `petclinic` |
| Master username | `petclinic` | `petclinic` |
| Credentials secret | `petclinic/dev/rds-credentials` | `petclinic/prod/rds-credentials` |
| Terraform module | `terraform/modules/rds/` | `terraform/modules/rds/` |

Both environments run identical instance sizing — the spec deliberately keeps dev and prod on free-tier Graviton so cost is not what differs between them. The settings that *do* differ are the two recovery-related ones above: backup retention and the final snapshot. Dev additionally sets `apply_immediately = true` so a change lands without waiting for a maintenance window.

The 100 GB autoscaling ceiling is **not** a cost commitment. Storage is billed on what is allocated (20 GB), not on the ceiling, so it reserves nothing — it only bounds how far autoscaling may grow. It is 100 GB rather than 20 GB because RDS requires the maximum storage threshold to be at least 10% above the allocated storage; an instance created with the two set equal fails with `Invalid max storage size for engine_name`.

**Network access:** the instance sits in the public subnets but has **no public address** (`publicly_accessible = false`). The RDS security group admits 3306 from the EKS node security group and from nothing else. The subnet is not the boundary — the security group is. Never widen that rule to a CIDR range.

---

## Schema Initialization Strategy

> **Story:** PETPLAT-24. **Decision: Spring Boot auto-initialization**, not a manual or init-container step.

### One database, not three

All three database-backed services share a single `petclinic` database on this one instance. They cannot be given separate databases: `visits.pet_id` is a foreign key to `pets.id`, and MySQL foreign keys do not cross schema boundaries. Splitting them would turn a database-enforced constraint into an application-enforced one.

Each service's `schema.sql` opens with `CREATE DATABASE IF NOT EXISTS petclinic; USE petclinic;`, so whichever service starts first creates the database, and the rest are no-ops against it.

### Schema scripts

The scripts live in the application repository, not this one, at `src/main/resources/db/mysql/schema.sql` per service:

| Order | Service | Script | Tables created |
|-------|---------|--------|----------------|
| 1 | customers-service | `spring-petclinic-customers-service/src/main/resources/db/mysql/schema.sql` | `types`, `owners`, `pets` |
| 2 | vets-service | `spring-petclinic-vets-service/src/main/resources/db/mysql/schema.sql` | `vets`, `specialties`, `vet_specialties` |
| 3 | visits-service | `spring-petclinic-visits-service/src/main/resources/db/mysql/schema.sql` | `visits` |

Seven tables total. Every statement is `CREATE TABLE IF NOT EXISTS`, so re-running a script against an already-initialized database is safe and idempotent.

**Order matters, and only for one edge:** `visits.pet_id` references `pets.id`, so the visits script fails if it runs before the customers script. The vets script is independent and can run at any point. Order is enforced by *deployment* order — customers-service is deployed before visits-service — not by the scripts themselves, and not by Terraform.

### How initialization is triggered

The services do not carry a `docker` or `mysql` profile in their own `application.yml`. Both are imported at runtime from the **config server**, which serves them from an external Git repository (`spring-petclinic-microservices-config`). The `docker` profile activates on the config-server import.

That means the schema-initialization settings are **not in this repository** and cannot be changed from it. The profile served by the config server must set:

| Property | Value | Why |
|----------|-------|-----|
| `spring.sql.init.mode` | `always` | `embedded` (the default) initializes only embedded databases, so against MySQL the scripts would never run |
| `spring.sql.init.schema-locations` | `classpath*:db/mysql/schema.sql` | The scripts are under `db/mysql/`; Spring's default location is `classpath*:schema.sql`, which matches nothing here |
| `spring.datasource.url` | `jdbc:mysql://${RDS_ENDPOINT}:3306/petclinic` | See the connection string below |

> **Verified against the application repository:** the three `db/mysql/schema.sql` files exist with the tables listed above, and no service declares `spring.sql.init` settings locally. **Not verified from this repository:** the exact contents of the external config repository — confirm the three properties above are present there before concluding initialization is misconfigured.

### Connection string format

```
jdbc:mysql://{rds-endpoint}:3306/petclinic
```

The `rds_connection_string` output of the dev and prod root modules emits exactly this. It contains **no credentials** — the username and password are injected separately from the `rds-credentials` Kubernetes Secret — so it is safe to place in a ConfigMap.

| Where the value comes from | What it is |
|----------------------------|------------|
| Terraform output `rds_connection_string` | Full JDBC URL |
| Kubernetes Secret `rds-credentials` key `username` | Master username |
| Kubernetes Secret `rds-credentials` key `password` | Generated master password |
| Kubernetes Secret `rds-credentials` key `host` / `port` | Not published — derive from the URL, or add them to the secret if a service needs them |

---

## Procedure: retrieve credentials from Secrets Manager

**When:** You need the master credentials to connect directly, or to verify the secret is populated correctly.
**Who:** Any engineer with `secretsmanager:GetSecretValue` on the secret.
**Time:** ~1 minute

**Steps:**

1. Read the secret:

   ```bash
   aws secretsmanager get-secret-value \
     --secret-id petclinic/dev/rds-credentials \
     --region eu-central-1 \
     --query SecretString --output text
   ```

2. Parse it into a shell variable if you are about to connect:

   ```bash
   export RDS_PASSWORD=$(aws secretsmanager get-secret-value \
     --secret-id petclinic/dev/rds-credentials \
     --region eu-central-1 \
     --query SecretString --output text | jq -r .password)
   ```

**Verify:**

- The output is a JSON object with exactly two keys, `username` and `password`:

  ```json
  {"username":"petclinic","password":"…"}
  ```

- The key names are load-bearing. The ExternalSecret in `k8s/base/external-secrets/rds-credentials.yaml` maps these exact property names onto the Kubernetes Secret keys, so renaming a key here breaks credential delivery to every database-backed service.

**Rollback:**

- None needed — this is a read-only procedure.

---

## Procedure: connect to the database

**When:** You need to inspect the schema, confirm a table exists, or debug a service's SQL.
**Who:** Engineer with VPC network access (the instance has no public address, so this must run from inside the VPC).
**Time:** ~5 minutes

**Steps:**

1. Resolve the endpoint and the password into your **local** shell. A pod inherits nothing from your environment, so anything it needs has to be passed to it explicitly:

   ```bash
   export RDS_ENDPOINT=$(aws rds describe-db-instances \
     --db-instance-identifier petclinic-dev-mysql \
     --region eu-central-1 \
     --query 'DBInstances[0].Endpoint.Address' --output text)

   export RDS_PASSWORD=$(aws secretsmanager get-secret-value \
     --secret-id petclinic/dev/rds-credentials \
     --region eu-central-1 \
     --query SecretString --output text | jq -r .password)
   ```

2. Start a throwaway MySQL client pod on an EKS node — a node is inside the RDS security group's allowed source. `MYSQL_PWD` carries the password into the container's environment, so it never appears in `argv`, in `kubectl describe` output, or in your shell history:

   ```bash
   kubectl run mysql-client --rm -it --restart=Never \
     --image=mysql:8.0 \
     --namespace default \
     --env="MYSQL_PWD=$RDS_PASSWORD" \
     -- mysql -h "$RDS_ENDPOINT" -u petclinic petclinic
   ```

   `$RDS_ENDPOINT` is expanded by your local shell before `kubectl` builds the pod. The trailing `petclinic` is the database name.

3. List the tables:

   ```sql
   SHOW TABLES;
   ```

> **Never write `-p <password>` with a space between the flag and the value.** The mysql client only accepts an *attached* password: `-p<password>` or `-p'<password>'`. Written with a space, `-p` means *"prompt me for a password"* and the string after it is parsed as the **database name** instead. In a non-interactive session that yields `Access denied ... (using password: NO)` — or `Unknown database '<your password>'` — and writes the password into your shell history for nothing. Prefer `MYSQL_PWD` as above and the question never arises.

**Verify:**

- `SHOW TABLES;` returns the seven tables across the three services: `types`, `owners`, `pets`, `vets`, `specialties`, `vet_specialties`, `visits`.
- The table count matches 7. A partial list means one service's schema script has not run — check the deployment order, since `visits` requires `pets` to exist first.

**Rollback:**

- The client pod is removed by `--rm` on exit. Delete it manually if it is left behind: `kubectl delete pod mysql-client`.

---

## Procedure: verify connectivity from an EKS pod

**When:** After applying the RDS module (PETPLAT-26), or when a service reports a connection failure.
**Who:** Engineer with `kubectl` access to the cluster.
**Time:** ~5 minutes

**Steps:**

1. Confirm the instance is available and note its endpoint:

   ```bash
   aws rds describe-db-instances \
     --db-instance-identifier petclinic-dev-mysql \
     --region eu-central-1 \
     --query 'DBInstances[0].{status:DBInstanceStatus,endpoint:Endpoint.Address,port:Endpoint.Port,public:PubliclyAccessible}'
   ```

2. Confirm the secret exists and is populated:

   ```bash
   aws secretsmanager describe-secret \
     --secret-id petclinic/dev/rds-credentials \
     --region eu-central-1
   ```

3. Test connectivity from a pod on a node. Both values must be passed in — a pod inherits nothing from your shell, so `$RDS_ENDPOINT` and `$RDS_PASSWORD` are **empty inside the container** unless they are supplied as below:

   ```bash
   kubectl run rds-probe --rm -it --restart=Never \
     --image=mysql:8.0 \
     --namespace default \
     --env="MYSQL_PWD=$RDS_PASSWORD" \
     -- mysql -h "$RDS_ENDPOINT" -u petclinic \
        -e "SELECT 1 AS connectivity_ok, VERSION() AS server_version;" petclinic
   ```

**Verify:**

- Step 1 reports `"status": "available"` and `"public": false`.
- Step 3 returns a row with `connectivity_ok = 1`.
- A **timeout** (rather than `Access denied`) means the security group is not admitting the node — check that `security_group_id` is the VPC module's `rds_sg_id` and that the nodes are using the node security group that rule references.
- **`Access denied` means the network path is fine.** MySQL answered the connection, so routing and the security group both work — only the credentials are at fault. The parenthesised suffix tells the two cases apart: `(using password: NO)` means no password was sent at all, `(using password: YES)` means one was sent and rejected.
- Services connect with the credentials from Secrets Manager, and the tables exist — the two remaining PETPLAT-26 criteria.

**Rollback:**

- The probe pod is removed by `--rm` on exit.

---

## Procedure: rotate the master password

**When:** The password has been exposed — pasted into a terminal, a ticket, a chat message, or shell history.
**Who:** Engineer with access to this environment's Terraform state.
**Time:** ~5 minutes

**Steps:**

1. Generate a new password and save the plan:

   ```bash
   terraform -chdir=terraform/environments/{env} plan \
     -replace="module.rds.random_password.master" -out=rotate.out
   ```

2. Confirm the plan updates the secret version and the instance **in place** rather than replacing the instance:

   ```bash
   terraform -chdir=terraform/environments/{env} show rotate.out | grep -E 'will be|must be replaced'
   ```

   `aws_db_instance.this must be replaced` means stop — the instance would be destroyed and rebuilt. That should not happen for a password change.

3. Apply:

   ```bash
   terraform -chdir=terraform/environments/{env} apply rotate.out
   ```

**Verify:**

- The stored password has actually changed. Compare a short digest rather than the value itself:

  ```bash
  aws secretsmanager get-secret-value \
    --secret-id petclinic/{env}/rds-credentials \
    --region eu-central-1 --query SecretString --output text \
    | jq -r .password | shasum | cut -c1-12
  ```

- The new password authenticates using [Procedure: connect to the database](#procedure-connect-to-the-database).

**Rollback:**

- The previous password is not recoverable. The instance and the secret are updated by the same apply, so they stay consistent with each other; if the apply fails partway, re-run it.

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| `mysql: command not found` / connection hangs | Pod is not on a node, or the node is not in the node security group the RDS rule references | Confirm with `kubectl get pod -o wide` that the pod is scheduled |
| Connection times out | RDS security group does not admit the source | Check `vpc_security_group_ids` on the instance matches `module.vpc.rds_sg_id` |
| `Access denied ... (using password: NO)` | **No password was sent at all.** Almost always `-p` written with a space, so mysql prompted instead of reading the value | Attach it — `-p'...'` — or use `MYSQL_PWD` as in [Procedure: connect to the database](#procedure-connect-to-the-database) |
| `Unknown database '<something that looks like a password>'` | Same root cause: with `-p` written as a bare flag, the next argument is parsed as the database name | Same |
| `Access denied ... (using password: YES)` | A password was sent and rejected — it does not match the instance | Both the instance and the secret are sourced from the same `random_password`, so a manual password change on the instance breaks the pair. Re-apply to reconcile, or rotate as below |
| `Table 'petclinic.pets' doesn't exist` | Schema initialization has not run | See [Schema Initialization Strategy](#schema-initialization-strategy) — check `spring.sql.init.mode` in the config repository, and that customers-service started before visits-service |
| `Unknown database 'petclinic'` | Same as above; the first service to start creates the database | Same |
| Destroy fails with "final snapshot already exists" | A previous destroy left `petclinic-{env}-mysql-final` behind | Delete the stale snapshot, or rename `final_snapshot_identifier` in the module |
| Re-apply fails: secret is scheduled for deletion | A non-zero `secret_recovery_window_in_days` is holding the name | Dev sets this to 0. For prod, wait out the window or restore the secret: `aws secretsmanager restore-secret` |
