terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "5.96.0"
    }
    okta = {
      source  = "okta/okta"
      version = "~> 5.0.0"
    }
    postgresql = {
      source  = "cyrilgdn/postgresql"
      version = "1.25.0"
    }
  }

  backend "s3" {
    bucket       = "yourbucket"
    key          = "yourkey"
    region       = "your region"
    encrypt      = true
    use_lockfile = true
  }
}

provider "aws" {
  region = var.region
  default_tags {
    tags = local.tags
  }
}

provider "postgresql" {
  host            = local.host
  database        = local.database
  username        = local.username
  password        = local.password
  sslmode         = "require"
  connect_timeout = 15
  superuser       = false # required for RDS users. AWS doesn't grant us superser, but instead `rds_superuser`
}

resource "aws_secretsmanager_secret" "okta_private_key" {
  name        = "okta-privatea"
  description = "Private key for Okta API access"
}

resource "aws_secretsmanager_secret_version" "okta_private_key" {
  secret_id                = aws_secretsmanager_secret.okta_private_key.id
  secret_string_wo         = var.okta_private_key
  secret_string_wo_version = 1

}

ephemeral "aws_secretsmanager_secret_version" "okta_private_key" {
  secret_id = aws_secretsmanager_secret.okta_private_key.id
}
provider "okta" {
  # org_name is first part of orgs's Okta domain before .okta.com
  org_name    = var.okta_org_name
  base_url    = "okta.com"
  client_id   = var.okta_client_id
  scopes      = ["okta.groups.manage", "okta.users.manage"]
  private_key = ephemeral.aws_secretsmanager_secret_version.okta_private_key.secret_string
}
