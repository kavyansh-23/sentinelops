module "vpc" {
  source = "../../modules/vpc"

  name = "sentinelops-dev"
  azs  = ["ap-southeast-2a", "ap-southeast-2b"]
}

output "vpc_id" {
  value = module.vpc.vpc_id
}
