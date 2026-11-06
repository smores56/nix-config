# agent-sandbox (macOS): run an agent inside a headless Tart macOS VM (sdlc #386).
#   agent-sandbox provision   one-time: clone the image, harden the guest, install the login key
#   agent-sandbox restart     stop the VM so the next launch re-plans the shares
#   agent-sandbox stop
#   agent-sandbox [cmd...]    default `claude`; runs in the guest at the same $PWD
# @VM@, @IMAGE@, @PLANNER@, @GUEST_PATH@, @DENY@, @RW@ and @EXTRA@ are substituted by default.nix.

vm=@VM@
image=@IMAGE@
planner=@PLANNER@
guest_path_prefix=@GUEST_PATH@
read -r -a deny <<<@DENY@
read -r -a rw <<<@RW@
read -r -a extra <<<@EXTRA@

# State stays under ~/Library, which is never shared, so the guest cannot read its own login key.
state="$HOME/Library/Application Support/agent-vm"
key="$state/id_ed25519"
known="$state/known_hosts"
guest_home=/Users/sam
# Virtualization.framework rejects more than 12 directory-sharing devices.
max_tagged=12

die() {
  printf 'agent-sandbox: %s\n' "$*" >&2
  exit 1
}

vm_field() {
  tart list --format json | jq -r --arg n "$vm" --arg f "$1" '.[] | select(.Name == $n) | .[$f] // empty'
}

guest_ssh() {
  # Never forward the host agent: its sockets are exactly what the guest must not reach.
  ssh -i "$key" -o IdentitiesOnly=yes -o IdentityAgent=none -o ForwardAgent=no -o ControlMaster=no -o ControlPath=none \
    -o UserKnownHostsFile="$known" -o StrictHostKeyChecking=accept-new \
    -o ConnectTimeout=5 "$@"
}

wait_for_guest() {
  local ip
  ip=$(tart ip "$vm" --wait 120) || die "no IP for $vm"
  for _ in $(seq 60); do
    if guest_ssh -o BatchMode=yes "admin@$ip" true 2>/dev/null; then
      printf '%s\n' "$ip"
      return
    fi
    sleep 2
  done
  die "guest ssh never came up at $ip"
}

# With no login session the guest ignores the power button, so `tart stop` would wait out its
# timeout and then kill the VM, losing unflushed writes; shut down from inside instead.
stop_vm() {
  [ "$(vm_field State)" = running ] || return 0
  local ip
  if ip=$(tart ip "$vm" 2>/dev/null) &&
    guest_ssh -o BatchMode=yes "admin@$ip" 'sudo -n shutdown -h now' >/dev/null 2>&1; then
    for _ in $(seq 60); do
      [ "$(vm_field State)" = running ] || return 0
      sleep 1
    done
  fi
  tart stop --timeout 30 "$vm" >/dev/null
}

plan() {
  local args=(--home "$HOME")
  for d in "${deny[@]}"; do args+=(--deny "$d"); done
  for r in "${rw[@]}"; do args+=(--rw "$r"); done
  python3 "$planner" "${args[@]}"
}

# Read-write shares and the absolute extras get their own tagged device so the guest can mount
# them at the identical path (git worktrees and Claude project keys record physical paths);
# read-only shares ride one multi-directory device and are reached through guest symlinks.
dir_args() {
  jq -r --arg h "$HOME" '.shares[]
    | if .mode == "rw" then "--dir=\($h)/\(.rel):tag=\(.tag)"
      else "--dir=\(.tag):\($h)/\(.rel):ro" end' "$1"
  local i=0
  for p in "${extra[@]}"; do
    printf -- '--dir=%s:ro,tag=extra%d\n' "$p" "$i"
    i=$((i + 1))
  done
}

start_vm() {
  local planfile="$1" logfile="$state/run.log"
  mapfile -t args < <(dir_args "$planfile")
  local tagged
  tagged=$(printf '%s\n' "${args[@]}" | grep -c 'tag=' || true)
  [ "$tagged" -le "$max_tagged" ] || die "$tagged tagged shares exceed the limit of $max_tagged"
  nohup tart run "$vm" --no-graphics "${args[@]}" >"$logfile" 2>&1 &
  disown
  for _ in $(seq 30); do
    [ "$(vm_field State)" = running ] && return
    grep -q VZErrorDomain "$logfile" 2>/dev/null && die "VM failed to start: $(tail -1 "$logfile")"
    sleep 1
  done
  die "VM did not reach running; see $logfile"
}

