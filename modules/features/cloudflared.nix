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
  yubikeyKeys = import ../lib/yubikey-keys.nix;
  fido2Pin = import ../lib/fido2-pin.nix { inherit pkgs; };
  inherit (fido2Pin) ensurePin;
  inherit (aiProviders) smortress;
  inherit (pkgs.stdenv.hostPlatform) isLinux;

  # The Access service token is deployed per host through sops: home-manager
  # sops on Darwin, sops-nix (/run/secrets) on NixOS. Two lines: Client ID and
  # Client Secret. There is no fallback; a host without the secret fails closed.
  sopsTokenFile =
    if config.sops.secrets ? cloudflare-access-ssh-token then
      config.sops.secrets.cloudflare-access-ssh-token.path
    else
      "/run/secrets/cloudflare-access-ssh-token";
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

  # Lazy PIV PIN collection for the Linux client. The smortress ProxyCommand
  # runs this before the tunnel: no-op once the agent holds the PIV key,
  # otherwise the shared helper prompts once and caches a verified PIN. A
  # non-interactive caller (the wallpaper timer) sets YK_ENSURE_NO_PROMPT and
  # fails instead of opening an unannounced dialog.
  ykPinAskpass = pkgs.writeShellScriptBin "yk-ensure-askpass" ''
    exec ${pkgs.coreutils}/bin/cat "''${XDG_RUNTIME_DIR:?}/fido2/pin"
  '';
  ykEnsure = pkgs.writeShellApplication {
    name = "yk-ensure";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.gnugrep
      pkgs.opensc
      pkgs.openssh
      pkgs.systemd
      pkgs.util-linux
    ];
    text = ''
      runtime="''${XDG_RUNTIME_DIR:?XDG_RUNTIME_DIR is not set}"
      agent="$runtime/fido2-agent"

      has_piv() {
        [ -S "$agent" ] && SSH_AUTH_SOCK="$agent" ssh-add -l 2>/dev/null |
          grep -q 'PIV AUTH pubkey'
      }

      if has_piv; then exit 0; fi

      # Prompting, verification, the retry guard, and the cache format are the
      # same ones the signing askpass uses, and the helper holds one lock, so
      # parallel ssh calls cannot open two dialogs.
      ${lib.getExe ensurePin} || exit 1

      # Serialise the provider load on the same lock: the helper releases it on
      # exit, and two callers that both see no PIV would otherwise load it (or
      # restart the agent) twice, dropping the identity the other is using.
      exec 8>"$runtime/fido2-ensure.lock"
      flock -w 60 8 || exit 1
      if has_piv; then exit 0; fi

      load_provider() {
        SSH_AUTH_SOCK="$agent" \
          SSH_ASKPASS="${lib.getExe ykPinAskpass}" \
          SSH_ASKPASS_REQUIRE=force \
          ssh-add -s "${pkgs.opensc}/lib/opensc-pkcs11.so"
      }

      if ! load_provider >/dev/null 2>&1; then
        # pam_p11 or ykman may have reset the provider's verified state.
        systemctl --user restart fido2-agent.service
        for _ in $(seq 1 50); do
          [ -S "$agent" ] && break
          sleep 0.1
        done
        load_provider >/dev/null
      fi
    '';
  };
  ykEnsureProxy = pkgs.writeShellApplication {
    name = "yk-ensure-proxy";
    text = ''
      ${lib.getExe ykEnsure}
      exec "$@"
    '';
  };

  # The laptop's smortress path collects the PIV PIN on first use; the server
  # and the other hosts keep the plain tunnel.
  smortressProxy =
    if isLinux && !isServer then
      "${lib.getExe ykEnsureProxy} ${cloudflared-access}/bin/cloudflared-access ssh --hostname %h"
    else
      "${cloudflared-access}/bin/cloudflared-access ssh --hostname %h";

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
  ]
  # The ssh_config only names this path; without installing it here the
  # activation would not realise the wrapper and every ProxyCommand would fail.
  ++ lib.optional isLinux ykEnsureProxy;

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
    ProxyCommand = smortressProxy;
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
    # The sandbox gets only the no-touch signing agent, not fido2-agent (which
    # also holds the sudo handle); forward it to a distinct streamlocal path.
    # The remote path is the server's fixed sandbox socket, so it hardcodes uid
    # 1000, matching the pin in modules/nixos/base.nix. The forward only binds
    # on a session whose key grants port forwarding — the PIV identity used
    # here — not on the restricted signing keys.
    RemoteForward = [ "/run/user/1000/agent-sign /run/user/1000/fido2-sign-agent" ];
    # The server also needs StreamLocalBindUnlink (it defaults to no there); the
    # client option only covers its own -L listeners.
    StreamLocalBindUnlink = "yes";
    # A refused forward must be loud: without this the session comes up with a
    # dead signing agent and signing fails later, far from the cause.
    ExitOnForwardFailure = "yes";
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

  # The Tang Pi is LAN-only: no tunnel, no proxy. Same PIV slot 9a identity as
  # smortress, so a laptop with yk-login (or OpenSC on macOS) needs no extra
  # secret. The literal address is a second pattern so old commands still match.
  programs.ssh.settings."tang-pi 10.0.0.193" = {
    HostName = "10.0.0.193";
    User = "smores";
  }
  // lib.optionalAttrs isLinux {
    IdentityAgent = "\${XDG_RUNTIME_DIR}/fido2-agent";
    IdentitiesOnly = "yes";
    IdentityFile = map (k: "~/.config/ssh-sk/${k.key}.pub") yubikeyKeys.piv;
  }
  // lib.optionalAttrs (!isLinux) {
    PKCS11Provider = "${pkgs.opensc}/lib/opensc-pkcs11.so";
    IdentityFile = map (k: "~/.config/ssh-sk/${k.key}.pub") yubikeyKeys.piv;
    IdentitiesOnly = "yes";
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
