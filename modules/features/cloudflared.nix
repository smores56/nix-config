# Reach smortress's loopback-only services (sshd, llama.cpp, SearXNG) from a
# client over the Cloudflare Tunnel. `cloudflared access` authenticates with a
# Cloudflare Access service token pulled from Proton Pass, so nothing lands on
# disk and no browser login is ever needed. The server itself reaches its own
# services on loopback (`dotfiles.llm`), so it gets no forwards.
{
  config,
  lib,
  pkgs,
  aiProviders,
  ...
}:
let
  inherit (config.dotfiles) aiProfile llm searchPort;
  inherit (config.dotfiles.webProxy) domain;
  inherit (aiProviders) smortress;

  # Vault path of the Access service token (login item: username = Client ID,
  # password = Client Secret). Not a secret in itself, so it is safe in the
  # store; `pass-cli inject` resolves the `pass://` refs into cloudflared's env.
  token = "pass://Hosting/Cloudflare Access service token";
  cloudflared-access = pkgs.writeShellApplication {
    name = "cloudflared-access";
    runtimeInputs = [
      pkgs.cloudflared
      pkgs.proton-pass-cli
    ];
    # `pass-cli run` pipes the child's stdio through its secret masker: it
    # buffers, and it drops the hidden `password` field outright, so the token
    # never reaches cloudflared and an SSH stream stalls just after the banner.
    # `inject` emits values verbatim, so resolve the token here and hand
    # cloudflared raw inherited stdio.
    text = ''
      export PROTON_PASS_KEY_PROVIDER="''${PROTON_PASS_KEY_PROVIDER:-fs}"

      template="{{ ${token}/username }}
      {{ ${token}/password }}"

      { read -r token_id; read -r token_secret; } < <(printf '%s\n' "$template" | pass-cli inject -f)
      if [ -z "$token_id" ] || [ -z "$token_secret" ]; then
        echo "cloudflared-access: could not resolve the Cloudflare Access service token (is pass-cli logged in?)" >&2
        exit 1
      fi
      export TUNNEL_SERVICE_TOKEN_ID="$token_id"
      export TUNNEL_SERVICE_TOKEN_SECRET="$token_secret"

      exec cloudflared access "$@"
    '';
  };

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

  # smortress is reached only through the tunnel: cloudflared proxies to its
  # loopback sshd (modules/nixos/ssh.nix). `%h` expands to HostName.
  # smortress's account is always `smores`; a client's own username may differ
  # (e.g. the macOS work host runs as `sam`), so the login user is fixed here
  # rather than taken from the local user.
  programs.ssh.settings."smortress" = {
    HostName = "ssh.${domain}";
    User = "smores";
    ProxyCommand = "${cloudflared-access}/bin/cloudflared-access ssh --hostname %h";
  };

  # A personal client reaches the server's llm/searx over the tunnel; a work
  # profile reaches its own, and smortress itself uses loopback, so neither
  # needs these forwards.
  systemd.user.services = lib.mkIf (aiProfile == "personal" && !llm) {
    cloudflared-llm = forward "llm" smortress.port;
    cloudflared-searx = forward "searx" searchPort;
  };
}
