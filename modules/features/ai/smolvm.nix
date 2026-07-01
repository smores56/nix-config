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

  # Smolfile for the persistent agent VM. No `cmd` — agents run via
  # `machine exec`, so `machine start` returns immediately after boot.
  #
  # Image is debian (not alpine): omp's native addons (pi_natives) are
  # glibc-linked and need glibc symbols that musl/gcompat can't provide.
  # maki is a static binary, so it works under any libc.
  #
  # Shared bin mounts to /root/.local/bin (NOT /usr/local/bin, which
  # would shadow the agent rootfs's crane binary and break image pulls).
  # Config dir mounts read-only at /mnt/host-config — Nix-managed config
  # dereference (symlinks into /nix/store resolved on the host side).
  #
  # ssh_agent forwards the host ssh-agent socket into the VM, so git
  # push (ssh) and ssh-format commit signing work without exposing
  # private key files. The host ssh-agent holds the keys (see ssh.nix).
  smolfile = tomlFormat.generate "agent.smolfile" {
    image = "debian:bookworm-slim";
    net = true;
    cpus = 2;
    memory = 1024;
    overlay = 10;
    auth.ssh_agent = true;
    env = [
      "BUN_INSTALL=/root/.bun"
      "MAKI_INSTALL_DIR=/root/.local/bin"
      "PATH=/root/.bun/bin:/root/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
    ];
    volumes = [
      "${sharedBinDir}:/root/.local/bin"
      "${configDir}:/mnt/host-config:ro"
      "${codeRoot}:/root/code"
      "${devRoot}:/root/dev"
    ];
  };

  # Idempotent provisioning command run inside the VM. Installs git,
  # gh, bun, omp, maki, and opencode into the persistent overlay
  # (/root/.bun) and shared virtiofs bin mount (/root/.local/bin), so
  # installs survive VM stop/start.
  #
  # smolvm machine exec doesn't pipe stdin reliably, so we pass the
  # script via `bash -c`.
  provisionScript = ''
    set -e
    export DEBIAN_FRONTEND=noninteractive

    # Sync config from the read-only host mount into the overlay, so
    # Nix-managed symlinks (into /nix/store, which doesn't exist in the
    # VM) are dereferenced and the real files land in /root/.config,
    # /root/.omp, and /root/.ssh. Only copies files that are missing or
    # changed.
    sync_config() {
      local src="$1" dst="$2"
      mkdir -p "$dst"
      cp -ruL "$src"/. "$dst"/ 2>/dev/null || true
    }
    sync_config /mnt/host-config/maki /root/.config/maki
    sync_config /mnt/host-config/omp /root/.omp
    sync_config /mnt/host-config/opencode /root/.config/opencode
    sync_config /mnt/host-config/git /root/.config/git
    sync_config /mnt/host-config/gh /root/.config/gh

    # SSH public keys for git ssh-format commit signing. The private
    # keys stay on the host; the agent signs via the forwarded ssh-agent
    # socket, git just needs the .pub to know which key to request.
    sync_config /mnt/host-config/ssh /root/.ssh

    # System packages: git + openssh-client (for ssh-format commit
    # signing via the forwarded ssh-agent) + ca-certificates for https
    # git remotes and gh API calls. apt-get update is always run because
    # the package lists don't persist in the overlay across VM resets.
    dpkg -s git openssh-client ca-certificates >/dev/null 2>&1 || {
      apt-get update -qq
      apt-get install -y -qq git openssh-client ca-certificates >/dev/null 2>&1
    }

    # gh CLI (static-ish binary tarball). Installed into the shared
    # virtiofs bin mount so it persists on the host across VM resets.
    if [ ! -x /root/.local/bin/gh ]; then
      apt-get install -y -qq curl >/dev/null 2>&1 || true
      gh_version=$(curl -fsSL https://api.github.com/repos/cli/cli/releases/latest \
        | sed -n 's/.*"tag_name":.*"v\([^"]*\)".*/\1/p' | head -1)
      curl -fsSL "https://github.com/cli/cli/releases/download/v''${gh_version}/gh_''${gh_version}_linux_amd64.tar.gz" \
        | tar xz -C /tmp
      install -m 0755 /tmp/gh_''${gh_version}_linux_amd64/bin/gh /root/.local/bin/gh
      rm -rf /tmp/gh_''${gh_version}_linux_amd64
    fi

    # Patch git config for the VM: the host config references
    # /nix/store/.../gh for the credential helper and may set
    # core.sshCommand to a host-only wrapper (git-github-ssh). Rewrite
    # the credential helper to the VM's gh path and drop sshCommand.
    # Runs after git is installed (above).
    git config --file /root/.config/git/config --unset-all \
      "credential.https://github.com.helper" 2>/dev/null || true
    git config --file /root/.config/git/config --add \
      "credential.https://github.com.helper" ""
    git config --file /root/.config/git/config --add \
      "credential.https://github.com.helper" "/root/.local/bin/gh auth git-credential"
    git config --file /root/.config/git/config --unset-all \
      "credential.https://gist.github.com.helper" 2>/dev/null || true
    git config --file /root/.config/git/config --add \
      "credential.https://gist.github.com.helper" ""
    git config --file /root/.config/git/config --add \
      "credential.https://gist.github.com.helper" "/root/.local/bin/gh auth git-credential"
    git config --file /root/.config/git/config --unset-all core.sshCommand 2>/dev/null || true

    # Bun + omp (glibc-linked native addons, not static).
    if [ ! -x /root/.bun/bin/bun ]; then
      apt-get install -y -qq curl unzip bash >/dev/null 2>&1 || true
      curl -fsSL https://bun.sh/install | bash
    fi
    export BUN_INSTALL=/root/.bun
    export PATH="$BUN_INSTALL/bin:$PATH"
    command -v omp >/dev/null 2>&1 || bun add -g @oh-my-pi/pi-coding-agent

    # maki (static musl binary). Installed into the shared virtiofs bin
    # mount, so it persists on the host and self-updates via `maki update`.
    if [ ! -x /root/.local/bin/maki ]; then
      apt-get install -y -qq curl >/dev/null 2>&1 || true
      curl -fsSL https://maki.sh/install.sh | MAKI_INSTALL_DIR=/root/.local/bin sh
    fi

    # opencode (static binary). Same shared bin mount pattern as maki;
    # self-updates via `opencode upgrade`.
    #
    # The opencode install script hardcodes INSTALL_DIR=$HOME/.opencode/bin
    # and ignores OPENCODE_INSTALL_DIR entirely (unlike maki's installer,
    # which honors MAKI_INSTALL_DIR). So we install to the default location
    # then relocate the binary into the shared /root/.local/bin mount,
    # mirroring how gh is installed above. Also pass --no-modify-path so
    # it doesn't litter /root/.bashrc with a PATH entry for the temp dir.
    if [ ! -x /root/.local/bin/opencode ]; then
      apt-get install -y -qq curl tar >/dev/null 2>&1 || true
      curl -fsSL https://opencode.ai/install | bash -s -- --no-modify-path
      install -m 0755 /root/.opencode/bin/opencode /root/.local/bin/opencode
      rm -rf /root/.opencode
    fi
  '';

  # Shared shell snippet: creates the VM if missing, starts it if stopped.
  # Inlined into the launcher to avoid duplicating the create-or-start
  # sequence across scripts.
  ensureVm = ''
    if ! $smolvm machine status --name "$name" >/dev/null 2>&1; then
      $smolvm machine create "$name" --smolfile ${smolfile}
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

    # Provision git, gh, bun, omp, maki, and opencode inside the VM (idempotent).
    $smolvm machine exec --name "$name" -- /bin/bash -c ${lib.escapeShellArg provisionScript}

    # Forward MAKI_INSTALL_DIR so `maki update` writes to the shared
    # virtiofs bin mount, not the default /usr/local/bin.
    env_args=(--env "MAKI_INSTALL_DIR=/root/.local/bin")

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
    enable =
      lib.mkEnableOption "smolvm sandbox for coding agents (maki/omp/opencode) with per-instance kernel tmpfs"
      // {
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
    # changes. Includes maki, opencode, omp, git, gh config, and SSH public keys.
    home.activation.syncSmolvmConfig = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      rm -rf ${configDir}
      mkdir -p ${configDir}/maki ${configDir}/opencode ${configDir}/omp ${configDir}/git ${configDir}/gh ${configDir}/ssh
      cp -rL ${config.home.homeDirectory}/.config/maki/. ${configDir}/maki/ 2>/dev/null || true
      cp -rL ${config.home.homeDirectory}/.config/opencode/. ${configDir}/opencode/ 2>/dev/null || true
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
