#!/usr/bin/env bash
set -euo pipefail

# Idempotent bootstrap for a fresh machine with only Nix installed.
#
# Usage:
#   bash <(curl -fsSL https://raw.githubusercontent.com/smores56/nix-config/main/bootstrap.sh)
#
# Override auto-detected user/host:
#   BOOTSTRAP_USER=smohr BOOTSTRAP_HOST=smoreswork bash <(curl ...)

REPO_OWNER="smores56"
REPO_NAME="nix-config"
REPO_URL_HTTPS="https://github.com/${REPO_OWNER}/${REPO_NAME}.git"
REPO_URL_SSH="git@github.com:${REPO_OWNER}/${REPO_NAME}.git"
REPO_DIR="${HOME}/dev/repos/github.com/${REPO_OWNER}/${REPO_NAME}"
HM_LINK="${HOME}/.config/home-manager"

USERNAME="${BOOTSTRAP_USER:-$(whoami)}"
HOSTNAME="${BOOTSTRAP_HOST:-$(hostname -s 2>/dev/null || hostname)}"
CONFIG_NAME="${USERNAME}@${HOSTNAME}"

KNOWN_HOME_CONFIGS=(
  "smores@smorestux"
  "smores@smoresbook"
  "smores@campfire"
  "smores@smortress"
  "smores@smoresnet"
  "smohr@smoreswork"
)
KNOWN_NIXOS_CONFIGS=(
  "campfire"
  "smorestux"
  "smoresbook"
  "smortress"
)

case "$USERNAME" in
  smohr) EMAIL="sam.mohr@sevenai.com" ;;
  *)     EMAIL="sam@sammohr.dev" ;;
esac

info()  { printf '\033[1;34m[info]\033[0m  %s\n' "$*"; }
ok()    { printf '\033[1;32m[ok]\033[0m    %s\n' "$*"; }
warn()  { printf '\033[1;33m[warn]\033[0m  %s\n' "$*"; }
err()   { printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; exit 1; }
skip()  { printf '\033[1;36m[skip]\033[0m  %s\n' "$*"; }

is_nixos() { [ -f /etc/NIXOS ] || command -v nixos-version &>/dev/null; }

has_nixos_config() {
  for h in "${KNOWN_NIXOS_CONFIGS[@]}"; do
    [ "$h" = "$HOSTNAME" ] && return 0
  done
  return 1
}

# ── Phase 0: Validate ─────────────────────────────────────────────

command -v nix >/dev/null 2>&1 || err "Nix is not installed"

valid=false
for c in "${KNOWN_HOME_CONFIGS[@]}"; do
  [ "$c" = "$CONFIG_NAME" ] && valid=true && break
done
$valid || err "No home-manager config for '${CONFIG_NAME}'. Known: ${KNOWN_HOME_CONFIGS[*]}"

info "Bootstrapping ${CONFIG_NAME}"

# ── Phase 1: Clone repository ─────────────────────────────────────

if [ -d "${REPO_DIR}/.git" ] || [ -f "${REPO_DIR}/.git" ]; then
  skip "Repository already cloned at ${REPO_DIR}"
else
  info "Cloning repository via HTTPS..."
  mkdir -p "$(dirname "$REPO_DIR")"
  nix-shell -p git --run "git clone ${REPO_URL_HTTPS} ${REPO_DIR}"
  ok "Repository cloned"
fi

# ── Phase 2: Create home-manager symlink ──────────────────────────

if [ -L "$HM_LINK" ] && [ "$(readlink "$HM_LINK")" = "$REPO_DIR" ]; then
  skip "home-manager symlink already correct"
elif [ -e "$HM_LINK" ]; then
  err "${HM_LINK} already exists but is not the expected symlink. Remove it and re-run."
else
  info "Creating home-manager symlink..."
  mkdir -p "$(dirname "$HM_LINK")"
  ln -s "$REPO_DIR" "$HM_LINK"
  ok "Symlinked ${HM_LINK} -> ${REPO_DIR}"
