# `tunnelName` is a non-UUID label only: cloudflared resolves the real tunnel
# UUID from `credentialsFile`, and the reconciler reads it back from that file.
{
  config,
  lib,
  ...
}:
let
  cfg = config.webProxy;

  # Hostnames that must never be reachable without Access in front of them: a
  # typo that clears `access.enable` would otherwise publish sshd/the LLM/
  # SearXNG/ntfy/chat to the internet. The reconciler refuses to *remove* their
  # Access too (defence in depth, mirroring PROTECTED_SUBDOMAINS in
  # modules/features/cloudflare/cloudflare_sync.py, which also guards their
  # ports), but failing evaluation here stops the mistake before anything is
  # applied. ntfy is listed here as well as in notify.nix so the guard still
  # holds if notify (whose assertion is gated on its own enable) is ever turned
  # off. The list is shared with the consistency check via
  # modules/protected-services.nix.
  protected = (import ../protected-services.nix).subdomains;
in
{
  options.webProxy = lib.mkOption {
    type = lib.types.submodule {
      options = {
        enable = lib.mkEnableOption "public exposure of smortress services via Cloudflare Tunnel (NixOS-only)";
        domain = lib.mkOption {
          type = lib.types.str;
          default = "sammohr.dev";
          description = "Apex domain whose subdomains are exposed (e.g. calibre.<domain>).";
        };
        tunnelName = lib.mkOption {
          type = lib.types.str;
          default = "smortress";
          description = "Stable human label for the tunnel. NOT the UUID: cloudflared resolves the real UUID from credentialsFile at runtime, and the reconciler reads it back out of that file. Empty leaves the tunnel daemon off.";
        };
        credentialsFile = lib.mkOption {
          type = lib.types.path;
          default = "/var/lib/cloudflared/credentials.json";
          description = "Path to the tunnel credentials JSON on the host. Kept out of the Nix store; provisioned out-of-band, except on smortress which points this at its sops-decrypted copy.";
        };
        apiTokenFile = lib.mkOption {
          type = lib.types.path;
          default = "/var/lib/cloudflare/api-token";
          description = "Path to the scoped Cloudflare API token (Zone:DNS:Write + Access: Apps and Policies:Write) on the host, mode 0600. Read by the reconciler at runtime; never enters the Nix store. smortress points this at its sops-decrypted copy.";
        };
        services = lib.mkOption {
          type = lib.types.attrsOf (
            lib.types.submodule {
              options = {
                port = lib.mkOption {
                  type = lib.types.port;
                  description = "Loopback port the service listens on.";
                };
                protocol = lib.mkOption {
                  type = lib.types.enum [
                    "http"
                    "tcp"
                    "ssh"
                  ];
                  default = "http";
                  description = "Origin scheme cloudflared proxies to. Non-HTTP schemes (tcp/ssh) are reached from clients via `cloudflared access <tcp|ssh>`, not a browser.";
                };
                access = {
                  enable = lib.mkEnableOption "Cloudflare Access in front of this endpoint (account IdP, shared allow-list)";
                  serviceAuth = lib.mkEnableOption ''
                    an additional Cloudflare Access Service Auth policy accepting any valid account service token. Set it for endpoints unattended clients reach (cloudflared access ssh/tcp) so they authenticate with a token minted in the dashboard instead of an IdP browser login; the email allow-list policy stays as a human fallback
                  '';
                };
              };
            }
          );
          default = { };
          description = "Services to expose, keyed by subdomain: each becomes <sub>.<domain> -> <protocol>://127.0.0.1:<port>, with a proxied DNS CNAME to the tunnel reconciled on every activation.";
        };
      };
    };
    default = { };
    description = "Public exposure of smortress HTTP services over Cloudflare Tunnel. TLS terminates at the Cloudflare edge; cloudflared proxies each subdomain straight to its loopback service.";
  };

  config = lib.mkIf cfg.enable {
    assertions =
      map (sub: {
        assertion = !(cfg.services ? ${sub}) || cfg.services.${sub}.access.enable;
        message = "webProxy.services.${sub} must set access.enable = true: exposing ${sub}.${cfg.domain} over the tunnel without Cloudflare Access would publish it to anyone who learns the hostname.";
      }) protected
      # A Service Auth policy only takes effect when Access is on; without this
      # the intent is silently dropped by the reconciler.
      ++ map (sub: {
        assertion = !cfg.services.${sub}.access.serviceAuth || cfg.services.${sub}.access.enable;
        message = "webProxy.services.${sub} sets access.serviceAuth without access.enable: the Service Auth policy would never be applied.";
      }) (builtins.attrNames cfg.services);

    services.cloudflared = lib.mkIf (cfg.tunnelName != "") {
      enable = true;
      tunnels.${cfg.tunnelName} = {
        inherit (cfg) credentialsFile;
        default = "http_status:404";
        ingress = lib.mapAttrs' (
          sub: s: lib.nameValuePair "${sub}.${cfg.domain}" "${s.protocol}://127.0.0.1:${toString s.port}"
        ) cfg.services;
      };
    };
  };
}
