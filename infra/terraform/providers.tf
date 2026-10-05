terraform {
  required_version = ">= 1.6"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

provider "aws" {
  region  = var.region
  profile = var.aws_profile

  # Tags de custo aplicadas automaticamente em todos os recursos (critério FinOps)
  default_tags {
    tags = {
      Projeto   = "ecommerce-farmavida"
      Grupo     = var.grupo
      Ambiente  = var.ambiente
      Owner     = var.owner
      ManagedBy = "terraform"
    }
  }
}
