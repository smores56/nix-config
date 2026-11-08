# agent-vm-verify (Linux host): assert the agent VM's home view, shares, secrets and firewall
# from outside the guest (sdlc #450). @name@ values are substituted by modules/nixos/agent-vm.nix.
set -euo pipefail

view=@view@
secrets=@secrets@
user=@user@
tap=@tap@
allow=(@allow@)
allow_rw=(@allowRw@)

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

# Every bind is nosuid and nodev, and read-only unless it is an allowRw root.
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
done < <(findmnt -R -n -o TARGET,OPTIONS "$view")

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
if as_user touch "$view/.gitignore" 2>/dev/null; then
  fail ".gitignore is writable"
fi
# The maki pack lock is the one writable file under a read-only root: a guest-local bind-over.
lock="$view/.config/maki/pack-lock.json.lock"
if [ -f "$lock" ]; then
  as_user test -w "$lock" || fail "the maki pack lock is not writable"
  findmnt -M "$lock" >/dev/null || fail "the maki pack lock has no bind-over"
fi

# Secrets are readable by the human alone.
while IFS= read -r f; do
  [ "$(stat -c %a "$f")" = 400 ] || fail "$f is not mode 0400"
  [ "$(stat -c %u "$f")" = "$(id -u "$user")" ] || fail "$f is not owned by $user"
done < <(find "$secrets" -maxdepth 1 -type f)

# The host never touches the guest's store image.
if grep -qF nix-store.img /proc/mounts; then fail "a mount references nix-store.img"; fi
if losetup -a | grep -qF nix-store.img; then fail "a loop device references nix-store.img"; fi

# The tap and both firewall chains exist.
ip -4 addr show "$tap" | grep -qF "10.77.0.1/30" || fail "$tap lacks its address"
for chain in agent-vm-in agent-vm-fwd; do
  iptables -S "$chain" >/dev/null 2>&1 || fail "firewall chain $chain is missing"
done

if [ "$failures" -gt 0 ]; then
  echo "agent-vm-verify: $failures failure(s)" >&2
  exit 1
fi
echo "agent-vm-verify: ok"
