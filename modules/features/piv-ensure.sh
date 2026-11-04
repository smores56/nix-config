# macOS counterpart of yk-ensure: the smortress ProxyCommand runs this before
# the tunnel. The long-lived PIV agent keeps the card session, so the PIN is
# asked once per card session instead of once per connection.
# Usage: piv-ensure <agent-socket> <pkcs11-provider> <gui-askpass> <pub>...
set -euo pipefail

sock=$1
provider=$2
gui=$3
shift 3

die() {
  echo "piv-ensure: $*" >&2
  exit 1
}

# A listed key is not proof: after unplug or sleep the agent still lists it
# but cannot sign. -T signs and verifies.
healthy() {
  local pub
  for pub in "$@"; do
    SSH_AUTH_SOCK=$sock ssh-add -T "$pub" </dev/null >/dev/null 2>&1 && return 0
  done
  return 1
}

healthy "$@" && exit 0

# A caller's own askpass (the wallpaper job's Keychain helper) answers without
# a dialog; a no-prompt caller without one must not open a dialog.
askpass=${SSH_ASKPASS:-}
if [ -z "$askpass" ]; then
  [ -z "${YK_ENSURE_NO_PROMPT:-}" ] || die "PIV agent is cold; run 'ssh smortress true' interactively first"
  askpass=$gui
fi

# One dialog for parallel connections; the second waits and finds it warm.
exec 9>"$sock.lock"
flock -w 120 9 || die "another unlock is still running"
healthy "$@" && exit 0

# Unload a stale provider first so ykman and the reload see a free card.
SSH_AUTH_SOCK=$sock ssh-add -e "$provider" </dev/null >/dev/null 2>&1 || true

tries=$(timeout 10 ykman piv info 2>/dev/null |
  sed -n 's/^PIN tries remaining:[[:space:]]*\([0-9][0-9]*\)\/.*/\1/p') || tries=
[ -n "$tries" ] || die "cannot read the PIV PIN retry count; is exactly one YubiKey inserted?"
[ "$tries" -ge 2 ] || die "only $tries PIV PIN try left; recover the PIN before using SSH"

# force: a ProxyCommand's stdin is ssh's transport, which ssh-add would
# otherwise read as the PIN. One attempt only; a wrong PIN is never retried.
SSH_AUTH_SOCK=$sock SSH_ASKPASS=$askpass SSH_ASKPASS_REQUIRE=force \
  ssh-add -s "$provider" </dev/null >/dev/null 2>&1 ||
  die "PIV unlock failed or was cancelled"
healthy "$@" || die "PIV agent loaded the card but cannot sign"
