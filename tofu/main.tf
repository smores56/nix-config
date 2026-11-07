# Ingress stays in Nix (modules/nixos/web-proxy.nix); the tunnel and its Access service token are
# operator-minted.

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

# Lets unattended `cloudflared access ssh/tcp` clients in without a browser login.
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

# Access email allow-list is the human policy; Open WebUI's own login is a second layer.
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

# Public hosts whose clients cannot complete an Access login (mobile media apps), so a per-IP WAF
# rule is the only brute-force control. The zone plan allows exactly ONE http_ratelimit rule (a
# second fails the apply with "2 out of 1"), so the three hosts share one threshold, sized for the
# burstiest client: an Immich timeline scroll exceeds a few hundred requests per 10s. 1000 is chosen
# for media; split a service out lower if the plan gains rule slots.
# Resource and ruleset names are historical; renaming forces a replacement, which the lifecycle
# block forbids.
resource "cloudflare_ruleset" "dav_rate_limit" {
  zone_id = data.cloudflare_zone.this.zone_id
  name    = "dav rate limit"
  kind    = "zone"
  phase   = "http_ratelimit"

  rules = [
    {
      action      = "block"
      description = "Rate limit the public app hosts per IP"
      expression  = "(http.host eq \"music.${var.domain}\" or http.host eq \"immich.${var.domain}\" or http.host eq \"calibre.${var.domain}\")"
      ratelimit = {
        characteristics = ["ip.src", "cf.colo.id"]
        # Free plan allows only a 10-second period and mitigation window.
        period              = 10
        requests_per_period = 1000
        mitigation_timeout  = 10
      }
    },
  ]

  lifecycle {
    prevent_destroy = true
  }
}
