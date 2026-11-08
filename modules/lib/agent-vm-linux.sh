# agent-sandbox (Linux): run a command, maki by default, inside the agent VM
# (modules/nixos/agent-vm.nix) at the same working directory. @name@ values are substituted by
# modules/lib/agent-vm.nix.
#
#   agent-sandbox [cmd [args...]]   run in the guest (default: maki)
#   agent-sandbox restart           print how to re-plan the home view
set -euo pipefail

addr=@guestAddr@
user=@user@
key=@stateDir@/id_ed25519
unit=@unit@
secret_env=(@secretEnv@)
# Host-side state beside the launcher key; prep creates the file user-owned so accept-new can
# remember the guest key.
known="@stateDir@/known_hosts"

case "${1:-}" in
restart)
  # The VM and its view are root services; this launcher never asks for elevation itself. A host
  # switch never restarts the guest, so this is also how a changed guest config takes effect. The
  # guest's writable store layer is discarded on every start, so guest builds reset too.
  echo "agent-sandbox: re-plan the home view and pick up guest changes with: sudo systemctl restart $unit" >&2
  exit 0
  ;;
-h | --help)
  echo "usage: agent-sandbox [cmd [args...]] | restart   (default cmd: maki)"
  exit 0
  ;;
esac
[ "$#" -gt 0 ] || set -- maki

if ! systemctl is-active --quiet "$unit"; then
  echo "agent-sandbox: $unit is not running (start it with: sudo systemctl start $unit)" >&2
  exit 1
fi

if [ ! -r "$key" ]; then
  echo "agent-sandbox: $key is missing; agent-vm-prep.service creates it" >&2
  exit 1
fi

ssh_opts=(
  -F /dev/null -i "$key" -o IdentitiesOnly=yes -o IdentityAgent=none -o ForwardAgent=no
  -o PKCS11Provider=none -o PermitLocalCommand=no -o ProxyCommand=none
  -o ControlMaster=no -o ControlPath=none -o PreferredAuthentications=publickey
  -o ClearAllForwardings=yes -o UserKnownHostsFile="$known" -o StrictHostKeyChecking=accept-new
)

ssh_opts+=(-o ConnectTimeout=5)

# The unit is active once qemu starts; sshd needs the guest boot.
ready=
while [ "$SECONDS" -lt 90 ]; do
  if err=$(ssh "${ssh_opts[@]}" -o BatchMode=yes "$user@$addr" true 2>&1); then
    ready=1
    break
  fi
  sleep 1
done
if [ -z "$ready" ]; then
  # A host key mismatch here means the guest's /var was recreated: drop the line from $known.
  echo "agent-sandbox: the guest did not accept SSH within 90s: $err" >&2
  exit 1
fi

# The guest's system first, then the host's nix and home entries. Store paths reach the guest
# through the read-only store share; a home entry only matters when it stays a directory (the
# guest's view exposes the allowlist), and any other one is inert.
guest_path=/run/wrappers/bin:/run/current-system/sw/bin
IFS=: read -ra entries <<<"$PATH"
for entry in "${entries[@]}"; do
  case "$entry" in /run/wrappers/* | /run/current-system/*) continue ;; esac
  resolved=$(readlink -f "$entry" 2>/dev/null) || continue
  case "$resolved" in /nix/store/* | "$HOME"/*) guest_path+=":$resolved" ;; esac
done

# Tool state stays guest-local; maki reads the real ~/.config and keeps its sessions in the
# host-shared ~/.local/state/maki.
exports=(
  "HOME=$HOME" "USER=$user" "LOGNAME=$user" "PATH=$guest_path"
  "XDG_CACHE_HOME=/var/lib/agent-vm/cache"
  "XDG_DATA_HOME=/var/lib/agent-vm/data"
  "GH_CONFIG_DIR=/var/lib/agent-vm/gh"
  # calibredb otherwise tries the read-only ~/.config/calibre and falls back to a temp dir.
  "CALIBRE_CONFIG_DIRECTORY=/var/lib/agent-vm/calibre"
)
remote="cd $(printf %q "$PWD") 2>/dev/null || { echo 'agent-sandbox: cwd is not shared; starting in ~' >&2; cd; };"
remote+=" export$(printf ' %q' "${exports[@]}");"
for pair in "${secret_env[@]}"; do
  var=${pair%%|*}
  file=${pair#*|}
  remote+=" [ -r $(printf %q "$file") ] && export $var=\"\$(cat $(printf %q "$file"))\";"
done
remote+=" exec$(printf ' %q' "$@")"

tty=()
if [ -t 0 ] && [ -t 1 ]; then tty=(-t); fi
exec ssh "${ssh_opts[@]}" "${tty[@]}" "$user@$addr" "$remote"
