locals {
  fastly_domain_name = "fastly-${var.static_domain_name}"

  primary_host_name  = aws_s3_bucket.static.region
  fallback_host_name = aws_s3_bucket.fallback.region

  dictionary_name = "compute_static"

  package_path = "./compute-static/pkg/compute-static.tar.gz"
}

### Stage 1

resource "fastly_service_compute" "static" {
  name = var.static_domain_name

  domain {
    name = local.fastly_domain_name
  }

  backend {
    # Must be identical to s3-primary-host item in dictionary
    name = local.primary_host_name

    address       = aws_s3_bucket.static.bucket_regional_domain_name
    override_host = aws_s3_bucket.static.bucket_regional_domain_name

    use_ssl           = true
    port              = 443
    ssl_cert_hostname = aws_s3_bucket.static.bucket_regional_domain_name
  }

  backend {
    # Must be identical to s3-fallback-host item in dictionary
    name = local.fallback_host_name

    address       = aws_s3_bucket.fallback.bucket_regional_domain_name
    override_host = aws_s3_bucket.fallback.bucket_regional_domain_name

    use_ssl           = true
    port              = 443
    ssl_cert_hostname = aws_s3_bucket.fallback.bucket_regional_domain_name
  }

  dictionary {
    name = local.dictionary_name
  }

  package {
    filename         = local.package_path
    source_code_hash = filesha512(local.package_path)
  }
}

resource "fastly_service_dictionary_items" "compute_static" {
  for_each = {
    for d in fastly_service_compute.static.dictionary : d.name => d if d.name == local.dictionary_name
  }

  service_id    = fastly_service_compute.static.id
  dictionary_id = each.value.dictionary_id
  manage_items  = true

  items = {
    "s3-primary-host" : local.primary_host_name
    "s3-fallback-host" : local.fallback_host_name
  }
}

resource "fastly_tls_subscription" "static" {
  certificate_authority = "lets-encrypt"
  domains               = [local.fastly_domain_name]
}

### Stage 2

resource "aws_route53_record" "static_tls_validation" {
  depends_on = [fastly_tls_subscription.static]

  for_each = {
    for challenge in fastly_tls_subscription.static.managed_dns_challenges :
    trimprefix(challenge.record_name, "_acme-challenge.") => challenge
  }

  name            = each.value.record_name
  type            = each.value.record_type
  zone_id         = data.aws_route53_zone.static.id
  allow_overwrite = true
  records         = [each.value.record_value]
  ttl             = 60
}

resource "fastly_tls_subscription_validation" "static" {
  depends_on      = [aws_route53_record.static_tls_validation]
  subscription_id = fastly_tls_subscription.static.id
}

resource "aws_route53_record" "fastly_static_domain" {
  name            = local.fastly_domain_name
  type            = "CNAME"
  zone_id         = data.aws_route53_zone.static.id
  allow_overwrite = true
  records         = ["n.sni.global.fastly.net"]
  ttl             = 60
}
