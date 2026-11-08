# agent-sandbox (macOS): run an agent inside a headless Tart macOS VM (sdlc #427).
#   agent-sandbox provision   one-time: clone the image, harden the guest, install the login key
#   agent-sandbox provision-nix  opt-in: install a guest-local Nix store and use it
#   agent-sandbox restart     stop the VM so the next launch re-plans the shares
#   agent-sandbox stop
#   agent-sandbox [cmd...]    default `claude`; runs in the guest at the same $PWD
# The @name@ placeholders are substituted by default.nix; the lists arrive as bash array bodies.

vm=@vm@
image=@image@
planner=@planner@
guest_path_prefix=@guestPath@
ca_bundle=@caBundle@
allow=(@allow@)
allow_rw=(@allowRw@)
extra=(@extra@)
guest_config=(@guestConfig@)
hand_in=(@handIn@)

# State stays under ~/Library, which is never shared, so the guest cannot read its own login key.
state="$HOME/Library/Application Support/agent-vm"
key="$state/id_ed25519"
known="$state/known_hosts"
lock="$state/lock"
guest_home=/Users/sam
nix_marker="$state/guest-nix"
nix_mode=0
[ -f "$nix_marker" ] && nix_mode=1
host_store=1
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
  for d in "${allow[@]}"; do args+=(--allow "$d"); done
  for r in "${allow_rw[@]}"; do args+=(--allow-rw "$r"); done
  python3 "$planner" "${args[@]}"
}

# Read-write shares and the absolute shares get their own tagged device so the guest can mount
# them at the identical path (git worktrees and Claude project keys record physical paths);
# read-only shares ride one multi-directory device and are reached through guest symlinks.
dir_args() {
  jq -r --arg h "$HOME" '.shares[]
    | if .mode == "rw" then "--dir=\($h)/\(.rel):tag=\(.tag)"
      else "--dir=\(.tag):\($h)/\(.rel):ro" end' "$1"
  [ "$host_store" -eq 1 ] && [ "$nix_mode" -eq 0 ] && printf -- '--dir=/nix/store:ro,tag=nix-store\n'
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
    printf 'set -e\nh=%q\nnix_mode=%q\n' "$guest_home" "$nix_mode"
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
if [ "$nix_mode" != 1 ]; then
  mounted /nix/store || sudo -n mount_virtiofs nix-store /nix/store
fi
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

  # Copy the host CLI config into a guest-local tree. The host paths are denied, so this is the
  # only copy the guest sees; the guest can write its own config without touching the host.
  local conf="$guest_home/Library/Application Support/agent-config" rel
  for rel in "${guest_config[@]}"; do
    [ -e "$HOME/$rel" ] || continue
    tar -C "$HOME" -chf - -- "$rel" |
      guest_ssh -o BatchMode=yes "admin@$ip" "mkdir -p $(printf %q "$conf") && tar -C $(printf %q "$conf") -xf -"
  done

  # Hand in only the git identities the agent signs and pushes with, at the path the host's
  # git config names. The guest's ~/.config/sops-nix is real guest state, not a shared link, so
  # the copy is written there and the host's sops output stays on the host.
  local dir names=() guest_secrets="$guest_home/.config/sops-nix/secrets"
  dir=$(readlink -f "$HOME/.config/sops-nix/secrets" 2>/dev/null) || return 0
  for name in "${hand_in[@]}"; do
    if [ -r "$dir/$name" ]; then names+=("$name"); fi
  done
  if [ "${#names[@]}" -gt 0 ]; then
    tar -C "$dir" -cf - -- "${names[@]}" |
      guest_ssh -o BatchMode=yes "admin@$ip" "$(printf 'sudo -n mkdir -p %q && sudo -n chown admin %q && chmod 700 %q && tar -C %q -xf -' "$guest_secrets" "$guest_secrets" "$guest_secrets" "$guest_secrets")"
  fi
}

