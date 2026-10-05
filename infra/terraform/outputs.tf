output "azs_utilizadas" {
  description = "AZs usadas no projeto"
  value       = local.azs
}

output "vpc_id" {
  value = aws_vpc.principal.id
}

output "url_loja" {
  description = "Endereço público da loja (HTTPS pelo CloudFront)"
  value       = "https://${aws_cloudfront_distribution.cdn.domain_name}"
}

output "alb_dns_name" {
  description = "DNS do ALB (aceita somente o CloudFront)"
  value       = aws_lb.web.dns_name
}

output "bucket_imagens" {
  value = aws_s3_bucket.imagens.id
}

output "rds_endpoint" {
  value = aws_db_instance.principal.address
}

output "rds_secret_arn" {
  description = "Senha do banco no Secrets Manager (nunca no código)"
  value       = aws_db_instance.principal.master_user_secret[0].secret_arn
}
