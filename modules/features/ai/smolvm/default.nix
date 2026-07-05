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
  ompAgent = "${config.home.homeDirectory}/.omp/agent";

  tomlFormat = pkgs.formats.toml { };
  jqBin = "${lib.getBin pkgs.jq}/bin/jq";
  smolvmBin = "${pkgs.smolvm}/bin/smolvm";
  image = "cgr.dev/chainguard/wolfi-base";

  # Direct virtiofs volumes: mounted as real directory mount points
  # (not symlinks) at their literal host paths. code/dev must be real
  # mounts so getcwd() returns the host path verbatim — maki indexes
  # session history by cwd, and all sessions were recorded with
  # /home/smores/code/... as the cwd on the host. Plain host dirs (no
  # Nix store symlinks), so they mount cleanly via virtiofs on both
  # Linux and Darwin.
  directVolumes = [
    {
      hostPath = codeRoot;
      guestPath = codeRoot;
    }
    {
      hostPath = devRoot;
      guestPath = devRoot;
    }
  ];

  # host→guest path mappings — bindfs symlink-farm entries. Each goes
  # through the single bindfs volume on Linux (needs --resolve-symlinks
  # for Nix store symlinks) or a direct virtiofs volume on Darwin.
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
      link = "omp-agent";
      hostPath = ompAgent;
      guestPath = "/root/.omp/agent";
    }
    {
      link = "nix-store";
      hostPath = "/nix/store";
      guestPath = "/nix/store";
      ro = true;
    }
  ];

  roOpt = e: if e ? ro && e.ro then ":ro" else "";

  # Linux: 1 bindfs volume + direct volumes for code/dev = 3 total,
  # at libkrun's stock IRQ ceiling of 3.
  linuxVolumes = [
    "${bindfsMount}:/root/host"
  ]
  ++ map (e: "${e.hostPath}:${e.guestPath}") directVolumes;

  # Darwin: no IRQ ceiling; bind every entry directly. code/dev come
  # first (as direct volumes), then the farm entries.
  darwinVolumes =
    (map (e: "${e.hostPath}:${e.guestPath}") directVolumes)
    ++ (map (e: "${e.hostPath}:${e.guestPath}${roOpt e}") entries);

  # Linux: symlink farm entries → `ln -sfn <hostPath> <hostLinksDir>/<link>`
  farmSymlinks = lib.concatMapStringsSep "\n" (
    e: "ln -sfn ${lib.escapeShellArg e.hostPath} ${hostLinksDir}/${e.link}"
  ) entries;

  # Linux: in-VM guest symlinks → `ln -sfn /root/host/<link> <guestPath>`.
  # Pre-creates each guestPath's parent (wolfi-base is minimal).
  guestSymlinks = lib.concatMapStringsSep "\n" (
    e:
    "mkdir -p \"$(dirname ${lib.escapeShellArg e.guestPath})\"\n"
    + "ln -sfn /root/host/${e.link} ${lib.escapeShellArg e.guestPath}"
  ) entries;

  # Linux: a single bindfs `--resolve-symlinks` rw mount over the
  # symlink farm serves every host path that needs symlink resolution
  # (Nix store paths). code/dev are excluded — they're direct virtiofs
  # volumes (see directVolumes) so getcwd() returns the literal host
  # path for maki session matching. 1 bindfs + 2 direct = 3 volumes,
  # at libkrun's stock IRQ ceiling of 3.
  # Darwin: libkrun's GIC has no IRQ ceiling, so direct per-entry
  # volumes are fine (bindfs would need macFUSE).
  isLinux = pkgs.stdenv.isLinux;
  smolfileVolumes = if isLinux then linuxVolumes else darwinVolumes;

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

    # Nix-managed config (git/gh/ssh) staged via `cp -rL` into the
    # overlay so they can rewrite at runtime. omp agent/ and maki
    # config are bindfs rw/ro-mounted directly (no staging).
    sync_file() {
      local src="$1" dst="$2"
      mkdir -p "$(dirname "$dst")"
      cp -fL "$src" "$dst" 2>/dev/null || true
    }
    sync_dir() {
      local src="$1" dst="$2"
      mkdir -p "$dst"
      cp -rfL "$src"/. "$dst"/ 2>/dev/null || true
    }
    sync_dir /mnt/host-config/git /root/.config/git
    sync_file /mnt/host-config/gh/config.yml /root/.config/gh/config.yml

    # omp agent/ is bindfs rw-mounted from the host (~/.omp/agent);
    # config.yml, models.yml, AGENTS.md, mcp.json, skills, extensions
    # all read/write through the mount. No staging or copy needed.

    # SSH config + public keys for git ssh-format commit signing. Private
    # keys stay on the host; the agent signs via the forwarded ssh-agent.
    sync_dir /mnt/host-config/ssh /root/.ssh

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
      # Wait for the bindfs mount to serve fresh contents after a
      # home-manager switch. Verifies a known Nix-managed file reads
      # non-empty (catches both a stale daemon and an in-progress
      # in-place update), not just that the entry exists.
      probe=${bindfsMount}/host-config/git/config
      for _ in $(seq 1 50); do
        [ -s "$probe" ] && break
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

    # guest cwd mirrors host cwd: code/dev are mounted at their
    # literal host paths (see entries), so maki session history
    # (indexed by cwd) matches across host and VM.
    guest_pwd=$(cd "$PWD" && pwd -P)

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

    # Stage Nix-managed config (git/gh/ssh) into a dir mounted ro
    # (Darwin) or via the bindfs symlink farm (Linux). Private ssh keys
    # are never staged — only config, *.pub and known_hosts. gh's
    # hosts.yml (oauth token) is excluded: the launcher forwards
    # GH_TOKEN instead. omp agent/{config.yml,models.yml,AGENTS.md,
    # mcp.json,skills,extensions} are bindfs rw-mounted directly from
    # ~/.omp/agent (see entries list) — no staging needed.
    home.activation.syncSmolvmConfig = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      rm -rf ${configDir}
      mkdir -p ${configDir}/git ${configDir}/gh ${configDir}/ssh
      cp -rL \${config.home.homeDirectory}/.config/git/config ${configDir}/git/ 2>/dev/null || true
      cp -rL \${config.home.homeDirectory}/.config/gh/config.yml ${configDir}/gh/ 2>/dev/null || true
      cp -rL \${config.home.homeDirectory}/.ssh/config ${configDir}/ssh/ 2>/dev/null || true
      cp -rL \${config.home.homeDirectory}/.ssh/*.pub ${configDir}/ssh/ 2>/dev/null || true
      cp -rL \${config.home.homeDirectory}/.ssh/known_hosts ${configDir}/ssh/ 2>/dev/null || true
      chmod -R u+w ${configDir}
    '';

    # Linux only: update the symlink farm in place. Preserving the
    # dir inode keeps the running bindfs daemon's cwd valid, so reads
    # keep succeeding with no restart and no disruption to in-flight
    # VMs. Stale links (removed entries) are pruned by scanning the
    # dir against the current entry set.
    home.activation.smolvmHostLinks = lib.mkIf isLinux (
      lib.hm.dag.entryAfter [ "writeBoundary" "setupSmolvmDirs" "syncSmolvmConfig" ] ''
        mkdir -p ${hostLinksDir}
        ${farmSymlinks}
        for link in ${hostLinksDir}/*; do
          [ -L "$link" ] || continue
          case "''${link##*/}" in
            ${lib.concatMapStringsSep "|" (e: e.link) entries}) ;;
            *) rm -f "$link" ;;
          esac
        done
        mkdir -p ${bindfsMount}
      ''
    );

    # Linux only: bindfs daemon serving the symlink farm as one FUSE
    # mount. Long-lived: home-manager switches update the farm in place
    # (smolvmHostLinks) without restarting this service, since a restart
    # would disrupt in-flight VMs with a brief empty-read window.
    # fusermount3 from a user service lacks the setuid bit needed to
    # unmount a stale FUSE mount, so we rely on clean shutdown.
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
