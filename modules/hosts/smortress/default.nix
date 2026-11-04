# smortress: the headless always-on server. It is the Cloudflare Tunnel origin
# and runs the local LLM, Immich/Calibre, and the backup disk.
let
  ports = import ../../ports.nix;
  # The ssh/llm/memory endpoints all want an email allow-list (human fallback)
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

  # Shared profiles (they drive machine.graphical/wayland/workHost and the
  # server-profile assertion), not host-local modules.
  profiles = [
    ../../profiles/cli.nix
    ../../profiles/user-base.nix
    ../../profiles/ai-tools.nix
    ../../profiles/server.nix
  ];
  # Host-local modules: the Secure Boot + TPM boot chain exists only on this
  # machine.
  nixosModules = [
    ./boot.nix
    ./secrets.nix
  ];

  homeOptions = {
    # The vault ciphertext is shared by Syncthing; the server only relays it and
    # never unlocks. Version history lives outside `/var/lib/data` so restic's
    # one source path does not carry it.
    syncthing = {
      device = "smortress";
      vaultPath = "/var/lib/data/vault";
      versioningPath = "/var/lib/syncthing-versions/vault";
    };
    calibre = {
      # OPDS password comes from sops (owner smores, 0400).
      passwordFile = "/run/secrets/calibre-password";
      # The library lives on the media dataset so it is backed up and the
      # agent's ingest queue can write it without a home exception.
      library = "/var/lib/data/books";
    };
  };

  nixosOptions = {
    # Media is agent-writable except Immich's managed Photos library. restic
    # runs as root and can read smores-owned sources.
    systemd.tmpfiles.rules = [
      # 0751: services with PrivateUsers (Immich) map smores:users to
      # nobody:nogroup, so they need others-traverse; subdirs keep their own
      # 0700/0770 modes, so only traversal is granted, never listing.
      "d /var/lib/data 0751 smores users -"
      # Navidrome's database: its own user owns it, and nothing else creates it
      # (the parent is 0751, so navidrome cannot).
      "d /var/lib/data/navidrome 0700 navidrome navidrome -"
      "d /var/lib/data/music 0775 smores users -"
      "d /var/lib/data/books 0775 smores users -"
      # The wallpaper feature's rsync source; smores populates it, the clients
      # pull from it.
      "d /var/lib/data/wallpapers 0775 smores users -"
      "d /var/lib/agent 0775 smores users -"
      "d /var/lib/agent/books-ingest 0775 smores users -"
      # Syncthing's staggered versions for the vault: outside the durable tree,
      # so restic's snapshots never carry them.
      "d /var/lib/syncthing-versions 0700 smores users -"
    ];
    # The vault is shared by a home-manager user unit; lingering starts it at
    # boot without a login.
    users.users.smores.linger = true;
    # Cryptomator's flattened layout is roughly two directories per cleartext
    # folder, so the watcher needs more watches than the default allows.
    boot.kernel.sysctl."fs.inotify.max_user_watches" = 204800;
    exposeSsh.enable = true;
    # The committed embedder: qwen3-embedding-8b (4096-d) through the gateway.
    # Flip to "local" to fall back to bge-m3 at 1024-d; either way a wipe and
    # re-ingest follows, because the vector width changes.
    memory.embedder = "neuralwatt";
    # Read-only search for the phone; work checkouts inside these roots are
    # refused by the server's employer check.
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
        # The memory MCP has no authentication of its own; Access with the
        # service token is the only route. tcp keeps Maki's loopback forward
        # working (`cloudflared access tcp` cannot dial an http ingress).
        memory = {
          port = ports.memoryMcp;
          protocol = "tcp";
          access = serviceAuth;
        };
        # Open WebUI is the human-facing PWA; Access plus its own email/password
        # login are the two layers. No service token: only the phone's browser
        # reaches it.
        chat = {
          port = ports.openWebui;
          access.enable = true;
        };
      };
    };
    immich = {
      # Relocated off /var/lib/immich so every media tree lives under one
      # root that restic backs up as a single path.
      mediaLocation = "/var/lib/data/photos";
      # The phone uploads over the LAN at home via Immich's local-network URL;
      # 10.0.0.0/24 is the LAN subnet. WAN access stays tunnel-only.
      lanSources = [ "10.0.0.0/24" ];
    };
    # The HDD is LUKS-encrypted: /var/backup lives inside a mapping opened at
    # boot from /etc/crypttab by a keyfile on the encrypted root, and restic
    # writes the local repo to /var/backup/restic. The format and re-key
    # procedure is in docs/manual-steps.md ("Encrypted backup disk").
    backup.device = "/dev/mapper/backup";
    backup.luks = {
      enable = true;
      device = "/dev/disk/by-id/ata-ST5000LM000-2AN170_WCJ42WX0";
    };
    alerting = {
      accountId = "385f7d47e2e8438fbda5d6f76d760434";
    };
    # Mirror this host's GitHub repos into the durable tree, which restic
    # carries. The probe requires this known-private repo to be refreshed every
    # run, catching a token that lost `repo` scope (which would otherwise
    # silently stop updating every private mirror).
    githubBackup.probeRepo = "sdlc";
  };
}
