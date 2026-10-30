# Build the agent sandbox and its forced-SSH wrappers. Keep the allow/deny
# lists here as data; the shell backend is modules/lib/agent-sandbox.sh.
{
  pkgs,
  lib,
  isServer,
  isDarwin,
}:
let
  # 0.12.0 fixes the setup-time symlink traversal (CVE-2026-87766) that matters
  # when mask destinations live in an agent-writable home. The flake overlays
  # bubblewrap from nixpkgs-unstable on Linux.
  bwrap = if isDarwin then null else pkgs.bubblewrap;

  path = lib.makeBinPath [
    pkgs.coreutils
    pkgs.findutils
    pkgs.gnugrep
    pkgs.gnused
    pkgs.bash
    pkgs.git
    pkgs.openssh
    pkgs.ripgrep
    pkgs.jq
    pkgs.gh
    pkgs.nix
  ];

  homeRw = [
    "$HOME/code"
    "$HOME/dev"
    "$HOME/Documents"
    "$HOME/Downloads"
    "$HOME/.cache"
    "$HOME/.cargo/registry"
    "$HOME/.cargo/git"
    "$HOME/.npm"
    "$HOME/.bun/install/cache"
    "$HOME/.local/state/agent"
    "$HOME/.local/share/agent"
    "$HOME/.cache/agent"
  ]
  ++ lib.optionals (!isDarwin) [ "/var/lib/media" ];

  # Read-only exceptions carved out of a writable parent (the user PATH must
  # not become an agent-writable executable directory).
  homeRo = [
    "$HOME/.cache/.bun/bin"
  ];

  homeMaskDirs = [
    "$HOME/.ssh"
    "$HOME/.config"
    "$HOME/.gnupg"
    "$HOME/.pki"
    "$HOME/.eid"
    "$HOME/.cloudflared"
    "$HOME/.aws"
    "$HOME/.kube"
    "$HOME/.docker"
    "$HOME/.local/share/keyrings"
    "$HOME/.local/share/fish"
    "$HOME/.local/share/memory"
    "$HOME/.local/share/proton-pass-cli"
    "$HOME/.local/share/maki"
    "$HOME/.local/state/key-backup"
    "$HOME/.local/state/memory"
    "$HOME/.local/state/maki"
    "$HOME/.cache/cliphist"
    "$HOME/.cache/maki"
    "$HOME/.cache/mozilla"
    "$HOME/.cache/chromium"
    "$HOME/.cache/gh"
    "$HOME/.mozilla"
    "$HOME/.var/app"
    "$HOME/.local/share/Steam"
    "$HOME/Library"
  ]
  ++ lib.optionals (!isDarwin) [ "/var/lib/media/Photos" ];

  homeMaskFiles = [
    "$HOME/.bash_history"
    "$HOME/.netrc"
    "$HOME/.git-credentials"
    "$HOME/.npmrc"
    "$HOME/.pypirc"
    "$HOME/.cargo/credentials.toml"
    "$HOME/.local/state/lesshst"
    "$HOME/.zsh_history"
    "$HOME/.python_history"
  ];

  configAllow = [
    "maki"
    "git"
    "bat"
    "delta"
    "helix"
    "nvim"
    "yazi"
    "lazygit"
    "television"
  ];

  secretBind = [
    "/run/secrets/github-personal-pat|/run/secrets/github-personal-pat"
    "/run/secrets/github-work-pat|/run/secrets/github-work-pat"
    "/run/secrets/neuralwatt-api-key|/run/secrets/neuralwatt-api-key"
    "/run/secrets/tinyfish-api-key|/run/secrets/tinyfish-api-key"
    "/run/secrets/immich-agent-api-key|/run/agent/immich-key"
  ];

  signingSockets = lib.optionals (!isDarwin) (
    if isServer then
      [
        "\${XDG_RUNTIME_DIR:-/run/user/$UID}/agent-sign"
        "\${XDG_RUNTIME_DIR:-/run/user/$UID}/fido2-sign-agent"
      ]
    else
      [ "\${XDG_RUNTIME_DIR:-/run/user/$UID}/fido2-sign-agent" ]
  );

  configFile = pkgs.writeText "agent-sandbox.conf" ''
    HOME_RW=(
    ${lib.concatMapStrings (p: "  \"${p}\"\n") homeRw}
    )
    HOME_RO=(
    ${lib.concatMapStrings (p: "  \"${p}\"\n") homeRo}
    )
    HOME_MASK_DIRS=(
    ${lib.concatMapStrings (p: "  \"${p}\"\n") homeMaskDirs}
    )
    HOME_MASK_FILES=(
    ${lib.concatMapStrings (p: "  \"${p}\"\n") homeMaskFiles}
    )
    CONFIG_ALLOW=(
    ${lib.concatMapStrings (p: "  \"${p}\"\n") configAllow}
    )
    SECRET_BIND=(
    ${lib.concatMapStrings (p: "  \"${p}\"\n") secretBind}
    )
    SIGNING_SOCKETS=(
    ${lib.concatMapStrings (p: "  \"${p}\"\n") signingSockets}
    )
    CLOUDFLARED_TOKEN="''${XDG_RUNTIME_DIR:-/run/user/$UID}/cloudflared-access/token"
    ${lib.optionalString isDarwin ''
      OPENAI_KEYCHAIN_ITEM="maki-openai-api-key"
      GH_TOKEN_KEYCHAIN_ITEM="maki-github-pat"''}
    EXEC_DENY=(
      sudo
      su
      pkexec
      osascript
      open
      launchctl
      security
      shortcuts
      crontab
      at
    )
    MACH_ALLOW=(
      com.apple.logd
      com.apple.system.logger
      com.apple.trustd.agent
      com.apple.mDNSResponder
      com.apple.dnssd.service
      com.apple.SystemConfiguration
      com.apple.bsd.dirhelper
      com.apple.pboard
      com.apple.opendirectoryd
    )
  '';

  signingKeyCommand = pkgs.writeShellApplication {
    name = "gpg-ssh-default-key";
    runtimeInputs = [
      pkgs.openssh
      pkgs.coreutils
      pkgs.gnugrep
    ];
    text = ''
      allowed="$HOME/.local/state/agent/config/allowed_signers"
      [ -r "$allowed" ] || exit 1
      keys=$(ssh-add -L 2>/dev/null) || exit 1
      while read -r type body _; do
        [ -n "''${type:-}" ] || continue
        if grep -qF -- "$type $body" "$allowed"; then
          printf 'key::%s %s\n' "$type" "$body"
          exit 0
        fi
      done <<<"$keys"
      exit 1
    '';
  };

  # On macOS there is no /run/secrets; the host-side launcher may inject
  # GH_TOKEN from Keychain. This helper is the fallback after the owner-
  # selecting login helper declined a request.
  gitCredential = pkgs.writeShellScriptBin "agent-sandbox-git-credential" ''
    if [ -n "''${GH_TOKEN:-}" ]; then
      printf 'username=x-access-token\npassword=%s\n' "$GH_TOKEN"
    fi
  '';

  gitConfig = pkgs.writeText "agent-sandbox-gitconfig" ''
    [include]
        path = ~/.local/state/agent/config/git/config

    [url "https://github.com/"]
        insteadOf = git@github.com:
        insteadOf = ssh://git@github.com/

    [credential]
        helper = !github-credential-helper
        helper = !agent-sandbox-git-credential
        useHttpPath = true

    [gpg "ssh"]
        allowedSignersFile = ~/.local/state/agent/config/allowed_signers
        defaultKeyCommand = ~/.local/state/agent/config/bin/gpg-ssh-default-key
        program = ${pkgs.openssh}/bin/ssh-keygen

    [core]
        sshCommand = ssh -F ~/.local/state/agent/config/ssh_config
    ${lib.optionalString isDarwin "[commit]\n        gpgsign = false\n"}
  '';

  sshConfig = pkgs.writeText "agent-sandbox-ssh-config" ''
    ${lib.optionalString (!isServer) ''
      Host smortress
        HostName smortress
        User smores
        ProxyCommand cloudflared-access ssh --hostname %h
        IdentitiesOnly yes
        ControlMaster no
        ForwardAgent no
        ${lib.optionalString (!isDarwin) "IdentityAgent /run/agent/sign"}
    ''}
    Host *
      UserKnownHostsFile ~/.local/state/agent/config/known_hosts
      IdentitiesOnly yes
      ${lib.optionalString (!isDarwin) "IdentityAgent /run/agent/sign"}
  '';

  sshShim = pkgs.writeShellScriptBin "ssh" ''
    exec ${pkgs.openssh}/bin/ssh -F "$HOME/.local/state/agent/config/ssh_config" "$@"
  '';

  ghShim = pkgs.writeShellScriptBin "gh" ''
    if [ -n "''${GH_TOKEN:-}" ]; then
      exec ${pkgs.gh}/bin/gh "$@"
    fi
    exec gh-pat "$@"
  '';

  agentSandbox = pkgs.writeShellApplication {
    name = "agent-sandbox";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.bash
    ]
    ++ lib.optionals (!isDarwin) [ pkgs.bubblewrap ];
    text = ''
      export AGENT_SANDBOX_CONFIG=${configFile}
      export AGENT_SANDBOX_PATH=${path}
      export AGENT_SSH_CONFIG=${sshConfig}
      export AGENT_SSH_SHIM=${sshShim}/bin/ssh
      export AGENT_GH_SHIM=${ghShim}/bin/gh
      export AGENT_CREDENTIAL_HELPER=${gitCredential}/bin/agent-sandbox-git-credential
      export AGENT_SIGNING_KEY_COMMAND=${signingKeyCommand}/bin/gpg-ssh-default-key
      export AGENT_GIT_CONFIG=${gitConfig}
      export AGENT_SANDBOX_BWRAP=${if isDarwin then "/bin/true" else lib.getExe bwrap}
      exec ${pkgs.bash}/bin/bash ${./agent-sandbox.sh} "$@"
    '';
  };

  agentSsh = pkgs.writeShellApplication {
    name = "agent-ssh";
    runtimeInputs = [
      pkgs.bash
      pkgs.coreutils
    ];
    text = ''
      if [ -n "''${SSH_ORIGINAL_COMMAND:-}" ]; then
        exec ${agentSandbox}/bin/agent-sandbox /bin/sh -c "$SSH_ORIGINAL_COMMAND"
      fi
      exec ${agentSandbox}/bin/agent-sandbox ${pkgs.bash}/bin/bash -i
    '';
  };

  # sshd execs the login shell with -c <forced command>. Detect exactly that
  # and skip fish's user config; everything else (interactive and ordinary
  # commands) gets the normal fish shell. The per-key command= does not
  # suppress ~/.ssh/rc, so PermitUserRC no is also required.
  agentLoginShell =
    (pkgs.writeShellApplication {
      name = "agent-login-shell";
      runtimeInputs = [ pkgs.fish ];
      text = ''
        if [ "$#" -ge 2 ] && [ "$1" = "-c" ] && [ "$2" = "${agentSsh}/bin/agent-ssh" ]; then
          exec ${pkgs.fish}/bin/fish --no-config "$@"
        fi
        exec ${pkgs.fish}/bin/fish "$@"
      '';
    })
    // {
      # NixOS users.users.<name>.shell requires a shell package with shellPath.
      shellPath = "/bin/agent-login-shell";
    };
in
{
  inherit
    agentSandbox
    agentSsh
    agentLoginShell
    ;
}
