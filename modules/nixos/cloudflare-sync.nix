# Reconciler for the Cloudflare side of `dotfiles.webProxy`: one oneshot that
# reads a secrets-free desired-state spec and makes DNS records (and, where
# enabled, Access applications) match it. It is additive for DNS — a matching
# CNAME is adopted, a missing one created, a changed one updated, and nothing is
# ever deleted — so unrelated records are safe. Access applications *are*
# deleted when `access.enable` is turned off, since that is what makes an
# endpoint public again.
#
# Provisioning (out of band, never committed):
#
#   install -d -m 0700 /var/lib/cloudflare
#   (umask 077; printf '%s' '<token>' > /var/lib/cloudflare/api-token)
#
# The token needs Zone:DNS:Write and Access: Apps and Policies:Write on the
# apex zone; the reconciler names the missing scope if an API call is denied.
# It is read at runtime, so it never enters the Nix store. cloudflared's own
# credentials (`dotfiles.webProxy.credentialsFile`) are read for the TunnelID
# that builds `<uuid>.cfargotunnel.com` — no UUID is authored anywhere.
#
# Add a service by adding an entry to `dotfiles.webProxy.services` (keyed by
# subdomain) and rebuilding; add `access.enable = true` to put Cloudflare
# Access in front of it. Dry-run any time with `sudo cloudflare-sync --check`
# (exits non-zero when the live state has drifted from the declared one).
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.dotfiles.webProxy;

  cloudflare-sync = pkgs.writeShellScriptBin "cloudflare-sync" ''
    exec ${pkgs.python3}/bin/python3 ${./../features/cloudflare/cloudflare_sync.py} "$@"
  '';

  # The spec is deliberately secrets-free: only the token path (not the token)
  # is passed, and the reconciler reads the file at runtime.
  spec = {
    zone = cfg.domain;
    inherit (cfg) credentialsFile;
    accessEmail = config.dotfiles.email;
    services = lib.mapAttrs (_: service: {
      inherit (service) port;
      access = service.access.enable;
    }) cfg.services;
  };
  specFile = pkgs.writeText "cloudflare-sync-spec.json" (builtins.toJSON spec);
in
{
  config = lib.mkIf (cfg.enable && cfg.tunnelName != "") {
    systemd.services.cloudflare-sync = {
      description = "Reconcile Cloudflare Tunnel DNS records and Access applications";
      wantedBy = [ "multi-user.target" ];
      wants = [ "network-online.target" ];
      after = [ "network-online.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "${cloudflare-sync}/bin/cloudflare-sync --spec ${specFile} --token-file ${cfg.apiTokenFile}";
      };
      # Route failures to the shared ntfy primitive, but only on hosts that have
      # enabled notify: the template does not exist otherwise and a dangling
      # `onFailure` reference fails activation.
      onFailure = lib.optional config.dotfiles.notify.enable config.dotfiles.notify.unit;
    };

    environment.systemPackages = [ cloudflare-sync ];
    # Stable path so `sudo cloudflare-sync --check` needs no /nix/store argument.
    environment.etc."cloudflare-sync/spec.json".source = specFile;
  };
}
