# smortress: the headless always-on server. It is the Cloudflare Tunnel origin
# and runs the local LLM, Immich/Calibre, and the backup disk.
let
  ports = import ../../ports.nix;
  # The ssh/llm endpoints all want an email allow-list (human fallback)
  # plus a Service Auth policy for unattended clients.
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

  homeOptions = {
    calibre = {
      enable = true;
      # OPDS password comes from sops (owner smores, 0400) instead of the
      # plaintext ~/.config/calibre-server/password, which is retired once
      # this lands.
      passwordFile = "/run/secrets/calibre-password";
    };
  };

  nixosOptions = {
    exposeSsh.enable = true;
    nvidia.enable = true;
    llm.enable = true;
    noSleep.enable = true;
    webProxy = {
      enable = true;
      tunnelName = "smortress";
      services = {
        calibre.port = ports.calibre;
        immich.port = ports.immich;
        # sshd (key-only, loopback; see modules/nixos/ssh.nix) is reachable
        # only through the tunnel. The Service Auth policy lets `cloudflared
        # access ssh` run unattended; the email policy keeps a browser
        # fallback. Must never lose Access (assertion in web-proxy.nix).
        ssh = {
          port = ports.ssh;
          protocol = "ssh";
          access = serviceAuth;
        };
        # maki reaches llama.cpp (api_key = "none") through the tunnel; the
        # service token keeps the agent's calls unattended.
        llm = {
          # Port comes from modules/ports.nix (the listener's single source).
          port = ports.llm;
          protocol = "tcp";
          access = serviceAuth;
        };
      };
    };
    immich = {
      enable = true;
      # Relocated off /var/lib/immich so every media dataset lives under one
      # root (backup source and read-only server mounts both use it).
      mediaLocation = "/var/lib/media/Photos";
      # The phone uploads over the LAN at home via Immich's local-network URL;
      # 10.0.0.0/24 is the LAN subnet. WAN access stays tunnel-only.
      lanSources = [ "10.0.0.0/24" ];
    };
    # These generic datasets replaced the old Immich-specific restic
    # pipeline, which has been removed.
    backup.enable = true;
    backup.datasets.Videos = {
      schedule = "*-*-* 01:00:00";
      fullCheckSchedule = "Sun *-*-* 07:00:00";
      # Incrementals run in minutes; 2h is a wall-clock backstop so a
      # deadlock trips fast (stallTimeout catches a stalled transfer sooner).
      timeout = "2h";
      onChange.enable = true;
    };
    backup.datasets.Photos = {
      schedule = "*-*-* 03:00:00";
      fullCheckSchedule = "Sun *-*-* 06:00:00";
      timeout = "2h";
      # A generated pre-unit dumps Postgres as the postgres user (NNP on, no
      # runuser); this snippet copies that dump into the mirror and fails if the
      # dump is missing or stale. `excludes` REPLACES the option default, so
      # the cache/credential patterns are repeated here alongside the two
      # regenerable Immich derived trees (thumbs, encoded-video) that Immich
      # rebuilds from the originals and that need not occupy a mirror.
      excludes = [
        "/.cache/**"
        "**/.cache/**"
        "/rclone.conf"
        "/thumbs/**"
        "/encoded-video/**"
      ];
      postgres = true;
      onChange = {
        enable = true;
        # Regenerable Immich trees excluded from the mirror must not trigger a
        # run either; the storage-template originals under library/ still do.
        ignore = [
          "thumbs"
          "encoded-video"
        ];
      };
      preBackup = ''
        dump=/var/lib/postgresql/backups/photos.dump
        test -s "$dump" || { echo "missing PostgreSQL dump: $dump"; exit 1; }
        # postgres owns the dump directory; refuse a symlink so a compromised
        # database cannot make root copy an arbitrary file into the mirror.
        [ ! -L "$dump" ] || { echo "refusing symlinked PostgreSQL dump: $dump"; exit 1; }
        now=$(date +%s)
        mtime=$(stat -c %Y "$dump")
        [ $((now - mtime)) -le 3600 ] || { echo "stale PostgreSQL dump: $dump"; exit 1; }
        mkdir -p "$BACKUP_CURRENT/db"
        # One stable name: copy never deletes, so dated names would accumulate
        # a full dump per run locally and offsite forever. Overwrites keep the
        # previous revision in the local versions/ tree; Proton holds the latest.
        # Stage then rename so a concurrent read never sees a partial dump.
        cp "$dump" "$BACKUP_CURRENT/db/immich.dump.tmp"
        mv "$BACKUP_CURRENT/db/immich.dump.tmp" "$BACKUP_CURRENT/db/immich.dump"
      '';
    };
    backup.datasets.Music = {
      schedule = "*-*-* 05:00:00";
      fullCheckSchedule = "Sun *-*-* 08:00:00";
      timeout = "2h";
      onChange.enable = true;
    };
    # OpenTofu state is the only copy of the edge object IDs; losing it means
    # `tofu import`, not data loss. Skip the provider cache and the transient
    # lock file.
    backup.datasets.CloudflareTofu = {
      source = "/var/lib/cloudflare-tofu";
      schedule = "*-*-* 00:15:00";
      timeout = "30m";
      onChange.enable = true;
      excludes = [
        "/.cache/**"
        "**/.cache/**"
        "/rclone.conf"
        "/.terraform/**"
        "/terraform.tfstate.lock.info"
      ];
    };
    alerting = {
      enable = true;
      accountId = "385f7d47e2e8438fbda5d6f76d760434";
    };
    # Mirror this host's GitHub repos onto the backup disk and Proton. The
    # probe requires this known-private repo to be refreshed every run, catching
    # a token that lost `repo` scope (which would otherwise silently stop
    # updating every private mirror).
    githubBackup.enable = true;
    githubBackup.probeRepo = "sdlc";
  };
}
