# Navidrome reads the music library read-only (the nixpkgs module bind-mounts
# MusicFolder RO) and keeps its state under /var/lib/navidrome. The admin
# password is seeded from a root-owned env file so the account exists before the
# Cloudflare Tunnel makes the endpoint public; Navidrome hardcodes the username
# to `admin`, so only ND_DEVAUTOCREATEADMINPASSWORD is honoured, and it is read
# once, during initial setup.
{
  config,
  lib,
  ...
}:
let
  cfg = config.dotfiles.navidrome;
in
{
  config = lib.mkIf cfg.enable {
    services.navidrome = {
      enable = true;
      inherit (cfg) environmentFile;
      settings = {
        MusicFolder = cfg.musicFolder;
        Port = cfg.port;
      };
    };
  };
}
