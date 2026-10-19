# Immich is the organising brain for the photo archive: a managed library
# (the database is the source of truth) filed by capture date, backed by a
# local Postgres + Redis. Only an always-on host should enable it. CPU-only ML
# is the nixpkgs default and is deliberate: smortress's GPU is committed to
# llama.cpp, so indexing must not contend for VRAM.
{ config, lib, ... }:
let
  cfg = config.dotfiles.immich;
  ports = import ../ports.nix;
in
{
  config = lib.mkIf cfg.enable {
    services.immich = {
      enable = true;
      inherit (cfg) mediaLocation;
      port = ports.immich;

      # Bind all interfaces; reachability is governed by the firewall rule
      # below (and the tunnel dials 127.0.0.1:${toString ports.immich}).
      host = "0.0.0.0";
      openFirewall = false;

      # Declarative config (settings non-null disables web-UI settings): one
      # folder per capture day, original filename preserved; Immich
      # disambiguates same-day filename collisions itself.
      settings = {
        storageTemplate = {
          enabled = true;
          template = "{{y}}/{{y}}-{{MM}}-{{dd}}/{{filename}}";
        };
      };
    };

    # The mobile app uploads over the LAN at home (fast, and bypasses the
    # Cloudflare upload cap) via its local-network URL. Open the port only to
    # the listed source CIDRs (IPv4) — matching by source, not interface, so a
    # global-IPv6 uplink cannot reach it. Empty keeps Immich tunnel-only.
    networking.firewall.extraCommands = lib.concatMapStrings (src: ''
      iptables -A nixos-fw -p tcp --dport ${toString config.services.immich.port} -s ${src} -j nixos-fw-accept
    '') cfg.lanSources;
    networking.firewall.extraStopCommands = lib.concatMapStrings (src: ''
      iptables -D nixos-fw -p tcp --dport ${toString config.services.immich.port} -s ${src} -j nixos-fw-accept || true
    '') cfg.lanSources;
  };
}
