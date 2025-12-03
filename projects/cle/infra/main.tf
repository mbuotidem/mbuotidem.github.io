resource "random_pet" "this" {
  length = 2
}

module "ecr" {
  source = "terraform-aws-modules/ecr/aws"

  repository_name         = "${random_pet.this.id}-ecr"
  repository_force_delete = true

  create_lifecycle_policy = false

  repository_lambda_read_access_arns = [module.lambda_function_with_docker_build_from_ecr.lambda_function_arn]
}

resource "random_password" "session_secret" {
  length  = 20
  special = false
}

locals {
  source_path   = "../"
  path_include  = ["**"]
  path_exclude  = ["**/__pycache__/**"]
  files_include = setunion([for f in local.path_include : fileset(local.source_path, f)]...)
  files_exclude = setunion([for f in local.path_exclude : fileset(local.source_path, f)]...)
  files         = sort(setsubtract(local.files_include, local.files_exclude))

  dir_sha = sha1(join("", [for f in local.files : filesha1("${local.source_path}/${f}")]))
}

module "docker_build_from_ecr" {
  source = "terraform-aws-modules/lambda/aws//modules/docker-build"

  ecr_repo = module.ecr.repository_name


  use_image_tag = true
  image_tag     = local.dir_sha

  source_path = local.source_path
  platform    = "linux/amd64"
  build_args = {
    FOO = "bar"
  }

  triggers = {
    dir_sha = local.dir_sha
  }

}

module "lambda_function_with_docker_build_from_ecr" {
  source = "terraform-aws-modules/lambda/aws"

  function_name = "${random_pet.this.id}-lambda-with-docker-build-from-ecr"
  description   = "My FastHTML lambda function"

  create_package = false
  package_type   = "Image"
  architectures  = ["x86_64"]


  image_uri                  = module.docker_build_from_ecr.image_uri
  create_lambda_function_url = true
  environment_variables = {
    "LIVE"           = "False"
    "SESSION_SECRET" = random_password.session_secret.result
  }
  reserved_concurrent_executions = 1
}


output "url" {
  value = module.lambda_function_with_docker_build_from_ecr.lambda_function_url

}
