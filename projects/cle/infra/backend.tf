terraform {
  backend "s3" {
    bucket         = "cle-terraform-backend"
    key            = "state/terraform.tfstate"
    region         = "us-east-1"
    encrypt        = true
    kms_key_id     = "alias/cle-terraform-backend-key"
    dynamodb_table = "cle-terraform-state"
  }
}


resource "aws_kms_key" "terraform_bucket_key" {
  description             = "This key is used to encrypt bucket objects"
  deletion_window_in_days = 10
  enable_key_rotation     = true
}

resource "aws_kms_alias" "key_alias" {
  name          = "alias/cle-terraform-backend-key"
  target_key_id = aws_kms_key.terraform_bucket_key.key_id
}

#tfsec:ignore:aws-s3-enable-bucket-logging
resource "aws_s3_bucket" "terraform_state" {
  bucket = "cle-terraform-backend"

}

resource "aws_s3_bucket_versioning" "versioning_backend" {
  bucket = aws_s3_bucket.terraform_state.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_public_access_block" "block" {
  bucket = aws_s3_bucket.terraform_state.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "backend" {
  bucket = aws_s3_bucket.terraform_state.id

  rule {
    apply_server_side_encryption_by_default {
      kms_master_key_id = aws_kms_alias.key_alias.target_key_arn
      sse_algorithm     = "aws:kms"
    }
  }
}

#tfsec:ignore:aws-dynamodb-enable-recovery
resource "aws_dynamodb_table" "terraform-state" {
  name           = "cle-terraform-state"
  read_capacity  = 20
  write_capacity = 20
  hash_key       = "LockID"

  attribute {
    name = "LockID"
    type = "S"
  }
  server_side_encryption {
    enabled     = true
    kms_key_arn = aws_kms_alias.key_alias.target_key_arn
  }
}
