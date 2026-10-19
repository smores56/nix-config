# Reach smortress's loopback-only services (sshd, llama.cpp) from a
# client over the Cloudflare Tunnel. `cloudflared access` authenticates with a
# Cloudflare Access service token pulled from Proton Pass, so nothing lands on
# disk and no browser login is ever needed. The server reaches its own
# services on loopback, so it gets no forwards.
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
  inherit (aiProviders) smortress;
  inherit (pkgs.stdenv.hostPlatform) isLinux;

  # Vault path of the Access service token (login item: username = Client ID,
  # password = Client Secret). Not a secret in itself, so it is safe in the
  # store; `pass-cli inject` resolves the `pass://` refs into cloudflared's env.
  token = "pass://Hosting/Cloudflare Access service token";

  # One template for the login-time cache and the per-connection fallback.
  tokenTemplate = pkgs.writeText "cloudflare-access-token.template" ''
    {{ ${token}/username }}
    {{ ${token}/password }}
  '';

  # Each `pass-cli inject` is a Proton API round trip (~1s), and a ProxyCommand
  # runs once per SSH connection, so resolve the long-lived service token once
  # per login into per-user tmpfs. 0600 in a 0700 directory, never on disk.
  tokenCache = "cloudflared-access";
  tokenCacheScript = pkgs.writeShellApplication {
    name = "cloudflared-access-cache";
    runtimeInputs = [ pkgs.proton-pass-cli ];
    text = ''
      tmp="$RUNTIME_DIRECTORY/token.$$"
      trap 'rm -f "$tmp"' EXIT
      umask 077
      pass-cli inject -f -i ${tokenTemplate} -o "$tmp"
      # Replace atomically: a ProxyCommand may read this while it is written.
      mv -f "$tmp" "$RUNTIME_DIRECTORY/token"
    '';
  };
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

      runtime="''${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
      cache="$runtime/${tokenCache}/token"

      # Two lines (id, secret); IFS= keeps any surrounding whitespace.
      read_token() {
        IFS= read -r token_id || true
        IFS= read -r token_secret || true
        [ -n "$token_id" ] && [ -n "$token_secret" ]
      }

      if ! read_token < "$cache" 2>/dev/null; then
        if ! read_token < <(pass-cli inject -f -i ${tokenTemplate}); then
          echo "cloudflared-access: could not resolve the Cloudflare Access service token (is pass-cli logged in?)" >&2
          exit 1
        fi
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

  # A personal client reaches the server's llm over the tunnel; a work
  # profile reaches its own, and smortress itself uses loopback, so neither
  # needs these forwards.
  systemd.user.services = lib.mkMerge [
    (lib.mkIf (aiProfile == "personal" && !isServer) {
      cloudflared-llm = forward "llm" smortress.port;
    })

    # macOS has no tmpfs user runtime to put this in; the wrapper's
    # pass-cli fallback covers it. Same retry policy as proton-pass-agent:
    # at login the user manager runs before DNS, so don't rate-limit away.
    (lib.mkIf isLinux {
      cloudflared-access-token = {
        Unit = {
          Description = "Cache the Cloudflare Access service token in tmpfs";
          After = [ "network-online.target" ];
          Wants = [ "network-online.target" ];
          StartLimitIntervalSec = 0;
        };
        Service = {
          Type = "oneshot";
          RemainAfterExit = true;
          Environment = [ "PROTON_PASS_KEY_PROVIDER=fs" ];
          RuntimeDirectory = tokenCache;
          RuntimeDirectoryMode = "0700";
          ExecStart = "${tokenCacheScript}/bin/cloudflared-access-cache";
          Restart = "on-failure";
          RestartSec = 5;
        };
        Install.WantedBy = [ "default.target" ];
      };
    })
  ];
}
