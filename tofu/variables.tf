variable "account_id" {
  type        = string
  description = "Cloudflare account ID."
}

variable "domain" {
  type        = string
  description = "Apex zone whose subdomains are exposed."
}

variable "tunnel_id" {
  type        = string
  description = "Cloudflare Tunnel UUID, read from the tunnel credentials JSON."
}

variable "email" {
  type        = string
  description = "Email allow-list principal and alert recipient."
}
