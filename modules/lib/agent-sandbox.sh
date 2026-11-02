#!/usr/bin/env bash
# agent-sandbox: same-UID, unprivileged path/privilege boundary for an agent
# harness. Linux uses bwrap; macOS uses sandbox-exec. The config is sourced
# from AGENT_SANDBOX_CONFIG; see modules/lib/agent-sandbox.nix.
#
# This is a path boundary, not a kernel boundary. The agent keeps the user's
# UID; the boundary is enforced by a mount namespace (Linux) or Seatbelt
# (macOS), plus PR_SET_NO_NEW_PRIVS, and it applies to every descendant.

set -euo pipefail
# shellcheck source=/dev/null
source "${AGENT_SANDBOX_CONFIG:?AGENT_SANDBOX_CONFIG is not set}"

if [ "$#" -lt 1 ]; then
  echo "usage: agent-sandbox <command> [args...]" >&2
  exit 2
fi

home=$HOME
agent_config="$home/.local/state/agent/config"
# Only the agent profile keeps git/ssh plumbing in this private config dir; the
# minimal profiles (the Jupyter kernel) have none to create or protect.
if [ -n "${AGENT_CONFIG_DIR:-}" ]; then
  if [ -L "$agent_config" ]; then
    echo "agent-sandbox: refusing a symlinked agent config dir: $agent_config" >&2
    exit 1
  fi
  mkdir -p \
    "$agent_config" \
    "$agent_config/bin" \
    "$home/.cache/agent" \
    "$home/.local/share/agent" \
    "$home/.local/state/agent"
fi

