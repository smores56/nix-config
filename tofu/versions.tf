terraform {
  required_version = ">= 1.8"

  required_providers {
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 5.0"
    }
  }
}

# The token comes from CLOUDFLARE_API_TOKEN (set by the flake app from sops).
provider "cloudflare" {}

data "cloudflare_zone" "this" {
  filter = {
    name = var.domain
  }
}
