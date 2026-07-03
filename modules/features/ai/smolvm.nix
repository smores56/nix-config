{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.dotfiles.smolvm;

  codeRoot = config.dotfiles.codeRoot;
  devRoot = "${config.home.homeDirectory}/dev";
  sharedDir = "${config.xdg.dataHome}/smolvm-shared";
  sharedBinDir = "${sharedDir}/bin";
  configDir = "${sharedDir}/config";

  tomlFormat = pkgs.formats.toml { };
  smolvmRootfs = pkgs.smolvm-agent-rootfs;

  # Smolfile for the persistent agent VM. The `cmd` keeps the container
  # alive (sleep infinity) so `machine start` succeeds — agents run via
  # `machine exec`, which joins the running container via `crun exec`.
  #
  # Image is a Nix-built rootfs directory (not a registry OCI image),
  # passed via `--image` on `machine create` (not in the smolfile)
  # because smolvm's image_source::classify/resolve — which detects
  # local directory paths — runs on the CLI path, not on smolfile
  # values. smolvm's ImageSource::Directory path mounts it via virtiofs
  # and treats it as a single-layer rootfs — no crane pull, no registry.
  #
  # Tier-2 tools (bun, omp, maki) have self-update mechanisms that fight
  # Nix's immutability — those stay on their installer flow in the
  # persistent overlay, installed by provisionScript below.
  #
  # Shared bin mounts to /root/.local/bin for tier-2 tools (maki etc).
  # Config dir mounts read-only at /mnt/host-config — Nix-managed config
  # dereference (symlinks into /nix/store resolved on the host side).
  #
  # ssh_agent forwards the host ssh-agent socket into the VM, so git
  # push (ssh) and ssh-format commit signing work without exposing
  # private key files. The host ssh-agent holds the keys (see ssh.nix).
  smolfile = tomlFormat.generate "agent.smolfile" {
    cmd = [
      "sleep"
      "infinity"
    ];
    net = true;
    cpus = 2;
    memory = 1024;
    auth.ssh_agent = true;
    env = [
      "BUN_INSTALL=/root/.bun"
      "SSL_CERT_FILE=/etc/ssl/certs/ca-bundle.crt"
      "CURL_CA_BUNDLE=/etc/ssl/certs/ca-bundle.crt"
      "MAKI_INSTALL_DIR=/mnt/smolvm-shared/bin"
      "PATH=/root/.bun/bin:/mnt/smolvm-shared/bin:/nix/var/nix/profiles/default/bin:/usr/bin:/bin"
    ];
    volumes = [
      "${sharedDir}:/mnt/smolvm-shared"
      "${configDir}:/mnt/host-config:ro"
      "${codeRoot}:/root/code"
    ];
  };

  # Idempotent provisioning command run inside the VM. Tier-1 tools
  # (git, gh, python3, openssh, ca-certs, curl, bash, coreutils) are
  # pre-baked into the Nix rootfs image — no apt-get needed. Only
  # tier-2 tools (bun, omp, maki) are installed here, plus config sync
  # and git credential helper patching.
  #
  # smolvm machine exec doesn't pipe stdin reliably, so we pass the
  # script via `bash -c`.
  provisionScript = ''
    set -e

    # Sync config from the read-only host mount into the overlay, so
    # Nix-managed symlinks (into /nix/store, which doesn't exist in the
    # VM) are dereferenced and the real files land in /root/.config,
    # /root/.omp, and /root/.ssh. Bulk sync uses `cp -u` so VM-side
    # state (agent.db with codex auth, etc.) survives across launches.
    sync_config() {
      local src="$1" dst="$2"
      mkdir -p "$dst"
      cp -ruL "$src"/. "$dst"/ 2>/dev/null || true
    }
    sync_config /mnt/host-config/maki /root/.config/maki
    sync_config /mnt/host-config/git /root/.config/git
    sync_config /mnt/host-config/gh /root/.config/gh

    # omp config.yml + models.yml are Nix-owned (host-side
    # `enforceOmpConfig` deep-merges and `enforceOmpModels` regenerates
    # every switch). omp rewrites config.yml in-app to capture runtime
    # toggles, advancing its mtime past the staging copy so `cp -u`
    # silently skips the fresh Nix version. Force-copy these two so
    # Nix-declared keys always land; runtime auth (env-var API keys,
    # GH_TOKEN) is forwarded by the launcher, not stored in these files.
    sync_config /mnt/host-config/omp /root/.omp
    cp -fL /mnt/host-config/omp/agent/config.yml /root/.omp/agent/config.yml 2>/dev/null || true
    cp -fL /mnt/host-config/omp/agent/models.yml /root/.omp/agent/models.yml 2>/dev/null || true

    # SSH public keys for git ssh-format commit signing. The private
    # keys stay on the host; the agent signs via the forwarded ssh-agent
    # socket, git just needs the .pub to know which key to request.
    sync_config /mnt/host-config/ssh /root/.ssh

    # Patch git config: the host config references /nix/store/.../gh
    # for the credential helper and may set core.sshCommand to a
    # host-only wrapper (git-github-ssh). Rewrite the credential helper
    # to use `gh` from PATH (nix profile) and drop sshCommand.
    git config --file /root/.config/git/config --unset-all \
      "credential.https://github.com.helper" 2>/dev/null || true
    git config --file /root/.config/git/config --add \
      "credential.https://github.com.helper" ""
    git config --file /root/.config/git/config --add \
      "credential.https://github.com.helper" "gh auth git-credential"
    git config --file /root/.config/git/config --unset-all \
      "credential.https://gist.github.com.helper" 2>/dev/null || true
    git config --file /root/.config/git/config --add \
      "credential.https://gist.github.com.helper" ""
    git config --file /root/.config/git/config --add \
      "credential.https://gist.github.com.helper" "gh auth git-credential"
    git config --file /root/.config/git/config --unset-all core.sshCommand 2>/dev/null || true

    # Bun + omp (glibc-linked native addons, not static).
    if [ ! -x /root/.bun/bin/bun ]; then
      curl -fsSL https://bun.sh/install | bash
    fi
    export BUN_INSTALL=/root/.bun
    export PATH="$BUN_INSTALL/bin:$PATH"
    command -v omp >/dev/null 2>&1 || bun add -g @oh-my-pi/pi-coding-agent

    # maki (static musl binary). Installed into the shared virtiofs bin
    # mount, so it persists on the host and self-updates via `maki update`.
    if [ ! -x /root/.local/bin/maki ]; then
      curl -fsSL https://maki.sh/install.sh | MAKI_INSTALL_DIR=/root/.local/bin sh
    fi

  '';

  # Shared shell snippet: creates the VM if missing, starts it if stopped.
  # Inlined into the launcher to avoid duplicating the create-or-start
  # sequence across scripts.
  ensureVm = ''
    if ! $smolvm machine status --name "$name" >/dev/null 2>&1; then
      $smolvm machine create --name "$name" --smolfile ${smolfile} --image ${smolvmRootfs}
    fi

    state=$($smolvm machine status --name "$name" --json 2>/dev/null \
      | sed -n 's/.*"state":"\([^"]*\)".*/\1/p')
    if [ "$state" != "running" ]; then
      $smolvm machine start --name "$name" >/dev/null
    fi
  '';

  launcher = pkgs.writeShellScriptBin "smolvm-agent" ''
    set -euo pipefail

    smolvm=${pkgs.smolvm}/bin/smolvm
    name="agent"

    ${ensureVm}

    # Provision git, gh, bun, omp, maki inside the VM (idempotent).
    $smolvm machine exec --name "$name" -- /bin/bash -c ${lib.escapeShellArg provisionScript}

    # Forward MAKI_INSTALL_DIR so `maki update` writes to the shared
    # virtiofs bin mount, not the default /usr/local/bin.
    env_args=(
      --env "MAKI_INSTALL_DIR=/root/.local/bin"
    )

    # Forward GitHub OAuth token so `gh` auth works inside the VM without
    # reading the denied ~/.config/gh/hosts.yml (which lives in /nix/store
    # anyway and isn't reachable in the VM). Read host-side via `gh auth token`.
    if command -v gh >/dev/null 2>&1; then
      gh_tok=$(gh auth token 2>/dev/null) || gh_tok=""
      if [ -n "$gh_tok" ]; then
        env_args+=(--env "GH_TOKEN=$gh_tok")
      fi
    fi

    # Forward API key env vars from the host shell into the VM. Both
    # omp (models.yml references env var names like "apiKey":"FOO_API_KEY")
    # and maki (provider scripts resolve env vars at runtime) use env-var-
    # based auth, so no secret files need to be mounted.
    for var in $(env | sed -n 's/^\([A-Z][A-Z0-9_]*_API_KEY\)=.*/\1/p'); do
      env_args+=(--env "$var=$(printenv "$var")")
    done
    if [ -n "''${CLOUDFLARE_ACCOUNT_ID:-}" ]; then
      env_args+=(--env "CLOUDFLARE_ACCOUNT_ID=$CLOUDFLARE_ACCOUNT_ID")
    fi

    # Map the host working directory to the guest. codeRoot mounts at
    # /root/code, devRoot at /root/dev — strip the matching prefix to get
    # the guest path. Falls back to /root/code for paths outside both.
    guest_pwd="/root/code"
    pwd_real=$(cd "$PWD" && pwd -P)
    code_root_real=$(cd ${lib.escapeShellArg codeRoot} && pwd -P)
    dev_root_real=$(cd ${lib.escapeShellArg devRoot} && pwd -P)
    case "$pwd_real" in
      "$code_root_real")
        guest_pwd="/root/code"
        ;;
      "$code_root_real"/*)
        guest_pwd="/root/code''${pwd_real#$code_root_real}"
        ;;
      "$dev_root_real")
        guest_pwd="/root/dev"
        ;;
      "$dev_root_real"/*)
        guest_pwd="/root/dev''${pwd_real#$dev_root_real}"
        ;;
    esac

    exec $smolvm machine exec --name "$name" --workdir "$guest_pwd" -i -t "''${env_args[@]}" -- "$@"
  '';
in
{
  options.dotfiles.smolvm = {
    enable = lib.mkEnableOption "smolvm sandbox for coding agents (maki/omp)" // {
      default = true;
    };
  };

  config = lib.mkIf cfg.enable {
    home.packages = [
      pkgs.smolvm
      launcher
    ];

    # Shared bin dir mounted writable into every agent VM at /root/.local/bin.
    # maki + gh live here as static binaries, self-updated in place.
    # Also ensures ~/dev exists as a virtiofs mount target.
    home.activation.setupSmolvmDirs = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      mkdir -p ${sharedBinDir}
      mkdir -p ${devRoot}
    '';

    # Dereference Nix-managed config symlinks (into /nix/store) into a
    # staging dir, mounted read-only into the VM at /mnt/host-config.
    # The /nix/store paths don't exist inside the VM, so symlinks would
    # be broken. This runs on every home-manager switch to pick up config
    # changes. Includes maki, omp, git, gh config, and SSH public keys.
    home.activation.syncSmolvmConfig = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      rm -rf ${configDir}
      mkdir -p ${configDir}/maki ${configDir}/omp ${configDir}/git ${configDir}/gh ${configDir}/ssh
      cp -rL ${config.home.homeDirectory}/.config/maki/. ${configDir}/maki/ 2>/dev/null || true
      cp -rL ${config.home.homeDirectory}/.omp/. ${configDir}/omp/ 2>/dev/null || true
      cp -rL ${config.home.homeDirectory}/.config/git/. ${configDir}/git/ 2>/dev/null || true
      cp -rL ${config.home.homeDirectory}/.config/gh/. ${configDir}/gh/ 2>/dev/null || true
      # Public keys only — private keys never enter the VM.
      cp -rL ${config.home.homeDirectory}/.ssh/*.pub ${configDir}/ssh/ 2>/dev/null || true
      cp -rL ${config.home.homeDirectory}/.ssh/known_hosts ${configDir}/ssh/ 2>/dev/null || true
      chmod -R u+w ${configDir}
    '';
  };
}
