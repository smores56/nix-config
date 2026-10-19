#!/usr/bin/env bash
set -euo pipefail

# Idempotent bootstrap for a fresh machine with only Nix installed.
#
# Usage (flake app):
#   nix run github:smores56/nix-config#bootstrap
#
# Or the served copy, from Bash, Zsh, or Fish:
#   curl -fsSL bootstrap.sammohr.dev | bash
#
# Override auto-detected user/host or the checkout root (prefix the command;
# these are read from the environment, not from arguments):
#   BOOTSTRAP_USER=smores BOOTSTRAP_HOST=smorespro nix run github:smores56/nix-config#bootstrap
#   BOOTSTRAP_CODE_ROOT="$HOME/code" nix run github:smores56/nix-config#bootstrap

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

# GitHub advertises a token's OAuth scopes in the `x-oauth-scopes` response
# header, but only for classic tokens. A fine-grained PAT omits the header and
# is scoped by its configured permissions instead (needs "Git SSH keys: write"
# and "SSH signing keys: write"), so an absent header means "cannot tell", not
# "missing". Returns 0 when the scopes are present and sufficient, 1 when they
# are present but insufficient, and 2 when the header is absent.
scope_status() {
  local needed="$1"
  local current
  current="$(gh api -i user 2>/dev/null | awk '
    tolower($0) ~ /^x-oauth-scopes:/ {
      sub(/^[Xx]-[Oo]auth-[Ss]copes:[[:space:]]*/, "")
      gsub(/[[:space:]]/, "")
      print
      exit
    }
  ')"
  [ -n "$current" ] || return 2

  local scope
  local IFS=','
  for scope in $needed; do
    case ",${current}," in
      *",${scope},"*) ;;
      *) return 1 ;;
    esac
  done
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

# This shell predates the profile the switch created, so put the generation it
# just built first on PATH; every later phase runs its tools.
PATH="$(readlink -f "${XDG_STATE_HOME:-${HOME}/.local/state}/home-manager/gcroots/current-home")/home-path/bin:${PATH}"
export PATH

# ── Phase 4: SSH identities from Proton Pass ──────────────────────
#
# Identities live in Proton Pass; the agent home-manager installed serves their
# private halves over SSH_AUTH_SOCK, so nothing is generated here. The public
# halves are fetched from the vault by `ssh-pub-keys` (modules/features/
# ssh-keys.nix), the same command every switch runs.

# A headless host logs in with the vault's PAT (sops-delivered, non-interactive);
# elsewhere the session is established interactively in a browser.
PROTON_PASS_PAT_FILE="${PROTON_PASS_PAT_FILE:-/run/secrets/proton-pass-pat}"
if [ -s "$PROTON_PASS_PAT_FILE" ]; then
  info "Logging in to Proton Pass with the vault PAT..."
  if PROTON_PASS_PERSONAL_ACCESS_TOKEN="$(cat "$PROTON_PASS_PAT_FILE")" \
    PROTON_PASS_KEY_PROVIDER="${PROTON_PASS_KEY_PROVIDER:-fs}" \
    pass-cli login; then
    ok "Logged in to Proton Pass"
  else
    warn "Proton Pass PAT login failed; log in interactively later."
  fi
fi

# The Phase 3 switch already ran ssh-pub-keys, before pass-cli was logged in.
if ssh-pub-keys; then
  ok "SSH public keys present and trusted in ~/.ssh/allowed_signers"
else
  warn "Some SSH public keys are missing (see above); re-run this script after logging in."
fi

# ── Phase 5: GitHub authentication ────────────────────────────────

GH_KEY_SCOPES="write:public_key,write:ssh_signing_key"
# dotfiles.sshKey in modules/options.nix; bash cannot read the option.
SSH_KEY="${HOME}/.ssh/id_personal"

# A headless host authenticates with the vault's GitHub PAT (sops-delivered,
# non-interactive); elsewhere use the device code flow in a browser.
GITHUB_PAT_FILE="${GITHUB_PAT_FILE:-/run/secrets/github-key-pat}"
GH_USED_PAT=0
if gh auth token --hostname "$GITHUB_HOST" --user "$GITHUB_USER" >/dev/null 2>&1; then
  skip "Already authenticated with GitHub as ${GITHUB_USER}"
elif [ -s "$GITHUB_PAT_FILE" ]; then
  GH_USED_PAT=1
  info "Authenticating with GitHub as ${GITHUB_USER} with the vault PAT..."
  gh auth login --hostname "$GITHUB_HOST" --git-protocol ssh --with-token <"$GITHUB_PAT_FILE"
  gh auth token --hostname "$GITHUB_HOST" --user "$GITHUB_USER" >/dev/null 2>&1 \
    || err "GitHub PAT authentication did not create credentials for ${GITHUB_USER}."
  ok "GitHub authentication complete"
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

if scope_status "$GH_KEY_SCOPES"; then
  skip "GitHub auth already has required scopes (${GH_KEY_SCOPES})"
