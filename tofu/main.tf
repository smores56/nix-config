# Eight static edge objects. Ingress remains in Nix
# (modules/nixos/web-proxy.nix); the tunnel itself and its Access service token
# stay operator-minted.

resource "cloudflare_dns_record" "wildcard" {
  zone_id = data.cloudflare_zone.this.zone_id
  name    = "*.${var.domain}"
  type    = "CNAME"
  content = "${var.tunnel_id}.cfargotunnel.com"
  proxied = true
  ttl     = 1
}

resource "cloudflare_zero_trust_access_policy" "email" {
  account_id = var.account_id
  name       = "email allow-list"
  decision   = "allow"

  include = [{
    email = {
      email = var.email
    }
  }]

  lifecycle {
    prevent_destroy = true
  }
}

# Service tokens are non-identity principals; this policy lets unattended
# `cloudflared access ssh/tcp` clients in without a browser login.
resource "cloudflare_zero_trust_access_policy" "service_auth" {
  account_id = var.account_id
  name       = "service auth"
  decision   = "non_identity"

  include = [{
    any_valid_service_token = {}
  }]

  lifecycle {
    prevent_destroy = true
  }
}

resource "cloudflare_zero_trust_access_application" "ssh" {
  account_id       = var.account_id
  name             = "ssh"
  domain           = "ssh.${var.domain}"
  type             = "self_hosted"
  session_duration = "24h"

  policies = [
    {
      id         = cloudflare_zero_trust_access_policy.email.id
      precedence = 1
    },
    {
      id         = cloudflare_zero_trust_access_policy.service_auth.id
      precedence = 2
    },
  ]

  lifecycle {
    prevent_destroy = true
  }
}

resource "cloudflare_zero_trust_access_application" "llm" {
  account_id       = var.account_id
  name             = "llm"
  domain           = "llm.${var.domain}"
  type             = "self_hosted"
  session_duration = "24h"

  policies = [
    {
      id         = cloudflare_zero_trust_access_policy.email.id
      precedence = 1
    },
    {
      id         = cloudflare_zero_trust_access_policy.service_auth.id
      precedence = 2
    },
  ]

  lifecycle {
    prevent_destroy = true
  }
}

resource "cloudflare_zero_trust_access_application" "memory" {
  account_id       = var.account_id
  name             = "memory"
  domain           = "memory.${var.domain}"
  type             = "self_hosted"
  session_duration = "24h"

  policies = [
    {
      id         = cloudflare_zero_trust_access_policy.email.id
      precedence = 1
    },
    {
      id         = cloudflare_zero_trust_access_policy.service_auth.id
      precedence = 2
    },
  ]

  lifecycle {
    prevent_destroy = true
  }
}

# The phone reaches LobeChat only through Access. The email allow-list is the
# human policy; LobeChat's own email/password login is the second layer.
resource "cloudflare_zero_trust_access_application" "chat" {
  account_id       = var.account_id
  name             = "chat"
  domain           = "chat.${var.domain}"
  type             = "self_hosted"
  session_duration = "24h"

  policies = [
    {
      id         = cloudflare_zero_trust_access_policy.email.id
      precedence = 1
    },
  ]

  lifecycle {
    prevent_destroy = true
  }
}

# Presigned S3 URLs are browser requests from chat.<domain>. Keep the origin
# private; the Access cookie is host-scoped, so the phone signs in here once.
# OPTIONS preflights bypass Access so RustFS can answer CORS itself.
resource "cloudflare_zero_trust_access_application" "s3" {
  account_id               = var.account_id
  name                     = "s3"
  domain                   = "s3.${var.domain}"
  type                     = "self_hosted"
  session_duration         = "24h"
  options_preflight_bypass = true

  policies = [
    {
      id         = cloudflare_zero_trust_access_policy.email.id
      precedence = 1
    },
  ]

  lifecycle {
    prevent_destroy = true
  }
}

# Presigned uploads/downloads are cross-origin fetches, which never send the
# Access cookie, so an Access session cannot cover them. Object paths are
# protected by SigV4 instead: RustFS rejects anything unsigned, and the API
# remains the only surface (the console is disabled).
resource "cloudflare_zero_trust_access_policy" "s3_objects_bypass" {
  account_id = var.account_id
  name       = "s3 object paths (presigned)"
  decision   = "bypass"
  include    = [{ everyone = {} }]

  lifecycle {
    prevent_destroy = true
  }
}

resource "cloudflare_zero_trust_access_application" "s3_objects" {
  account_id       = var.account_id
  name             = "s3 objects (presigned)"
  domain           = "s3.${var.domain}/lobe"
  type             = "self_hosted"
  session_duration = "24h"

  policies = [
    {
      id         = cloudflare_zero_trust_access_policy.s3_objects_bypass.id
      precedence = 1
    },
  ]

  lifecycle {
    prevent_destroy = true
  }
}

resource "cloudflare_notification_policy" "tunnel_health" {
  account_id = var.account_id
  name       = "tunnel health"
  enabled    = true
  alert_type = "tunnel_health_event"

  filters = {
    tunnel_id = [var.tunnel_id]
  }

  mechanisms = {
    email = [{
      id = var.email
    }]
  }

  lifecycle {
    prevent_destroy = true
  }
}

resource "cloudflare_notification_policy" "service_token_expiry" {
  account_id = var.account_id
  name       = "service token expiry"
  enabled    = true
  alert_type = "expiring_service_token_alert"

  mechanisms = {
    email = [{
      id = var.email
    }]
  }

  lifecycle {
    prevent_destroy = true
  }
}
