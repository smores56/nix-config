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
  domain = config.dotfiles.webProxy.domain;
  smortress = aiProviders.smortress;

  # Vault path of the Access service token (login item: username = Client ID,
  # password = Client Secret). Not a secret in itself, so it is safe in the
  # store; `pass-cli run` resolves the `pass://` refs into cloudflared's env.
  token = "pass://Hosting/Cloudflare Access service token";
  cloudflared-access = pkgs.writeShellApplication {
    name = "cloudflared-access";
    runtimeInputs = [
      pkgs.cloudflared
      pkgs.proton-pass-cli
    ];
    text = ''
      export PROTON_PASS_KEY_PROVIDER="''${PROTON_PASS_KEY_PROVIDER:-fs}"
      export TUNNEL_SERVICE_TOKEN_ID='${token}/username'
      export TUNNEL_SERVICE_TOKEN_SECRET='${token}/password'
      exec pass-cli run --no-masking -- cloudflared access "$@"
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
  programs.ssh.settings."smortress" = {
    HostName = "ssh.${domain}";
    User = "smores";
    ProxyCommand = "${cloudflared-access}/bin/cloudflared-access ssh --hostname %h";
  };

  systemd.user.services = {
    cloudflared-llm = lib.mkIf (aiProfile == "personal" && !llm) (forward "llm" smortress.port);
    cloudflared-searx = lib.mkIf (aiProfile == "personal" && !llm) (forward "searx" searchPort);
  };
}
