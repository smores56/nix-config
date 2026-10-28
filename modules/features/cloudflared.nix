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
  ports = import ../ports.nix;
  yubikeyKeys = import ../lib/yubikey-keys.nix;
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

  # macOS has no systemd fido2-agent. smortress sudo uses a forwarded agent
  # holding only the touch-only sudo handles; launchd keeps the agent alive and
  # reloads the handles after a crash.
  sudoAgent = pkgs.writeShellApplication {
    name = "smortress-sudo-agent";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.openssh
    ];
    text = ''
      sock="$HOME/.ssh/sudo-agent.sock"
      install -d -m 700 "$(dirname "$sock")"
      rm -f "$sock"
      ssh-agent -D -a "$sock" &
      agent=$!
      trap 'kill "$agent" 2>/dev/null || true' EXIT
      for _ in $(seq 1 50); do
        [ -S "$sock" ] && break
        sleep 0.1
      done
      for key in "$HOME"/.config/ssh-sk/k*/sudo; do
        [ -f "$key" ] || continue
        if ! SSH_AUTH_SOCK="$sock" ssh-add "$key" >/dev/null; then
          echo "smortress-sudo-agent: could not load $key" >&2
        fi
      done
      wait "$agent"
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
    # Every connection to the host re-runs the Access check. A shared master
    # would also outlive the credential decision, so the design keeps this
    # host out of connection reuse.
    ControlMaster = "no";
    ProxyCommand = "${cloudflared-access}/bin/cloudflared-access ssh --hostname %h";
  }
  // lib.optionalAttrs isLinux {
    # pam_rssh (sudo) signs through the forwarded FIDO2 agent, whose credential
    # is touch-required. On darwin the launchd sudo agent below provides the
    # same forwarded socket.
    ForwardAgent = "\${XDG_RUNTIME_DIR}/fido2-agent";
    # PIV slot 9a, loaded into fido2-agent by yk-login (PIN ONCE, touch NEVER).
    # No PKCS11Provider: the provider stays in the agent so the card session and
    # PIN never leave it.
    IdentityAgent = "\${XDG_RUNTIME_DIR}/fido2-agent";
    IdentitiesOnly = "yes";
    IdentityFile = map (k: "~/.config/ssh-sk/${k.key}.pub") yubikeyKeys.piv;
  }
  // lib.optionalAttrs (!isLinux) {
    # T4/macOS: CryptoTokenKit is not used; OpenSC prompts the PIN on the tty.
    PKCS11Provider = "${pkgs.opensc}/lib/opensc-pkcs11.so";
    # IdentitiesOnly also filters PKCS#11 keys; list the committed public
    # halves so the PIV login identity is still offered.
    IdentityFile = map (k: "~/.config/ssh-sk/${k.key}.pub") yubikeyKeys.piv;
    IdentitiesOnly = "yes";
    # No fido2-agent on macOS: forward the launchd agent that holds only the
    # touch-only sudo handles, so pam_rssh needs a touch and no PIN. The socket
    # lives in ~/.ssh because launchd cannot know the per-session TMPDIR; it is
    # 0600 inside the 0700 directory and is not key material.
    ForwardAgent = "${config.home.homeDirectory}/.ssh/sudo-agent.sock";
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

    # macOS has no tmpfs user runtime to put this in; the wrapper's
    # pass-cli fallback covers it. Same retry policy as proton-pass-agent:
    # at login the user manager runs before DNS, so don't rate-limit away.
    (lib.mkIf (isLinux && !isServer) {
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

  # Keep the macOS sudo agent alive and reload the handles after a crash.
  launchd.agents.smortress-sudo-agent = lib.mkIf (!isLinux) {
    enable = true;
    config = {
      ProgramArguments = [ "${sudoAgent}/bin/smortress-sudo-agent" ];
      EnvironmentVariables.HOME = config.home.homeDirectory;
      ThrottleInterval = 5;
      RunAtLoad = true;
      KeepAlive = true;
      StandardOutPath = "${config.home.homeDirectory}/Library/Logs/smortress-sudo-agent.log";
      StandardErrorPath = "${config.home.homeDirectory}/Library/Logs/smortress-sudo-agent.err";
    };
  };
}
