# Radicale is the system of record for calendar (VEVENT) and contacts
# (VCARD), including VTODO for Tasks.org. It is exposed publicly as
# `dav.sammohr.dev` through the tunnel with its own bcrypt auth: CalDAV clients
# (DAVx5, khal, vdirsyncer, macOS Calendar) cannot complete a Cloudflare Access
# browser login, so Access is deliberately not in front of it.
{ config, ... }:
let
  ports = import ../ports.nix;
in
{
  services.radicale = {
    enable = true;
    user = "radicale";
    group = "radicale";
    settings = {
      server.hosts = [ "127.0.0.1:${toString ports.radicale}" ];
      auth = {
        type = "htpasswd";
        htpasswd_filename = config.sops.secrets.radicale-htpasswd.path;
      };
      storage.filesystem_folder = "/var/lib/data/radicale";
      rights.type = "owner_only";
    };
  };

  systemd.tmpfiles.rules = [
    "d /var/lib/data/radicale 0750 radicale radicale -"
  ];
}
