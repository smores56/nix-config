# agent-sandbox (macOS): run an agent inside a headless Tart macOS VM (sdlc #386).
#   agent-sandbox provision   one-time: clone the image, harden the guest, install the login key
#   agent-sandbox restart     stop the VM so the next launch re-plans the shares
#   agent-sandbox stop
#   agent-sandbox [cmd...]    default `claude`; runs in the guest at the same $PWD
# The @name@ placeholders are substituted by default.nix; the lists arrive as bash array bodies.

vm=@vm@
image=@image@
planner=@planner@
guest_path_prefix=@guestPath@
deny=(@deny@)
rw=(@rw@)
extra=(@extra@)

# State stays under ~/Library, which is never shared, so the guest cannot read its own login key.
state="$HOME/Library/Application Support/agent-vm"
key="$state/id_ed25519"
known="$state/known_hosts"
lock="$state/lock"
guest_home=/Users/sam
# Virtualization.framework accepts 12 directory-sharing devices, and the multi-directory device
# that carries the read-only shares is one of them.
max_devices=12

die() {
  printf 'agent-sandbox: %s\n' "$*" >&2
  exit 1
}

vm_field() {
  tart list --format json | jq -r --arg n "$vm" --arg f "$1" '.[] | select(.Name == $n) | .[$f] // empty'
}

# Every ssh to the guest ignores ~/.ssh/config: a hostile guest sshd must never be offered the
# host's YubiKey identities, providers, forwards or local commands.
ssh_opts=(
  -F /dev/null -i "$key" -o IdentitiesOnly=yes -o IdentityAgent=none -o ForwardAgent=no
  -o PKCS11Provider=none -o PermitLocalCommand=no -o ProxyCommand=none
  -o ControlMaster=no -o ControlPath=none -o PreferredAuthentications=publickey
  -o UserKnownHostsFile="$known" -o StrictHostKeyChecking=accept-new
)

guest_ssh() {
  ssh "${ssh_opts[@]}" -o ConnectTimeout=5 "$@"
}

guest_ip() {
  tart ip "$vm" --wait "${1:-120}"
}

wait_for_guest() {
  local ip
  for _ in $(seq 60); do
    # Re-resolve each round: a lease can change while the guest boots.
    if ip=$(guest_ip 5 2>/dev/null) && guest_ssh -o BatchMode=yes "admin@$ip" true 2>/dev/null; then
      printf '%s\n' "$ip"
      return
    fi
    sleep 2
  done
  die "guest ssh never came up"
}

# With no login session the guest ignores the power button, so `tart stop` would wait out its
# timeout and then kill the VM, losing unflushed writes; shut down from inside instead.
stop_vm() {
  [ "$(vm_field State)" = running ] || return 0
  local ip
  if ip=$(guest_ip 5 2>/dev/null); then
    # The connection drops mid-command, so its exit status says nothing.
    guest_ssh -o BatchMode=yes "admin@$ip" 'sudo -n shutdown -h now' >/dev/null 2>&1 || true
  fi
  for _ in $(seq 60); do
    [ "$(vm_field State)" = running ] || return 0
    sleep 1
  done
  echo "agent-sandbox: guest did not shut down; forcing" >&2
  tart stop --timeout 30 "$vm" >/dev/null
}

plan() {
  local args=(--home "$HOME")
  for d in "${deny[@]}"; do args+=(--deny "$d"); done
  for r in "${rw[@]}"; do args+=(--rw "$r"); done
  python3 "$planner" "${args[@]}"
}

# Read-write shares and the absolute shares get their own tagged device so the guest can mount
# them at the identical path (git worktrees and Claude project keys record physical paths);
# read-only shares ride one multi-directory device and are reached through guest symlinks.
dir_args() {
  jq -r --arg h "$HOME" '.shares[]
    | if .mode == "rw" then "--dir=\($h)/\(.rel):tag=\(.tag)"
      else "--dir=\(.tag):\($h)/\(.rel):ro" end' "$1"
  printf -- '--dir=/nix/store:ro,tag=nix-store\n'
  local i=0
  for p in "${extra[@]}"; do
    printf -- '--dir=%s:ro,tag=extra%d\n' "$p" "$i"
    i=$((i + 1))
  done
}

