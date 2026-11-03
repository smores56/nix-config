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
  # macOS has no mount namespaces, so logs stay in the human's rotated log
  # directory; Linux masks it with a private tmpfs below instead.
  ++ lib.optionals isDarwin [ "$HOME/.local/logs" ]
  # The whole media tree is writable so new media dirs need no allowlist. The
  # masks are applied after every bind, so the Photos tmpfs still hides the
  # Immich library (writes path-resolve into the tmpfs, never the host dir).
  ++ lib.optionals (!isDarwin) [
    "/var/lib/data/music"
    "/var/lib/data/books"
  ];

  # Read-only exceptions carved out of a writable parent (the user PATH must
  # not become an agent-writable executable directory).
  homeRo = [ "$HOME/.cache/.bun/bin" ];

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
    "$HOME/.local/state/maki"
    # maki has no log-path setting (MAKI_LOG is the level), so mask the log
    # directory with a writable tmpfs: the agent gets working logs and the
    # human's log is neither read nor extended.
    "$HOME/.local/logs"
    "$HOME/.claude"
    "$HOME/.codex"
    # ~/.agents/skills is Nix-managed and shared with maki; leave it readable.
    "$HOME/.local/state/key-backup"
    "$HOME/.local/state/memory"
    "$HOME/.cache/cliphist"
    "$HOME/.cache/maki"
    "$HOME/.cache/mozilla"
    "$HOME/.cache/chromium"
    "$HOME/.cache/gh"
    "$HOME/.mozilla"
    "$HOME/.var/app"
    "$HOME/.local/share/Steam"
    # Syncthing carries the Cryptomator vault ciphertext here (vault.nix); the
    # `vault <cmd>` helper promises the agent never sees the vault, and that
    # promise only holds if every profile, not just jupyter, masks the tree.
    "$HOME/Sync"
    "$HOME/Library"
  ]
  # Durable data on the server. Neither belongs in an agent namespace even if
  # /var is bound in later: photos is the Immich library, the vault is the
  # ciphertext Syncthing syncs.
  ++ lib.optionals (!isDarwin) [
    "/var/lib/data/photos"
    "/var/lib/data/vault"
  ];

  # Darwin only: directories of links to decrypted sops files the sandbox may
  # read. Seatbelt matches the resolved path (/private/var/folders/.../secrets.d/
  # <generation>/<name>), so the launcher resolves each link at start and allows
  # exactly that file; every other sops secret stays denied. Linux binds the key
  # at its /run/secrets path instead (secretBind).
  darwinSecretLinkDirs = lib.optionals isDarwin [ "$HOME/.local/share/github" ];

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
    "$HOME/.claude.json"
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

  # Files inside a read-only config allowlist entry that a tool must be able to
  # lock or rewrite. Each gets a writable copy in the agent state, bound over
  # the read-only one; the rest of the config stays immutable. maki locks its
  # package lockfile at startup even when no package is installed.
  configWritable = [ "maki/pack-lock.json.lock" ];

  secretBind = [
    "/run/secrets/github-personal-pat|/run/secrets/github-personal-pat"
    # The personal commit-signing key, at the path the host git config names,
    # so the included config signs unchanged inside the boundary. It is also
    # the laptop sandbox's forced-command login to smortress (Host smortress).
    "/run/secrets/github-personal-signing-key|/run/secrets/github-personal-signing-key"
    "/run/secrets/neuralwatt-api-key|/run/secrets/neuralwatt-api-key"
    "/run/secrets/tinyfish-api-key|/run/secrets/tinyfish-api-key"
    "/run/secrets/immich-agent-api-key|/run/agent/immich-key"
    "/run/secrets/memory-mcp-token|/run/secrets/memory-mcp-token"
  ];

  # Secrets promoted into the sandbox environment (VAR|host path), read by the
  # launcher before bwrap starts. The minimal profiles declare none: their
  # descendants live on the untrusted side of the boundary.
  secretRead = [
    "NEURALWATT_API_KEY|/run/secrets/neuralwatt-api-key"
    "TINYFISH_API_KEY|/run/secrets/tinyfish-api-key"
    "IMMICH_API_KEY|/run/secrets/immich-agent-api-key"
    "OPENAI_API_KEY|\${OPENAI_KEYCHAIN_ITEM:-/nonexistent}"
  ];

  # One array per list: both generated configs share the shell contract in
  # agent-sandbox.sh, only the contents differ.
  renderList = name: values: ''
    ${name}=(
    ${lib.concatMapStrings (p: "  \"${p}\"\n") values}
    )
  '';

  configFile = pkgs.writeText "agent-sandbox.conf" ''
    ${renderList "HOME_RW" homeRw}
    ${renderList "HOME_RO" homeRo}
    ${renderList "HOME_MASK_DIRS" homeMaskDirs}
    ${renderList "HOME_MASK_FILES" homeMaskFiles}
    ${renderList "DARWIN_SECRET_LINK_DIRS" darwinSecretLinkDirs}
    ${renderList "CONFIG_ALLOW" configAllow}
    ${renderList "CONFIG_WRITABLE" configWritable}
    ${renderList "SECRET_BIND" secretBind}
    ${renderList "SECRET_READ" secretRead}
    ${renderList "ENV_EXTRA" (
      # The sandbox starts from an empty environment, which drops the CA bundle
      # path Nix's git/curl need on macOS; pin the store copy (readable there).
      lib.optionals isDarwin [
        "SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"
        "NIX_SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"
      ]
    )}
    ${renderList "ENV_PASSTHROUGH" [ ]}
    AGENT_CONFIG_DIR=1
    CLOUDFLARED_TOKEN="''${XDG_RUNTIME_DIR:-/run/user/$UID}/cloudflared-access/token"
    EMPTY_DIR="${pkgs.emptyDirectory}"
    ${lib.optionalString isDarwin ''OPENAI_KEYCHAIN_ITEM="maki-openai-api-key"''}
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
      # getpwuid(3): ssh and ssh-keygen refuse to run without the user record.
      com.apple.system.opendirectoryd.libinfo
    )
  '';

  gitConfig = pkgs.writeText "agent-sandbox-gitconfig" ''
    # The included host config already rewrites GitHub remotes to HTTPS and
    # scopes the owner-selecting credential helper to https://github.com.
    [include]
        path = ~/.local/state/agent/config/git/config

    [gpg "ssh"]
        allowedSignersFile = ~/.local/state/agent/config/allowed_signers
        # Pinned so signing never depends on the sandbox PATH order (macOS's
        # /usr/bin/ssh-keygen may come first).
        program = ${pkgs.openssh}/bin/ssh-keygen

    [core]
        sshCommand = ssh -F ~/.local/state/agent/config/ssh_config
    # Sign every commit made inside the boundary with the owner's sops key that
    # the included host config names (bound at /run/secrets on Linux, linked
    # outside the masked ~/.config on Darwin). The host's global gpgsign is
    # replaced by this file (GIT_CONFIG_SYSTEM=/dev/null).
    [commit]
        gpgsign = true
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
        ${lib.optionalString (!isDarwin) "IdentityFile /run/secrets/github-personal-signing-key"}
    ''}
    Host *
      UserKnownHostsFile ~/.local/state/agent/config/known_hosts
      IdentitiesOnly yes
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
      export AGENT_GIT_CONFIG=${gitConfig}
      export AGENT_SANDBOX_BWRAP=${if isDarwin then "/bin/true" else lib.getExe bwrap}
      exec ${pkgs.bash}/bin/bash ${./agent-sandbox.sh} "$@"
    '';
  };

  # Minimal profile for the Open WebUI code interpreter. A kernel is untrusted
  # code driven by a chat, so it gets one writable workspace and nothing else
  # from the host: no agent config dir, no git/ssh shims, no promoted secrets,
  # no repo protection (there are no repos to protect). It keeps the secret and
  # data masks, the same-UID boundary, and the host network namespace (Open WebUI
  # reaches it on loopback).
  jupyterWorkspace = "/var/lib/agent/jupyter";

  jupyterPath = lib.makeBinPath [
    pkgs.coreutils
    pkgs.bash
    pkgs.findutils
    pkgs.gnugrep
    pkgs.gnused
    pkgs.jq
  ];

  # Everything the runtime writes stays in the workspace: HOME is bound
  # read-only here and has no writable exception, so a tool that insists on a
  # home path fails instead of reaching the host's tree.
  jupyterEnvExtra = [
    "PATH=${jupyterPath}"
    "JUPYTER_CONFIG_DIR=${jupyterWorkspace}/.jupyter/config"
    "JUPYTER_DATA_DIR=${jupyterWorkspace}/.jupyter/data"
    "JUPYTER_RUNTIME_DIR=${jupyterWorkspace}/.jupyter/runtime"
    "IPYTHONDIR=${jupyterWorkspace}/.ipython"
    "XDG_CACHE_HOME=${jupyterWorkspace}/.cache"
    "XDG_CONFIG_HOME=${jupyterWorkspace}/.config"
    "XDG_DATA_HOME=${jupyterWorkspace}/.local/share"
    "XDG_STATE_HOME=${jupyterWorkspace}/.local/state"
    "MPLCONFIGDIR=${jupyterWorkspace}/.cache/matplotlib"
  ];

  jupyterConfigFile = pkgs.writeText "jupyter-sandbox.conf" ''
    ${renderList "HOME_RW" [ jupyterWorkspace ]}
    ${renderList "HOME_RO" [ ]}
    ${renderList "HOME_MASK_DIRS" homeMaskDirs}
    ${renderList "HOME_MASK_FILES" homeMaskFiles}
    ${renderList "DARWIN_SECRET_LINK_DIRS" [ ]}
    ${renderList "CONFIG_ALLOW" [ ]}
    ${renderList "CONFIG_WRITABLE" [ ]}
    ${renderList "SECRET_BIND" [ ]}
    ${renderList "SECRET_READ" [ ]}
    ${renderList "ENV_EXTRA" jupyterEnvExtra}
    ${renderList "ENV_PASSTHROUGH" [ "JUPYTER_TOKEN" ]}
    EMPTY_DIR="${pkgs.emptyDirectory}"
    # Linux only: the Darwin branch of the shell wants EXEC_DENY, MACH_ALLOW,
    # and the git shims, which this profile deliberately does not carry.
  '';

  # The token is a sops secret the launcher reads host-side (the service user
  # owns it): it reaches the sandbox only as JUPYTER_TOKEN, which jupyter_server
  # honours, so no token is baked into the store or the unit.
  jupyterSandbox = pkgs.writeShellApplication {
    name = "jupyter-sandbox";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.bash
    ]
    ++ lib.optionals (!isDarwin) [ pkgs.bubblewrap ];
    text = ''
      : "''${JUPYTER_TOKEN_FILE:?JUPYTER_TOKEN_FILE is not set}"
      JUPYTER_TOKEN=$(<"$JUPYTER_TOKEN_FILE")
      export JUPYTER_TOKEN
      export AGENT_SANDBOX_CONFIG=${jupyterConfigFile}
      export AGENT_SANDBOX_PATH=${jupyterPath}
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
    jupyterSandbox
    jupyterWorkspace
    ;
}
