#!/usr/bin/env bash
# jupyter-sandbox: same-UID bwrap boundary for the Open WebUI code interpreter, configured via
# AGENT_SANDBOX_CONFIG (modules/lib/jupyter-sandbox.nix). Agents run in the agent VM instead
# (modules/nixos/agent-vm.nix).
# Not a kernel boundary: the code keeps the user's UID; the mount namespace plus
# PR_SET_NO_NEW_PRIVS applies to every descendant.

set -euo pipefail
# shellcheck source=/dev/null
source "${AGENT_SANDBOX_CONFIG:?AGENT_SANDBOX_CONFIG is not set}"

if [ "$#" -lt 1 ]; then
  echo "usage: jupyter-sandbox <command> [args...]" >&2
  exit 2
fi

home=$HOME

# Start in the caller's directory when inside a writable entry, else HOME.
start=$home
for d in "${HOME_RW[@]}"; do
  case "$PWD" in
    "$d" | "$d"/*)
      start=$PWD
      break
      ;;
  esac
done

add_env() {
  local name=$1
  if [ -n "${!name:-}" ]; then
    ENV_ARGS+=("$name=${!name}")
  fi
}

ENV_ARGS=(
  "HOME=$home"
  "USER=${USER:-smores}"
  "LOGNAME=${LOGNAME:-${USER:-smores}}"
  "PWD=$start"
  "PATH=$AGENT_SANDBOX_PATH"
  "TMPDIR=/tmp"
  "SHELL=/bin/sh"
  "XDG_RUNTIME_DIR=/run/agent/runtime"
)
# Profile values go last so they can retarget PATH and the XDG dirs (later assignment wins).
ENV_ARGS+=("${ENV_EXTRA[@]}")
for name in TERM COLORTERM LANG LC_ALL LC_CTYPE LC_MESSAGES TZ "${ENV_PASSTHROUGH[@]}"; do
  add_env "$name"
done

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
  --dir /run/agent
  --dir /run/agent/runtime
  --ro-bind /nix/store /nix/store
  --ro-bind /etc /etc
  --ro-bind /bin /bin
  --ro-bind-try /usr /usr
  --ro-bind "$home" "$home"
)

for d in "${HOME_RW[@]}"; do
  args+=(--bind-try "$d" "$d")
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

for e in "${ENV_ARGS[@]}"; do
  args+=(--setenv "${e%%=*}" "${e#*=}")
done

args+=(--chdir "$start" -- "$@")
exec "$AGENT_SANDBOX_BWRAP" "${args[@]}"
