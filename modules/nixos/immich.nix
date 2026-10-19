# Immich is the organising brain for the photo archive: a managed library
# (the database is the source of truth) filed by capture date, backed by a
# local Postgres + Redis. Only an always-on host should enable it. CPU-only ML
# is the nixpkgs default and is deliberate: smortress's GPU is committed to
# llama.cpp, so indexing must not contend for VRAM.
{ config, lib, ... }:
let
  cfg = config.immich;
  ports = import ../ports.nix;
in
{
  options.immich = lib.mkOption {
    type = lib.types.submodule {
      options = {
        enable = lib.mkEnableOption "self-hosted Immich photo library (NixOS-only)";
        mediaLocation = lib.mkOption {
          type = lib.types.path;
          default = "/var/lib/immich";
          description = "Directory Immich stores its managed library in. The default is created by the Immich module.";
        };
        lanSources = lib.mkOption {
          type = lib.types.listOf (lib.types.strMatching "[0-9]{1,3}(\\.[0-9]{1,3}){3}/[0-9]{1,2}");
          default = [ ];
          example = [ "10.0.0.0/24" ];
          description = "IPv4 source CIDRs allowed to reach the Immich port directly (the mobile app's local-network URL). Empty keeps Immich tunnel-only. Source-scoped rather than interface-scoped so a global-IPv6 uplink cannot expose it to the WAN. Each entry is interpolated into a root iptables command, so the type validates it as a CIDR.";
        };
      };
    };
    default = { };
    description = "Self-hosted Immich photo/video library and its Postgres/Redis backing services.";
  };

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
