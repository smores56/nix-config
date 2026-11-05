# Build the agent sandbox and its forced-SSH wrappers. Keep the allow/deny
# lists here as data; the shell backend is modules/lib/agent-sandbox.sh.
{
  pkgs,
  lib,
  isServer,
}:
let
  # 0.12.0 fixes the setup-time symlink traversal (CVE-2026-87766) that matters when mask
  # destinations are in an agent-writable home; the flake overlays it from unstable on Linux.
  bwrap = pkgs.bubblewrap;

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
    # Masks apply after every bind, so the Photos tmpfs hides the Immich library under the writable media tree.
    "/var/lib/data/music"
    "/var/lib/data/books"
  ];

  # Read-only exceptions under a writable parent (the user PATH must not become agent-writable).
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
    # maki has no log-path setting: mask the log dir with a writable tmpfs so the human's log is neither read nor extended.
    "$HOME/.local/logs"
    "$HOME/.claude"
    "$HOME/.codex"
    "$HOME/.local/state/key-backup"
    "$HOME/.local/state/memory"
    "$HOME/.cache/cliphist"
    "$HOME/.cache/maki"
    "$HOME/.cache/mozilla"
    "$HOME/.cache/chromium"
    "$HOME/.cache/BraveSoftware"
    "$HOME/.cache/gh"
    "$HOME/.mozilla"
    "$HOME/.var/app"
    "$HOME/.local/share/Steam"
    # `vault <cmd>` promises the agent never sees the vault ciphertext, so every profile masks the tree.
    "$HOME/Sync"
    # Durable server data: neither belongs in an agent namespace even if /var is bound later.
    "/var/lib/data/photos"
    "/var/lib/data/vault"
  ];

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

  # Files in a read-only config entry that a tool must lock or rewrite; each gets a writable copy
  # in agent state bound over it (maki locks its package lockfile at startup).
  configWritable = [ "maki/pack-lock.json.lock" ];

  secretBind = [
    "/run/secrets/github-personal-pat|/run/secrets/github-personal-pat"
    # The personal commit-signing key at the path the host git config names; also the laptop
    # sandbox's forced-command login to smortress.
    "/run/secrets/github-personal-signing-key|/run/secrets/github-personal-signing-key"
    "/run/secrets/neuralwatt-api-key|/run/secrets/neuralwatt-api-key"
    "/run/secrets/tinyfish-api-key|/run/secrets/tinyfish-api-key"
    "/run/secrets/immich-agent-api-key|/run/agent/immich-key"
    "/run/secrets/memory-mcp-token|/run/secrets/memory-mcp-token"
    # cloudflared-access reads it for the Host smortress ProxyCommand. Access also admits it to
    # llm and memory (already reachable via loopback forwards), so only the ssh endpoint is new.
    "/run/secrets/cloudflare-access-ssh-token|/run/secrets/cloudflare-access-ssh-token"
  ];

  # Secrets promoted into the sandbox environment (VAR|host path), read before bwrap starts.
  # Minimal profiles declare none.
  secretRead = [
    "NEURALWATT_API_KEY|/run/secrets/neuralwatt-api-key"
    "TINYFISH_API_KEY|/run/secrets/tinyfish-api-key"
    "IMMICH_API_KEY|/run/secrets/immich-agent-api-key"
  ];

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
    ${renderList "CONFIG_ALLOW" configAllow}
    ${renderList "CONFIG_WRITABLE" configWritable}
    ${renderList "SECRET_BIND" secretBind}
    ${renderList "SECRET_READ" secretRead}
    ${renderList "ENV_EXTRA" [ ]}
    ${renderList "ENV_PASSTHROUGH" [ ]}
    AGENT_CONFIG_DIR=1
    EMPTY_DIR="${pkgs.emptyDirectory}"
  '';

  gitConfig = pkgs.writeText "agent-sandbox-gitconfig" ''
    # The host config already rewrites GitHub remotes to HTTPS and scopes the credential helper to github.com.
    [include]
        path = ~/.local/state/agent/config/git/config

    [gpg "ssh"]
        allowedSignersFile = ~/.local/state/agent/config/allowed_signers
        # Pinned so signing does not depend on PATH order.
        program = ${pkgs.openssh}/bin/ssh-keygen

    [core]
        sshCommand = ssh -F ~/.local/state/agent/config/ssh_config
    # Sign commits with the owner's sops key at the /run/secrets path the host config names; this
    # file replaces the host's gpgsign (GIT_CONFIG_SYSTEM=/dev/null).
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
        IdentityFile /run/secrets/github-personal-signing-key
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
      pkgs.bubblewrap
    ];
    text = ''
      export AGENT_SANDBOX_CONFIG=${configFile}
      export AGENT_SANDBOX_PATH=${path}
      export AGENT_SSH_CONFIG=${sshConfig}
      export AGENT_SSH_SHIM=${sshShim}/bin/ssh
      export AGENT_GH_SHIM=${ghShim}/bin/gh
      export AGENT_GIT_CONFIG=${gitConfig}
      export AGENT_SANDBOX_BWRAP=${lib.getExe bwrap}
      exec ${pkgs.bash}/bin/bash ${./agent-sandbox.sh} "$@"
    '';
  };

  # Minimal profile for the Open WebUI code interpreter: untrusted code gets one writable workspace,
  # no agent config, git/ssh shims, promoted secrets or repo protection. It keeps the masks, the
  # same-UID boundary and the host network namespace (Open WebUI reaches it on loopback).
  jupyterWorkspace = "/var/lib/agent/jupyter";

  jupyterPath = lib.makeBinPath [
    pkgs.coreutils
    pkgs.bash
    pkgs.findutils
    pkgs.gnugrep
    pkgs.gnused
    pkgs.jq
  ];

  # HOME is read-only with no writable exception, so a tool needing a home path fails instead of reaching the host.
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
    ${renderList "CONFIG_ALLOW" [ ]}
    ${renderList "CONFIG_WRITABLE" [ ]}
    ${renderList "SECRET_BIND" [ ]}
    ${renderList "SECRET_READ" [ ]}
    ${renderList "ENV_EXTRA" jupyterEnvExtra}
    ${renderList "ENV_PASSTHROUGH" [ "JUPYTER_TOKEN" ]}
    EMPTY_DIR="${pkgs.emptyDirectory}"
  '';

  # A sops secret the launcher reads host-side; it reaches the sandbox only as JUPYTER_TOKEN, so no token is in the store or unit.
  jupyterSandbox = pkgs.writeShellApplication {
    name = "jupyter-sandbox";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.bash
      pkgs.bubblewrap
    ];
    text = ''
      : "''${JUPYTER_TOKEN_FILE:?JUPYTER_TOKEN_FILE is not set}"
      JUPYTER_TOKEN=$(<"$JUPYTER_TOKEN_FILE")
      export JUPYTER_TOKEN
      export AGENT_SANDBOX_CONFIG=${jupyterConfigFile}
      export AGENT_SANDBOX_PATH=${jupyterPath}
      export AGENT_SANDBOX_BWRAP=${lib.getExe bwrap}
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

  # sshd execs the login shell with -c <forced command>; detect that and skip fish's user config.
  # The per-key command= does not suppress ~/.ssh/rc, so PermitUserRC no is also required.
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
