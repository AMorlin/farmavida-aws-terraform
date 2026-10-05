# ============================================================================
# FarmaVida — E-commerce de Alta Disponibilidade
# Recursos organizados por arquivo:
#   rede.tf            -> VPC, subnets públicas/privadas em 2 AZs, IGW, NAT por AZ, rotas, NACL, VPC endpoint S3
#   seguranca.tf       -> Security Groups encadeados, IAM role da EC2, KMS, CloudTrail
#   armazenamento.tf   -> S3 de imagens (BPA, versionamento, lifecycle), RDS PostgreSQL Multi-AZ
#   computacao.tf      -> Launch Template, Auto Scaling Group, ALB, target group, políticas de escala
#   cdn.tf             -> CloudFront (S3 via OAC + ALB como origem)
#   observabilidade.tf -> CloudWatch (alarmes, logs), SNS, AWS Budgets
# ============================================================================

data "aws_availability_zones" "disponiveis" {
  state = "available"
}

data "aws_caller_identity" "atual" {}

locals {
  azs  = slice(data.aws_availability_zones.disponiveis.names, 0, 2) # 2 AZs (critério de rede)
  nome = "farmavida"
}

resource "random_id" "sufixo" {
  byte_length = 3 # nomes globais de bucket S3
}