else
  scope_code=$?
  if [ "$scope_code" = "2" ]; then
    warn "GitHub token advertises no OAuth scopes (fine-grained PAT); relying on its configured permissions (needs 'Git SSH keys: write' and 'SSH signing keys: write')."
  elif [ "$GH_USED_PAT" = "1" ]; then
    err "The GitHub PAT is missing required scopes (${GH_KEY_SCOPES}). Grant them to the token and re-run (a PAT session cannot refresh scopes non-interactively)."
  else
    info "Adding missing GitHub auth scopes (${GH_KEY_SCOPES})..."
    gh auth refresh --hostname "$GITHUB_HOST" --scopes "$GH_KEY_SCOPES"
    ok "GitHub auth scopes ready"
  fi
fi

if [ ! -s "${SSH_KEY}.pub" ]; then
  warn "Skipping GitHub SSH key registration: ${SSH_KEY}.pub is missing."
  warn "Log in to Proton Pass (see Phase 4) and re-run this script."
else
  SSH_KEY_BLOB="$(awk '{print $2}' "${SSH_KEY}.pub")"
  # --paginate: the key lists are paged (30/page); without it a key beyond the
  # first page looks unregistered and is re-added, failing on the duplicate. The
  # here-string also avoids a `gh | grep -q` SIGPIPE/pipefail false negative.
  existing_auth_keys="$(gh api user/keys --paginate --jq '.[].key')"
  if grep -qF "$SSH_KEY_BLOB" <<<"$existing_auth_keys"; then
    skip "SSH authentication key already registered with GitHub"
  else
    info "Adding SSH authentication key to GitHub..."
    gh ssh-key add "${SSH_KEY}.pub" --type authentication --title "${CONFIG_NAME}"
    ok "SSH authentication key added to GitHub"
  fi

  existing_signing_keys="$(gh api user/ssh_signing_keys --paginate --jq '.[].key')"
  if grep -qF "$SSH_KEY_BLOB" <<<"$existing_signing_keys"; then
    skip "SSH signing key already registered with GitHub"
  else
    info "Adding SSH signing key to GitHub..."
    gh ssh-key add "${SSH_KEY}.pub" --type signing --title "${CONFIG_NAME} signing"
    ok "SSH signing key added to GitHub"
  fi
fi

# ── Phase 6: Switch remote to SSH ─────────────────────────────────

# A shell that predates the home-manager switch (this one) has no SSH_AUTH_SOCK
# yet; derive the agent's default socket, matching the home-manager module.
if [ -z "${SSH_AUTH_SOCK:-}" ]; then
  if [ "$(uname -s)" = "Darwin" ]; then
    SSH_AUTH_SOCK="$(getconf DARWIN_USER_TEMP_DIR)/proton-pass-agent"
  else
    SSH_AUTH_SOCK="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/proton-pass-agent"
  fi
  export SSH_AUTH_SOCK
fi

CURRENT_REMOTE="$(git -C "$REPO_DIR" remote get-url origin 2>/dev/null || true)"
if ! ssh-add -L >/dev/null 2>&1; then
  warn "No SSH identity from the Proton Pass agent; leaving the HTTPS remote in place."
elif [ "$CURRENT_REMOTE" = "$REPO_URL_SSH" ]; then
  skip "Remote already using SSH"
else
  info "Switching remote from HTTPS to SSH..."
  git -C "$REPO_DIR" remote set-url origin "$REPO_URL_SSH"
  ok "Remote switched to SSH"
fi

# ── Phase 7: NixOS setup ──────────────────────────────────────────

if is_nixos && has_nixos_config; then
  info "NixOS detected with config for ${HOSTNAME}"

  HARDWARE_DEST="${REPO_DIR}/modules/hosts/${HOSTNAME}/hardware.nix"

  if [ ! -f "$HARDWARE_DEST" ]; then
    info "Generating hardware configuration..."
    sudo nixos-generate-config --force
    mkdir -p "$(dirname "$HARDWARE_DEST")"
    cp /etc/nixos/hardware-configuration.nix "$HARDWARE_DEST"
    ok "Hardware config saved to ${HARDWARE_DEST}"
    warn "Commit this file: cd ${REPO_DIR} && git add modules/hosts/${HOSTNAME} && git commit -m 'Add ${HOSTNAME} hardware config'"
  else
    skip "Hardware config already exists at ${HARDWARE_DEST}"
  fi

  info "Running nixos-rebuild switch (this may take a while)..."
  sudo nixos-rebuild switch --flake "${REPO_DIR}#${HOSTNAME}" --upgrade
  ok "NixOS rebuild complete"
elif is_nixos; then
  warn "NixOS detected but no nixosConfiguration for '${HOSTNAME}'."
  warn "Add modules/hosts/${HOSTNAME}/meta.nix (with nixos = true) and re-run."
fi

# ── Done ──────────────────────────────────────────────────────────

echo ""
ok "Bootstrap complete for ${CONFIG_NAME}!"
echo ""
info "Next steps:"
echo "  - Open a new terminal to load fish shell"
echo "  - Verify: gh auth status"
