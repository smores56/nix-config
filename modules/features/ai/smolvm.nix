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

  isLinux = pkgs.stdenv.isLinux;
  smolfileVolumes = if isLinux then linuxVolumes else darwinVolumes;

  smolfile = tomlFormat.generate "agentbox.smolfile" {
    inherit image;
    net = true;
    cpus = 4;
    memory = 8192;
    overlay = 20;
    # Forwards the host ssh-agent socket into the VM, so git push (ssh)
    # and ssh-format commit signing work without exposing private keys.
    auth.ssh_agent = true;
    env = [
      "BUN_INSTALL=/root/.bun"
      "MAKI_INSTALL_DIR=/root/.local/bin"
      "MISE_DATA_DIR=/root/.local/share/mise"
      # mise shims first → per-repo pins override the shared bin mount;
      # then shared bin (maki/gh/mise), then /root/.bun/bin (omp global
      # shim). The latter two live in the overlay.
      "PATH=/root/.local/share/mise/shims:/root/.local/bin:/root/.bun/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
    ];
    volumes = smolfileVolumes;
  };

  # Idempotent provisioning run inside the VM on every start. mise installs
  # the bun runtime and the default global toolset (rust/just/python/deno)
  # into the overlay (MISE_DATA_DIR). Global bun packages (omp) go to
  # /root/.bun (BUN_INSTALL), also in the overlay — both persist across
  # VM restarts but not across VM delete/recreate. maki + gh + the mise
  # binary itself live in the shared bin mount (host-persistent).
  provisionScript = ''
    set -e
    export BUN_INSTALL=/root/.bun
    export MISE_DATA_DIR=/root/.local/share/mise
    export PATH="/root/.local/share/mise/shims:/root/.local/bin:/root/.bun/bin:$PATH"

    ${lib.optionalString isLinux guestSymlinks}

    # Nix-managed config (git/gh/ssh/mise) staged into the overlay via
    # `cp -rL` so they can rewrite at runtime. omp agent/ (~/.omp/agent)
    # and maki config/state are bindfs-mounted directly — no staging.
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

  # Shared create-or-start-or-provision snippet, inlined into the
  # launcher. Serialized under flock so concurrent agentbox invocations
  # (e.g. several spawn_session calls in one batch) don't race on
  # `machine create`/`machine start`/provision and wedge the VM
  # (which would EIO-kill every spawned Zellij tab). The final
  # interactive `machine exec` runs outside the lock so it never blocks
  # on a sibling's session.
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

    if ! $smolvm machine status --name "$name" >/dev/null 2>&1; then
      $smolvm machine create "$name" --smolfile ${smolfile}
    fi

    state=$($smolvm machine status --name "$name" --json 2>/dev/null \
      | ${jqBin} -r '.state')
    [ "$state" = running ] || $smolvm machine start --name "$name" >/dev/null

    $smolvm machine exec --name "$name" -- /bin/sh -c ${lib.escapeShellArg provisionScript}

    exec 9>&-
  '';

  launcher = pkgs.writeShellScriptBin "agentbox" ''
    set -euo pipefail

    smolvm=${smolvmBin}
    name="agentbox"

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
      cp -rL \${config.home.homeDirectory}/.ssh/config ${configDir}/ssh/ 2>/dev/null || true
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
