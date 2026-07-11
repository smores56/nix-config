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
  sharedDir = "${config.xdg.dataHome}/agentbox";
  sharedBinDir = "${sharedDir}/bin";
  configDir = "${sharedDir}/config";
  hostLinksDir = "${sharedDir}/host-links";
  bindfsMount = "${sharedDir}/host-mount";
  makiConfig = "${config.home.homeDirectory}/.config/maki";
  makiState = "${config.home.homeDirectory}/.local/state/maki";

  workflow = import ../../lib/repo-workflow.nix { inherit config lib pkgs; };
  tomlFormat = pkgs.formats.toml { };
  jqBin = "${lib.getBin pkgs.jq}/bin/jq";
  smolvmBin = "${pkgs.smolvm}/bin/smolvm";
  image = "cgr.dev/chainguard/wolfi-base";

  # Default global mise toolset. Per-repo mise.toml/.tool-versions overrides
  # per-cwd. rust backend uses rustup under the hood and provides rustc+cargo.
  defaultMiseConfig = pkgs.writeText "mise-config.toml" ''
    [tools]
    rust = "latest"
    just = "latest"
    python = "3.12"
    deno = "latest"
    bun = "latest"
  '';

  # Env vars baked into every agentbox VM (base and clones). Per-invocation
  # secrets (GH_TOKEN, *_API_KEY) are forwarded on `machine exec`, not here.
  baseEnv = [
    "MAKI_INSTALL_DIR=/root/.local/bin"
    "MISE_DATA_DIR=/root/.local/share/mise"
    "CARGO_TARGET_DIR=/root/.cargo-target"
    # mise shims first → per-repo pins override the shared bin mount;
    # then shared bin (maki/gh/mise). The latter lives in the overlay.
    "PATH=/root/.local/share/mise/shims:/root/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
  ];

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
      link = "nix-store";
      hostPath = "/nix/store";
      guestPath = "/nix/store";
      ro = true;
    }
    {
      link = "agent-state";
      hostPath = "${sharedDir}/agent-state";
      guestPath = "/root/host/agent-state";
    }
    {
      link = "repo-caches";
      hostPath = "${sharedDir}/repo-caches";
      guestPath = "/root/host/repo-caches";
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

  isLinux = pkgs.stdenv.isLinux;
  smolfileVolumes = if isLinux then linuxVolumes else darwinVolumes;

  # Single source of truth for VM config. The Smolfile (base VM creation
  # during snapshot regen) and the CLI arg list (clone creation via
  # --from) both derive from this. smolvm rejects combining --from with
  # --smolfile, so clones get these as CLI flags.
  vmConfig = {
    inherit image;
    net = true;
    cpus = 16;
    memory = 16384;
    overlay = 20;
    auth.ssh_agent = true;
    env = baseEnv;
    volumes = smolfileVolumes;
  };

  smolfile = tomlFormat.generate "agentbox.smolfile" vmConfig;

  # Clone-create CLI args mirroring vmConfig. Used when creating a
  # per-name VM from the snapshot (--from + --smolfile is rejected,
  # and --from + --image is rejected since the snapshot already has
  # the image baked in).
  cloneCreateArgs = lib.cli.toGNUCommandLine { } {
    inherit (vmConfig) net cpus;
    mem = vmConfig.memory;
    overlay = vmConfig.overlay;
    ssh-agent = vmConfig.auth.ssh_agent;
    env = vmConfig.env;
    volume = vmConfig.volumes;
  };

  # Config-staging block, shared by base + per-VM provision. Copies the
  # ro host-config mount (config, *.pub, known_hosts — never privates)
  # into /root so runtime rewrites work. maki config/state are
  # bindfs-mounted directly and not staged here.
  syncConfig = ''
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
    sync_file /mnt/host-config/mise/config.toml /root/.config/mise/config.toml
    sync_dir /mnt/host-config/ssh /root/.ssh
  '';

  # Heavy installs. Runs once during snapshot regen; clones created from
  # the snapshot inherit all of this and skip it. Idempotent guards mean
  # a re-run on the same base VM is a no-op. Stages config first so mise
  # install picks up the toolset from config.toml.
  baseProvisionScript = ''
    set -e
    export MISE_DATA_DIR=/root/.local/share/mise
    export PATH="/root/.local/share/mise/shims:/root/.local/bin:$PATH"

    ${lib.optionalString isLinux guestSymlinks}

    ${syncConfig}

    # System packages. python-3 is required by maki's Python eval
    # backend; bash by mise's python backend; curl by rustup-init and
    # the gh/mise/maki installers below. apk indexes don't persist
    # across VM resets, so update is always run.
    apk info -e git openssh-client ca-certificates python-3 bash curl unzip xz bubblewrap >/dev/null 2>&1 || {
      apk update -q
      apk add -q git openssh-client ca-certificates python-3 bash curl unzip xz bubblewrap
    }

    install -m 0755 /mnt/host-config/bin/repos /root/.local/bin/repos
    install -m 0755 /mnt/host-config/bin/worktrees /root/.local/bin/worktrees

    # gh CLI tarball into the shared bin mount (persists on host).
    if [ ! -x /root/.local/bin/gh ]; then
      gh_version=$(curl -fsSL https://api.github.com/repos/cli/cli/releases/latest \
        | sed -n 's/.*"tag_name":.*"v\([^"]*\)".*/\1/p' | head -1)
      curl -fsSL "https://github.com/cli/cli/releases/download/v''${gh_version}/gh_''${gh_version}_linux_amd64.tar.gz" \
        | tar xz -C /tmp
      install -m 0755 /tmp/gh_''${gh_version}_linux_amd64/bin/gh /root/.local/bin/gh
      rm -rf /tmp/gh_''${gh_version}_linux_amd64
    fi

    # mise: installs bun runtime + default global toolset (rust/cargo,
    # just, python, deno) into the overlay (MISE_DATA_DIR). The mise
    # binary lands in the shared bin mount (host-persistent).
    if [ ! -x /root/.local/bin/mise ]; then
      curl -fsSL https://mise.run | MISE_QUIET=1 sh
    fi
    # mise activate in .bashrc gives cd-driven per-repo reactivation
    # for interactive shells; the shim dir on PATH covers non-interactive
    # maki spawns (no shell sourcing).
    grep -q 'mise activate' /root/.bashrc 2>/dev/null || {
      echo 'eval "$(mise activate bash)"' >> /root/.bashrc
    }
    # Install/refresh the default global toolset. Idempotent — mise
    # skips tools already at the pinned version.
    mise install -q -y

    # maki (static musl binary) into the shared bin mount; self-updates
    # via `maki update` (uses current_exe()).
    if [ ! -x /root/.local/bin/maki ]; then
      curl -fsSL https://maki.sh/install.sh | MAKI_INSTALL_DIR=/root/.local/bin sh
    fi
  '';

  # Light provisioning: runs on every agentbox launch. Restages config
  # from the ro host-config mount (catches home-manager switches) and
  # rewrites the host git config's credential helper + sshCommand for
  # in-VM paths. No installs — the snapshot has them; if the snapshot
  # is stale w.r.t. Smolfile, snapshotVersion bumps and lazy-regen
  # fires before reaching here.
  perVmProvisionScript = ''
    set -e

    ${lib.optionalString isLinux guestSymlinks}

    ${syncConfig}

    # Install the cell entry script
    install -m 0755 /mnt/host-config/cell-entry /usr/local/bin/agentbox-cell

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
  '';

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

  # Cell entry script: runs inside the VM via `smolvm machine exec`,
  # launches a fresh bubblewrap mount namespace per agent process.
  # All paths are resolved on the host and passed as CELL_* env vars.
  cellScript = ''
    #!/usr/bin/env bash
    set -euo pipefail

    bwrap_args=(
      --die-with-parent
      --new-session
      --unshare-user --unshare-pid --unshare-ipc --unshare-uts
      --ro-bind / /
      --proc /proc
      --dev /dev
      --tmpfs /tmp
      --setenv HOME /root
      --setenv TMPDIR /tmp
      --setenv PATH /root/.local/share/mise/shims:/root/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
      --setenv MAKI_INSTALL_DIR /root/.local/bin
      --setenv MISE_DATA_DIR /root/.local/share/mise
      --setenv CARGO_TARGET_DIR /root/.cargo-target
    )

    if bwrap --help 2>/dev/null | grep -q -- '--unshare-cgroup-try'; then
      bwrap_args+=(--unshare-cgroup-try)
    elif bwrap --help 2>/dev/null | grep -q -- '--unshare-cgroup'; then
      bwrap_args+=(--unshare-cgroup)
    fi

    if [ -n "''${CELL_CODEROOT:-}" ] && [ "''${CELL_CODEROOT}" != "''${CELL_WORKSPACE:-}" ]; then
      bwrap_args+=(--ro-bind "$CELL_CODEROOT" "$CELL_CODEROOT")
    fi

    [ -n "''${CELL_WORKSPACE:-}" ] && bwrap_args+=(--bind "$CELL_WORKSPACE" "$CELL_WORKSPACE")

    if [ -n "''${CELL_GIT_COMMON:-}" ]; then
      bwrap_args+=(--ro-bind "$CELL_GIT_COMMON" "$CELL_GIT_COMMON")
      [ -d "$CELL_GIT_COMMON/objects" ] && bwrap_args+=(--bind "$CELL_GIT_COMMON/objects" "$CELL_GIT_COMMON/objects")
      [ -d "$CELL_GIT_COMMON/refs" ] && bwrap_args+=(--bind "$CELL_GIT_COMMON/refs" "$CELL_GIT_COMMON/refs")
      [ -d "$CELL_GIT_COMMON/logs" ] && bwrap_args+=(--bind "$CELL_GIT_COMMON/logs" "$CELL_GIT_COMMON/logs")
    fi
    [ -n "''${CELL_GIT_DIR:-}" ] && [ -d "$CELL_GIT_DIR" ] && bwrap_args+=(--bind "$CELL_GIT_DIR" "$CELL_GIT_DIR")

    [ -n "''${CELL_DEVROOT:-}" ] && bwrap_args+=(--bind "$CELL_DEVROOT" "$CELL_DEVROOT")

    [ -d /root/.config/maki ] && bwrap_args+=(--bind /root/.config/maki /root/.config/maki)
    [ -d /root/.local/state/maki ] && bwrap_args+=(--bind /root/.local/state/maki /root/.local/state/maki)

    if [ -n "''${CELL_REPO_CACHE:-}" ] && [ -d "$CELL_REPO_CACHE" ]; then
      bwrap_args+=(--bind "$CELL_REPO_CACHE" "$CELL_REPO_CACHE")
      bwrap_args+=(
        --setenv DENO_DIR "$CELL_REPO_CACHE/deno"
        --setenv MISE_CACHE_DIR "$CELL_REPO_CACHE/mise"
        --setenv PIP_CACHE_DIR "$CELL_REPO_CACHE/pip"
        --setenv npm_config_cache "$CELL_REPO_CACHE/npm"
        --setenv CARGO_HOME "$CELL_REPO_CACHE/cargo"
        --setenv GOMODCACHE "$CELL_REPO_CACHE/go/pkg/mod"
        --setenv GOCACHE "$CELL_REPO_CACHE/go/build"
        --setenv BUN_INSTALL_CACHE_DIR "$CELL_REPO_CACHE/bun"
      )
    fi

    [ -n "''${CELL_CWD:-}" ] && bwrap_args+=(--chdir "$CELL_CWD")

    exec bwrap "''${bwrap_args[@]}" -- "$@"
  '';

  # Snapshot version: regenerates only when inputs that affect the
  # snapshot's installed state change. Captured at Nix eval time and
  # baked into the launcher, so no `nix` calls in the launcher path.
  # Changes to baseProvisionScript, defaultMiseConfig, image, or the
  # smolvm package version bump the version and trigger lazy regen.
  # All inputs must be strings — derivations don't coerce for hashing.
  snapshotVersion = builtins.substring 0 12 (
    builtins.hashString "sha256" (
      baseProvisionScript
      + cellScript
      + perVmProvisionScript
      + (lib.fileContents defaultMiseConfig)
      + image
      + pkgs.smolvm.version
      + builtins.toJSON vmConfig
      + "v2"
    )
  );
  snapshotDir = "${sharedDir}/snapshots";
  snapshotPath = "${snapshotDir}/base-${snapshotVersion}.smolmachine";

  # Lazy snapshot regen. Serialized under its own flock so concurrent
  # agentbox invocations racing on a missing/stale snapshot don't
  # double-regen. After acquiring the lock, re-checks existence
  # (another process may have just regenerated it). Regen flow:
  #   create base VM (Smolfile) → start → heavy provision → stop →
  #   pack → delete base → atomic rename into place.
  # Prunes older snapshots best-effort after a successful regen.
  ensureBaseSnapshot = ''
    snapshot=${snapshotPath}
    snapshot_dir=${snapshotDir}

    if [ ! -f "$snapshot" ]; then
      regen_lock=/run/user/$(id -u)/agentbox-snapshot.lock
      mkdir -p "$(dirname "$regen_lock")" "$snapshot_dir"
      # Use fd 8 for the regen lock — fd 9 holds the per-VM lock
      # (ensureVm). `exec 9>` would drop the per-VM open file
      # description and release that lock prematurely.
      exec 8>"$regen_lock"
      $flock 8

      if [ ! -f "$snapshot" ]; then
        echo "agentbox: snapshot ${snapshotVersion} missing, regenerating (~2 min)…" >&2
        base_tmp=agentbox-base-$$
        cleanup_base() {
          $smolvm machine status --name "$base_tmp" >/dev/null 2>&1 \
            && $smolvm machine stop --name "$base_tmp" >/dev/null 2>&1 || true
          $smolvm machine delete "$base_tmp" -f >/dev/null 2>&1 || true
          rm -f "$snapshot_dir/base.tmp" "$snapshot_dir/base.tmp.smolmachine"
        }
        trap cleanup_base EXIT
        $smolvm machine create "$base_tmp" --smolfile ${smolfile} >&2
        $smolvm machine start --name "$base_tmp" >&2
        $smolvm machine exec --name "$base_tmp" -- /bin/sh -c ${lib.escapeShellArg baseProvisionScript} >&2
        $smolvm machine stop --name "$base_tmp" >&2
        $smolvm pack create --from-vm "$base_tmp" --output "$snapshot_dir/base.tmp" >&2
        $smolvm machine delete "$base_tmp" -f >&2
        mv "$snapshot_dir/base.tmp.smolmachine" "$snapshot"
        rm -f "$snapshot_dir/base.tmp"
        trap - EXIT
        find "$snapshot_dir" -name 'base-*.smolmachine' ! -name "$(basename "$snapshot")" -delete 2>/dev/null || true
      fi

      exec 8>&-
    fi
  '';

  # Per-VM ensure: create from snapshot (with CLI args mirroring
  # vmConfig, since --from + --smolfile is rejected by smolvm) if
  # missing, start if stopped, run light provision. Serialized per
  # `name` so concurrent agentbox invocations against the same VM
  # don't race on create/start/provision. The final interactive
  # `machine exec` runs outside the lock so it never blocks on a
  # sibling's session.
  ensureVm = ''
    flock=${pkgs.util-linux.bin}/bin/flock
    runtime_dir="''${XDG_RUNTIME_DIR:-}"
    if [ -z "$runtime_dir" ] || ! mkdir -p "$runtime_dir" 2>/dev/null; then
      runtime_dir="''${TMPDIR:-/tmp}"
      mkdir -p "$runtime_dir"
    fi
    lock="$runtime_dir/agentbox-''${name}.lock"
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

    ${ensureBaseSnapshot}

    if ! $smolvm machine status --name "$name" >/dev/null 2>&1; then
      $smolvm machine create "$name" --from "$snapshot" ${lib.concatStringsSep " " cloneCreateArgs}
    fi

    state=$($smolvm machine status --name "$name" --json 2>/dev/null \
      | ${jqBin} -r '.state')
    [ "$state" = running ] || $smolvm machine start --name "$name" >/dev/null

    $smolvm machine exec --name "$name" -- /bin/sh -c ${lib.escapeShellArg perVmProvisionScript}

    exec 9>&-
  '';

  # Explicit credential forwarding — no wildcard env scanning.
  # Only these named variables are forwarded when set.
  credentialEnvNames = [
    "NEURALWATT_API_KEY"
    "CLOUDFLARE_API_KEY"
    "CLOUDFLARE_ACCOUNT_ID"
    "GLEAN_API_TOKEN"
    "ANTHROPIC_API_KEY"
    "OPENAI_API_KEY"
    "GEMINI_API_KEY"
    "DEEPSEEK_API_KEY"
  ];

  launcher = pkgs.writeShellScriptBin "agentbox" ''
    set -euo pipefail

    smolvm=${smolvmBin}
    name="agentbox"
    agent_id="''${AGENTBOX_AGENT_ID:-default}"
    do_reset=false
    do_reset_agent=false
    do_reset_repo_cache=false

    while [ $# -gt 0 ]; do
      case "$1" in
        --name)
          name="$2"; shift 2 ;;
        --name=*)
          name="''${1#--name=}"; shift ;;
        --agent-id)
          agent_id="$2"; shift 2 ;;
        --agent-id=*)
          agent_id="''${1#--agent-id=}"; shift ;;
        --reset)
          do_reset=true; shift ;;
        --reset-agent)
          do_reset_agent=true; shift ;;
        --reset-repo-cache)
          do_reset_repo_cache=true; shift ;;
        --)
          shift; break ;;
        *)
          break ;;
      esac
    done

    codeRoot="${codeRoot}"
    devRoot="${devRoot}"
    launch_pwd=$(cd "''${PWD}" && pwd -P)

    # Resolve Git worktree boundary
    worktree=""
    git_common=""
    git_dir=""
    canonical=""
    if git -C "$launch_pwd" rev-parse --show-toplevel >/dev/null 2>&1; then
      worktree=$(git -C "$launch_pwd" rev-parse --show-toplevel)
      git_common=$(git -C "$launch_pwd" rev-parse --path-format=absolute --git-common-dir)
      git_dir=$(git -C "$launch_pwd" rev-parse --path-format=absolute --git-dir)
      canonical=$(dirname "$git_common")
    fi

    is_subpath() {
      case "$2/" in "$1/"*) return 0 ;; *) return 1 ;; esac
    }

    # Determine workspace and codeRoot mount mode
    if [ -n "$worktree" ]; then
      if [ "$worktree" = "$canonical" ]; then
        # Canonical launch: entire checkout RW (includes nested .worktrees)
        :
      elif is_subpath "$canonical/.worktrees" "$worktree"; then
        # Nested worktree: only this worktree RW, codeRoot RO
        :
      else
        echo "agentbox: linked worktree outside canonical/.worktrees not supported" >&2
        exit 1
      fi
    elif [ "$launch_pwd" = "$devRoot" ] || is_subpath "$devRoot" "$launch_pwd"; then
      # ~/dev launch: no repo overlay
      worktree=""
    else
      echo "agentbox: not inside a Git repository or ~/dev" >&2
      exit 1
    fi

    # Compute repo digest for per-repo cache
    if [ -n "$canonical" ]; then
      repo_digest=$(printf '%s' "$canonical" | sha256sum | cut -c1-24)
    else
      repo_digest="nodev"
    fi

    # Validate agent_id
    if ! printf '%s' "$agent_id" | grep -qE '^[A-Za-z0-9._-]+$'; then
      echo "agentbox: invalid agent-id (must match ^[A-Za-z0-9._-]+\$)" >&2
      exit 1
    fi

    agent_state_dir="${sharedDir}/agent-state/$agent_id"
    repo_cache_dir="${sharedDir}/repo-caches/$repo_digest"

    # Handle reset commands
    if $do_reset_agent; then
      rm -rf "$agent_state_dir"
      echo "agentbox: reset agent state for $agent_id"
    fi
    if $do_reset_repo_cache; then
      rm -rf "$repo_cache_dir"
      echo "agentbox: reset repo cache for $repo_digest"
    fi

    mkdir -p "$agent_state_dir" "$repo_cache_dir"

    # Build CELL_* env vars for the cell script
    cell_env_args=()
    cell_env_args+=(--env "CELL_DEVROOT=$devRoot")
    cell_env_args+=(--env "CELL_AGENT_ID=$agent_id")
    [ -n "$worktree" ] && cell_env_args+=(--env "CELL_WORKSPACE=$worktree")
    [ -n "$canonical" ] && cell_env_args+=(--env "CELL_CODEROOT=$codeRoot")
    [ -n "$git_common" ] && cell_env_args+=(--env "CELL_GIT_COMMON=$git_common")
    [ -n "$git_dir" ] && cell_env_args+=(--env "CELL_GIT_DIR=$git_dir")
    cell_env_args+=(--env "CELL_REPO_CACHE=/root/host/repo-caches/$repo_digest")
    cell_env_args+=(--env "CELL_CWD=$launch_pwd")

    # Symlink agent state subdirs if they don't exist
    for sub in .config/maki .local/state/maki .omp/agent .cache; do
      mkdir -p "$agent_state_dir/$sub"
    done

    ${ensureVm}

    # If --reset, recreate the VM after ensureVm has set up the snapshot
    if $do_reset; then
      $smolvm machine stop --name "$name" >/dev/null 2>&1 || true
      $smolvm machine delete --name "$name" -f >/dev/null 2>&1 || true
      $smolvm machine create "$name" --from "${snapshotPath}" ${lib.concatStringsSep " " cloneCreateArgs}
      $smolvm machine start --name "$name" >/dev/null
      $smolvm machine exec --name "$name" -- /bin/sh -c ${lib.escapeShellArg perVmProvisionScript}
    fi

    # Build credential env args
    env_args=(--env "MAKI_INSTALL_DIR=/root/.local/bin")

    # Forward gh OAuth token via env (VM doesn't read hosts.yml).
    if command -v gh >/dev/null 2>&1; then
      gh_tok=$(gh auth token 2>/dev/null) || gh_tok=""
      [ -n "$gh_tok" ] && env_args+=(--env "GH_TOKEN=$gh_tok")
    fi

    # Explicit credential forwarding (no wildcard)
    for var in ${lib.concatStringsSep " " credentialEnvNames}; do
      val=$(printenv "$var" 2>/dev/null) || val=""
      [ -n "$val" ] && env_args+=(--env "$var=$val")
    done

    exec $smolvm machine exec --name "$name" \
      "''${cell_env_args[@]}" "''${env_args[@]}" \
      --workdir "$launch_pwd" -i -t \
      -- /usr/local/bin/agentbox-cell "$@"
  '';