start_vm() {
  local shares="$1" logfile="$state/run.log" devices
  mapfile -t args < <(dir_args "$shares")
  devices=$(printf '%s\n' "${args[@]}" | grep -cE '[:,]tag=' || true)
  if jq -e '.shares | any(.mode == "ro")' "$shares" >/dev/null; then devices=$((devices + 1)); fi
  [ "$devices" -le "$max_devices" ] || die "$devices sharing devices exceed the limit of $max_devices"
  nohup tart run "$vm" --no-graphics "${args[@]}" >"$logfile" 2>&1 &
  disown
  for _ in $(seq 30); do
    [ "$(vm_field State)" = running ] && return
    grep -q VZErrorDomain "$logfile" 2>/dev/null && die "VM failed to start: $(tail -1 "$logfile")"
    sleep 1
  done
  die "VM did not reach running; see $logfile"
}

# Idempotent per session. Mounts and read-only symlinks follow the shares the VM booted with;
# home-manager symlinks and plain top-level files follow the fresh plan.
# shellcheck disable=SC2016 # the printf formats emit guest-side shell; $h expands there
setup_guest() {
  local ip="$1" shares="$2" fresh="$3"
  {
    printf 'set -e\nh=%q\n' "$guest_home"
    cat <<'EOF'
mounted() { mount | grep -q " on $(cd "$1" 2>/dev/null && pwd -P) "; }
# Make $1 a symlink to $2, clearing what an earlier plan left there: a mount, an empty directory
# or an old link. A non-empty real directory is guest state worth keeping, so stop instead.
place_link() {
  mkdir -p "$(dirname "$1")"
  if [ -d "$1" ] && [ ! -L "$1" ]; then
    if mounted "$1"; then sudo -n umount "$1"; fi
    rmdir "$1" 2>/dev/null || { echo "agent-sandbox: $1 is a non-empty guest directory" >&2; exit 1; }
  fi
  ln -sfn "$2" "$1"
}
place_mount() {
  if [ -L "$1" ]; then rm "$1"; fi
  mkdir -p "$1"
  mounted "$1" || sudo -n mount_virtiofs "$2" "$1"
}
mounted /nix/store || sudo -n mount_virtiofs nix-store /nix/store
EOF
    local i=0
    for p in "${extra[@]}"; do
      printf 'sudo -n mkdir -p %q; mounted %q || sudo -n mount_virtiofs extra%d %q\n' "$p" "$p" "$i" "$p"
      i=$((i + 1))
    done
    jq -r '.shares[] | select(.mode == "rw") | "\(.tag)\t\(.rel)"' "$shares" |
      while IFS=$'\t' read -r tag rel; do
        printf 'place_mount "$h"/%q %q\n' "$rel" "$tag"
      done
    jq -r '.shares[] | select(.mode == "ro") | "\(.tag)\t\(.rel)"' "$shares" |
      while IFS=$'\t' read -r tag rel; do
        printf 'place_link "$h"/%q %q\n' "$rel" "/Volumes/My Shared Files/$tag"
      done
    jq -r '.links[] | "\(.rel)\t\(.target)"' "$fresh" |
      while IFS=$'\t' read -r rel target; do
        printf 'place_link "$h"/%q %q\n' "$rel" "$target"
      done
  } | guest_ssh -o BatchMode=yes "admin@$ip" 'sh -s'

  # .claude.json and Finder/CoreFoundation files are guest-local state, not context.
  local copies=()
  while IFS= read -r rel; do
    case "$rel" in .claude.json | .DS_Store | .CFUserTextEncoding) continue ;; esac
    if [ -f "$HOME/$rel" ]; then copies+=("$rel"); fi
  done < <(jq -r '.copies[]' "$fresh")
  if [ "${#copies[@]}" -gt 0 ]; then
    tar -C "$HOME" -cf - -- "${copies[@]}" |
      guest_ssh -o BatchMode=yes "admin@$ip" "tar -C $(printf %q "$guest_home") -xf -"
  fi
}