fi

# ── Phase 3: home-manager switch ──────────────────────────────────

info "Running home-manager switch (this may take a while on first run)..."
nix-shell -p home-manager --run "home-manager switch --no-write-lock-file"
ok "home-manager switch complete"

export PATH="${HOME}/.nix-profile/bin:${PATH}"

# ── Phase 4: SSH key generation ───────────────────────────────────

SSH_KEY="${HOME}/.ssh/id_ed25519"
if [ -f "$SSH_KEY" ]; then
  skip "SSH key already exists at ${SSH_KEY}"
else
  info "Generating SSH key..."
  mkdir -p "${HOME}/.ssh"
  chmod 700 "${HOME}/.ssh"
  ssh-keygen -t ed25519 -C "$EMAIL" -f "$SSH_KEY" -N ""
  ok "SSH key generated"
fi

# ── Phase 5: GitHub authentication ────────────────────────────────

if gh auth status &>/dev/null; then
  skip "Already authenticated with GitHub"
else
  info "Authenticating with GitHub (device code flow)..."
  info "A code will appear below. Visit https://github.com/login/device from any browser to enter it."
  gh auth login --git-protocol ssh --web
  ok "GitHub authentication complete"
fi

SSH_KEY_FINGERPRINT="$(ssh-keygen -lf "${SSH_KEY}.pub" | awk '{print $2}')"
if gh ssh-key list 2>/dev/null | grep -q "$SSH_KEY_FINGERPRINT"; then
  skip "SSH key already registered with GitHub"
else
  info "Adding SSH key to GitHub..."
  gh ssh-key add "${SSH_KEY}.pub" --title "${CONFIG_NAME}"
  ok "SSH key added to GitHub"
fi

# ── Phase 6: Switch remote to SSH ─────────────────────────────────

CURRENT_REMOTE="$(git -C "$REPO_DIR" remote get-url origin 2>/dev/null || true)"
if [ "$CURRENT_REMOTE" = "$REPO_URL_SSH" ]; then
  skip "Remote already using SSH"
else
  info "Switching remote from HTTPS to SSH..."
  git -C "$REPO_DIR" remote set-url origin "$REPO_URL_SSH"
  ok "Remote switched to SSH"
fi

# ── Phase 7: NixOS setup ──────────────────────────────────────────

if is_nixos && has_nixos_config; then
  info "NixOS detected with config for ${HOSTNAME}"

  HARDWARE_DEST="${REPO_DIR}/modules/hosts/${HOSTNAME}.nix"

  if [ ! -f "$HARDWARE_DEST" ]; then
    info "Generating hardware configuration..."
    sudo nixos-generate-config --force
    cp /etc/nixos/hardware-configuration.nix "$HARDWARE_DEST"
    ok "Hardware config saved to ${HARDWARE_DEST}"
    warn "Commit this file: cd ${REPO_DIR} && git add modules/hosts/${HOSTNAME}.nix && git commit -m 'Add ${HOSTNAME} hardware config'"
  else
    skip "Hardware config already exists at ${HARDWARE_DEST}"
  fi

  info "Running nixos-rebuild switch (this may take a while)..."
  sudo nixos-rebuild switch --flake "$REPO_DIR" --upgrade
  ok "NixOS rebuild complete"
elif is_nixos; then
  warn "NixOS detected but no nixosConfiguration for '${HOSTNAME}'."
  warn "Add a config to modules/flake/configurations.nix and re-run."
fi

# ── Done ──────────────────────────────────────────────────────────

echo ""
ok "Bootstrap complete for ${CONFIG_NAME}!"
echo ""
info "Next steps:"
echo "  - Open a new terminal to load fish shell"
if is_nixos; then
  echo "  - Run 'sudo tailscale up' to join the tailnet"
fi
echo "  - Verify: gh auth status"
