terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }

  backend "s3" {
    bucket       = "sentinelops-tfstate-441620015519"
    key          = "dev/terraform.tfstate"
    region       = "ap-southeast-2"
    profile      = "sentinel"
    use_lockfile = true
    encrypt      = true
  }
}

provider "aws" {
  region  = "ap-southeast-2"
  profile = "sentinel"

  default_tags {
    tags = {
      Project     = "sentinelops"
      Environment = "dev"
      ManagedBy   = "terraform"
    }
  }
}
