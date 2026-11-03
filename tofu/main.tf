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

# The phone reaches Open WebUI only through Access. The email allow-list is the
# human policy; Open WebUI's own email/password login is the second layer.
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

# Rate limiting for the public hosts whose clients cannot complete an Access
# login. CalDAV/CardDAV clients (Radicale has no brute-force protection of its
# own) and the media apps (Navidrome, Immich, Calibre are reached by mobile apps
# that authenticate with a password) therefore have no identity layer in front
# of them, and a per-IP WAF rule is the only brute-force control left.
#
# The thresholds are set to stop credential stuffing, not to shape ordinary
# traffic: a first DAVx5/khal/vdirsyncer sync walks a whole collection, and an
# Immich timeline scroll fetches one thumbnail per tile, so both routinely
# exceed a few hundred requests per ten seconds. The counter is therefore high
# enough for a normal client to fit under, and the ten-second block is the
# brute-force control: an address over the ceiling gets no answers for ten
# seconds, which makes guessing slow and noisy without touching normal use.
#
# Cloudflare's free plan caps a zone at one rate-limiting rule, so a downgraded
# zone rejects the second rule below at plan time; `nix run .#cloudflare-plan`
# is how the operator finds out.
resource "cloudflare_ruleset" "dav_rate_limit" {
  zone_id = data.cloudflare_zone.this.zone_id
  name    = "dav rate limit"
  kind    = "zone"
  phase   = "http_ratelimit"

  rules = [
    {
      action      = "block"
      description = "Rate limit CalDAV/CardDAV clients per IP"
      expression  = "(http.host eq \"dav.${var.domain}\")"
      ratelimit = {
        characteristics = ["ip.src", "cf.colo.id"]
        # Free-plan rate limiting only permits a 10-second period. 600/10s is a
        # credential-stuffing ceiling, not a traffic shaper: a first full sync
        # of one collection by a normal client must fit under it.
        period              = 10
        requests_per_period = 600
        # Free-plan rate limiting caps both the period and the mitigation at 10s.
        mitigation_timeout = 10
      }
    },
    {
      action      = "block"
      description = "Rate limit the public media app hosts per IP"
      expression  = "(http.host eq \"music.${var.domain}\" or http.host eq \"immich.${var.domain}\" or http.host eq \"calibre.${var.domain}\")"
      ratelimit = {
        characteristics = ["ip.src", "cf.colo.id"]
        # 1000 requests per 10s is deliberately lenient: the Immich mobile
        # client fetches a thumbnail per timeline tile plus the videos, and the
        # target is credential stuffing, not normal use. The 10s block is what
        # makes guessing impractical.
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
