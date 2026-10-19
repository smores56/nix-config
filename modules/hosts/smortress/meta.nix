# smortress: the headless always-on server. It is the Cloudflare Tunnel origin
# and runs the local LLM, SearXNG, Immich/Navidrome/Calibre, and the backup disk.
# `dotfiles` is shared by the NixOS config and the home config, so a value
# lives in exactly one place; each module reads the knobs it knows.
let
  ports = import ../../ports.nix;
  # The ssh/llm/searx endpoints all want an email allow-list (human fallback)
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

  dotfiles = {
    displayManager = "none";
    nixos = true;
    exposeSsh = true;
    nvidia = true;
    llm = true;
    search = true;
    noSleep = true;
    webProxy = {
      enable = true;
      tunnelName = "smortress";
      services = {
        calibre.port = ports.calibre;
        immich.port = ports.immich;
        # Public, protected only by Navidrome's own auth: music streaming is
        # low-bandwidth, so the Cloudflare CDN terms that bite video don't apply.
        music.port = ports.navidrome;
        # Unauthenticated loopback listener, so it must sit behind Access
        # (enforced by an assertion in modules/nixos/notify.nix).
        ntfy = {
          port = ports.ntfy;
          access.enable = true;
        };
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
        # SearXNG (dotfiles.searchPort). maki reaches it through a
        # `cloudflared access tcp` forward (modules/features/cloudflared.nix),
        # so the ingress is tcp — an http ingress forwards the carrier's
        # WebSocket upgrade to SearXNG and fails with "websocket: bad
        # handshake". The service token keeps maki's calls unattended.
        searx = {
          # Port comes from modules/ports.nix (the listener's single source).
          port = ports.searx;
          protocol = "tcp";
          access = serviceAuth;
        };
        # Open WebUI. A browser app, so the default `http` ingress is correct
        # (an http ingress is what carries its WebSockets). Cloudflare Access is
        # the outer gate, Open WebUI's own login the inner one; `chat` is a
        # protected subdomain, so the assertion below forces access.enable.
        chat = {
          port = ports.chat;
          access.enable = true;
        };
      };
    };
    calibre.enable = true;
    # OPDS password comes from sops (owner smores, 0400) instead of the plaintext
    # ~/.config/calibre-server/password, which is retired once this lands.
    calibre.passwordFile = "/run/secrets/calibre-password";
    immich.enable = true;
    # Relocated off /var/lib/immich so every media dataset lives under one
    # root (backup source and read-only server mounts both use it).
    immich.mediaLocation = "/var/lib/media/Photos";
    # The phone uploads over the LAN at home via Immich's local-network URL;
    # 10.0.0.0/24 is the LAN subnet. WAN access stays tunnel-only.
    immich.lanSources = [ "10.0.0.0/24" ];
    navidrome.enable = true;
    # Open WebUI: single-user chat at chat.<domain>, loopback-only (the tunnel
    # ingress and Access are added with the rest of the chat feature).
    chat.enable = true;
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
        now=$(date +%s)
        mtime=$(stat -c %Y "$dump")
        [ $((now - mtime)) -le 3600 ] || { echo "stale PostgreSQL dump: $dump"; exit 1; }
        mkdir -p "$BACKUP_CURRENT/db"
        cp "$dump" "$BACKUP_CURRENT/db/immich-$BACKUP_DATE.dump"
      '';
    };
    backup.datasets.Music = {
      schedule = "*-*-* 05:00:00";
      fullCheckSchedule = "Sun *-*-* 08:00:00";
      timeout = "2h";
      onChange.enable = true;
    };
    notify.enable = true;
    alerting.enable = true;
    # Mirror this host's GitHub repos onto the backup disk (local-only; GitHub is
    # the offsite copy). The probe requires this known-private repo to be
    # refreshed every run, catching a token that lost `repo` scope (which would
    # otherwise silently stop updating every private mirror).
    githubBackup.enable = true;
    githubBackup.probeRepo = "sdlc-state";
  };
}
