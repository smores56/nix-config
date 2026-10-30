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
mkdir -p \
  "$agent_config" \
  "$agent_config/bin" \
  "$home/.cache/agent" \
  "$home/.local/share/agent" \
  "$home/.local/state/agent"

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

read_secret NEURALWATT_API_KEY /run/secrets/neuralwatt-api-key
read_secret TINYFISH_API_KEY /run/secrets/tinyfish-api-key
read_secret IMMICH_API_KEY /run/secrets/immich-agent-api-key
read_secret OPENAI_API_KEY "${OPENAI_KEYCHAIN_ITEM:-/nonexistent}"

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
  if [ -r "$home/.config/ssh/allowed_signers" ]; then
    cp "$home/.config/ssh/allowed_signers" "$agent_config/allowed_signers"
  fi
  if [ -r "$home/.config/ssh/known_hosts" ]; then
    cp "$home/.config/ssh/known_hosts" "$agent_config/known_hosts"
  fi
  cp "$AGENT_GIT_CONFIG" "$agent_config/gitconfig"
  cp "$AGENT_SSH_CONFIG" "$agent_config/ssh_config"
  mkdir -p "$agent_config/bin"
  cp "$AGENT_SSH_SHIM" "$agent_config/bin/ssh"
  cp "$AGENT_GH_SHIM" "$agent_config/bin/gh"
  cp "$AGENT_SIGNING_KEY_COMMAND" "$agent_config/bin/gpg-ssh-default-key"
  cp "$AGENT_CREDENTIAL_HELPER" "$agent_config/bin/agent-sandbox-git-credential"
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
    "PATH=$agent_config/bin:$home/.local/bin:$home/.nix-profile/bin:$AGENT_SANDBOX_PATH"
    "TMPDIR=/tmp"
    "SHELL=/bin/sh"
    "XDG_STATE_HOME=$home/.local/state/agent"
    "XDG_CACHE_HOME=$home/.cache/agent"
    "XDG_DATA_HOME=$home/.local/share/agent"
    "XDG_CONFIG_HOME=$agent_config"
    "XDG_RUNTIME_DIR=/run/agent/runtime"
    "GH_CONFIG_DIR=$home/.cache/agent/gh"
    "GIT_CONFIG_GLOBAL=$agent_config/gitconfig"
    "GIT_CONFIG_SYSTEM=/dev/null"
    "MAKI_LOG=/tmp/maki.log"
  )
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
  add_env GH_TOKEN
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
  if [ -z "${GH_TOKEN:-}" ] && [ -n "${GH_TOKEN_KEYCHAIN_ITEM:-}" ]; then
    GH_TOKEN=$(/usr/bin/security find-generic-password -s "$GH_TOKEN_KEYCHAIN_ITEM" -w 2>/dev/null) || GH_TOKEN=
    export GH_TOKEN
  fi
  prepare_darwin_config
  build_env_args

  profile=$(mktemp "${TMPDIR:-/tmp}/agent-sandbox.XXXXXX.sbpl")
  trap 'rm -f "$profile"' EXIT
  {
    echo '(version 1)'
    echo '(deny default)'
    echo '(allow process-exec (subpath "/nix/store") (subpath "/bin") (subpath "/usr/bin") (subpath "/usr/sbin") (subpath "/usr/local") (subpath "/opt/homebrew") (subpath "/Library/Developer") (subpath "'"$home/.local/bin"'") (subpath "'"$agent_config/bin"'"))'
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
    echo '(allow file-read* (subpath "/System") (subpath "/Library") (subpath "/usr") (subpath "/bin") (subpath "/private/etc") (subpath "/private/var/db") (subpath "/dev") (literal "/tmp") (subpath "/tmp") (subpath "/private/tmp") (subpath "'"${TMPDIR:-/tmp}"'"))'
    echo "(allow file-write* (literal \"/dev/null\") (literal \"/dev/tty\") (subpath \"/tmp\") (subpath \"/private/tmp\") (subpath \"${TMPDIR:-/tmp}\"))"
    for d in "${HOME_RW[@]}"; do
      echo "(allow file-write* (subpath \"$d\"))"
    done
    echo "(allow file-write* (subpath \"$agent_config\"))"
    echo '(allow sysctl-read)'
    echo '(allow process-info* (target same-sandbox))'
    echo '(allow signal (target same-sandbox))'
    echo '(allow pseudo-tty)'
    echo '(allow network*)'
    for svc in "${MACH_ALLOW[@]}"; do
      echo "(allow mach-lookup (global-name \"$svc\"))"
    done
    echo '(deny appleevent-send)'
    echo '(deny lsopen)'
    echo '(deny job-creation)'
    echo '(deny file-write-mount file-write-unmount)'
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
  --dir /run/agent/bin
  --dir /run/agent/runtime
  --ro-bind /nix/store /nix/store
  --ro-bind /etc /etc
  --ro-bind /bin /bin
  --ro-bind-try /nix/var/nix/daemon-socket/socket /nix/var/nix/daemon-socket/socket
  --ro-bind "$home" "$home"
)

for d in "${HOME_RW[@]}"; do
  args+=(--bind-try "$d" "$d")
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

for d in "${HOME_MASK_DIRS[@]}"; do
  # A missing path has nothing to expose; creating a mountpoint under the
  # read-only home would fail.
  [ -d "$d" ] && args+=(--tmpfs "$d")
done
for f in "${HOME_MASK_FILES[@]}"; do
  # --file cannot create a mountpoint under a read-only home. A read-only
  # /dev/null bind makes reads fail (EPERM), which is the deny we want.
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

args+=(
  --ro-bind "$AGENT_GIT_CONFIG" "$agent_config/gitconfig"
  --ro-bind "$AGENT_SSH_CONFIG" "$agent_config/ssh_config"
  --ro-bind "$AGENT_SIGNING_KEY_COMMAND" "$agent_config/bin/gpg-ssh-default-key"
  --ro-bind "$AGENT_CREDENTIAL_HELPER" "$agent_config/bin/agent-sandbox-git-credential"
  --ro-bind "$AGENT_SSH_SHIM" "$agent_config/bin/ssh"
  --ro-bind "$AGENT_GH_SHIM" "$agent_config/bin/gh"
)
if [ -r "$home/.config/ssh/allowed_signers" ]; then
  args+=(--ro-bind "$home/.config/ssh/allowed_signers" "$agent_config/allowed_signers")
fi
if [ -r "$home/.config/ssh/known_hosts" ]; then
  args+=(--ro-bind "$home/.config/ssh/known_hosts" "$agent_config/known_hosts")
fi

for e in "${ENV_ARGS[@]}"; do
  args+=(--setenv "${e%%=*}" "${e#*=}")
done

args+=(--chdir "$start" -- "$@")
exec "$AGENT_SANDBOX_BWRAP" "${args[@]}"
