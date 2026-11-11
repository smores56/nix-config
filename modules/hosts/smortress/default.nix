# smortress: the headless always-on server. It is the Cloudflare Tunnel origin
# and runs the local LLM, Immich/Calibre, and the backup disk.
let
  ports = import ../../ports.nix;
  # ssh/llm/memory/agent want an email allow-list plus a Service Auth policy: unattended
  # clients authenticate with a token, and a blessed device's proxy skips the browser PIN
  # page.
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
    ../../profiles/maki.nix
    ../../profiles/server.nix
  ];
  nixosModules = [
    ./boot.nix
    ./secrets.nix
    ../../nixos/host-hardening.nix
    ../../nixos/cluster-data-apps.nix
    ../../nixos/todo-daemon.nix
    # Host-local: the k3s guest and its tap/firewall plumbing are smortress-only.
    ../../nixos/cluster-vm.nix
    # The private-data guest; inert until `kanbeiVm.enable` (docs/kanbei-vm.md cutover).
    ../../nixos/kanbei-vm.nix
    # The Firecracker ingest plane and its host writer/proxy/resolver; needs Kanbei's key.
    ../../nixos/ingest-vm.nix
    # #509 retirement assertions; inert until the cutover switch below is flipped.
    ../../nixos/kanbei-cutover.nix
  ];
  homeModules = [
    ../../features/todo.nix
  ];

  homeOptions = {
    calibre = {
      passwordFile = "/run/secrets/calibre-password";
      # On the media dataset so it is backed up and the ingest queue can write it.
      library = "/var/lib/data/books";
    };
  };

  nixosOptions = {
    hostHardening.enable = true;
    # Flip only after the cluster serves every data app; stops the native services.
    clusterDataApps.enable = false;
    # Deliberately off until the one-time GPU cutover (docs/kanbei-vm.md); Immich triage still
    # owns the 3090 and enabling this stops nvidia/llm/photo-triage on the host.
    kanbeiVm.enable = false;
    # The ingest plane starts five Firecracker guests and needs the Kanbei key; off until the
    # same cutover (docs/kanbei-ingest.md).
    ingestVm.enable = false;
    # #509 retirement: off keeps the live agent VM/Open WebUI/files-mcp until the cutover.
    kanbeiSplit.cutover.enable = false;
    vaultSync.device = "smortress";
    # The assistant gateway binds loopback in the guest; the host proxies it to the tunnel.
    agentVm.ingressPorts = [
      ports.agent
      ports.letta
    ];
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
    ];
    exposeSsh.enable = true;
    # Work checkouts inside these roots are refused by the server's employer check.
    filesearch = {
      roots = [
        "/home/smores/repos"
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
        # Human-facing assistant: Access plus Open WebUI's own login; the service token
        # lets a blessed device's proxy reach it without the PIN page. `agent` is the
        # browser frontend for the Letta agent; nanobot keeps its own hostname beside it.
        agent = {
          port = ports.openWebui;
          access = serviceAuth;
        };
        nanobot = {
          port = ports.agent;
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
  };
}
