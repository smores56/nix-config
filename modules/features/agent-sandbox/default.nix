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
            if [ -d "$HOME/.local/logs" ]; then
              mkdir -p "$HOME/.local/logs/maki"
              : > "$HOME/.local/logs/maki/.agent-sandbox-probe"
              rm "$HOME/.local/logs/maki/.agent-sandbox-probe"
            fi
            if [ -e "$XDG_CONFIG_HOME/maki/pack-lock.json.lock" ]; then
              test -w "$XDG_CONFIG_HOME/maki/pack-lock.json.lock"
            fi
            ! touch "$HOME/.agent-sandbox-probe" 2>/dev/null
            if [ -d "$HOME/code" ]; then
              touch "$HOME/code/.agent-sandbox-probe"
              rm "$HOME/code/.agent-sandbox-probe"
            fi
            if [ -d /var/lib/data/music ]; then
              touch /var/lib/data/music/.agent-sandbox-probe
              rm /var/lib/data/music/.agent-sandbox-probe
              mkdir /var/lib/data/music/.agent-sandbox-probe-dir
              rmdir /var/lib/data/music/.agent-sandbox-probe-dir
            fi
            # A mask is a tmpfs, so anything written inside it is scratch in the
            # private namespace and says nothing about the host. Emptiness is the
            # assertion: the real directory's contents must not be visible.
            if [ -d /var/lib/data/photos ]; then
              test -z "$(ls -A /var/lib/data/photos)"
            fi
            # A mask is an empty tmpfs, and a tmpfs is writable: emptiness is
            # the assertion (the host ciphertext is unreachable), not refusal of
            # a write, which lands in the namespace and vanishes.
            if [ -d /var/lib/data/vault ]; then
              test -z "$(ls -A /var/lib/data/vault)"
            fi
            if [ -d "$HOME/Sync" ]; then
              test -z "$(ls -A "$HOME/Sync")"
            fi
            if [ -d /var/lib/agent/books-ingest ]; then
              touch /var/lib/agent/books-ingest/.agent-sandbox-probe
              rm /var/lib/agent/books-ingest/.agent-sandbox-probe
            fi
            repo_list="$XDG_STATE_HOME/agent-sandbox-repos"
            find "$HOME/code" "$HOME/dev" -maxdepth 8 -name .git -type d -prune -print >"$repo_list" 2>/dev/null || true
            repo_count=0
            while IFS= read -r repo; do
              [ -n "$repo" ] || continue
              repo_count=$((repo_count + 1))
              ! touch "$repo/config" 2>/dev/null
              ! touch "$repo/hooks/.agent-sandbox-probe" 2>/dev/null
              if [ "$repo_count" -ge 5 ]; then
                break
              fi
            done <"$repo_list"
            rm -f "$repo_list"
            test ! -e /run/user
            command -v maki >/dev/null && maki --version >/dev/null
            nix store ping >/dev/null 2>&1
            if [ -S /nix/var/nix/daemon-socket/socket ]; then
              # The resolved store URL, not the raw setting: the read-only state
              # dir is what makes `store = auto` fall through to the daemon.
              nix store info --json | grep -q '"url":"daemon"'
              ! test -w /nix/var/nix
            fi
          '
          echo "agent-sandbox-check: ok"
        '';
      })
    ];
  };
}
