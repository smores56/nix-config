# Five static edge objects. Ingress remains in Nix (modules/nixos/web-proxy.nix);
# the tunnel itself and its Access service token stay operator-minted.

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
