# smortress: the headless always-on server. It is the Cloudflare Tunnel origin
# and runs the local LLM, Immich/Calibre, and the backup disk.
let
  ports = import ../../ports.nix;
  # ssh/llm/memory want an email allow-list plus a Service Auth policy for unattended clients.
  serviceAuth = {
    enable = true;
    serviceAuth = true;
  };
in
{
  system = "x86_64-linux";
  username = "smores";
  nixos = true;
  home = true;

  profiles = [
    ../../profiles/cli.nix
    ../../profiles/user-base.nix
    ../../profiles/ai-tools.nix
    ../../profiles/server.nix
  ];
  nixosModules = [
    ./boot.nix
    ./secrets.nix
  ];

  homeOptions = {
    # Ciphertext relay only; version history lives outside `/var/lib/data` so restic's
    # single source path skips it.
    syncthing = {
      device = "smortress";
      vaultPath = "/var/lib/data/vault";
      versioningPath = "/var/lib/syncthing-versions/vault";
    };
    calibre = {
      passwordFile = "/run/secrets/calibre-password";
      # On the media dataset so it is backed up and the ingest queue can write it.
      library = "/var/lib/data/books";
    };
  };

  nixosOptions = {
    # restic runs as root and reads smores-owned sources.
    systemd.tmpfiles.rules = [
      # 0751: PrivateUsers services (Immich) map smores:users to nobody, so they need traverse only.
      "d /var/lib/data 0751 smores users -"
      # Nothing else creates it (the parent is 0751).
      "d /var/lib/data/navidrome 0700 navidrome navidrome -"
      "d /var/lib/data/music 0775 smores users -"
      "d /var/lib/data/books 0775 smores users -"
      "d /var/lib/data/wallpapers 0775 smores users -"
      "d /var/lib/agent 0775 smores users -"
      "d /var/lib/agent/books-ingest 0775 smores users -"
      # Outside the durable tree so restic skips it.
      "d /var/lib/syncthing-versions 0700 smores users -"
    ];
    exposeSsh.enable = true;
    # Work checkouts inside these roots are refused by the server's employer check.
    filesearch = {
      roots = [
        "/home/smores/code"
        "/home/smores/Documents"
        "/home/smores/Downloads"
        "/home/smores/dev"
      ];
    };
    webProxy = {
      tunnelName = "smortress";
      services = {
        calibre.port = ports.calibre;
        immich.port = ports.immich;
        dav.port = ports.radicale;
        navidrome.port = ports.navidrome;
        # Reachable only through the tunnel; must never lose Access (web-proxy.nix asserts it).
        ssh = {
          port = ports.ssh;
          protocol = "ssh";
          access = serviceAuth;
        };
        llm = {
          port = ports.llm;
          protocol = "tcp";
          access = serviceAuth;
        };
        # No auth of its own, so Access is the only route; tcp because `cloudflared access
        # tcp` cannot dial an http ingress.
        memory = {
          port = ports.memoryMcp;
          protocol = "tcp";
          access = serviceAuth;
        };
        # Human-facing PWA: Access plus its own login; no service token.
        chat = {
          port = ports.openWebui;
          access.enable = true;
        };
      };
    };
    immich = {
      # One root so restic backs up every media tree as a single path.
      mediaLocation = "/var/lib/data/photos";
      # LAN upload via Immich's local-network URL; WAN stays tunnel-only.
      lanSources = [ "10.0.0.0/24" ];
    };
    # LUKS HDD opened at boot via /etc/crypttab; see docs/manual-steps.md ("Encrypted backup disk").
    backup.device = "/dev/mapper/backup";
    backup.luks = {
      enable = true;
      device = "/dev/disk/by-id/ata-ST5000LM000-2AN170_WCJ42WX0";
    };
    alerting = {
      accountId = "385f7d47e2e8438fbda5d6f76d760434";
    };
    # The probe repo must refresh every run, catching a token that lost `repo` scope.
    githubBackup.probeRepo = "sdlc";
  };
}
