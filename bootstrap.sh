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

contains_line() {
  local needle="$1"
  local lines="$2"
  while IFS= read -r line; do
    [ "$line" = "$needle" ] && return 0
  done <<< "$lines"
  return 1
}

format_names() {
  local names="$1"
  printf '%s' "${names//$'\n'/ }"
}

flake_attr_names() {
  local attr="$1"
  nix eval --impure --raw --expr "builtins.concatStringsSep \"\n\" (builtins.attrNames (builtins.getFlake \"git+file://${REPO_DIR}\").${attr})"
}

has_nixos_config() {
  contains_line "$HOSTNAME" "$NIXOS_CONFIGS"
}

# ── Phase 0: Validate ─────────────────────────────────────────────

command -v nix >/dev/null 2>&1 || err "Nix is not installed"

# Enable flakes for all nix commands in this script (nix.conf doesn't exist yet
# on a fresh machine — home-manager will create it once it runs)
export NIX_CONFIG="experimental-features = nix-command flakes"

info "Bootstrapping ${CONFIG_NAME}"

# ── Phase 1: Clone repository ─────────────────────────────────────

if [ -d "${REPO_DIR}/.git" ] || [ -f "${REPO_DIR}/.git" ]; then
  skip "Repository already cloned at ${REPO_DIR}"
else
  info "Cloning repository via HTTPS..."
  mkdir -p "$(dirname "${REPO_DIR}")"
  nix-shell -p git --run "git clone '${REPO_URL_HTTPS}' '${REPO_DIR}'"
  ok "Repository cloned"
fi

# ── Phase 2: Validate flake configuration ─────────────────────────

HOME_CONFIGS="$(flake_attr_names homeConfigurations)" || err "Unable to read homeConfigurations from ${REPO_DIR}"
NIXOS_CONFIGS="$(flake_attr_names nixosConfigurations)" || err "Unable to read nixosConfigurations from ${REPO_DIR}"

contains_line "$CONFIG_NAME" "$HOME_CONFIGS" \
  || err "No home-manager config for '${CONFIG_NAME}'. Known: $(format_names "$HOME_CONFIGS")"

# ── Phase 3: Create home-manager symlink ──────────────────────────

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

# ── Phase 4: home-manager switch ──────────────────────────────────

info "Running home-manager switch (this may take a while on first run)..."
nix-shell -p home-manager --run "home-manager switch --no-write-lock-file"
ok "home-manager switch complete"

export PATH="${HOME}/.nix-profile/bin:${PATH}"

# ── Phase 5: SSH key generation ───────────────────────────────────

SSH_KEY="${HOME}/.ssh/id_personal"
if [ -f "$SSH_KEY" ]; then
  skip "SSH key already exists at ${SSH_KEY}"
else
  info "Generating SSH key..."
  mkdir -p "${HOME}/.ssh"
  chmod 700 "${HOME}/.ssh"
  ssh-keygen -t ed25519 -C "$EMAIL" -f "$SSH_KEY" -N ""
  ok "SSH key generated"
fi

# ── Phase 6: GitHub authentication ────────────────────────────────

GH_KEY_SCOPES="read:public_key,write:public_key,read:ssh_signing_key,write:ssh_signing_key"

if gh auth status &>/dev/null; then
  skip "Already authenticated with GitHub"
  info "Ensuring GitHub auth has SSH key management scopes..."
  gh auth refresh --scopes "$GH_KEY_SCOPES"
  ok "GitHub auth scopes ready"
else
  info "Authenticating with GitHub (device code flow)..."
  info "A code will appear below. Visit https://github.com/login/device from any browser to enter it."
  gh auth login --git-protocol ssh --web --skip-ssh-key --scopes "$GH_KEY_SCOPES"
  ok "GitHub authentication complete"
fi

SSH_KEY_BLOB="$(awk '{print $2}' "${SSH_KEY}.pub")"
if gh api user/keys --jq '.[].key' | grep -qF "$SSH_KEY_BLOB"; then
  skip "SSH authentication key already registered with GitHub"
else
  info "Adding SSH authentication key to GitHub..."
  gh ssh-key add "${SSH_KEY}.pub" --type authentication --title "${CONFIG_NAME}"
  ok "SSH authentication key added to GitHub"
fi

if gh api user/ssh_signing_keys --jq '.[].key' | grep -qF "$SSH_KEY_BLOB"; then
  skip "SSH signing key already registered with GitHub"
else
  info "Adding SSH signing key to GitHub..."
  gh ssh-key add "${SSH_KEY}.pub" --type signing --title "${CONFIG_NAME} signing"
  ok "SSH signing key added to GitHub"
fi

# ── Phase 7: Switch remote to SSH ─────────────────────────────────

CURRENT_REMOTE="$(git -C "$REPO_DIR" remote get-url origin 2>/dev/null || true)"
if [ "$CURRENT_REMOTE" = "$REPO_URL_SSH" ]; then
  skip "Remote already using SSH"
else
  info "Switching remote from HTTPS to SSH..."
  git -C "$REPO_DIR" remote set-url origin "$REPO_URL_SSH"
  ok "Remote switched to SSH"
fi

# ── Phase 8: NixOS setup ──────────────────────────────────────────

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
  sudo nixos-rebuild switch --flake "${REPO_DIR}#${HOSTNAME}" --upgrade
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
