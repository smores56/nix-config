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
  hostLinksDir = "${sharedDir}/host-links";
  bindfsMount = "${sharedDir}/host-mount";
  makiConfig = "${config.home.homeDirectory}/.config/maki";
  makiState = "${config.home.homeDirectory}/.local/state/maki";

  tomlFormat = pkgs.formats.toml { };
  jqBin = "${lib.getBin pkgs.jq}/bin/jq";
  smolvmBin = "${pkgs.smolvm}/bin/smolvm";
  coreutilsBin = "${lib.getBin pkgs.coreutils}/bin";
  image = "cgr.dev/chainguard/wolfi-base";

  # host→guest path mappings. Each entry drives: the bindfs symlink-farm
  # entry name (Linux), the in-VM symlink from guest path onto
  # /root/host/<link> (Linux), and the direct virtiofs volume (Darwin).
  #   link      : bindfs symlink-farm entry name
  #   hostPath  : absolute host path (resolved host-side via bindfs)
  #   guestPath : absolute guest path the agent sees
  #   ro        : optional, appends :ro on the Darwin direct volume
  #               (Linux bindfs is rw; ro enforced by target perms)
  entries = [
    {
      link = "bin";
      hostPath = sharedBinDir;
      guestPath = "/root/.local/bin";
    }
    {
      link = "code";
      hostPath = codeRoot;
      guestPath = "/root/code";
    }
    {
      link = "dev";
      hostPath = devRoot;
      guestPath = "/root/dev";
    }
    {
      link = "host-config";
      hostPath = configDir;
      guestPath = "/mnt/host-config";
      ro = true;
    }
    {
      link = "maki-config";
      hostPath = makiConfig;
      guestPath = "/root/.config/maki";
    }
    {
      link = "maki-state";
      hostPath = makiState;
      guestPath = "/root/.local/state/maki";
    }
    {
      link = "nix-store";
      hostPath = "/nix/store";
      guestPath = "/nix/store";
      ro = true;
    }
  ];

  roOpt = e: if e ? ro && e.ro then ":ro" else "";

  # Linux: single bindfs mount → 1 volume
  linuxVolume = "${bindfsMount}:/root/host";

  # Darwin: no IRQ ceiling; bind each entry directly.
  darwinVolumes = map (e: "${e.hostPath}:${e.guestPath}${roOpt e}") entries;

  # Linux: symlink farm entries → `ln -sfn <hostPath> <hostLinksDir>/<link>`
  farmSymlinks = lib.concatMapStringsSep "\n" (
    e: "ln -sfn ${lib.escapeShellArg e.hostPath} ${hostLinksDir}/${e.link}"
  ) entries;

  # Linux: in-VM guest symlinks → `ln -sfn /root/host/<link> <guestPath>`
  # Pre-creates each guestPath's parent (wolfi-base is minimal).
  guestSymlinks = lib.concatMapStringsSep "\n" (
    e:
    "mkdir -p \"$(dirname ${lib.escapeShellArg e.guestPath})\"\n"
    + "ln -sfn /root/host/${e.link} ${lib.escapeShellArg e.guestPath}"
  ) entries;

  # Linux: a single bindfs `--resolve-symlinks` rw mount over the
  # symlink farm serves every host path. bindfs resolves symlinks
  # host-side, so `maki-config -> ~/.config/maki -> /nix/store/...`
  # reads correctly without a separate /nix/store mount. ro on
  # Nix-managed paths is enforced by /nix/store's own a-w perms.
  # One virtiofs volume stays under libkrun's stock IRQ ceiling of 3.
  # Darwin: libkrun's GIC has no IRQ ceiling, so direct per-entry
  # volumes are fine (bindfs would need macFUSE).
  isLinux = pkgs.stdenv.isLinux;
  smolfileVolumes = if isLinux then [ linuxVolume ] else darwinVolumes;

  smolfile = tomlFormat.generate "agent.smolfile" {
    inherit image;
    net = true;
    cpus = 2;
    memory = 1024;
    overlay = 10;
    # Forwards the host ssh-agent socket into the VM, so git push (ssh)
    # and ssh-format commit signing work without exposing private keys.
    auth.ssh_agent = true;
    env = [
      "BUN_INSTALL=/root/.bun"
      "MAKI_INSTALL_DIR=/root/.local/bin"
      "PATH=/root/.bun/bin:/root/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
    ];
    volumes = smolfileVolumes;
  };

  # Idempotent provisioning run inside the VM on every start: installs
  # git, gh, bun, omp, maki into the persistent overlay (/root/.bun)
  # and shared bin mount (/root/.local/bin). On Linux the first step
  # symlinks each natural guest path onto the single /root/host mount.
  provisionScript = ''
    set -e

    ${lib.optionalString isLinux guestSymlinks}

    # Staged config (Nix symlinks dereffed host-side via `cp -rL`)
    # into the overlay so omp/git/gh/ssh can rewrite their config at
    # runtime. maki config is mounted directly (no staging).
    sync_config() {
      local src="$1" dst="$2"
      mkdir -p "$dst"
      cp -ruL "$src"/. "$dst"/ 2>/dev/null || true
    }
    sync_config /mnt/host-config/git /root/.config/git
    sync_config /mnt/host-config/gh /root/.config/gh

    # omp rewrites config.yml in-app, advancing its mtime past the
    # staging copy so `cp -u` skips the fresh Nix version. Force-copy
    # these two so Nix-declared keys always land; runtime auth (env-var
    # API keys, GH_TOKEN) is forwarded by the launcher, not in files.
    sync_config /mnt/host-config/omp /root/.omp
    cp -fL /mnt/host-config/omp/agent/config.yml /root/.omp/agent/config.yml 2>/dev/null || true
    cp -fL /mnt/host-config/omp/agent/models.yml /root/.omp/agent/models.yml 2>/dev/null || true

    # SSH public keys for git ssh-format commit signing. Private keys
    # stay on the host; the agent signs via the forwarded ssh-agent.
    sync_config /mnt/host-config/ssh /root/.ssh

    # System packages. python-3 is required by omp's Python eval
    # backend (stdlib-only runner script). apk indexes don't persist
    # across VM resets, so update is always run.
    apk info -e git openssh-client ca-certificates python-3 >/dev/null 2>&1 || {
      apk update -q
      apk add -q git openssh-client ca-certificates python-3
    }

    # gh CLI tarball into the shared bin mount (persists on host).
    if [ ! -x /root/.local/bin/gh ]; then
      apk add -q curl
      gh_version=$(curl -fsSL https://api.github.com/repos/cli/cli/releases/latest \
        | sed -n 's/.*"tag_name":.*"v\([^"]*\)".*/\1/p' | head -1)
      curl -fsSL "https://github.com/cli/cli/releases/download/v''${gh_version}/gh_''${gh_version}_linux_amd64.tar.gz" \
        | tar xz -C /tmp
      install -m 0755 /tmp/gh_''${gh_version}_linux_amd64/bin/gh /root/.local/bin/gh
      rm -rf /tmp/gh_''${gh_version}_linux_amd64
    fi

    # Host git config references host-only paths (/nix/store/.../gh,
    # git-github-ssh wrapper). Rewrite credential helper to the VM's gh
    # path and drop sshCommand.
    for host in github.com gist.github.com; do
      key="credential.https://''${host}.helper"
      git config --file /root/.config/git/config --unset-all "$key" 2>/dev/null || true
      git config --file /root/.config/git/config --add "$key" ""
      git config --file /root/.config/git/config --add "$key" "/root/.local/bin/gh auth git-credential"
    done
    git config --file /root/.config/git/config --unset-all core.sshCommand 2>/dev/null || true

    # Bun + omp (glibc-linked native addons, not static).
    if [ ! -x /root/.bun/bin/bun ]; then
      apk add -q curl unzip bash
      curl -fsSL https://bun.sh/install | bash
    fi
    export BUN_INSTALL=/root/.bun
    export PATH="$BUN_INSTALL/bin:$PATH"
    command -v omp >/dev/null 2>&1 || bun add -g @oh-my-pi/pi-coding-agent

    # maki (static musl binary) into the shared bin mount; self-updates
    # via `maki update` (uses current_exe()).
    if [ ! -x /root/.local/bin/maki ]; then
      apk add -q curl
      curl -fsSL https://maki.sh/install.sh | MAKI_INSTALL_DIR=/root/.local/bin sh
    fi
  '';

  # Shared create-or-start-or-provision snippet, inlined into the
  # launcher. Serialized under flock so concurrent smolvm-agent
  # invocations (e.g. several spawn_session calls in one batch) don't
  # race on `machine create`/`machine start`/provision and wedge the VM
  # (which would EIO-kill every spawned Zellij tab). The final
  # interactive `machine exec` runs outside the lock so it never blocks
  # on a sibling's session.
  ensureVm = ''
    flock=${pkgs.util-linux.bin}/bin/flock
    lock=/run/user/$(id -u)/smolvm-agent-''${name}.lock
    mkdir -p "$(dirname "$lock")"
    exec 9>"$lock"
    $flock 9

    ${lib.optionalString isLinux ''
      # Wait for the bindfs mount to repopulate after a home-manager
      # switch (brief window where the FUSE mount exists but reads return
      # empty). Otherwise provision misreads an empty /root/host.
      for _ in $(seq 1 50); do
        [ -e ${bindfsMount}/maki-config ] \
          && [ -e ${bindfsMount}/nix-store ] \
          && [ -e ${bindfsMount}/bin ] && break
        sleep 0.1
      done
    ''}

    if ! $smolvm machine status --name "$name" >/dev/null 2>&1; then
      $smolvm machine create "$name" --smolfile ${smolfile}
    fi

    state=$($smolvm machine status --name "$name" --json 2>/dev/null \
      | ${jqBin} -r '.state')
    [ "$state" = running ] || $smolvm machine start --name "$name" >/dev/null

    $smolvm machine exec --name "$name" -- /bin/sh -c ${lib.escapeShellArg provisionScript}

    exec 9>&-
  '';

  launcher = pkgs.writeShellScriptBin "smolvm-agent" ''
    set -euo pipefail

    smolvm=${smolvmBin}
    name="agent"

    ${ensureVm}

    env_args=(--env "MAKI_INSTALL_DIR=/root/.local/bin")

    # Forward gh OAuth token via env (VM doesn't read hosts.yml).
    if command -v gh >/dev/null 2>&1; then
      gh_tok=$(gh auth token 2>/dev/null) || gh_tok=""
      [ -n "$gh_tok" ] && env_args+=(--env "GH_TOKEN=$gh_tok")
    fi

    # omp and maki use env-var-based auth — no secret files mounted.
    for var in $(env | sed -n 's/^\([A-Z][A-Z0-9_]*_API_KEY\)=.*/\1/p'); do
      env_args+=(--env "$var=$(printenv "$var")")
    done
    [ -n "''${CLOUDFLARE_ACCOUNT_ID:-}" ] \
      && env_args+=(--env "CLOUDFLARE_ACCOUNT_ID=$CLOUDFLARE_ACCOUNT_ID")

    # Map host cwd to guest path under /root/code or /root/dev.
    pwd_real=$(cd "$PWD" && pwd -P)
    code_root_real=$(cd ${lib.escapeShellArg codeRoot} && pwd -P)
    dev_root_real=$(cd ${lib.escapeShellArg devRoot} && pwd -P)
    guest_pwd="/root/code"
    case "$pwd_real" in
      "$code_root_real") guest_pwd="/root/code" ;;
      "$code_root_real"/*) guest_pwd="/root/code''${pwd_real#$code_root_real}" ;;
      "$dev_root_real") guest_pwd="/root/dev" ;;
      "$dev_root_real"/*) guest_pwd="/root/dev''${pwd_real#$dev_root_real}" ;;
    esac

    exec $smolvm machine exec --name "$name" --workdir "$guest_pwd" -i -t "''${env_args[@]}" -- "$@"
  '';
in
{
  imports = [ ./smolvm-enter.nix ];

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
    home.activation.setupSmolvmDirs = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      mkdir -p ${sharedBinDir}
      mkdir -p ${devRoot}
    '';

    # Stage Nix-managed config (omp/git/gh/ssh) into a dir mounted ro
    # (Darwin) or via the bindfs symlink farm (Linux). Private ssh keys
    # are never staged — only *.pub and known_hosts. gh's hosts.yml
    # (oauth token) is excluded: the launcher forwards GH_TOKEN instead.
    home.activation.syncSmolvmConfig = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      rm -rf ${configDir}
      mkdir -p ${configDir}/omp ${configDir}/git ${configDir}/gh ${configDir}/ssh
      cp -rL ${config.home.homeDirectory}/.omp/. ${configDir}/omp/ 2>/dev/null || true
      cp -rL ${config.home.homeDirectory}/.config/git/. ${configDir}/git/ 2>/dev/null || true
      cp -rL ${config.home.homeDirectory}/.config/gh/config.yml ${configDir}/gh/ 2>/dev/null || true
      cp -rL ${config.home.homeDirectory}/.ssh/*.pub ${configDir}/ssh/ 2>/dev/null || true
      cp -rL ${config.home.homeDirectory}/.ssh/known_hosts ${configDir}/ssh/ 2>/dev/null || true
      chmod -R u+w ${configDir}
    '';

    # Linux only: build the symlink farm and restart the bindfs daemon.
    # The restart is important — `rm -rf + mkdir` gives the dir a new
    # inode, so the running bindfs's cwd still points at the deleted
    # old inode (reads return empty). The restart picks up the new dir.
    home.activation.smolvmHostLinks = lib.mkIf isLinux (
      lib.hm.dag.entryAfter [ "writeBoundary" "setupSmolvmDirs" "syncSmolvmConfig" ] ''
        rm -rf ${hostLinksDir}
        mkdir -p ${hostLinksDir}
        ${farmSymlinks}
        mkdir -p ${bindfsMount}
        PATH="${lib.getBin pkgs.systemd}/bin:$PATH" \
          systemctl --user restart smolvm-bindfs.service 2>/dev/null || true
      ''
    );

    # Linux only: bindfs daemon serving the symlink farm as one FUSE
    # mount. No ExecStartPre: systemd sends SIGTERM to the old bindfs
    # before starting the new one, and bindfs releases the FUSE mount
    # on exit. fusermount3 from a user service lacks the setuid bit
    # needed to unmount a stale FUSE mount, so we rely on clean shutdown.
    systemd.user.services.smolvm-bindfs = lib.mkIf isLinux {
      Unit = {
        Description = "bindfs symlink-farm mount for smolvm agent VMs";
        After = [ "default.target" ];
      };
      Service = {
        Type = "simple";
        ExecStart = "${lib.getExe' pkgs.bindfs "bindfs"} -f --resolve-symlinks --no-allow-other ${hostLinksDir} ${bindfsMount}";
        Restart = "on-failure";
        RestartSec = 2;
      };
      Install = {
        WantedBy = [ "default.target" ];
      };
    };
  };
}