# Start in the caller's directory when it is inside a writable allowlist
# entry; otherwise start at HOME. A coding agent works from HOME fine.
start=$home
for d in "${HOME_RW[@]}"; do
  case "$PWD" in
    "$d" | "$d"/*)
      start=$PWD
      break
      ;;
  esac
done

read_secret() {
  local var=$1 file=$2
  if [ -r "$file" ]; then
    printf -v "$var" '%s' "$(cat "$file")"
    # shellcheck disable=SC2163 # $var is the variable name
    export "$var"
  fi
}

# The signing agent is the only credential the sandbox gets. Pick the first
# socket that exists; with none, SSH/signing fail closed.
signing_sock=
for sock in "${SIGNING_SOCKETS[@]}"; do
  if [ -S "$sock" ]; then
    signing_sock=$sock
    break
  fi
done

# Secrets promoted into the sandbox environment, each read from a host file the
# descendant cannot see itself. The minimal profiles declare none.
for pair in "${SECRET_READ[@]}"; do
  read_secret "${pair%%|*}" "${pair#*|}"
done

# Darwin has no mount namespace and no private /tmp. Copy the selected
# configs into the agent-only config dir; the profile denies the real
# ~/.config. Linux binds them read-only instead.
prepare_darwin_config() {
  local name src dest
  for name in "${CONFIG_ALLOW[@]}"; do
    src="$home/.config/$name"
    dest="$agent_config/$name"
    [ -e "$src" ] || continue
    rm -rf "$dest"
    cp -a "$src" "$dest"
  done
  rm -f "$agent_config/allowed_signers" "$agent_config/known_hosts" "$agent_config/gitconfig" "$agent_config/ssh_config"
  if [ -r "$home/.config/ssh/allowed_signers" ]; then
    cp "$home/.config/ssh/allowed_signers" "$agent_config/allowed_signers"
  fi
  if [ -r "$home/.config/ssh/known_hosts" ]; then
    cp "$home/.config/ssh/known_hosts" "$agent_config/known_hosts"
  fi
  cp "$AGENT_GIT_CONFIG" "$agent_config/gitconfig"
  cp "$AGENT_SSH_CONFIG" "$agent_config/ssh_config"
  if [ -L "$agent_config/bin" ]; then
    echo "agent-sandbox: refusing a symlinked config bin dir" >&2
    exit 1
  fi
  mkdir -p "$agent_config/bin"
  rm -f "$agent_config/bin/ssh" "$agent_config/bin/gh" "$agent_config/bin/gpg-ssh-default-key" "$agent_config/bin/agent-sandbox-git-credential"
  cp "$AGENT_SSH_SHIM" "$agent_config/bin/ssh"
  cp "$AGENT_GH_SHIM" "$agent_config/bin/gh"
  cp "$AGENT_SIGNING_KEY_COMMAND" "$agent_config/bin/gpg-ssh-default-key"
  chmod 755 "$agent_config/bin/"*
}

add_env() {
  local name=$1
  if [ -n "${!name:-}" ]; then
    ENV_ARGS+=("$name=${!name}")
  fi
}

build_env_args() {
  ENV_ARGS=(
    "HOME=$home"
    "USER=${USER:-smores}"
    "LOGNAME=${LOGNAME:-${USER:-smores}}"
    "PWD=$start"
    "PATH=$agent_config/bin:$home/.local/bin:$home/.nix-profile/bin:$home/.cargo/bin:$home/.bun/bin:$home/.deno/bin:$home/.wasmer/bin:$AGENT_SANDBOX_PATH"
    "TMPDIR=/tmp"
    "SHELL=/bin/sh"
    # maki derives its log dir from the parent of the state dir (logs_dir =
    # parent(XDG_STATE_HOME)/logs/maki), so keep the state one level down:
    # state and logs both land under the writable agent state.
    "XDG_STATE_HOME=$home/.local/state/agent/state"
    "XDG_CACHE_HOME=$home/.cache/agent"
    "XDG_DATA_HOME=$home/.local/share/agent"
    "XDG_CONFIG_HOME=$agent_config"
    "XDG_RUNTIME_DIR=/run/agent/runtime"
    "GH_CONFIG_DIR=$home/.cache/agent/gh"
    "GIT_CONFIG_GLOBAL=$agent_config/gitconfig"
    "GIT_CONFIG_SYSTEM=/dev/null"
    # Keep pre-commit hook environments out of the shared ~/.cache: a hook it
    # writes there would run for the human outside the sandbox.
    "PRE_COMMIT_HOME=$home/.cache/agent/pre-commit"
  )
  # Profile overrides go last: `env -i` and bwrap --setenv both let a later
  # assignment win, so a profile can retarget PATH and the XDG dirs.
  ENV_ARGS+=("${ENV_EXTRA[@]}")
  add_env TERM
  add_env COLORTERM
  add_env LANG
  add_env LC_ALL
  add_env LC_CTYPE
  add_env LC_MESSAGES
  add_env TZ
  add_env NIX_PATH
  add_env NEURALWATT_API_KEY
  add_env TINYFISH_API_KEY
  add_env IMMICH_API_KEY
  add_env OPENAI_API_KEY
  # Profile-declared names to carry across the boundary as-is; the minimal
  # Jupyter profile uses it for the token its launcher reads from the sops file.
  for name in "${ENV_PASSTHROUGH[@]}"; do
    add_env "$name"
  done
  # GH_TOKEN is never inherited: the gh wrapper and git helper inside select a
  # PAT by the target repository's owner, and a caller's token would defeat
  # that split.
  if [ -n "$signing_sock" ]; then
    ENV_ARGS+=("SSH_AUTH_SOCK=/run/agent/sign")
  fi
}

if [ "$(uname -s)" = Darwin ]; then
  command -v /usr/bin/sandbox-exec >/dev/null 2>&1 || {
    echo "agent-sandbox: /usr/bin/sandbox-exec is missing" >&2
    exit 1
  }
  # The OpenAI key is a Keychain item on the work Mac. Read it here, outside
  # the sandbox; SecurityAgent/securityd are denied inside.
  if [ -z "${OPENAI_API_KEY:-}" ] && [ -n "${OPENAI_KEYCHAIN_ITEM:-}" ]; then
    OPENAI_API_KEY=$(/usr/bin/security find-generic-password -s "$OPENAI_KEYCHAIN_ITEM" -w 2>/dev/null) || OPENAI_API_KEY=
    export OPENAI_API_KEY
  fi
  prepare_darwin_config
  build_env_args

  profile=$(mktemp "${TMPDIR:-/tmp}/agent-sandbox.XXXXXX.sbpl")
  trap 'rm -f "$profile"' EXIT
  {
    echo '(version 1)'
    echo '(deny default)'
    echo '(allow process-exec (subpath "/nix/store") (subpath "/bin") (subpath "/usr/bin") (subpath "/usr/sbin") (subpath "/usr/local") (subpath "/opt/homebrew") (subpath "/Library/Developer") (subpath "'"$home/.local/bin"'") (subpath "'"$agent_config/bin"'"))'
    echo "(allow process-exec (subpath \"$home/.cargo/bin\") (subpath \"$home/.bun/bin\") (subpath \"$home/.deno/bin\") (subpath \"$home/.wasmer/bin\"))"
    for exe in "${EXEC_DENY[@]}"; do
      echo "(deny process-exec (literal \"/usr/bin/$exe\"))"
      echo "(deny process-exec (literal \"/bin/$exe\"))"
    done
    echo "(allow file-read* (subpath \"$home\"))"
    for d in "${HOME_MASK_DIRS[@]}"; do
      echo "(deny file-read* (subpath \"$d\"))"
    done
    for f in "${HOME_MASK_FILES[@]}"; do
      echo "(deny file-read* (literal \"$f\"))"
    done
    # macOS 27 aborts every process (SIGABRT, no logged denial) unless the root
    # directory itself is readable; the literal grants nothing beneath it. Nix
    # binaries load their dylibs from the store, so it must be readable too
    # (store paths are world-readable build outputs, never secrets). /var is the
    # root symlink to /private/var that sops-nix's link chain crosses.
    echo '(allow file-read* (literal "/") (literal "/var") (subpath "/nix/store") (subpath "/System") (subpath "/Library") (subpath "/usr") (subpath "/bin") (subpath "/private/etc") (subpath "/private/var/db") (subpath "/dev") (literal "/tmp") (subpath "/tmp") (subpath "/private/tmp") (subpath "'"${TMPDIR:-/tmp}"'"))'
    echo "(allow file-write* (literal \"/dev/null\") (literal \"/dev/tty\") (subpath \"/tmp\") (subpath \"/private/tmp\") (subpath \"${TMPDIR:-/tmp}\"))"
    # The TMPDIR rules above name /var/folders, which Seatbelt never matches (it
    # sees the resolved /private/var/folders), and sops-nix decrypts into that
    # same directory. Deny its secrets explicitly so widening those rules can
    # never expose them, then allow only the listed links' resolved files plus
    # the symlink nodes their chain crosses (sops-nix links through the masked
    # ~/.config/sops-nix/secrets); later rules win. Listing stays denied because
    # the directory resolves into the denied secrets.d.
    echo '(deny file-read* file-write* (regex #"^/private/var/folders/.+/secrets\.d/"))'
    for d in "${DARWIN_SECRET_LINK_DIRS[@]}"; do
      for link in "$d"/*; do
        [ -L "$link" ] || continue
        target=$(realpath "$link" 2>/dev/null) || continue
        echo "(allow file-read* (literal \"$target\"))"
        hop=$(readlink "$link")
        while [ -n "$hop" ] && [ "$hop" != / ]; do
          if [ -L "$hop" ]; then
            echo "(allow file-read* (literal \"$hop\"))"
          fi
          hop=$(dirname "$hop")
        done
      done
    done
    for d in "${HOME_RW[@]}"; do
      echo "(allow file-write* (subpath \"$d\"))"
    done
    echo "(allow file-write* (subpath \"$agent_config\"))"
    for d in "${HOME_RO[@]}"; do
      echo "(deny file-write* (subpath \"$d\"))"
    done
    echo '(allow sysctl-read)'
    echo '(allow process-info* (target same-sandbox))'
    echo '(allow signal (target same-sandbox))'
    echo '(allow pseudo-tty)'
    echo '(allow process-fork)'
    echo '(allow network*)'
    echo '(deny file-read* file-write* (subpath "/private/tmp/com.apple.launchd"))'
    echo "(deny file-read* file-write* (subpath \"${TMPDIR:-/tmp}/com.apple.launchd\"))"
    for svc in "${MACH_ALLOW[@]}"; do
      echo "(allow mach-lookup (global-name \"$svc\"))"
    done
    echo '(deny appleevent-send)'
    echo '(deny lsopen)'
    echo '(deny job-creation)'
    echo '(deny file-write-mount file-write-unmount)'
    # Repo metadata that can execute or redirect commands outside the sandbox:
    # hooks, config/hooksPath, and a worktree's .git file.
    echo '(deny file-write* (regex #"/\.git/(hooks(/.*)?|config(\.worktree)?)$"))'
    echo '(deny file-write* (regex #"/\.git$"))'
    echo '(deny mach-lookup (global-name "com.apple.securityd.xpc") (global-name "com.apple.SecurityServer") (global-name "com.apple.launchd") (global-name-prefix "com.apple.xpc.launchd") (global-name "com.apple.coreservices.appleevents") (global-name "com.apple.CoreServices.coreservicesd") (global-name "com.apple.tccd"))'
  } >"$profile"

  exec /usr/bin/sandbox-exec -f "$profile" /usr/bin/env -i "${ENV_ARGS[@]}" "$@"
fi

# Linux
build_env_args
args=(
  --die-with-parent
  --new-session
  --unshare-pid
  --unshare-ipc
  --unshare-uts
  --unshare-cgroup
  --unshare-user
  --cap-drop ALL
  --clearenv
  --proc /proc
  --dev /dev
  --tmpfs /tmp
  --tmpfs /run
  --dir /run/secrets
  --dir /run/agent
  --dir /run/agent/runtime
  --ro-bind /nix/store /nix/store
  --ro-bind /etc /etc
  --ro-bind /bin /bin
  --ro-bind-try /usr /usr
  --ro-bind "$home" "$home"
)

# `store = auto` picks a LocalStore when it can write the state dir, and bwrap
# creates that dir writable in its tmpfs, so every store-touching eval would
# take lock files inside the read-only store and fail. Bind the host dir (which
# carries the daemon socket) read-only so the client resolves to the daemon. A
# host without a daemon keeps the ephemeral local store instead.
if [ -S /nix/var/nix/daemon-socket/socket ]; then
  args+=(--ro-bind /nix/var/nix /nix/var/nix)
fi

for d in "${HOME_RW[@]}"; do
  args+=(--bind-try "$d" "$d")
done

# Existing repos keep their auto-execution surfaces read-only: .git/hooks and
# .git/config cannot be written, and a worktree's .git file (which names
# gitdir) cannot be repointed. Repos created inside the sandbox are not in the
# scan, so their metadata stays writable; that is the accepted "agent-created
# repos are reviewed" case. Renaming an existing .git still moves the ro
# mountpoints with it, so this raises the bar rather than closing the same-UID
# boundary.
protect_repos() {
  local -a roots=()
  local root entry gitdir common
  for root in "${HOME_RW[@]}"; do
    case "$root" in
      "$home/code" | "$home/dev" | "$home/Documents" | "$home/Downloads") roots+=("$root") ;;
    esac
  done
  [ "${#roots[@]}" -gt 0 ] || return 0
  while IFS= read -r -d '' entry; do
    if [ -d "$entry" ]; then
      gitdir=$entry
    else
      gitdir=$(sed -n 's/^gitdir: //p' "$entry")
      [ -n "$gitdir" ] || continue
      args+=(--ro-bind "$entry" "$entry")
      common=$(git -C "${entry%/.git}" rev-parse --git-common-dir 2>/dev/null) || common=$gitdir
      case "$common" in
        /*) ;;
        *) common="${entry%/.git}/$common" ;;
      esac
      gitdir=$common
    fi
    if [ -d "$gitdir/hooks" ]; then
      args+=(--ro-bind "$gitdir/hooks" "$gitdir/hooks")
    else
      args+=(--ro-bind "$EMPTY_DIR" "$gitdir/hooks")
    fi
    if [ -f "$gitdir/config" ]; then
      args+=(--ro-bind "$gitdir/config" "$gitdir/config")
    fi
    if [ -f "$gitdir/config.worktree" ]; then
      args+=(--ro-bind "$gitdir/config.worktree" "$gitdir/config.worktree")
    fi
  done < <(
    find "${roots[@]}" -maxdepth 8 \
      \( -name node_modules -o -name target -o -name .direnv -o -name dist -o -name .venv \) -prune -o \
      -name .git -prune -print0 2>/dev/null
  )
}
protect_repos

for d in "${HOME_RO[@]}"; do
  args+=(--ro-bind-try "$d" "$d")
done

# Config allowlist: read-only copies inside the agent config dir. Bind before
# the ~/.config mask so bwrap resolves the source from the host tree.
for name in "${CONFIG_ALLOW[@]}"; do
  src="$home/.config/$name"
  dest="$agent_config/$name"
  if [ -e "$src" ]; then
    args+=(--ro-bind "$src" "$dest")
  fi
done

# Writable exceptions inside a read-only config entry. The destination must
# exist before the read-only dir is mounted, so create the host's sidecar if
# it is missing (maki creates the same empty lock file itself); the writable
# copy lives in the agent state and is bound over it.
for rel in "${CONFIG_WRITABLE[@]}"; do
  hostfile="$home/.config/$rel"
  if [ ! -e "$hostfile" ]; then
    [ -d "$(dirname "$hostfile")" ] || continue
    : >"$hostfile" 2>/dev/null || continue
  fi
  src="$home/.local/state/agent/config-rw/$rel"
  dest="$agent_config/$rel"
  mkdir -p "$(dirname "$src")"
  [ -e "$src" ] || : >"$src"
  args+=(--bind "$src" "$dest")
done

for d in "${HOME_MASK_DIRS[@]}"; do
  # A missing path has nothing to expose; creating a mountpoint under the
  # read-only home would fail.
  [ -d "$d" ] && args+=(--tmpfs "$d")
done
for f in "${HOME_MASK_FILES[@]}"; do
  # --file cannot create a mountpoint under a read-only home. A read-only
  # /dev/null bind denies the file (reads are empty or EPERM); it is still a mask.
  [ -e "$f" ] && args+=(--ro-bind /dev/null "$f")
done

for pair in "${SECRET_BIND[@]}"; do
  src=${pair%%|*}
  dest=${pair#*|}
  if [ -r "$src" ]; then
    args+=(--dir "$(dirname "$dest")" --ro-bind "$src" "$dest")
  fi
done

if [ -n "$signing_sock" ]; then
  args+=(--ro-bind "$signing_sock" /run/agent/sign)
fi
if [ -r "${CLOUDFLARED_TOKEN:-/nonexistent}" ]; then
  args+=(--dir /run/agent/runtime/cloudflared-access --ro-bind "$CLOUDFLARED_TOKEN" /run/agent/runtime/cloudflared-access/token)
fi

if [ -n "${AGENT_CONFIG_DIR:-}" ]; then
  args+=(
    --ro-bind "$AGENT_GIT_CONFIG" "$agent_config/gitconfig"
    --ro-bind "$AGENT_SSH_CONFIG" "$agent_config/ssh_config"
    --ro-bind "$AGENT_SIGNING_KEY_COMMAND" "$agent_config/bin/gpg-ssh-default-key"
    --ro-bind "$AGENT_SSH_SHIM" "$agent_config/bin/ssh"
    --ro-bind "$AGENT_GH_SHIM" "$agent_config/bin/gh"
  )
  if [ -r "$home/.config/ssh/allowed_signers" ]; then
    args+=(--ro-bind "$home/.config/ssh/allowed_signers" "$agent_config/allowed_signers")
  fi
  if [ -r "$home/.config/ssh/known_hosts" ]; then
    args+=(--ro-bind "$home/.config/ssh/known_hosts" "$agent_config/known_hosts")
  fi
fi

for e in "${ENV_ARGS[@]}"; do
  args+=(--setenv "${e%%=*}" "${e#*=}")
done

args+=(--chdir "$start" -- "$@")
exec "$AGENT_SANDBOX_BWRAP" "${args[@]}"
