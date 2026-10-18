# `tunnelName` is a non-UUID label only: cloudflared resolves the real tunnel
# UUID from `credentialsFile`, and the reconciler reads it back from that file.
{
  config,
  lib,
  ...
}:
let
  d = config.dotfiles;
  cfg = d.webProxy;

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
  config = lib.mkIf cfg.enable {
    assertions =
      map (sub: {
        assertion = !(cfg.services ? ${sub}) || cfg.services.${sub}.access.enable;
        message = "dotfiles.webProxy.services.${sub} must set access.enable = true: exposing ${sub}.${cfg.domain} over the tunnel without Cloudflare Access would publish it to anyone who learns the hostname.";
      }) protected
      # A Service Auth policy only takes effect when Access is on; without this
      # the intent is silently dropped by the reconciler.
      ++ map (sub: {
        assertion = !cfg.services.${sub}.access.serviceAuth || cfg.services.${sub}.access.enable;
        message = "dotfiles.webProxy.services.${sub} sets access.serviceAuth without access.enable: the Service Auth policy would never be applied.";
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
