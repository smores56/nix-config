# Reach smortress's loopback-only services (sshd, llama.cpp) from a client over the Cloudflare
# Tunnel, authenticated by a per-host Access service token from sops (no fallback). The server
# uses loopback, so it gets no forwards.
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
  piv = import ../lib/piv.nix { inherit config lib pkgs; };
  inherit (aiProviders) smortress;

  # Deployed per host via sops (home-manager sops on Darwin, sops-nix on NixOS): Client ID and
  # Client Secret on two lines. A host without it fails closed.
  sopsTokenFile = import ../lib/secret-path.nix config "cloudflare-access-ssh-token";
  cloudflared-access = pkgs.writeShellApplication {
    name = "cloudflared-access";
    runtimeInputs = [ pkgs.cloudflared ];
    text = ''
      token_file="${sopsTokenFile}"

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

  tunnel = "${cloudflared-access}/bin/cloudflared-access ssh --hostname %h";
  # `ssh smortress` needs no YubiKey: the pre-connect step stands down when no
  # card is present, and ssh then falls through to sshd's password prompt. PIV-only
  # hosts (tang-pi) keep the hard failure because they do not opt in.
  smortressProxy =
    if isServer then
      tunnel
    else
      "env YK_ENSURE_PASSWORD_FALLBACK=1 ${lib.getExe piv.ensureProxy} ${tunnel}";

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

  # smortress is reached only through the tunnel to its loopback sshd (modules/nixos/ssh.nix); its
  # account is always `smores`. Each connection re-runs the Access check, so no shared master.
  # Identity and forwarding: modules/features/piv.nix.
  programs.ssh.settings.smortress = {
    HostName = "ssh.${domain}";
    User = "smores";
    ControlMaster = "no";
    ProxyCommand = smortressProxy;
  };

  # Personal clients reach the server's llm over the tunnel; work profiles reach their own; smortress uses loopback.
  systemd.user.services = lib.mkMerge [
    (lib.mkIf (aiProfile == "personal" && !isServer) {
      cloudflared-llm = forward "llm" smortress.port;
    })
  ];
}
