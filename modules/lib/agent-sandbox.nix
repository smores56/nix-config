# The bwrap sandbox for the Open WebUI code interpreter (modules/nixos/jupyter.nix). Agents moved to
# the agent VM (modules/nixos/agent-vm.nix); the shell backend is modules/lib/agent-sandbox.sh.
{
  pkgs,
  lib,
}:
let
  # 0.12.0 fixes the setup-time symlink traversal (CVE-2026-87766) that matters when mask
  # destinations are in an agent-writable home; the flake overlays it from unstable on Linux.
  bwrap = pkgs.bubblewrap;

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

  renderList = name: values: ''
    ${name}=(
    ${lib.concatMapStrings (p: "  \"${p}\"\n") values}
    )
  '';

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

in
{
  inherit
    jupyterSandbox
    jupyterWorkspace
    ;
}