# Idempotent per session: mount tagged shares at their host paths, link read-only shares and
# home-manager symlinks, then snapshot the plain top-level files.
# shellcheck disable=SC2016 # the printf formats emit guest-side shell; $h and $p expand there
setup_guest() {
  local ip="$1" planfile="$2"
  {
    printf 'set -e\nh=%q\n' "$guest_home"
    cat <<'EOF'
mounted() { mount | grep -q " on $1 "; }
mounted /private/var/agent-nix/store || sudo -n mount_virtiofs extra0 /nix/store
EOF
    local i=1
    for p in "${extra[@]:1}"; do
      printf 'sudo -n mkdir -p %q; mounted %q || sudo -n mount_virtiofs extra%d %q\n' "$p" "$p" "$i" "$p"
      i=$((i + 1))
    done
    jq -r '.shares[] | select(.mode == "rw") | "\(.tag)\t\(.rel)"' "$planfile" |
      while IFS=$'\t' read -r tag rel; do
        printf 'p="$h"/%q; [ -L "$p" ] && rm "$p"; mkdir -p "$p"; mounted "$p" || sudo -n mount_virtiofs %q "$p"\n' "$rel" "$tag"
      done
    jq -r '.shares[] | select(.mode == "ro") | "\(.tag)\t\(.rel)"' "$planfile" |
      while IFS=$'\t' read -r tag rel; do
        printf 'mkdir -p "$(dirname "$h"/%q)"; ln -sfn %q "$h"/%q\n' "$rel" "/Volumes/My Shared Files/$tag" "$rel"
      done
    jq -r '.links[] | "\(.rel)\t\(.target)"' "$planfile" |
      while IFS=$'\t' read -r rel target; do
        printf 'mkdir -p "$(dirname "$h"/%q)"; ln -sfn %q "$h"/%q\n' "$rel" "$target" "$rel"
      done
  } | guest_ssh -o BatchMode=yes "admin@$ip" 'sh -s'

  # .claude.json and Finder/CoreFoundation files are guest-local state, not context.
  local copies
  mapfile -t copies < <(jq -r '.copies[]' "$planfile" | grep -vxE '\.claude\.json|\.DS_Store|\.CFUserTextEncoding' || true)
  if [ "${#copies[@]}" -gt 0 ]; then
    tar -C "$HOME" -cf - -- "${copies[@]}" |
      guest_ssh -o BatchMode=yes "admin@$ip" "tar -C $(printf %q "$guest_home") -xf -"
  fi
}

provision() {
  mkdir -p "$state"
  [ -f "$key" ] || ssh-keygen -q -t ed25519 -N '' -C 'agent-sandbox host->guest' -f "$key"
  [ -n "$(vm_field Name)" ] || tart clone "$image" "$vm"
  [ "$(vm_field State)" = running ] || {
    nohup tart run "$vm" --no-graphics >"$state/provision.log" 2>&1 &
    disown
  }
  # The base image ships admin/admin; this is the only use of that password, and it is replaced.
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
# admin holds the SecureToken, so even root must give the old password; a re-run finds it changed.
dscl . -passwd /Users/admin admin "\$(openssl rand -hex 24)Aa1" >/dev/null 2>&1 || true
EOF
  )
  ip=$(tart ip "$vm" --wait 120) || die "no IP for $vm"
  # Replacing the password also ends the image's auto-login, and with it the Tart guest agent
  # behind `tart exec`; once the key is installed, sshd is the way back in.
  if guest_ssh -o BatchMode=yes "admin@$ip" true 2>/dev/null; then
    guest_ssh -o BatchMode=yes "admin@$ip" "$script"
  else
    for _ in $(seq 60); do tart exec "$vm" true 2>/dev/null && break; sleep 3; done
    tart exec "$vm" sh -c "$script"
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
planfile="$state/plan.json"
plan >"$planfile.new"
if [ "$(vm_field State)" = running ]; then
  cmp -s "$planfile" "$planfile.new" ||
    echo "agent-sandbox: \$HOME's layout changed since the VM started; run \`agent-sandbox restart\` to re-share" >&2
  rm "$planfile.new"
else
  mv "$planfile.new" "$planfile"
  start_vm "$planfile"
fi
ip=$(wait_for_guest)
setup_guest "$ip" "$planfile"

cwd="$guest_home"
while IFS= read -r root; do
  case "$PWD/" in "$HOME/$root/"*) cwd="$PWD" ;; esac
done < <(jq -r '.shares[].rel' "$planfile")
sock="/tmp/agent-docker-$$.sock"
remote_cmd=$(printf 'export HOME=%q PATH=%q DOCKER_HOST=unix://%q; cd %q; exec' \
  "$guest_home" "$guest_path_prefix:$PATH" "$sock" "$cwd")
for a in "$@"; do remote_cmd+=" $(printf %q "$a")"; done
# ExitOnForwardFailure also makes ssh wait for the forward before starting the command, so the
# agent never races an absent socket.
forward=()
[ -S "$HOME/.docker/run/docker.sock" ] &&
  forward=(-o ExitOnForwardFailure=yes -R "$sock:$HOME/.docker/run/docker.sock")
exec ssh -i "$key" -o IdentitiesOnly=yes -o IdentityAgent=none -o ForwardAgent=no -o ControlMaster=no -o ControlPath=none \
  -o UserKnownHostsFile="$known" -t "${forward[@]}" "admin@$ip" "$remote_cmd"
