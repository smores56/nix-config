# agent-vm-update (Linux host): apply host/userland changes, or schedule the boot a guest
# closure change needs. The guest is asked, not trusted: `who` counts human ptys only.
set -euo pipefail

expected_file=@expected@
key=@key@
known=@known@
guest=@user@@@guestAddr@
[ "$(id -u)" -eq 0 ] || {
  echo "agent-vm-update: run as root (sudo agent-vm-update)" >&2
  exit 2
}
ssh_opts=(
  -F /dev/null -i "$key" -o IdentitiesOnly=yes -o IdentityAgent=none -o ForwardAgent=no
  -o PKCS11Provider=none -o PermitLocalCommand=no -o ProxyCommand=none
  -o ControlMaster=no -o ControlPath=none -o PreferredAuthentications=publickey
  -o ClearAllForwardings=yes -o UserKnownHostsFile="$known" -o StrictHostKeyChecking=accept-new
  -o ConnectTimeout=5
)
run() { ssh "${ssh_opts[@]}" -o BatchMode=yes "$guest" "$@"; }

mode=check
force=0
wait=0
while [ "$#" -gt 0 ]; do
  case "$1" in
  --now) mode=boot ;;
  --check) mode=check ;;
  --force) force=1 ;;
  --wait) shift; wait=${1:?--wait needs seconds} ;;
  *) echo "usage: agent-vm-update [--check|--now] [--force] [--wait SECONDS]" >&2; exit 2 ;;
  esac
  shift
done

expected=$(readlink "$expected_file" 2>/dev/null || true)
[ -n "$expected" ] || { echo "agent-vm-update: no expected toplevel at $expected_file" >&2; exit 1; }
booted=$(run 'readlink /run/booted-system') || { echo "agent-vm-update: guest unreachable" >&2; exit 1; }
current=$(run 'readlink /run/current-system') || { echo "agent-vm-update: guest unreachable" >&2; exit 1; }
humans=$(run 'who | wc -l') || { echo "agent-vm-update: guest unreachable" >&2; exit 1; }

if [ "$booted" = "$expected" ]; then
  echo "agent-vm-update: current (booted=$expected)"
  exit 0
fi

if [ "$current" != "$expected" ] && [ "$booted" = "$current" ]; then
  echo "agent-vm-update: switching userland to $expected"
  remote=$(printf "sudo -n nix-env -p /nix/var/nix/profiles/system --set %q && sudo -n systemd-run --unit=agent-vm-switch --no-block %q switch" "$expected" "$expected/bin/switch-to-configuration")
  run "$remote"
  for _ in $(seq 30); do
    if [ "$(run 'readlink /run/current-system')" = "$expected" ]; then
      echo "agent-vm-update: userland switched; kernel reboot is still pending"
      exit 0
    fi
    sleep 2
  done
  echo "agent-vm-update: the switch did not complete; check journalctl -u agent-vm-switch in the guest" >&2
  exit 1
fi

echo "agent-vm-update: reboot required (booted=$booted expected=$expected, human sessions=$humans)"
[ "$mode" = boot ] || exit 0
if [ "$force" -eq 0 ]; then
  while [ "$humans" -gt 0 ] && [ "$wait" -gt 0 ]; do
    echo "agent-vm-update: waiting for $humans human session(s), ${wait}s left"
    sleep 10
    wait=$((wait - 10))
    humans=$(run 'who | wc -l')
  done
  [ "$humans" -eq 0 ] || {
    echo "agent-vm-update: $humans human session(s) are active; pass --force to reboot anyway" >&2
    exit 1
  }
fi
run 'sudo -n shutdown -r now' >/dev/null 2>&1 || true
echo "agent-vm-update: guest reboot requested; the host recreates the writable store layer"
