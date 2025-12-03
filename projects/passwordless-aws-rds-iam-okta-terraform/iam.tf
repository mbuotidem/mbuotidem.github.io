data "aws_iam_policy_document" "db_access" {
  statement {
    sid = "dbaccess"

    actions = [
      "rds-db:connect",
    ]

    resources = [
      join(
        "",
        [
          "arn:aws:rds-db:${var.region}:",
          data.aws_caller_identity.current.account_id,
          ":dbuser:",
          module.db.db_instance_resource_id,
          "/",
          "$${saml:sub}"
        ]
      )
    ]

    condition {
      test     = "StringEquals"
      variable = "saml:sub_type"
      values   = ["persistent"]
    }
  }
}

resource "aws_iam_policy" "db_access_policy" {
  name   = "rds-db-access-policy"
  path   = "/"
  policy = data.aws_iam_policy_document.db_access.json
}

resource "aws_ssoadmin_permission_set" "db_access_permission_set" {
  name             = "db_access_permission_set"
  description      = "Permission set for RDS DB access via IAM"
  instance_arn     = data.aws_ssoadmin_instances.sso.arns[0]
  session_duration = "PT1H"
  tags = {
    Purpose = "RDS DB Access"
  }
}

resource "aws_ssoadmin_customer_managed_policy_attachment" "db_access_policy_attachment" {
  instance_arn       = aws_ssoadmin_permission_set.db_access_permission_set.instance_arn
  permission_set_arn = aws_ssoadmin_permission_set.db_access_permission_set.arn
  customer_managed_policy_reference {
    name = aws_iam_policy.db_access_policy.name
    path = "/"
  }
}

resource "aws_ssoadmin_account_assignment" "assign_admins" {
  instance_arn       = tolist(data.aws_ssoadmin_instances.sso.arns)[0]
  permission_set_arn = aws_ssoadmin_permission_set.db_access_permission_set.arn

  principal_id   = data.aws_identitystore_group.admins.group_id
  principal_type = "GROUP"

  target_id   = data.aws_caller_identity.current.account_id
  target_type = "AWS_ACCOUNT"
}
