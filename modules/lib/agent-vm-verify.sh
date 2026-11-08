# agent-vm-verify (Linux host): assert the agent VM's home view, shares, secrets and firewall
# from outside the guest (sdlc #450). @name@ values are substituted by modules/nixos/agent-vm.nix.
set -euo pipefail

# runuser and iptables need root; without it every write probe fails for the wrong reason.
if [ "$(id -u)" -ne 0 ]; then
  echo "agent-vm-verify: run as root: sudo agent-vm-verify" >&2
  exit 2
fi

view=@view@
secrets=@secrets@
user=@user@
tap=@tap@
allow=(@allow@)
allow_rw=(@allowRw@)
expected_secrets=(@secretsList@)

failures=0
fail() {
  echo "agent-vm-verify: $*" >&2
  failures=$((failures + 1))
}
as_user() { runuser -u "$user" -- "$@"; }
opts_of() { findmnt -n -M "$1" -o OPTIONS || true; }
list_dir() { find "$1" -mindepth 1 -maxdepth 1 -printf '%f\n' | sort; }

# The view itself is a read-only, nosuid, nodev tmpfs.
[ "$(findmnt -n -M "$view" -o FSTYPE)" = tmpfs ] || fail "$view is not a tmpfs"
view_opts=$(opts_of "$view")
for flag in ro nosuid nodev; do
  case ",$view_opts," in *",$flag,"*) ;; *) fail "$view lacks $flag" ;; esac
done

# Nothing outside the allowlist is visible: the top level is exactly the roots' first
# components, and every synthesized parent directory holds only the allowed entries.
expected_top=$(printf '%s\n' "${allow[@]}" "${allow_rw[@]}" | cut -d/ -f1 | sort -u)
actual_top=$(list_dir "$view")
[ "$actual_top" = "$expected_top" ] || fail "top level is: $actual_top"
[ "$(list_dir "$view/.config" | tr '\n' ' ')" = "git maki " ] || fail ".config exposes more than maki and git"
[ "$(list_dir "$view/.local" | tr '\n' ' ')" = "bin logs state " ] || fail ".local exposes more than bin, logs and state"
[ "$(list_dir "$view/.local/state" | tr '\n' ' ')" = "maki " ] || fail ".local/state exposes more than maki"
[ "$(list_dir "$view/.local/logs" | tr '\n' ' ')" = "maki " ] || fail ".local/logs exposes more than maki"
for p in .ssh .gnupg .cache .local/share Documents Downloads Desktop .config/sops .config/gh; do
  [ ! -e "$view/$p" ] || fail "absent path is visible: $p"
done

# Every bind is nosuid and nodev, and read-only unless it is an allowRw root. nosuid/nodev on
# every bind is also the guarantee the design asks for by name: no setuid or setgid binary and
# no device node is usable from the view.
while IFS=' ' read -r target opts; do
  [ "$target" = "$view" ] && continue
  for flag in nosuid nodev; do
    case ",$opts," in *",$flag,"*) ;; *) fail "$target lacks $flag" ;; esac
  done
  rel=${target#"$view"/}
  writable=0
  for r in "${allow_rw[@]}"; do
    case "$rel" in "$r" | "$r"/*) writable=1 ;; esac
  done
  case ",$opts," in
    *,ro,*) [ "$writable" -eq 1 ] && fail "writable root is read-only: $rel" ;;
    *) [ "$writable" -eq 1 ] || fail "read-only root is writable: $rel" ;;
  esac
done < <(findmnt -R -l -n -o TARGET,OPTIONS "$view")

# Writes land where they should, as the human.
for rel in ".local/state/maki" ".local/logs/maki" "repos" "wip"; do
  [ -d "$view/$rel" ] || continue
  if ! as_user touch "$view/$rel/.agent-vm-verify" 2>/dev/null; then
    fail "$rel is not writable"
  else
    rm -f "$view/$rel/.agent-vm-verify"
  fi
done
for rel in ".agents" ".config/maki" ".config/git" ".local/bin"; do
  [ -d "$view/$rel" ] || continue
  if as_user touch "$view/$rel/.agent-vm-verify" 2>/dev/null; then
    rm -f "$view/$rel/.agent-vm-verify"
    fail "$rel is writable"
  fi
done
# The maki pack lock is bound over inside the guest, so its writability is the guest check's.

# Every sops secret the host holds for the guest arrives user-owned, mode 0400. A name the
# host does not have (a host-scoped secret) is a warning: nothing was handed in, which the
# operator sees in the unit's journal.
for name in "${expected_secrets[@]}"; do
  if [ ! -e "/run/secrets/$name" ]; then
    echo "agent-vm-verify: note: /run/secrets/$name is absent on this host" >&2
    continue
  fi
  f="$secrets/$name"
  [ -f "$f" ] || { fail "hand-in secret is missing: $name"; continue; }
  [ "$(stat -c %a "$f")" = 400 ] || fail "$name is not mode 0400"
  [ "$(stat -c %u "$f")" = "$(id -u "$user")" ] || fail "$name is not owned by $user"
done

# The host never touches the guest's store image.
if grep -qF nix-store.img /proc/mounts; then fail "a mount references nix-store.img"; fi
if losetup -a | grep -qF nix-store.img; then fail "a loop device references nix-store.img"; fi

# The tap and both firewall chains exist.
ip -4 addr show "$tap" | grep -qF "@hostAddr@/30" || fail "$tap lacks its address"
for chain in agent-vm-in agent-vm-fwd; do
  iptables -S "$chain" >/dev/null 2>&1 || fail "firewall chain $chain is missing"
done

if [ "$failures" -gt 0 ]; then
  echo "agent-vm-verify: $failures failure(s)" >&2
  exit 1
fi
echo "agent-vm-verify: ok"
