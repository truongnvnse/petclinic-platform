# backend.tf — Remote state backend, dev (PETPLAT-3)
#
# State lives in the shared S3 bucket created by scripts/bootstrap-state.sh,
# with DynamoDB providing state locking. Dev and prod share the bucket but use
# separate keys, so the two environments never touch each other's state.
#
# NOTE: Backend blocks cannot reference variables — the bucket and table names
# must be literal. The account ID suffix is not a secret.

terraform {
  backend "s3" {
    bucket         = "petclinic-terraform-state-550798137608"
    key            = "petclinic/dev/terraform.tfstate"
    region         = "eu-central-1"
    encrypt        = true
    dynamodb_table = "petclinic-terraform-locks"
  }
}
