# `agent-sandbox maki` is the explicit entry point for any agent harness; `m` is a shell
# abbreviation, and plain `maki` is the manually installed binary and runs unsandboxed.
# Lists and backend: modules/lib/agent-sandbox.nix and agent-sandbox.sh.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  isServer = builtins.elem "server" config.machine.profiles;
  sandbox = import ../../lib/agent-sandbox.nix {
    inherit
      pkgs
      lib
      isServer
      ;
  };
in
{
  config = {
    home.packages = [
      sandbox.agentSandbox

      # Operator check: runs the real sandbox against the user's home, so not a nix-build check.
      (pkgs.writeShellApplication {
        name = "agent-sandbox-check";
        runtimeInputs = [
          pkgs.coreutils
          pkgs.findutils
          pkgs.gnugrep
        ];
        text =
          let
            # One escaped argument: this runs under /bin/sh, and the script's own quotes must survive the outer parse.
            linuxCheck = ''
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
              # A mask is a writable tmpfs: emptiness is the assertion, not a refused write.
              if [ -d /var/lib/data/photos ]; then
                test -z "$(ls -A /var/lib/data/photos)"
              fi
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
                # The resolved store URL: the read-only state dir is what makes `store = auto` fall through to the daemon.
                nix store info --json | grep -q '"url":"daemon"'
                ! test -w /nix/var/nix
              fi
            '';
          in
          ''
            sb=${sandbox.agentSandbox}/bin/agent-sandbox
            # shellcheck disable=SC2016 # the inner script is expanded by /bin/sh
            "$sb" /bin/sh -c ${lib.escapeShellArg linuxCheck}
            echo "agent-sandbox-check: ok"
          '';
      })
    ];
  };
}
