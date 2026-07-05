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
  ompAgent = "${config.home.homeDirectory}/.omp/agent";
  worktrunkConfig = "${config.home.homeDirectory}/.config/worktrunk";

  tomlFormat = pkgs.formats.toml { };
  jqBin = "${lib.getBin pkgs.jq}/bin/jq";
  smolvmBin = "${pkgs.smolvm}/bin/smolvm";
  image = "cgr.dev/chainguard/wolfi-base";
  worktrunkVersion = "0.65.0";
  ghqVersion = "1.10.1";

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
    "BUN_INSTALL=/root/.bun"
    "MAKI_INSTALL_DIR=/root/.local/bin"
    "MISE_DATA_DIR=/root/.local/share/mise"
    "CARGO_TARGET_DIR=/root/.cargo-target"
    # mise shims first → per-repo pins override the shared bin mount;
    # then shared bin (maki/gh/mise), then /root/.bun/bin (omp global
    # shim). The latter two live in the overlay.
    "PATH=/root/.local/share/mise/shims:/root/.local/bin:/root/.bun/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
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
      link = "omp-agent";
      hostPath = ompAgent;
      guestPath = "/root/.omp/agent";
    }
    {
      link = "worktrunk-config";
      hostPath = worktrunkConfig;
      guestPath = "/root/.config/worktrunk";
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
  # into /root so runtime rewrites work. omp/maki config/state are
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
    export BUN_INSTALL=/root/.bun
    export MISE_DATA_DIR=/root/.local/share/mise
    export PATH="/root/.local/share/mise/shims:/root/.local/bin:/root/.bun/bin:$PATH"

    ${lib.optionalString isLinux guestSymlinks}

    ${syncConfig}

    # System packages. python-3 is required by omp's Python eval
    # backend; bash by mise's python backend; curl by rustup-init and
    # the gh/mise/maki installers below. apk indexes don't persist
    # across VM resets, so update is always run.
    apk info -e git openssh-client ca-certificates python-3 bash curl unzip xz >/dev/null 2>&1 || {
      apk update -q
      apk add -q git openssh-client ca-certificates python-3 bash curl unzip xz
    }

    # Worktree/repo tools into the shared bin mount (persists on host).
    case "$(uname -m)" in
      x86_64) worktrunk_target=x86_64-unknown-linux-musl; ghq_target=amd64 ;;
      aarch64|arm64) worktrunk_target=aarch64-unknown-linux-musl; ghq_target=arm64 ;;
      *) echo "unsupported agentbox arch: $(uname -m)" >&2; exit 1 ;;
    esac

    if ! /root/.local/bin/wt --version 2>/dev/null | grep -q ${lib.escapeShellArg worktrunkVersion}; then
      tmp=$(mktemp -d)
      curl -fsSL "https://github.com/max-sixty/worktrunk/releases/download/v${worktrunkVersion}/worktrunk-''${worktrunk_target}.tar.xz" \
        | tar -xJ -C "$tmp"
      install -m 0755 "$tmp/worktrunk-''${worktrunk_target}/wt" /root/.local/bin/wt
      install -m 0755 "$tmp/worktrunk-''${worktrunk_target}/git-wt" /root/.local/bin/git-wt
      rm -rf "$tmp"
    fi

    if ! /root/.local/bin/ghq --version 2>/dev/null | grep -q ${lib.escapeShellArg ghqVersion}; then
      tmp=$(mktemp -d)
      curl -fsSL "https://github.com/x-motemen/ghq/releases/download/v${ghqVersion}/ghq_linux_''${ghq_target}.zip" -o "$tmp/ghq.zip"
      unzip -q "$tmp/ghq.zip" -d "$tmp"
      install -m 0755 "$tmp/ghq_linux_''${ghq_target}/ghq" /root/.local/bin/ghq
      rm -rf "$tmp"
    fi

    install -m 0755 /mnt/host-config/bin/git-branch-prefix /root/.local/bin/git-branch-prefix
    install -m 0755 /mnt/host-config/bin/agent-branch-name /root/.local/bin/agent-branch-name

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
    # binary lands in the shared bin mount (host-persistent). Global
    # bun packages (omp) go to /root/.bun (BUN_INSTALL), also in the
    # overlay — BUN_INSTALL pins where global packages + bin shims live
    # so omp survives a bun version bump within mise.
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

    # omp (bun global install) into /root/.bun (BUN_INSTALL, overlay).
    # The bun runtime itself is mise-managed; BUN_INSTALL pins where
    # global packages + bin shims live so omp survives a bun version bump.
    if ! command -v omp >/dev/null 2>&1; then
      /root/.local/share/mise/shims/bun add -g @oh-my-pi/pi-coding-agent
    fi

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

  # Snapshot version: regenerates only when inputs that affect the
  # snapshot's installed state change. Captured at Nix eval time and
  # baked into the launcher, so no `nix` calls in the launcher path.
  # Changes to baseProvisionScript, defaultMiseConfig, image, or the
  # smolvm package version bump the version and trigger lazy regen.
  # All inputs must be strings — derivations don't coerce for hashing.
  snapshotVersion = builtins.substring 0 12 (
    builtins.hashString "sha256" (
      baseProvisionScript + (lib.fileContents defaultMiseConfig) + image + pkgs.smolvm.version
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
        $smolvm machine create "$base_tmp" --smolfile ${smolfile} >&2
        $smolvm machine start --name "$base_tmp" >&2
        $smolvm machine exec --name "$base_tmp" -- /bin/sh -c ${lib.escapeShellArg baseProvisionScript} >&2
        $smolvm machine stop --name "$base_tmp" >&2
        # pack create emits <output> (stub) + <output>.smolmachine
        # (sidecar). machine create --from needs the sidecar. Stage
        # both as base.tmp(+.smolmachine), then atomically rename to
        # the versioned names so a concurrent reader never sees a
        # half-written snapshot.
        $smolvm pack create --from-vm "$base_tmp" --output "$snapshot_dir/base.tmp" >&2
        $smolvm machine delete "$base_tmp" -f >&2
        mv "$snapshot_dir/base.tmp.smolmachine" "$snapshot"
        rm -f "$snapshot_dir/base.tmp"
        # Best-effort prune: keep only the just-regenerated version.
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

  launcher = pkgs.writeShellScriptBin "agentbox" ''
    set -euo pipefail

    smolvm=${smolvmBin}
    name="agentbox"

    while [ $# -gt 0 ]; do
      case "$1" in
        --name)
          name="$2"
          shift 2
          ;;
        --name=*)
          name="''${1#--name=}"
          shift
          ;;
        --)
          shift
          break
          ;;
        *)
          break
          ;;
      esac
    done

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
  options.dotfiles.smolvm = {
    enable = lib.mkEnableOption "agentbox sandbox for coding agents (maki/omp)" // {
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
    '';

    # Stage Nix-managed config (git/gh/ssh/mise) into a dir mounted ro
    # (Darwin) or via the bindfs symlink farm (Linux). Private ssh keys
    # are never staged — only config, *.pub and known_hosts. gh's
    # hosts.yml (oauth token) is excluded: the launcher forwards
    # GH_TOKEN instead. omp agent/{config.yml,models.yml,AGENTS.md,
    # mcp.json,skills,extensions} are bindfs rw-mounted directly from
    # ~/.omp/agent (see entries list) — no staging needed.
    home.activation.syncAgentboxConfig = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      rm -rf ${configDir}
      mkdir -p ${configDir}/git ${configDir}/gh ${configDir}/ssh ${configDir}/mise ${configDir}/bin
      cp -rL \${config.home.homeDirectory}/.config/git/config ${configDir}/git/ 2>/dev/null || true
      cp -rL \${config.home.homeDirectory}/.config/gh/config.yml ${configDir}/gh/ 2>/dev/null || true
      cp -rL \${config.home.homeDirectory}/.config/ssh/config ${configDir}/ssh/ 2>/dev/null || true
      cp -rL \${config.home.homeDirectory}/.ssh/*.pub ${configDir}/ssh/ 2>/dev/null || true
      cp -rL \${config.home.homeDirectory}/.ssh/known_hosts ${configDir}/ssh/ 2>/dev/null || true
      cp -fL ${defaultMiseConfig} ${configDir}/mise/config.toml
      sed '1s|^#!.*|#!/usr/bin/env bash|; /^export PATH=/d' ${
        pkgs.writeShellApplication {
          name = "git-branch-prefix";
          runtimeInputs = [ pkgs.git ];
          text = ''
            WORK_ORGS=(${lib.escapeShellArgs config.dotfiles.work.githubOrgs})
            PERSONAL_PREFIX=${lib.escapeShellArg config.dotfiles.branchPrefix}
            WORK_PREFIX=${lib.escapeShellArg (toString (config.dotfiles.work.branchPrefix or ""))}
            TICKET_PREFIX=${lib.escapeShellArg (toString (config.dotfiles.work.ticketPrefix or ""))}

            origin_org() {
              local url path
              url=$(git remote get-url origin 2>/dev/null) || url=""
              case "$url" in
                git@github.com:*) path=''${url#git@github.com:} ;;
                ssh://git@github.com/*) path=''${url#ssh://git@github.com/} ;;
                https://github.com/*) path=''${url#https://github.com/} ;;
                http://github.com/*) path=''${url#http://github.com/} ;;
                *) path="" ;;
              esac
              printf '%s' "''${path%%/*}"
            }

            is_work_repo() {
              local org w
              org=$(origin_org)
              [ -n "$org" ] || return 1
              for w in ''${WORK_ORGS[@]+"''${WORK_ORGS[@]}"}; do
                [ "$org" = "$w" ] && return 0
              done
              return 1
            }

            if is_work_repo; then
              if [ -n "$WORK_PREFIX" ]; then prefix=$WORK_PREFIX; else prefix=$PERSONAL_PREFIX; fi
              if [ -n "$TICKET_PREFIX" ]; then printf '%s/%s-' "$prefix" "$TICKET_PREFIX"; else printf '%s/' "$prefix"; fi
            else
              printf '%s/' "$PERSONAL_PREFIX"
            fi
          '';
        }
      }/bin/git-branch-prefix > ${configDir}/bin/git-branch-prefix
      chmod 0755 ${configDir}/bin/git-branch-prefix
      sed '1s|^#!.*|#!/usr/bin/env bash|; /^export PATH=/d' ${
        pkgs.writeShellApplication {
          name = "agent-branch-name";
          runtimeInputs = [
            pkgs.git
            pkgs.coreutils
            pkgs.gnused
          ];
          text = ''
            WORK_ORGS=(${lib.escapeShellArgs config.dotfiles.work.githubOrgs})
            PERSONAL_PREFIX=${lib.escapeShellArg config.dotfiles.branchPrefix}
            WORK_PREFIX=${lib.escapeShellArg (toString (config.dotfiles.work.branchPrefix or ""))}
            TICKET_PREFIX=${lib.escapeShellArg (toString (config.dotfiles.work.ticketPrefix or ""))}

            origin_org() {
              local url path
              url=$(git remote get-url origin 2>/dev/null) || url=""
              case "$url" in
                git@github.com:*) path=''${url#git@github.com:} ;;
                ssh://git@github.com/*) path=''${url#ssh://git@github.com/} ;;
                https://github.com/*) path=''${url#https://github.com/} ;;
                http://github.com/*) path=''${url#http://github.com/} ;;
                *) path="" ;;
              esac
              printf '%s' "''${path%%/*}"
            }

            is_work_repo() {
              local org w
              org=$(origin_org)
              [ -n "$org" ] || return 1
              for w in ''${WORK_ORGS[@]+"''${WORK_ORGS[@]}"}; do
                [ "$org" = "$w" ] && return 0
              done
              return 1
            }

            work_branch_prefix() {
              if [ -n "$WORK_PREFIX" ]; then printf '%s' "$WORK_PREFIX"; else printf '%s' "$PERSONAL_PREFIX"; fi
            }

            slug=""
            task=""
            ticket=""
            dry_run=false
            while [ $# -gt 0 ]; do
              case "$1" in
                --slug) slug=$2; shift 2 ;;
                --task) task=$2; shift 2 ;;
                --ticket) ticket=$2; shift 2 ;;
                --dry-run) dry_run=true; shift ;;
                *) printf 'agent-branch-name: unknown arg: %s\n' "$1" >&2; exit 2 ;;
              esac
            done

            slugify() {
              printf '%s' "$1" \
                | tr '[:upper:]' '[:lower:]' \
                | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//' \
                | cut -c1-50 \
                | sed -E 's/-+$//'
            }

            if [ -z "$slug" ]; then
              [ -n "$task" ] || { printf 'agent-branch-name: --slug or --task required\n' >&2; exit 2; }
              clean=$(printf '%s' "$task" | tr '[:upper:]' '[:lower:]')
              if [ -n "$TICKET_PREFIX" ]; then
                tp_lower=$(printf '%s' "$TICKET_PREFIX" | tr '[:upper:]' '[:lower:]')
                clean=$(printf '%s' "$clean" | sed -E "s/$tp_lower-[0-9]+//g")
              fi
              slug=$(slugify "$clean")
            fi
            [ -n "$slug" ] || { printf 'agent-branch-name: empty slug\n' >&2; exit 2; }

            if ! is_work_repo; then
              printf '%s/%s\n' "$PERSONAL_PREFIX" "$slug"
              exit 0
            fi

            if [ -z "$ticket" ] && [ -n "$task" ] && [ -n "$TICKET_PREFIX" ]; then
              ticket=$(printf '%s' "$task" | grep -oiE "$TICKET_PREFIX-[0-9]+" | head -1 || true)
            fi

            if [ -z "$ticket" ] && [ -n "$TICKET_PREFIX" ]; then
              if $dry_run; then
                ticket="$TICKET_PREFIX-DRYRUN"
              else
                title=$task
                [ -n "$title" ] || title=$slug
                created=$(linear issue create -t "$title" --team "$TICKET_PREFIX" --assignee self --start --no-interactive 2>&1) || {
                  printf 'agent-branch-name: linear issue create failed:\n%s\n' "$created" >&2
                  exit 1
                }
                ticket=$(printf '%s' "$created" | grep -oiE "$TICKET_PREFIX-[0-9]+" | head -1 || true)
                [ -n "$ticket" ] || {
                  printf 'agent-branch-name: could not parse ticket id from linear output:\n%s\n' "$created" >&2
                  exit 1
                }
              fi
            fi

            if [ -n "$ticket" ]; then
              printf '%s/%s-%s\n' "$(work_branch_prefix)" "$ticket" "$slug"
            else
              printf '%s/%s\n' "$(work_branch_prefix)" "$slug"
            fi
          '';
        }
      }/bin/agent-branch-name > ${configDir}/bin/agent-branch-name
      chmod 0755 ${configDir}/bin/agent-branch-name
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
