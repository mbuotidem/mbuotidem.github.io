variable "vpc_id" {
  type        = string
  description = "vpc to deploy resources to"
}

variable "region" {
  type        = string
  description = "desired region"
}

variable "okta_private_key" {
  # Pass in as env var using TF_VAR_okta_private_key
  type        = string
  description = "private key from okta api service app "
}

variable "okta_org_name" {
  type        = string
  description = "org_name is first part of orgs's Okta domain before .okta.com"

}

variable "okta_client_id" {
  type        = string
  description = "id of okta service app"

}

variable "okta_group_name" {
  type        = string
  description = "okta group you'd like to grant db access to"

}
