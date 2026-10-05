# ---------------------------------------------------------------- S3: imagens do catálogo

resource "aws_s3_bucket" "imagens" {
  bucket = "${local.nome}-imagens-${random_id.sufixo.hex}"
}

resource "aws_s3_bucket_public_access_block" "imagens" {
  bucket                  = aws_s3_bucket.imagens.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "imagens" {
  bucket = aws_s3_bucket.imagens.id
  rule {
    object_ownership = "BucketOwnerEnforced" # ACLs desligadas
  }
}

resource "aws_s3_bucket_versioning" "imagens" {
  bucket = aws_s3_bucket.imagens.id
  versioning_configuration {
    status = "Enabled" # protege contra sobrescrita/exclusão acidental
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "imagens" {
  bucket = aws_s3_bucket.imagens.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.dados.arn
    }
    bucket_key_enabled = true # reduz chamadas ao KMS em ~99%
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "imagens" {
  bucket = aws_s3_bucket.imagens.id

  rule {
    id     = "catalogo-intelligent-tiering"
    status = "Enabled"
    filter { prefix = "catalogo/" }
    transition {
      days          = 30
      storage_class = "INTELLIGENT_TIERING" # produtos fora de linha esfriam sozinhos
    }
  }

  rule {
    id     = "versoes-antigas"
    status = "Enabled"
    filter {}
    noncurrent_version_expiration {
      noncurrent_days = 30
    }
    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

# Somente esta distribuição do CloudFront lê o bucket (OAC)
resource "aws_s3_bucket_policy" "imagens" {
  bucket = aws_s3_bucket.imagens.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "CloudFrontOAC"
        Effect    = "Allow"
        Principal = { Service = "cloudfront.amazonaws.com" }
        Action    = "s3:GetObject"
        Resource  = "${aws_s3_bucket.imagens.arn}/*"
        Condition = { StringEquals = { "AWS:SourceArn" = aws_cloudfront_distribution.cdn.arn } }
      },
      {
        Sid       = "SomenteTLS"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource  = [aws_s3_bucket.imagens.arn, "${aws_s3_bucket.imagens.arn}/*"]
        Condition = { Bool = { "aws:SecureTransport" = "false" } }
      },
    ]
  })
  depends_on = [aws_s3_bucket_public_access_block.imagens]
}

# ---------------------------------------------------------------- RDS PostgreSQL Multi-AZ

resource "aws_db_subnet_group" "dados" {
  name       = "${local.nome}-dados"
  subnet_ids = aws_subnet.dados[*].id
}

resource "aws_db_parameter_group" "pg" {
  name   = "${local.nome}-pg17"
  family = "postgres17"

  parameter {
    name  = "rds.force_ssl"
    value = "1" # TLS obrigatório em trânsito
  }
  parameter {
    name  = "log_min_duration_statement"
    value = "1000" # loga consultas acima de 1 s
  }
}

resource "aws_db_instance" "principal" {
  identifier     = "${local.nome}-db"
  engine         = "postgres"
  engine_version = "17"
  instance_class = var.db_instance_class

  allocated_storage     = 20
  max_allocated_storage = 100 # autoscaling de storage para picos de pedidos
  storage_type          = "gp3"
  storage_encrypted     = true
  kms_key_id            = aws_kms_key.dados.arn

  db_name                       = "farmavida"
  username                      = "farmavida_admin"
  manage_master_user_password   = true # senha gerada e rotacionada no Secrets Manager
  master_user_secret_kms_key_id = aws_kms_key.dados.arn

  multi_az               = true # standby síncrono na outra AZ, failover automático
  db_subnet_group_name   = aws_db_subnet_group.dados.name
  vpc_security_group_ids = [aws_security_group.db.id]
  parameter_group_name   = aws_db_parameter_group.pg.name
  publicly_accessible    = false

  backup_retention_period         = 7             # PITR de até 7 dias (RPO de ~5 min)
  backup_window                   = "06:00-07:00" # 03h-04h em Fortaleza
  maintenance_window              = "sun:07:00-sun:08:00"
  copy_tags_to_snapshot           = true
  enabled_cloudwatch_logs_exports = ["postgresql"]
  auto_minor_version_upgrade      = true

  deletion_protection       = true
  skip_final_snapshot       = false
  final_snapshot_identifier = "${local.nome}-db-final"
}
