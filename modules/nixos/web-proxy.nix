# Tunnel ingress and the Access requirement assertion. DNS and Access objects
# are managed by the minimal OpenTofu config in `tofu/`; `tunnelName` is only a
# label, and the tunnel UUID is read from `credentialsFile`.
{
  config,
  lib,
  ...
}:
let
  cfg = config.webProxy;

  # A typo that clears `access.enable` would publish sshd, the LLM, or the
  # memory MCP to the internet. OpenTofu owns those apps and their policies;
  # this assertion stops the mistake before the tunnel ingress is applied.
  protected = [
    "ssh"
    "llm"
    "memory"
    "chat"
    "s3"
  ];
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
          description = "Stable human label for the tunnel. NOT the UUID: cloudflared resolves the real UUID from credentialsFile at runtime, and OpenTofu reads it back out of that file. Empty leaves the tunnel daemon off.";
        };
        credentialsFile = lib.mkOption {
          type = lib.types.path;
          default = "/var/lib/cloudflared/credentials.json";
          description = "Path to the tunnel credentials JSON on the host. Kept out of the Nix store; provisioned out-of-band, except on smortress which points this at its sops-decrypted copy.";
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
                  description = "Origin scheme cloudflared proxies to. Non-HTTP schemes (tcp/ssh) are reached from clients via `cloudflared access <tcp|ssh>`, not a browser. An HTTP service reached only by unattended clients may also use tcp, so the client forward can inject the Access token (e.g. memory).";
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
          description = "Services to expose, keyed by subdomain: each becomes a connector ingress rule <sub>.<domain> -> <protocol>://127.0.0.1:<port>. No DNS is written here: OpenTofu owns the single proxied wildcard CNAME that fronts the tunnel (tofu/main.tf), so every subdomain resolves through it.";
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
      # the intent is silently dropped by the tunnel ingress.
      ++ map (sub: {
        assertion = !cfg.services.${sub}.access.serviceAuth || cfg.services.${sub}.access.enable;
        message = "webProxy.services.${sub} sets access.serviceAuth without access.enable: the Service Auth policy would never be applied.";
      }) (builtins.attrNames cfg.services)
      # Access applications are hand-written in tofu/ for the protected
      # services. Enabling access on any other service would evaluate cleanly
      # while leaving the hostname uncovered by an application.
      ++ map (sub: {
        assertion = !cfg.services.${sub}.access.enable || builtins.elem sub protected;
        message = "webProxy.services.${sub}: Cloudflare Access is implemented only for ${lib.concatStringsSep ", " protected}; add a tofu/ application and extend webProxy.protected before exposing this service with Access.";
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
