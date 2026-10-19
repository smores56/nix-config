# Reconciler for the Cloudflare side of `dotfiles.webProxy`: one oneshot that
# reads a secrets-free desired-state spec and makes DNS records (and, where
# enabled, Access applications) match it. It is additive for DNS — a matching
# CNAME is adopted, a missing one created, a changed one updated, and nothing is
# ever deleted — so unrelated records are safe. Access applications *are*
# deleted when `access.enable` is turned off, since that is what makes an
# endpoint public again — except for a protected allowlist
# (ssh/llm/searx/ntfy/chat), whose apps the reconciler refuses to delete so a
# Nix typo cannot publish them.
#
# A service with `access.serviceAuth = true` additionally gets a Service Auth
# policy accepting any valid account service token, so unattended clients
# (cloudflared access ssh/tcp) authenticate without an IdP browser login.
#
# The API token and cloudflared's credentials are secrets, so they live in sops
# (`secrets/smortress.yaml`); smortress repoints
# `dotfiles.webProxy.apiTokenFile`/`credentialsFile` at the decrypted files
# (modules/nixos/secrets.nix). The token needs Zone:DNS:Write and Access: Apps
# and Policies:Write on the apex zone; the reconciler names the missing scope
# if an API call is denied. It is read at runtime, so it never enters the Nix
# store. cloudflared's credentials are read for the TunnelID that builds
# `<uuid>.cfargotunnel.com` — no UUID is authored anywhere.
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

  # Defaults make `sudo cloudflare-sync --check` work with no arguments: the
  # spec is installed at a stable path and the token path comes from the option
  # (a sops file on smortress). The unit below relies on them too.
  cloudflare-sync = pkgs.writeShellScriptBin "cloudflare-sync" ''
    exec ${pkgs.python3}/bin/python3 ${./../features/cloudflare/cloudflare_sync.py} \
      --spec /etc/cloudflare-sync/spec.json --token-file ${cfg.apiTokenFile} "$@"
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
      serviceAuth = service.access.serviceAuth;
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
        ExecStart = "${cloudflare-sync}/bin/cloudflare-sync";
        # The reconciler only makes outbound HTTPS calls and reads two files, so
        # it needs no filesystem writes and no privilege beyond its own user.
        NoNewPrivileges = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        PrivateDevices = true;
        ProtectKernelTunables = true;
        ProtectControlGroups = true;
        LockPersonality = true;
        SystemCallArchitectures = "native";
        RestrictAddressFamilies = [
          "AF_INET"
          "AF_INET6"
          "AF_UNIX"
        ];
      };
      # The unit text is otherwise stable — the wrapper bakes in only the script
      # and token paths — so without this a `dotfiles.webProxy.services` change
      # would leave the unit byte-identical and systemd would not restart this
      # oneshot: the reconciler would not re-run until reboot.
      restartTriggers = [ specFile ];
      # Route failures through the Cloudflare email template, only when enabled.
      onFailure = lib.optional config.dotfiles.alerting.enable "cloudflare-email@%n.service";
    };

    environment.systemPackages = [ cloudflare-sync ];
    # Stable path so `sudo cloudflare-sync --check` needs no /nix/store argument.
    environment.etc."cloudflare-sync/spec.json".source = specFile;
  };
}
