#!/usr/bin/env bash
# agent-sandbox: same-UID path/privilege boundary for an agent harness (bwrap on Linux,
# sandbox-exec on macOS), configured via AGENT_SANDBOX_CONFIG (modules/lib/agent-sandbox.nix).
# Not a kernel boundary: the agent keeps the user's UID; the mount namespace/Seatbelt plus
# PR_SET_NO_NEW_PRIVS applies to every descendant.

set -euo pipefail
# shellcheck source=/dev/null
source "${AGENT_SANDBOX_CONFIG:?AGENT_SANDBOX_CONFIG is not set}"

if [ "$#" -lt 1 ]; then
  echo "usage: agent-sandbox <command> [args...]" >&2
  exit 2
fi

home=$HOME
agent_config="$home/.local/state/agent/config"
# Only the agent profile keeps git/ssh plumbing here; minimal profiles have none.
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

# Start in the caller's directory when inside a writable allowlist entry, else HOME.
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

# Secrets promoted from host files the descendant cannot read itself.
for pair in "${SECRET_READ[@]}"; do
  read_secret "${pair%%|*}" "${pair#*|}"
done

# Darwin has no mount namespace: copy configs into the agent-only dir (the profile denies the
# real ~/.config); Linux binds them read-only.
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
  rm -f "$agent_config/bin/ssh" "$agent_config/bin/gh"
  cp "$AGENT_SSH_SHIM" "$agent_config/bin/ssh"
  cp "$AGENT_GH_SHIM" "$agent_config/bin/gh"
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
    # maki's log dir is parent(XDG_STATE_HOME)/logs/maki, so state sits one level down.
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
  # Profile overrides go last so they can retarget PATH and the XDG dirs (later assignment wins).
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
  # Profile-declared names carried across as-is (the Jupyter profile's token).
  for name in "${ENV_PASSTHROUGH[@]}"; do
    add_env "$name"
  done
  # GH_TOKEN is never inherited: the gh wrapper and git helper select a PAT by repo owner,
  # which a caller's token would defeat.
}

