# Reach smortress's loopback-only services (sshd, llama.cpp) from a
# client over the Cloudflare Tunnel. `cloudflared access` authenticates with a
# per-host Cloudflare Access service token delivered by sops; there is no
# fallback. The server reaches its own services on loopback, so it gets no
# forwards.
{
  config,
  lib,
  pkgs,
  aiProviders,
  ...
}:
let
  aiProfile = config.user.aiProfile;
  domain = "sammohr.dev";
  isServer = builtins.elem "server" config.machine.profiles;
  ports = import ../ports.nix;
  piv = import ../lib/piv.nix { inherit config lib pkgs; };
  inherit (aiProviders) smortress;

  # The Access service token is deployed per host through sops: home-manager
  # sops on Darwin, sops-nix (/run/secrets) on NixOS. Two lines: Client ID and
  # Client Secret. There is no fallback; a host without the secret fails closed.
  sopsTokenFile = import ../lib/secret-path.nix config "cloudflare-access-ssh-token";
  cloudflared-access = pkgs.writeShellApplication {
    name = "cloudflared-access";
    runtimeInputs = [ pkgs.cloudflared ];
    text = ''
      token_file="${sopsTokenFile}"

      # Two lines (id, secret); IFS= keeps any surrounding whitespace.
      {
        IFS= read -r token_id || true
        IFS= read -r token_secret || true
      } 2>/dev/null < "$token_file" || true

      if [ -z "''${token_id:-}" ] || [ -z "''${token_secret:-}" ]; then
        echo "cloudflared-access: missing or malformed Cloudflare Access token (two lines: Client ID, Client Secret) at $token_file" >&2
        exit 1
      fi

      export TUNNEL_SERVICE_TOKEN_ID="$token_id"
      export TUNNEL_SERVICE_TOKEN_SECRET="$token_secret"

      exec cloudflared access "$@"
    '';
  };

  # A laptop warms its PIV agent before the tunnel; the server only tunnels.
  tunnel = "${cloudflared-access}/bin/cloudflared-access ssh --hostname %h";
  smortressProxy = if isServer then tunnel else "${lib.getExe piv.ensureProxy} ${tunnel}";

  # A loopback forward for one tunnel service; maki points at 127.0.0.1:<port>.
  forward = sub: port: {
    Unit = {
      Description = "Forward ${sub}.${domain} to 127.0.0.1:${toString port} through Cloudflare Access";
      After = [ "network-online.target" ];
      Wants = [ "network-online.target" ];
    };
    Service = {
      ExecStart = "${cloudflared-access}/bin/cloudflared-access tcp --hostname ${sub}.${domain} --url 127.0.0.1:${toString port}";
      Restart = "on-failure";
      RestartSec = 5;
    };
    Install.WantedBy = [ "default.target" ];
  };
in
{
  home.packages = [
    pkgs.cloudflared
    cloudflared-access
  ];

  # smortress is reached only through the tunnel to its loopback sshd
  # (modules/nixos/ssh.nix); its account is always `smores`, whatever the
  # client's username. Each connection re-runs the Access check, so it never
  # shares a master. Identity and forwarding: modules/features/piv.nix.
  programs.ssh.settings.smortress = {
    HostName = "ssh.${domain}";
    User = "smores";
    ControlMaster = "no";
    ProxyCommand = smortressProxy;
  };

  # A personal client reaches the server's llm over the tunnel; a work
  # profile reaches its own, and smortress itself uses loopback, so neither
  # needs these forwards.
  systemd.user.services = lib.mkMerge [
    (lib.mkIf (aiProfile == "personal" && !isServer) {
      cloudflared-llm = forward "llm" smortress.port;
      # The memory wrapper is an HTTP MCP server behind Access; the shim adds
      # the group headers and the forward injects the service token, so
      # ~/.config/maki/mcp.toml carries no secret. On smortress itself the shim
      # dials the same loopback port directly.
      cloudflared-memory = forward "memory" ports.memoryMcp;
    })
  ];
}