provision() {
  mkdir -p "$state"
  [ -f "$key" ] || ssh-keygen -q -t ed25519 -N '' -C 'agent-sandbox host->guest' -f "$key"
  [ -n "$(vm_field Name)" ] || tart clone "$image" "$vm"
  if [ "$(vm_field State)" != running ]; then
    nohup tart run "$vm" --no-graphics >"$state/provision.log" 2>&1 &
    disown
  fi
  # The base image ships admin/admin; this is its only use, and the last line proves it is gone.
  local script ip
  script=$(
    cat <<EOF
set -e
sudo -n true 2>/dev/null || echo admin | sudo -S -p '' -v
sudo -n sh -c 'echo "admin ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/agent-nopasswd && chmod 440 /etc/sudoers.d/agent-nopasswd'
sudo -n sh -c 'printf "nix\tprivate/var/agent-nix\n" > /etc/synthetic.conf && mkdir -p /private/var/agent-nix/store'
sudo -n sh -c 'cat > /etc/ssh/sshd_config.d/000-agent.conf' <<'CONF'
PasswordAuthentication no
KbdInteractiveAuthentication no
AllowAgentForwarding no
AllowTcpForwarding remote
X11Forwarding no
AllowStreamLocalForwarding remote
StreamLocalBindUnlink yes
CONF
mkdir -p ~/.ssh && chmod 700 ~/.ssh
printf '%s\n' '$(cat "$key.pub")' > ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys
sudo -n mkdir -p $guest_home && sudo -n chown admin:staff $guest_home
# admin holds the SecureToken, so even root must give the old password.
if dscl . -authonly admin admin >/dev/null 2>&1; then
  dscl . -passwd /Users/admin admin "\$(openssl rand -hex 24)Aa1"
fi
! dscl . -authonly admin admin >/dev/null 2>&1
EOF
  )
  ip=$(guest_ip) || die "no IP for $vm"
  # Replacing the password also ends the image's auto-login, and with it the Tart guest agent
  # behind `tart exec`; once the key is installed, sshd is the way back in.
  if guest_ssh -o BatchMode=yes "admin@$ip" true 2>/dev/null; then
    guest_ssh -o BatchMode=yes "admin@$ip" "$script" || die "guest hardening failed"
  else
    for _ in $(seq 60); do tart exec "$vm" true 2>/dev/null && break; sleep 3; done
    tart exec "$vm" sh -c "$script" || die "guest hardening failed"
  fi
  stop_vm
  echo "agent-sandbox: provisioned $vm; the first launch boots it with the shares"
}

case "${1:-}" in
  provision) provision; exit ;;
  stop) stop_vm; exit ;;
  restart) stop_vm; shift ;;
esac
[ $# -gt 0 ] || set -- claude

[ -f "$key" ] && [ -n "$(vm_field Name)" ] || die "not provisioned; run: agent-sandbox provision"
fresh="$state/plan.json"
shares="$state/vm-shares.json"
# Per-process temp file: concurrent launches each write a whole plan, then rename atomically.
tmp=$(mktemp "$state/plan.XXXXXX")
plan >"$tmp"
mv "$tmp" "$fresh"

# One launcher at a time boots and prepares the guest; sessions themselves run concurrently.
for _ in $(seq 120); do mkdir "$lock" 2>/dev/null && break; sleep 1; done
[ -d "$lock" ] || die "another launch holds $lock"
trap 'rmdir "$lock" 2>/dev/null || true' EXIT
if [ "$(vm_field State)" = running ] && [ -f "$shares" ]; then
  cmp -s <(jq -S .shares "$shares") <(jq -S .shares "$fresh") ||
    echo "agent-sandbox: \$HOME's directories changed since the VM started; run \`agent-sandbox restart\` to re-share" >&2
else
  stop_vm
  jq '{shares}' "$fresh" >"$shares"
  start_vm "$shares"
fi
ip=$(wait_for_guest)
setup_guest "$ip" "$shares" "$fresh"
rmdir "$lock"
trap - EXIT

cwd="$guest_home"
while IFS= read -r root; do
  case "$PWD/" in "$HOME/$root/"*) cwd="$PWD" ;; esac
done < <(jq -r '.shares[].rel' "$shares")
sock="/tmp/agent-docker-$$.sock"
remote_cmd=$(printf 'export HOME=%q PATH=%q DOCKER_HOST=unix://%q; cd %q; exec' \
  "$guest_home" "$guest_path_prefix:$PATH" "$sock" "$cwd")
for a in "$@"; do remote_cmd+=" $(printf %q "$a")"; done
# The forwarded Docker socket is an accepted risk (#386): containers can mount whatever Docker
# Desktop's File sharing allows. ExitOnForwardFailure also makes ssh wait for the forward before
# the command starts, so the agent never races an absent socket.
forward=()
if [ -S "$HOME/.docker/run/docker.sock" ]; then
  forward=(-o ExitOnForwardFailure=yes -R "$sock:$HOME/.docker/run/docker.sock")
fi
exec ssh "${ssh_opts[@]}" -t "${forward[@]}" "admin@$ip" "$remote_cmd"
