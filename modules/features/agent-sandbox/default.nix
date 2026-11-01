# The agent sandbox is the explicit entry point for any agent harness:
#
#   agent-sandbox maki
#
# `m` is a shell abbreviation for that command, not a wrapper binary. Plain
# `maki` is the manually installed binary and runs unsandboxed. The lists and
# backend live in modules/lib/agent-sandbox.nix and agent-sandbox.sh.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.agentSandbox;
  isServer = builtins.elem "server" config.machine.profiles;
  isDarwin = pkgs.stdenv.hostPlatform.isDarwin;
  sandbox = import ../../lib/agent-sandbox.nix {
    inherit
      pkgs
      lib
      isServer
      isDarwin
      ;
  };
in
{
  options.agentSandbox.enable = lib.mkOption {
    type = lib.types.bool;
    default = true;
    description = "the same-UID agent sandbox (bwrap/Seatbelt)";
  };

  config = lib.mkIf cfg.enable {
    home.packages = [
      sandbox.agentSandbox

      # A one-time operator cleanup, never automatic. It removes the retired
      # private keys and the gh OAuth token, and clears the clipboard history.
      (pkgs.writeShellApplication {
        name = "agent-sandbox-cleanup";
        runtimeInputs = [ pkgs.coreutils ];
        text = ''
          if [ "''${1:-}" != "--yes" ]; then
            echo "usage: agent-sandbox-cleanup --yes" >&2
            echo "removes ''${HOME}/.config/maki/signing_ed25519, ''${HOME}/.config/pi/ssh," >&2
            echo "''${HOME}/.config/gh/hosts.yml, and the cliphist/fish history" >&2
            exit 2
          fi
          rm -f "$HOME/.config/maki/signing_ed25519" "$HOME/.config/maki/signing_ed25519.pub"
          rm -rf "$HOME/.config/pi/ssh"
          rm -f "$HOME/.config/gh/hosts.yml"
          rm -rf "$HOME/.cache/cliphist"
          : > "$HOME/.local/share/fish/fish_history" 2>/dev/null || true
          echo "agent-sandbox-cleanup: done" >&2
        '';
      })

      # Operator check: runs the real sandbox and asserts the boundary. It
      # needs the user's home, so it is not a nix-build check.
      (pkgs.writeShellApplication {
        name = "agent-sandbox-check";
        runtimeInputs = [
          pkgs.coreutils
          pkgs.findutils
          pkgs.gnugrep
        ];
        text = ''
          sb=${sandbox.agentSandbox}/bin/agent-sandbox
          # shellcheck disable=SC2016 # the inner script is evaluated by /bin/sh
          "$sb" /bin/sh -c '
            set -eu
            if [ -r /proc/self/status ]; then
              grep -q "^NoNewPrivs:[[:space:]]*1" /proc/self/status
            fi
            test -z "$(command -v sudo || true)"
            test ! -e /run/wrappers/bin/sudo
            test ! -e /run/current-system/sw/bin/sudo
            test -z "$(ls -A "$HOME/.ssh")"
            test -z "$(ls -A "$HOME/.config")"
            ! touch "$HOME/.agent-sandbox-probe" 2>/dev/null
            if [ -d "$HOME/code" ]; then
              touch "$HOME/code/.agent-sandbox-probe"
              rm "$HOME/code/.agent-sandbox-probe"
            fi
            if [ -d /var/lib/media ]; then
              touch /var/lib/media/.agent-sandbox-probe
              rm /var/lib/media/.agent-sandbox-probe
              mkdir /var/lib/media/.agent-sandbox-probe-dir
              rmdir /var/lib/media/.agent-sandbox-probe-dir
            fi
            if [ -d /var/lib/media/Photos ]; then
              test -z "$(ls -A /var/lib/media/Photos)"
              ! touch /var/lib/media/Photos/.agent-sandbox-probe 2>/dev/null
            fi
            if [ -d /var/lib/media/Calibre-Ingest ]; then
              touch /var/lib/media/Calibre-Ingest/.agent-sandbox-probe
              rm /var/lib/media/Calibre-Ingest/.agent-sandbox-probe
            fi
            repo=$(find "$HOME/code" "$HOME/dev" -maxdepth 8 -name .git -type d -prune -print 2>/dev/null | head -n 1)
            if [ -n "$repo" ]; then
              ! touch "$repo/config" 2>/dev/null
              ! touch "$repo/hooks/.agent-sandbox-probe" 2>/dev/null
            fi
            command -v maki >/dev/null && maki --version >/dev/null
            nix store ping >/dev/null 2>&1
          '
          echo "agent-sandbox-check: ok"
        '';
      })
    ];
  };
}
