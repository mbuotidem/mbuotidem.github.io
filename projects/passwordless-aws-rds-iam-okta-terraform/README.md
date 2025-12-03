# Passwordless AWS RDS IAM Authentication with Okta

This Terraform project sets up passwordless PostgreSQL RDS access using AWS IAM authentication integrated with Okta SAML. Users authenticate through Okta and can connect to the database using temporary IAM credentials instead of passwords.

## What it does

- Creates a PostgreSQL RDS instance with IAM authentication enabled
- Sets up AWS IAM Identity Center (SSO) permission sets for database access
- Syncs Okta users with PostgreSQL roles
- Automatically terminates database sessions for users removed from Okta
- Stores Okta API credentials in AWS Secrets Manager

## Requirements

- AWS CLI configured with appropriate permissions
- Terraform >= 1.0
- Okta service app with API access
- AWS Identity Center configured with Okta as identity provider
- Private subnets with tags `Tier = "Private"`

## Setup

1. Set environment variables:
```bash
export TF_VAR_vpc_id="vpc-xxxxxxxxx"
export TF_VAR_region="us-east-1"
export TF_VAR_okta_org_name="your-okta-org"
export TF_VAR_okta_client_id="your-client-id"
export TF_VAR_okta_group_name="your-group-name"
export TF_VAR_okta_private_key="$(cat path/to/private-key.pem)"
export OKTA_API_PRIVATE_KEY="$(cat path/to/private-key.pem)"
```

1. Set backend config

```
backend "s3" {
    bucket       = "yourbucket"
    key          = "yourkey"
    region       = "your region"
    encrypt      = true
    use_lockfile = true
  }
```

2. Initialize and apply Terraform:
```bash
terraform init
terraform plan
terraform apply
```

You might need to run apply more than once.

## Destroy

Terraform destroy should work. You might need to run it a few times.
