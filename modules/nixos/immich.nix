# Managed library (the database is the source of truth) filed by capture date, on
# local Postgres + Redis. CPU-only ML is deliberate: the GPU is committed to llama.cpp.
{ config, lib, ... }:
let
  cfg = config.immich;
  ports = import ../ports.nix;
in
{
  options.immich = lib.mkOption {
    type = lib.types.submodule {
      options = {
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

  config = {
    services.immich = {
      enable = true;
      inherit (cfg) mediaLocation;
      port = ports.immich;

      # Bind all interfaces; reachability is governed by the firewall rule
      # below (and the tunnel dials 127.0.0.1:${toString ports.immich}).
      host = "0.0.0.0";
      openFirewall = false;

      # Declarative config (non-null settings disable web-UI settings): one folder per
      # capture day, original filename kept.
      settings = {
        storageTemplate = {
          enabled = true;
          template = "{{y}}/{{y}}-{{MM}}-{{dd}}/{{filename}}";
        };
      };
    };

    # LAN upload (fast, bypasses the Cloudflare upload cap). Matches by source CIDR, not
    # interface, so a global-IPv6 uplink cannot reach it. Empty keeps Immich tunnel-only.
    networking.firewall.extraCommands = lib.concatMapStrings (src: ''
      iptables -A nixos-fw -p tcp --dport ${toString config.services.immich.port} -s ${src} -j nixos-fw-accept
    '') cfg.lanSources;
    networking.firewall.extraStopCommands = lib.concatMapStrings (src: ''
      iptables -D nixos-fw -p tcp --dport ${toString config.services.immich.port} -s ${src} -j nixos-fw-accept || true
    '') cfg.lanSources;
  };
}
