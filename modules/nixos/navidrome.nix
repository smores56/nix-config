# Music streaming. Navidrome serves the library read-only over the Subsonic
# API; it is public with its own auth (Symfonium/Feishin/Substreamer), because
# mobile Subsonic clients cannot complete a Cloudflare Access login.
{ ... }:
let
  ports = import ../ports.nix;
in
{
  services.navidrome = {
    enable = true;
    settings = {
      Address = "127.0.0.1";
      Port = ports.navidrome;
      MusicFolder = "/var/lib/data/music";
      # The database is durable and backed up; the cache is regenerable and
      # lives outside the backup tree.
      DataFolder = "/var/lib/data/navidrome";
      CacheFolder = "/var/lib/agent/navidrome-cache";
      EnableInsightsCollector = false;
    };
  };
}
