# ---------------------------------------------------------------- Security Groups encadeados
# CloudFront -> sg-alb -> sg-app -> sg-db. Cada regra referencia a camada anterior, não IPs.

data "aws_ec2_managed_prefix_list" "cloudfront" {
  name = "com.amazonaws.global.cloudfront.origin-facing"
}

resource "aws_security_group" "alb" {
  name        = "${local.nome}-alb"
  description = "ALB - aceita apenas trafego vindo do CloudFront"
  vpc_id      = aws_vpc.principal.id
  tags        = { Name = "sg-alb" }
}

resource "aws_vpc_security_group_ingress_rule" "alb_cloudfront" {
  security_group_id = aws_security_group.alb.id
  description       = "HTTP somente dos edge locations do CloudFront"
  ip_protocol       = "tcp"
  from_port         = 80
  to_port           = 80
  prefix_list_id    = data.aws_ec2_managed_prefix_list.cloudfront.id
}

resource "aws_vpc_security_group_egress_rule" "alb_app" {
  security_group_id            = aws_security_group.alb.id
  description                  = "Encaminha para as instancias"
  ip_protocol                  = "tcp"
  from_port                    = 80
  to_port                      = 80
  referenced_security_group_id = aws_security_group.app.id
}

resource "aws_security_group" "app" {
  name        = "${local.nome}-app"
  description = "EC2 web/app - aceita apenas o ALB; sem SSH (acesso via SSM)"
  vpc_id      = aws_vpc.principal.id
  tags        = { Name = "sg-app" }
}

resource "aws_vpc_security_group_ingress_rule" "app_alb" {
  security_group_id            = aws_security_group.app.id
  description                  = "HTTP vindo do ALB"
  ip_protocol                  = "tcp"
  from_port                    = 80
  to_port                      = 80
  referenced_security_group_id = aws_security_group.alb.id
}

resource "aws_vpc_security_group_egress_rule" "app_https" {
  security_group_id = aws_security_group.app.id
  description       = "HTTPS de saida (pacotes, SSM, CloudWatch, Secrets Manager) via NAT/endpoint"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_egress_rule" "app_http_pacotes" {
  security_group_id = aws_security_group.app.id
  description       = "HTTP de saida para repositorios de pacotes do Amazon Linux"
  ip_protocol       = "tcp"
  from_port         = 80
  to_port           = 80
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_egress_rule" "app_db" {
  security_group_id            = aws_security_group.app.id
  description                  = "PostgreSQL no RDS"
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
  referenced_security_group_id = aws_security_group.db.id
}

resource "aws_security_group" "db" {
  name        = "${local.nome}-db"
  description = "RDS PostgreSQL - aceita apenas as instancias de app"
  vpc_id      = aws_vpc.principal.id
  tags        = { Name = "sg-db" }
}

resource "aws_vpc_security_group_ingress_rule" "db_app" {
  security_group_id            = aws_security_group.db.id
  description                  = "PostgreSQL vindo do app"
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
  referenced_security_group_id = aws_security_group.app.id
}

# ---------------------------------------------------------------- KMS (chave do cliente, com rotação)

resource "aws_kms_key" "dados" {
  description             = "FarmaVida - dados pessoais e de pagamento (RDS, S3, CloudTrail)"
  enable_key_rotation     = true
  deletion_window_in_days = 30

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AdministracaoPelaConta"
        Effect    = "Allow"
        Principal = { AWS = "arn:aws:iam::${data.aws_caller_identity.atual.account_id}:root" }
        Action    = "kms:*"
        Resource  = "*"
      },
      {
        Sid       = "CloudFrontLeImagensViaOAC"
        Effect    = "Allow"
        Principal = { Service = "cloudfront.amazonaws.com" }
        Action    = ["kms:Decrypt"]
        Resource  = "*"
        Condition = { StringEquals = { "AWS:SourceArn" = aws_cloudfront_distribution.cdn.arn } }
      },
      {
        Sid       = "CloudTrailCifraLogs"
        Effect    = "Allow"
        Principal = { Service = "cloudtrail.amazonaws.com" }
        Action    = ["kms:GenerateDataKey*", "kms:DescribeKey"]
        Resource  = "*"
        Condition = { StringLike = { "kms:EncryptionContext:aws:cloudtrail:arn" = "arn:aws:cloudtrail:*:${data.aws_caller_identity.atual.account_id}:trail/*" } }
      },
    ]
  })
}

resource "aws_kms_alias" "dados" {
  name          = "alias/${local.nome}-dados"
  target_key_id = aws_kms_key.dados.key_id
}

# ---------------------------------------------------------------- IAM role das instâncias (sem access keys)

resource "aws_iam_role" "app" {
  name = "${local.nome}-ec2-app"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

# Session Manager: área administrativa e manutenção sem bastion e sem porta 22
resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.app.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy_attachment" "cloudwatch_agent" {
  role       = aws_iam_role.app.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
}

# Permissões da aplicação restritas aos recursos do projeto (sem "*:*")
resource "aws_iam_role_policy" "app" {
  name = "${local.nome}-app-minimo"
  role = aws_iam_role.app.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ImagensDoCatalogo"
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:PutObject"]
        Resource = "${aws_s3_bucket.imagens.arn}/catalogo/*"
      },
      {
        Sid      = "SenhaDoBanco"
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue"]
        Resource = aws_db_instance.principal.master_user_secret[0].secret_arn
      },
      {
        Sid      = "ChaveDoProjeto"
        Effect   = "Allow"
        Action   = ["kms:Decrypt", "kms:GenerateDataKey"]
        Resource = aws_kms_key.dados.arn
      },
    ]
  })
}

resource "aws_iam_instance_profile" "app" {
  name = "${local.nome}-ec2-app"
  role = aws_iam_role.app.name
}

# ---------------------------------------------------------------- CloudTrail (auditoria de API)

resource "aws_s3_bucket" "trilha" {
  bucket        = "${local.nome}-cloudtrail-${random_id.sufixo.hex}"
  force_destroy = true
}

resource "aws_s3_bucket_public_access_block" "trilha" {
  bucket                  = aws_s3_bucket.trilha.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "trilha" {
  bucket = aws_s3_bucket.trilha.id
  rule {
    id     = "logs-auditoria"
    status = "Enabled"
    filter {}
    transition {
      days          = 90
      storage_class = "GLACIER_IR"
    }
    expiration {
      days = 1825 # 5 anos de retenção de auditoria
    }
  }
}

resource "aws_s3_bucket_policy" "trilha" {
  bucket = aws_s3_bucket.trilha.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "CloudTrailAclCheck"
        Effect    = "Allow"
        Principal = { Service = "cloudtrail.amazonaws.com" }
        Action    = "s3:GetBucketAcl"
        Resource  = aws_s3_bucket.trilha.arn
      },
      {
        Sid       = "CloudTrailWrite"
        Effect    = "Allow"
        Principal = { Service = "cloudtrail.amazonaws.com" }
        Action    = "s3:PutObject"
        Resource  = "${aws_s3_bucket.trilha.arn}/AWSLogs/${data.aws_caller_identity.atual.account_id}/*"
        Condition = { StringEquals = { "s3:x-amz-acl" = "bucket-owner-full-control" } }
      },
    ]
  })
}

resource "aws_cloudtrail" "auditoria" {
  name                          = "${local.nome}-trilha"
  s3_bucket_name                = aws_s3_bucket.trilha.id
  is_multi_region_trail         = true
  include_global_service_events = true
  enable_log_file_validation    = true
  kms_key_id                    = aws_kms_key.dados.arn
  depends_on                    = [aws_s3_bucket_policy.trilha]
}
