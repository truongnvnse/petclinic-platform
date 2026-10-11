# variables.tf — vpc module inputs
#
# Interface defined in docs/technical-spec.md → "Terraform Modules" → Module: vpc.

variable "project" {
  description = "Project name used for resource naming and tagging"
  type        = string
  default     = "petclinic"
}

variable "environment" {
  description = "Environment name — must be 'dev' or 'prod'"
  type        = string

  validation {
    condition     = contains(["dev", "prod"], var.environment)
    error_message = "The environment must be either 'dev' or 'prod'."
  }
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC (dev 10.0.0.0/16, prod 10.1.0.0/16 — kept non-overlapping for future peering)"
  type        = string
}

variable "public_subnet_cidrs" {
  description = "CIDR blocks for the public subnets, one per availability zone, positionally paired with availability_zones"
  type        = list(string)

  validation {
    condition     = length(var.public_subnet_cidrs) >= 2
    error_message = "At least two public subnets are required — EKS and the ALB need subnets in two availability zones."
  }
}

variable "availability_zones" {
  description = "Availability zones for the public subnets, in the same order as public_subnet_cidrs (must be the same length)"
  type        = list(string)
}

variable "tags" {
  description = "Additional tags merged onto every resource in this module"
  type        = map(string)
  default     = {}
}
