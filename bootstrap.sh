#!/usr/bin/env bash
set -euo pipefail

# Idempotent bootstrap for a fresh machine with only Nix installed.
#
# Usage from Bash, Zsh, or Fish:
#   curl -fsSL bootstrap.sammohr.dev | bash
#
# Override auto-detected user/host:
#   curl -fsSL bootstrap.sammohr.dev | env BOOTSTRAP_USER=smohr BOOTSTRAP_HOST=smoreswork bash
#
# Override repository root:
#   curl -fsSL bootstrap.sammohr.dev | env BOOTSTRAP_CODE_ROOT="$HOME/code" bash

REPO_OWNER="smores56"
REPO_NAME="nix-config"
REPO_URL_HTTPS="https://github.com/${REPO_OWNER}/${REPO_NAME}.git"
REPO_URL_SSH="git@github.com:${REPO_OWNER}/${REPO_NAME}.git"
GITHUB_HOST="github.com"
GITHUB_USER="${BOOTSTRAP_GITHUB_USER:-${REPO_OWNER}}"
CODE_ROOT="${BOOTSTRAP_CODE_ROOT:-${HOME}/code}"
REPO_DIR="${CODE_ROOT}/${GITHUB_HOST}/${REPO_OWNER}/${REPO_NAME}"

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

is_git_checkout() {
  [ -d "$1/.git" ] || [ -f "$1/.git" ]
}

is_nonempty_dir() {
  [ -d "$1" ] && [ -n "$(find "$1" -mindepth 1 -maxdepth 1 -print -quit)" ]
}

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

validate_origin() {
  local actual
  actual="$(git -C "$1" remote get-url origin 2>/dev/null || true)"
  case "$actual" in
    "$REPO_URL_HTTPS"|"$REPO_URL_SSH") return 0 ;;
    "") err "Existing checkout at ${1} has no 'origin' remote. Remove or rename it, or set BOOTSTRAP_CODE_ROOT to a clean directory." ;;
    *)  err "Existing checkout at ${1} has unexpected origin '${actual}' (expected ${REPO_URL_HTTPS} or ${REPO_URL_SSH}). Remove or rename it, or set BOOTSTRAP_CODE_ROOT to a clean directory." ;;
  esac
}

clone_repo() {
  mkdir -p "$(dirname "$REPO_DIR")"
  GHQ_ROOT="$CODE_ROOT" nix-shell -p ghq --run "ghq get '${REPO_URL_HTTPS}'"
}

# ── Phase 0: Validate ─────────────────────────────────────────────

command -v nix >/dev/null 2>&1 || err "Nix is not installed"

# Enable flakes for all nix commands in this script (nix.conf doesn't exist yet
# on a fresh machine — home-manager will create it once it runs)
export NIX_CONFIG="experimental-features = nix-command flakes"

info "Bootstrapping ${CONFIG_NAME}"

# ── Phase 1: Clone repository via ghq ─────────────────────────────

if is_git_checkout "$REPO_DIR"; then
  validate_origin "$REPO_DIR"
  skip "Repository already at ${REPO_DIR}"
elif is_nonempty_dir "$REPO_DIR"; then
  err "${REPO_DIR} exists but is not a Git checkout. Remove or rename it, or set BOOTSTRAP_CODE_ROOT to a clean directory."
else
  info "Cloning repository via ghq into ${REPO_DIR}..."
  clone_repo
  ok "Repository cloned"
fi

# ── Phase 2: Validate flake configuration ─────────────────────────

HOME_CONFIGS="$(flake_attr_names homeConfigurations)" || err "Unable to read homeConfigurations from ${REPO_DIR}"
NIXOS_CONFIGS="$(flake_attr_names nixosConfigurations)" || err "Unable to read nixosConfigurations from ${REPO_DIR}"

contains_line "$CONFIG_NAME" "$HOME_CONFIGS" \
  || err "No home-manager config for '${CONFIG_NAME}'. Known: $(format_names "$HOME_CONFIGS")"

# ── Phase 3: home-manager switch ──────────────────────────────────

info "Running home-manager switch (this may take a while on first run)..."
nix-shell -p home-manager --run "home-manager switch --flake '${REPO_DIR}#${CONFIG_NAME}' --no-write-lock-file"
ok "home-manager switch complete"

export PATH="${HOME}/.nix-profile/bin:${PATH}"

# ── Phase 4: SSH key generation ───────────────────────────────────

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

# ── Phase 5: GitHub authentication ────────────────────────────────

GH_KEY_SCOPES="read:public_key,write:public_key,read:ssh_signing_key,write:ssh_signing_key"

if gh auth token --hostname "$GITHUB_HOST" --user "$GITHUB_USER" >/dev/null 2>&1; then
  skip "Already authenticated with GitHub as ${GITHUB_USER}"
else
  info "Authenticating with GitHub as ${GITHUB_USER} (device code flow)..."
  info "A code will appear below. Visit https://github.com/login/device from any browser to enter it."
  gh auth login --hostname "$GITHUB_HOST" --git-protocol ssh --web --skip-ssh-key --scopes "$GH_KEY_SCOPES"
  gh auth token --hostname "$GITHUB_HOST" --user "$GITHUB_USER" >/dev/null 2>&1 \
    || err "GitHub authentication did not create credentials for ${GITHUB_USER}. Re-run and choose ${GITHUB_USER} in the browser."
  ok "GitHub authentication complete"
fi

info "Selecting GitHub account ${GITHUB_USER}..."
gh auth switch --hostname "$GITHUB_HOST" --user "$GITHUB_USER" >/dev/null \
  || err "Unable to select GitHub account ${GITHUB_USER}. Run: gh auth switch --hostname ${GITHUB_HOST} --user ${GITHUB_USER}"
ok "Using GitHub account ${GITHUB_USER}"

ACTIVE_GITHUB_USER="$(gh api user --jq .login 2>/dev/null || true)"
[ "$ACTIVE_GITHUB_USER" = "$GITHUB_USER" ] \
  || err "gh is authenticated as '${ACTIVE_GITHUB_USER:-unknown}', expected '${GITHUB_USER}'. Unset GH_TOKEN/GITHUB_TOKEN or authenticate as ${GITHUB_USER}."

info "Ensuring GitHub auth has SSH key management scopes..."
gh auth refresh --hostname "$GITHUB_HOST" --scopes "$GH_KEY_SCOPES"
ok "GitHub auth scopes ready"

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
