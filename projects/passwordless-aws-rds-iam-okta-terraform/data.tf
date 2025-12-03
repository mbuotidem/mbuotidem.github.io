locals {
  name = "passwordless-aws-rds-iam-okta-terraform"
  tags = {
    Name       = local.name
    Repository = "https://github.com/mbuotidem/passwordless-aws-rds-iam-okta-terraform"
  }
  host                     = substr(module.db.db_instance_endpoint, 0, length(module.db.db_instance_endpoint) - 5)
  username                 = "complete_postgresql"
  database                 = "completePostgresql"
  password                 = jsondecode(ephemeral.aws_secretsmanager_secret_version.secret-version.secret_string)["password"]
  terminated_sessions_file = "${path.module}/terminated_sessions.json"

}


data "aws_vpc" "vpc" {
  id = var.vpc_id
}

data "okta_group" "admins" {
  name = var.okta_group_name
}

output "okta_group" {
  value = data.okta_group.admins.id
}

data "aws_ssoadmin_instances" "sso" {
}

data "aws_identitystore_group" "admins" {
  identity_store_id = tolist(data.aws_ssoadmin_instances.sso.identity_store_ids)[0]

  alternate_identifier {
    unique_attribute {
      attribute_path  = "DisplayName"
      attribute_value = data.okta_group.admins.name
    }
  }
}

data "okta_users" "admins" {
  group_id = data.okta_group.admins.id
}


data "aws_subnets" "private" {
  filter {
    name   = "vpc-id"
    values = [var.vpc_id]
  }

  tags = {
    Tier = "Private"
  }
}

data "aws_caller_identity" "current" {}
