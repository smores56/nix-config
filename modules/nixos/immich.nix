# Immich is the organising brain for the photo archive: a managed library
# (the database is the source of truth) filed by capture date, backed by a
# local Postgres + Redis. Only an always-on host should enable it. CPU-only ML
# is the nixpkgs default and is deliberate: smortress's GPU is committed to
# llama.cpp, so indexing must not contend for VRAM.
{ config, lib, ... }:
let
  cfg = config.dotfiles.immich;
in
{
  config = lib.mkIf cfg.enable {
    services.immich = {
      enable = true;
      inherit (cfg) mediaLocation;

      # Listen on all interfaces but open no firewall port: Immich is reached
      # over the tailnet, and the tailscale0 interface is already trusted.
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
  };
}
