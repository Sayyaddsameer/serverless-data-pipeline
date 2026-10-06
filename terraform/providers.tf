provider "aws" {
  region = var.aws_region
}

# Backend configuration uses partial configuration.
# Actual values for bucket, key, region, and dynamodb_table
# are supplied at init time via -backend-config flags or
# a backend.hcl file. This keeps secrets and environment-specific
# details out of version-controlled code.
#
# Example init command:
#   terraform init \
#     -backend-config="bucket=my-tf-state-bucket" \
#     -backend-config="key=data-pipeline/terraform.tfstate" \
#     -backend-config="region=us-east-1" \
#     -backend-config="dynamodb_table=terraform-locks"

terraform {
  backend "s3" {}
}