provision() {
  [ -f "$nix_marker" ] && die "guest Nix is provisioned; re-clone the guest to reset"
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

# Opt-in: install a guest-local Nix store. The default launcher keeps the host store read-only
# at /nix/store; after this succeeds, the marker makes the launcher use the guest profile and
# store. This is the only way to build Darwin outputs in the guest without forwarding the host
# nix-daemon.
provision_nix() {
  [ -f "$nix_marker" ] && die "guest Nix is already provisioned"
  mkdir -p "$state"
  for _ in $(seq 120); do mkdir "$lock" 2>/dev/null && break; sleep 1; done
  [ -d "$lock" ] || die "another launch holds $lock"
  trap 'rmdir "$lock" 2>/dev/null || true' EXIT
  [ -f "$key" ] && [ -n "$(vm_field Name)" ] || die "not provisioned; run: agent-sandbox provision"
  stop_vm
  host_store=0
  local fresh="$state/plan.json" shares="$state/vm-shares.json" tmp ip
  tmp=$(mktemp "$state/plan.XXXXXX")
  plan >"$tmp" || die "share planning failed"
  mv "$tmp" "$fresh"
  jq '{shares}' "$fresh" >"$shares"
  start_vm "$shares"
  ip=$(wait_for_guest)

  # The launcher's synthetic /nix line owns the mountpoint; the installer needs to create its
  # own APFS volume, so remove the line and reboot before installing.
  guest_ssh -o BatchMode=yes "admin@$ip" "sudo -n sed -i '' '/^nix[[:space:]]/d' /etc/synthetic.conf" || die "could not remove the launcher's synthetic /nix entry"
  guest_ssh -o BatchMode=yes "admin@$ip" 'sudo -n shutdown -r now' >/dev/null 2>&1 || true
  sleep 15
  ip=$(wait_for_guest)

  guest_ssh -t "admin@$ip" "curl --proto '=https' --tlsv1.2 -sSf -L https://install.determinate.systems/nix | sh -s -- install --no-confirm --extra-conf 'experimental-features = nix-command flakes'" || die "guest Nix install failed"
  guest_ssh -o BatchMode=yes "admin@$ip" 'sudo -n sh -c "printf \"min-free = 5368709120\nmax-free = 21474836480\nauto-optimise-store = true\n\" >> /etc/nix/nix.conf"' || true
  guest_ssh -o BatchMode=yes "admin@$ip" 'HOME=/Users/sam /nix/var/nix/profiles/default/bin/nix profile install nixpkgs#git nixpkgs#gh nixpkgs#jq nixpkgs#docker-client nixpkgs#ripgrep nixpkgs#claude-code nixpkgs#cacert nixpkgs#google-cloud-sdk nixpkgs#kubectl' || die "guest tool install failed"
  guest_ssh -o BatchMode=yes "admin@$ip" 'HOME=/Users/sam /nix/var/nix/profiles/default/bin/nix --version' >/dev/null || die "guest Nix is not usable"

  # Weekly GC as a system LaunchDaemon; a headless guest has no Aqua session for a user agent.
  guest_ssh -o BatchMode=yes "admin@$ip" 'sudo -n mkdir -p /Library/LaunchDaemons && sudo -n tee /Library/LaunchDaemons/local.nix-gc.plist >/dev/null <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>local.nix-gc</string>
<key>ProgramArguments</key><array>
<string>/nix/var/nix/profiles/default/bin/nix-collect-garbage</string>
<string>--delete-older-than</string><string>14d</string>
</array>
<key>StartCalendarInterval</key><dict><key>Weekday</key><integer>0</integer><key>Hour</key><integer>3</integer></dict>
</dict></plist>
EOF
sudo -n launchctl bootstrap system /Library/LaunchDaemons/local.nix-gc.plist' || true

  touch "$nix_marker"
  stop_vm
  echo "agent-sandbox: guest Nix store provisioned; the next launch uses the guest profile"
}

case "${1:-}" in
  provision) provision; exit ;;
  provision-nix) provision_nix; exit ;;
  stop) stop_vm; exit ;;
  restart) stop_vm; shift ;;
esac
[ $# -gt 0 ] || set -- claude

[ -f "$key" ] && [ -n "$(vm_field Name)" ] || die "not provisioned; run: agent-sandbox provision"
fresh="$state/plan.json"
shares="$state/vm-shares.json"
# Per-process temp file: concurrent launches each write a whole plan, then rename atomically.
tmp=$(mktemp "$state/plan.XXXXXX")
plan >"$tmp" || die "share planning failed"
if [ "$nix_mode" -eq 1 ]; then
  # The guest profile and Nix state belong to the guest store; the host's links would shadow
  # them, and place_link() refuses a non-empty guest directory.
  jq '(.shares |= map(select(.rel != ".nix-profile" and .rel != ".local/state/nix" and .rel != ".config/nix"))) | (.links |= map(select(.rel != ".nix-profile" and .rel != ".local/state/nix" and .rel != ".config/nix"))) | (.copies |= map(select(. != ".nix-profile" and . != ".local/state/nix" and . != ".config/nix")))' "$tmp" > "$tmp.filtered"
  mv "$tmp.filtered" "$tmp"
fi
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
conf="$guest_home/Library/Application Support/agent-config"
if [ "$nix_mode" -eq 1 ]; then
  ca_file="$guest_home/.nix-profile/etc/ssl/certs/ca-bundle.crt"
else
  ca_file="$ca_bundle"
fi
if [ "$nix_mode" -eq 1 ]; then
  guest_path="$guest_home/.nix-profile/bin:/nix/var/nix/profiles/default/bin:/usr/bin:/bin:/usr/sbin:/sbin"
else
  guest_path="$guest_path_prefix:$PATH"
fi
# The host's CA path comes from the nix installer under /nix/var, which the guest lacks.
remote_cmd=$(printf 'export HOME=%q PATH=%q DOCKER_HOST=unix://%q DOCKER_CONFIG=%q GH_CONFIG_DIR=%q KUBECONFIG=%q CLOUDSDK_CONFIG=%q GIT_CONFIG_GLOBAL=%q SSL_CERT_FILE=%q NIX_SSL_CERT_FILE=%q; cd %q; exec' \
  "$guest_home" "$guest_path" "$sock" "$conf/.docker" "$conf/.config/gh" "$conf/.kube/config" "$conf/.config/gcloud" "$conf/.config/git/config" "$ca_file" "$ca_file" "$cwd")
for a in "$@"; do remote_cmd+=" $(printf %q "$a")"; done
# The forwarded Docker socket is an accepted risk (#427): containers can mount whatever Docker
# Desktop's File sharing allows. ExitOnForwardFailure also makes ssh wait for the forward before
# the command starts, so the agent never races an absent socket.
forward=()
if [ -S "$HOME/.docker/run/docker.sock" ]; then
  forward=(-o ExitOnForwardFailure=yes -R "$sock:$HOME/.docker/run/docker.sock")
fi
exec ssh "${ssh_opts[@]}" -t "${forward[@]}" "admin@$ip" "$remote_cmd"
