# ---------------------------------------------------------------- CloudFront
# Uma distribuição, duas origens: /img/* vem do S3 (cache longo), o resto vai ao ALB (sem cache).
# O usuário sempre fala HTTPS com a borda mais próxima (Fortaleza, Rio, São Paulo...).

data "aws_cloudfront_cache_policy" "otimizado" {
  name = "Managed-CachingOptimized"
}

data "aws_cloudfront_cache_policy" "sem_cache" {
  name = "Managed-CachingDisabled"
}

data "aws_cloudfront_origin_request_policy" "tudo_menos_host" {
  name = "Managed-AllViewerExceptHostHeader"
}

resource "aws_cloudfront_origin_access_control" "imagens" {
  name                              = "${local.nome}-imagens-oac"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

resource "aws_cloudfront_distribution" "cdn" {
  enabled         = true
  is_ipv6_enabled = true
  comment         = "FarmaVida - loja + imagens do catalogo"
  price_class     = "PriceClass_All" # inclui as bordas da América do Sul

  origin {
    origin_id                = "s3-imagens"
    domain_name              = aws_s3_bucket.imagens.bucket_regional_domain_name
    origin_access_control_id = aws_cloudfront_origin_access_control.imagens.id
  }

  origin {
    origin_id   = "alb-loja"
    domain_name = aws_lb.web.dns_name
    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "http-only" # vira https-only com certificado ACM (próximo passo)
      origin_ssl_protocols   = ["TLSv1.2"]
    }
  }

  default_cache_behavior {
    target_origin_id         = "alb-loja"
    viewer_protocol_policy   = "redirect-to-https"
    allowed_methods          = ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"]
    cached_methods           = ["GET", "HEAD"]
    cache_policy_id          = data.aws_cloudfront_cache_policy.sem_cache.id
    origin_request_policy_id = data.aws_cloudfront_origin_request_policy.tudo_menos_host.id
    compress                 = true
  }

  ordered_cache_behavior {
    path_pattern           = "/img/*"
    target_origin_id       = "s3-imagens"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]
    cache_policy_id        = data.aws_cloudfront_cache_policy.otimizado.id
    compress               = true
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    cloudfront_default_certificate = true # *.cloudfront.net; domínio próprio via ACM + Route 53 é bônus
    minimum_protocol_version       = "TLSv1.2_2021"
  }
}