if [ "$(uname -s)" = Darwin ]; then
  command -v /usr/bin/sandbox-exec >/dev/null 2>&1 || {
    echo "agent-sandbox: /usr/bin/sandbox-exec is missing" >&2
    exit 1
  }
  # A Keychain item on the work Mac: read outside the sandbox (SecurityAgent/securityd are denied inside).
  if [ -z "${OPENAI_API_KEY:-}" ] && [ -n "${OPENAI_KEYCHAIN_ITEM:-}" ]; then
    OPENAI_API_KEY=$(/usr/bin/security find-generic-password -s "$OPENAI_KEYCHAIN_ITEM" -w 2>/dev/null) || OPENAI_API_KEY=
    export OPENAI_API_KEY
  fi
  prepare_darwin_config
  build_env_args

  # The caller's TMPDIR, without the trailing slash macOS puts on it: a
  # `(subpath ".../T/")` rule does not match `.../T/com.apple.launchd.<id>`.
  tmpdir_host=${TMPDIR:-/tmp}
  tmpdir_host=${tmpdir_host%/}
  parent=$(dirname "$home")

  profile=$(mktemp "$tmpdir_host/agent-sandbox.XXXXXX.sbpl")
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
    # macOS 27 SIGABRTs every process unless the root dir is readable (the literal grants nothing
    # beneath it); nix dylibs load from the store (world-readable outputs). /var is the symlink
    # sops-nix's chain crosses; the home's parent needs it because realpath(3) stats every component
    # (git: "Invalid path '/Users': Operation not permitted").
    echo "(allow file-read* (literal \"/\") (literal \"/var\") (subpath \"/nix/store\") (subpath \"/System\") (subpath \"/Library\") (subpath \"/usr\") (subpath \"/bin\") (subpath \"/private/etc\") (subpath \"/private/var/db\") (subpath \"/dev\") (literal \"/tmp\") (subpath \"/tmp\") (subpath \"/private/tmp\") (subpath \"$tmpdir_host\"))"
    echo "(allow file-write* (literal \"/dev/null\") (literal \"/dev/tty\") (subpath \"/tmp\") (subpath \"/private/tmp\") (subpath \"${tmpdir_host}\"))"
    echo "(allow file-read-metadata (literal \"$parent\"))"
    # Seatbelt sees /private/var/folders, never the /var spelling the TMPDIR rules name, and sops-nix
    # decrypts there. Deny its secrets so widening those rules cannot expose them, then allow only the
    # listed links' resolved files and the symlink nodes their chain crosses; later rules win.
    # Listing stays denied (the directory resolves into the denied secrets.d).
    echo '(deny file-read* file-write* (regex #"^/private/var/folders/.+/secrets\.d/"))'
    for d in "${DARWIN_SECRET_LINK_DIRS[@]}"; do
      for name in "${DARWIN_SECRET_LINK_NAMES[@]}"; do
        link="$d/$name"
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
    # connect() to a unix socket is network-outbound, so the ~/.ssh mask alone
    # leaves the host's agents reachable; the PIV agent signs with no touch.
    echo "(deny network-outbound (subpath \"$home/.ssh\"))"
    # launchd's listener dirs are `com.apple.launchd.<id>`, which a `subpath` rule misses (subpath is
    # a path-component prefix): use a regex on the resolved TMPDIR (Seatbelt never sees /var/folders).
    tmpdir_resolved=$tmpdir_host
    [ -d "$tmpdir_resolved" ] && tmpdir_resolved=$(realpath "$tmpdir_resolved" 2>/dev/null || printf '%s' "$tmpdir_resolved")
    echo '(deny file-read* file-write* (regex #"^/private/tmp/com\.apple\.launchd"))'
    echo "(deny file-read* file-write* (regex #\"^${tmpdir_resolved//./\\.}/com\\.apple\\.launchd\"))"
    # piv-ensure caches the PIV PIN for the login session in the per-user temp
    # dir, which the TMPDIR rules above would otherwise expose.
    pin_cache=$(realpath "$(/usr/bin/getconf DARWIN_USER_TEMP_DIR)") || {
      echo "agent-sandbox: cannot resolve the per-user temp dir" >&2
      exit 1
    }
    echo "(deny file-read* file-write* (subpath \"$pin_cache/piv\") (subpath \"$tmpdir_resolved/piv\"))"
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

# `store = auto` picks a LocalStore when it can write the state dir; bwrap makes that dir writable
# in its tmpfs, so evals would lock files inside the read-only store. Bind the host dir (daemon
# socket) read-only so the client uses the daemon; a daemonless host keeps the ephemeral store.
if [ -S /nix/var/nix/daemon-socket/socket ]; then
  args+=(--ro-bind /nix/var/nix /nix/var/nix)
fi

for d in "${HOME_RW[@]}"; do
  args+=(--bind-try "$d" "$d")
done

# Existing repos keep .git/hooks, .git/config and a worktree's .git file read-only. Repos created
# inside the sandbox are not scanned (accepted: agent-created repos are reviewed). Renaming an
# existing .git moves the ro mountpoints, so this raises the bar rather than closing the boundary.
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

# Config allowlist: read-only copies in the agent config dir, bound before the ~/.config mask.
for name in "${CONFIG_ALLOW[@]}"; do
  src="$home/.config/$name"
  dest="$agent_config/$name"
  if [ -e "$src" ]; then
    args+=(--ro-bind "$src" "$dest")
  fi
done

# Writable exceptions inside a read-only config entry: the destination must exist before the ro dir
# is mounted, so create the host sidecar if missing; the writable agent-state copy is bound over it.
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

if [ -n "${AGENT_CONFIG_DIR:-}" ]; then
  args+=(
    --ro-bind "$AGENT_GIT_CONFIG" "$agent_config/gitconfig"
    --ro-bind "$AGENT_SSH_CONFIG" "$agent_config/ssh_config"
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
