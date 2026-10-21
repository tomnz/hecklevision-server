terraform {
  required_version = ">= 1.6"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }

  # State is local by default. To migrate to S3 later:
  #
  #   1. Create bucket and lock table (once):
  #        aws s3api create-bucket --bucket <unique-bucket-name> --region <region> \
  #          --create-bucket-configuration LocationConstraint=<region>
  #        aws dynamodb create-table --table-name hecklevision-tf-lock --region <region> \
  #          --attribute-definitions AttributeName=LockID,AttributeType=S \
  #          --key-schema AttributeName=LockID,KeyType=HASH \
  #          --billing-mode PAY_PER_REQUEST
  #   2. Uncomment the block below.
  #   3. Run: terraform init -migrate-state
  #
  # backend "s3" {
  #   bucket         = "<unique-bucket-name>"
  #   key            = "hecklevision-server/terraform.tfstate"
  #   region         = "<region>"
  #   dynamodb_table = "hecklevision-tf-lock"
  #   encrypt        = true
  # }
}
