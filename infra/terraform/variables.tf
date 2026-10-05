variable "region" {
  description = "Região AWS (us-east-1 costuma ser mais barata; sa-east-1 = São Paulo)"
  type        = string
  default     = "us-east-1"
}

variable "aws_profile" {
  description = "Profile do ~/.aws/credentials (null = cadeia padrão de credenciais)"
  type        = string
  default     = null
}

variable "grupo" {
  description = "Nome do grupo (usado nas tags)"
  type        = string
}

variable "owner" {
  description = "E-mail do responsável (usado nas tags, no SNS de alarmes e no AWS Budget)"
  type        = string
}

variable "ambiente" {
  description = "Ambiente"
  type        = string
  default     = "projeto-final"
}

variable "vpc_cidr" {
  description = "CIDR da VPC principal"
  type        = string
  default     = "10.0.0.0/16"
}

variable "instance_type" {
  description = "Tipo das instâncias web/app (Graviton: ~20% mais barato que x86 equivalente)"
  type        = string
  default     = "t4g.small"
}

variable "asg_min" {
  description = "Mínimo de instâncias (1 por AZ: tolera a perda de uma AZ)"
  type        = number
  default     = 2
}

variable "asg_max" {
  description = "Máximo de instâncias (10× o tráfego normal em datas promocionais)"
  type        = number
  default     = 20
}

variable "db_instance_class" {
  description = "Classe do RDS PostgreSQL Multi-AZ"
  type        = string
  default     = "db.t4g.small"
}

variable "budget_mensal_usd" {
  description = "Limite do AWS Budget mensal (US$): base ~US$ 223 + folga para o mês da Black Friday (~US$ 295)"
  type        = number
  default     = 300
}
