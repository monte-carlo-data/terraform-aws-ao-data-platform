data "aws_route53_zone" "main" {
  count   = var.hosted_zone_id != null ? 1 : 0
  zone_id = var.hosted_zone_id
}

# ACM Certificates — TLS certificates for the OTel Collector and ClickHouse NLB endpoints.
# DNS validation is automated via Route 53 when hosted_zone_id is provided.

resource "aws_acm_certificate" "otel_collector" {
  count             = var.otel_collector_domain != null ? 1 : 0
  domain_name       = var.otel_collector_domain
  validation_method = "DNS"
  tags              = var.tags
  lifecycle { create_before_destroy = true }
}

resource "aws_acm_certificate" "clickhouse" {
  count             = var.clickhouse_domain != null ? 1 : 0
  domain_name       = var.clickhouse_domain
  validation_method = "DNS"
  tags              = var.tags
  lifecycle { create_before_destroy = true }
}

resource "aws_route53_record" "otel_collector_cert_validation" {
  for_each = var.otel_collector_domain != null && var.hosted_zone_id != null ? {
    for dvo in aws_acm_certificate.otel_collector[0].domain_validation_options : dvo.domain_name => dvo
  } : {}

  allow_overwrite = true
  name            = each.value.resource_record_name
  records         = [each.value.resource_record_value]
  ttl             = 60
  type            = each.value.resource_record_type
  zone_id         = var.hosted_zone_id
}

resource "aws_route53_record" "clickhouse_cert_validation" {
  for_each = var.clickhouse_domain != null && var.hosted_zone_id != null ? {
    for dvo in aws_acm_certificate.clickhouse[0].domain_validation_options : dvo.domain_name => dvo
  } : {}

  allow_overwrite = true
  name            = each.value.resource_record_name
  records         = [each.value.resource_record_value]
  ttl             = 60
  type            = each.value.resource_record_type
  zone_id         = var.hosted_zone_id
}

resource "aws_acm_certificate_validation" "otel_collector" {
  count                   = var.otel_collector_domain != null && var.hosted_zone_id != null ? 1 : 0
  certificate_arn         = aws_acm_certificate.otel_collector[0].arn
  validation_record_fqdns = [for r in aws_route53_record.otel_collector_cert_validation : r.fqdn]
}

resource "aws_acm_certificate_validation" "clickhouse" {
  count                   = var.clickhouse_domain != null && var.hosted_zone_id != null ? 1 : 0
  certificate_arn         = aws_acm_certificate.clickhouse[0].arn
  validation_record_fqdns = [for r in aws_route53_record.clickhouse_cert_validation : r.fqdn]
}
