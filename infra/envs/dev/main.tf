variable "image_tag" {
  type    = string
  default = "v1"
}

data "aws_ecr_repository" "app" {
  name = "sentinelops-app"
}

module "vpc" {
  source = "../../modules/vpc"

  name = "sentinelops-dev"
  azs  = ["ap-southeast-2a", "ap-southeast-2b"]
}

module "alb" {
  source = "../../modules/alb"

  name              = "sentinelops-dev"
  vpc_id            = module.vpc.vpc_id
  public_subnet_ids = module.vpc.public_subnet_ids
  target_port       = 8080
}

module "app" {
  source = "../../modules/ecs-service"

  name                  = "sentinelops-dev-app"
  vpc_id                = module.vpc.vpc_id
  private_subnet_ids    = module.vpc.private_subnet_ids
  image                 = "${data.aws_ecr_repository.app.repository_url}:${var.image_tag}"
  container_port        = 8080
  target_group_arn      = module.alb.target_group_arn
  alb_security_group_id = module.alb.security_group_id
  environment           = { APP_VERSION = var.image_tag }
}

output "vpc_id" {
  value = module.vpc.vpc_id
}

output "alb_url" {
  value = "http://${module.alb.dns_name}"
}

variable "alert_email" {
  type    = string
  default = ""
}

module "observability" {
  source = "../../modules/observability"

  name                    = "sentinelops-dev"
  alb_arn_suffix          = module.alb.alb_arn_suffix
  target_group_arn_suffix = module.alb.target_group_arn_suffix
  cluster_name            = module.app.cluster_name
  service_name            = module.app.service_name
  log_group_name          = module.app.log_group_name
  alert_email             = var.alert_email
}