in
{
  options.dotfiles.smolvm = {
    enable = lib.mkEnableOption "agentbox sandbox for coding agents (maki)" // {
      default = true;
    };
  };

  config = lib.mkIf cfg.enable {
    home.packages = [
      pkgs.smolvm
      launcher
    ];
    home.activation.setupAgentboxDirs = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      mkdir -p ${sharedBinDir}
      mkdir -p ${devRoot}
      mkdir -p ${snapshotDir}
      mkdir -p ${sharedDir}/agent-state
      mkdir -p ${sharedDir}/repo-caches
    '';

    # Stage Nix-managed config (git/gh/ssh/mise) into a dir mounted ro
    # (Darwin) or via the bindfs symlink farm (Linux). Private ssh keys
    # are never staged — only config, *.pub and known_hosts. gh's
    # hosts.yml (oauth token) is excluded: the launcher forwards
    # GH_TOKEN instead. maki config/state are bindfs rw-mounted directly
    # from ~/.config/maki and ~/.local/state/maki (see entries list) —
    # no staging needed.
    home.activation.syncAgentboxConfig = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      rm -rf ${configDir}
      mkdir -p ${configDir}/git ${configDir}/gh ${configDir}/ssh ${configDir}/mise ${configDir}/bin
      cp -rL \${config.home.homeDirectory}/.config/git/config ${configDir}/git/ 2>/dev/null || true
      cp -rL \${config.home.homeDirectory}/.config/gh/config.yml ${configDir}/gh/ 2>/dev/null || true
      cp -rL \${config.home.homeDirectory}/.config/ssh/config ${configDir}/ssh/ 2>/dev/null || true
      cp -rL \${config.home.homeDirectory}/.ssh/*.pub ${configDir}/ssh/ 2>/dev/null || true
      cp -rL \${config.home.homeDirectory}/.ssh/known_hosts ${configDir}/ssh/ 2>/dev/null || true
      cp -fL ${defaultMiseConfig} ${configDir}/mise/config.toml
      cp -fL ${pkgs.writeText "agentbox-cell-entry" cellScript} ${configDir}/cell-entry
      chmod 0755 ${configDir}/cell-entry
      sed '1s|^#!.*|#!/usr/bin/env bash|; /^export PATH=/d' ${workflow.repos}/bin/repos > ${configDir}/bin/repos
      chmod 0755 ${configDir}/bin/repos
      sed '1s|^#!.*|#!/usr/bin/env bash|; /^export PATH=/d' ${workflow.worktrees}/bin/worktrees > ${configDir}/bin/worktrees
      chmod 0755 ${configDir}/bin/worktrees
      chmod -R u+w ${configDir}
    '';

    # Linux only: update the symlink farm in place. Preserving the
    # dir inode keeps the running bindfs daemon's cwd valid, so reads
    # keep succeeding with no restart and no disruption to in-flight
    # VMs. Stale links (removed entries) are pruned by scanning the
    # dir against the current entry set.
    home.activation.agentboxHostLinks = lib.mkIf isLinux (
      lib.hm.dag.entryAfter [ "writeBoundary" "setupAgentboxDirs" "syncAgentboxConfig" ] ''
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
    # (agentboxHostLinks) without restarting this service, since a restart
    # would disrupt in-flight VMs with a brief empty-read window.
    # fusermount3 from a user service lacks the setuid bit needed to
    # unmount a stale FUSE mount, so we rely on clean shutdown.
    systemd.user.services.agentbox-bindfs = lib.mkIf isLinux {
      Unit = {
        Description = "bindfs symlink-farm mount for agentbox VMs";
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
