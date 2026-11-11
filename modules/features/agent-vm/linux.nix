# The Linux agent boundary (sdlc #386): `agent-sandbox maki` runs maki in the microvm guest that
# modules/nixos/agent-vm.nix declares. T9 makes plain `maki` the `a` default; this launcher and
# its check disappear once kanbeiSplit.cutover.enable flips.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  agentVm = import ../../lib/agent-vm.nix { inherit pkgs lib; };
  launcher = agentVm.launcher config.home.username;

  # Runs in the guest through the real launcher; sudo is the guest's own, never the host's.
  guestCheck = ''
    set -eu
    fail() { echo "agent-vm-check: $*" >&2; exit 1; }
    for p in .config/sops .local/share/keyrings .gnupg .local/share/vault \
      .local/share/todo .ssh Documents Downloads Desktop .local/state/agent .local/share/agent .cache; do
      [ ! -e "$HOME/$p" ] || fail "path $p outside the allowlist is visible"
    done
    [ -r "$HOME/.config/maki/init.lua" ] || fail "the maki config is not visible"
    [ -f "$HOME/.config/git/config" ] || fail "the git config is not visible"
    for c in maki git maki-session-resume; do command -v "$c" >/dev/null || fail "$c is not on PATH"; done
    ! touch "$HOME/.config/.agent-vm-probe" 2>/dev/null || fail "~/.config is writable"
    ! touch "$HOME/.config/maki/.agent-vm-probe" 2>/dev/null || fail "~/.config/maki is writable"
    ! touch "$HOME/.agent-vm-probe" 2>/dev/null || fail "the home root is writable"
    if touch "$HOME/.local/bin/.agent-vm-probe" 2>/dev/null; then
      rm -f "$HOME/.local/bin/.agent-vm-probe"
      fail "~/.local/bin is writable"
    fi
    # The one writable file under the read-only maki config has a guest-local bind-over. A
    # read-only bind rejects the write at virtiofsd, though the guest mount itself is rw.
    lock="$HOME/.config/maki/pack-lock.json.lock"
    if [ -e "$lock" ] && ! touch "$lock" 2>/dev/null; then fail "the maki pack lock is not writable"; fi
    [ -w "$HOME/.local/state/maki" ] || fail "the maki state is not writable"
    [ -w "$HOME/.local/logs/maki" ] || fail "the maki log dir is not writable"
    [ -w "$HOME/repos" ] || fail "repos is not writable"
    [ -w /var/lib/agent-vm/cache ] || fail "the guest cache is not writable"
    probe="$HOME/.local/state/maki/.agent-vm-probe"
    sudo touch "$probe" || fail "a shared writable tree rejects guest root"
    sudo chown 0:0 "$probe" 2>/dev/null || true
    ! sudo mknod "$HOME/.local/state/maki/.agent-vm-dev" b 8 0 2>/dev/null || fail "guest root can mknod in a shared tree"
    [ -r /run/secrets/github-personal-pat ] || fail "hand-in secrets are unreadable"
    ! timeout 3 bash -c 'exec 3<>/dev/tcp/${agentVm.hostAddr}/22' 2>/dev/null || fail "host sshd is reachable from the guest"
    timeout 3 bash -c 'exec 3<>/dev/tcp/127.0.0.1/${toString (import ../../ports.nix).memoryMcp}' || fail "the memory proxy is unreachable"
    ! ls /dev/hidraw* >/dev/null 2>&1 || fail "the guest sees hidraw devices"
  '';
  agentVmCheck = pkgs.writeShellApplication {
    name = "agent-vm-check";
    runtimeInputs = [ pkgs.coreutils ];
    text = ''
      # shellcheck disable=SC2016 # the guest script is expanded by the guest's bash
      ${launcher}/bin/agent-sandbox bash -c ${lib.escapeShellArg guestCheck}
      probe="$HOME/.local/state/maki/.agent-vm-probe"
      # Guest root wrote it and tried to chown it to root: squashing must leave it the human's.
      [ "$(stat -c %u "$probe")" = "$(id -u)" ] || { echo "agent-vm-check: guest root owns host files" >&2; exit 1; }
      rm -f "$probe"
      echo "agent-vm-check: ok"
    '';
  };
in
{
  config =
    lib.mkIf (pkgs.stdenv.hostPlatform.isLinux && !(config.kanbeiSplit.cutover.enable or false))
      {
        home.packages = [
          launcher
          agentVmCheck
        ];
      };
}
