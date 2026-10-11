# backend.tf — Remote state backend, prod (PETPLAT-4)
#
# Same bucket and lock table as dev, different state key. Sharing the bucket
# keeps bootstrap to a single one-time setup; the key prefix is what isolates
# the two environments.
#
# NOTE: Backend blocks cannot reference variables — the bucket and table names
# must be literal. The account ID suffix is not a secret.

terraform {
  backend "s3" {
    bucket         = "petclinic-terraform-state-550798137608"
    key            = "petclinic/prod/terraform.tfstate"
    region         = "eu-central-1"
    encrypt        = true
    dynamodb_table = "petclinic-terraform-locks"
  }
}
