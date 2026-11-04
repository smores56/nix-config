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

            repoSnippet = ''r=""; for g in $(find "$HOME/code" -maxdepth 5 -name .git -type d 2>/dev/null); do p=''${g%/.git}; u=$(git -C "$p" remote get-url origin 2>/dev/null) || continue; case $u in *smores56*) r=$p; break;; esac; done; [ -n "$r" ] || exit 3'';

            # Each assertion prints its own PASS/FAIL/SKIP; a denial counts only when the command failed with
            # "Operation not permitted" (a bare non-zero exit could be a missing path). The inner script runs
            # under the store bash because `/bin/sh` in the sandbox prints "Error opening
            # /private/var/select/sh: Operation not permitted" every run, which a loose grep would match.
            # Untested: mach-lookup, `appleevent-send`, `lsopen` and `job-creation` denials surface as
            # unknown-service or AppleEvent errors, never EPERM.
            # macOS has no mount namespace, so the profile denies writing any `/.git` and a new repo cannot
            # be created inside the boundary (docs/manual-steps.md); the signing assertion uses
            # `git commit-tree` in an existing personal checkout (leaves a dangling object `git gc` collects).
            darwinCheck = ''
              set -u
              pass=0 fail=0
              ok(){ pass=$((pass+1)); printf 'PASS %s\n' "$1"; }
              skip(){ printf 'SKIP %s\n' "$1"; }
              no(){ fail=$((fail+1)); printf 'FAIL %s\n' "$1"; [ -z "''${2:-}" ] || printf '     | %s\n' "$2"; }
              # Exit 3: a precondition was absent (no repo, maki or PAT): a skip, not a failure.
              try_allow(){
                local o rc
                o=$(bash -c "$2" 2>&1); rc=$?
                if [ "$rc" -eq 0 ]; then ok "$1"
                elif [ "$rc" -eq 3 ]; then skip "$1"
                else no "$1" "$o"; fi
              }
              try_deny(){
                local o rc
                o=$(bash -c "$2" 2>&1); rc=$?
                if [ "$rc" -eq 0 ]; then no "$1 (was allowed)" "$o"
                elif [ "$rc" -eq 3 ]; then skip "$1"
                elif [[ $o == *"Operation not permitted"* ]]; then ok "$1"
                else no "$1 (failed for another reason)" "$o"; fi
              }
              # A masked path that does not exist yet is a skip: ENOENT is not evidence.
              deny_path(){
                local o
                o=$(bash -c "ls \"$2\"" 2>&1)
                case $o in
                  *"Operation not permitted"*) ok "$1" ;;
                  *"No such file or directory"*) skip "$1 (absent)" ;;
                  *) no "$1 (was allowed)" "$o" ;;
                esac
              }

              # EXEC_DENY is one mechanism, so these prove it rather than one rule each.
              try_deny "sudo not invocable" '/usr/bin/sudo -n true'
              try_deny "su not invocable" '/usr/bin/su root -c true'
              try_deny "security (Keychain binary) cannot exec" '/usr/bin/security find-generic-password -s maki-openai-api-key -w'
              try_deny "launchctl denied" '/bin/launchctl print gui/$UID'
              try_deny "osascript denied" '/usr/bin/osascript -e "return 1"'
              # connect() to a unix socket is a network operation: the cached PIV agent would sign a login
              # with no touch even though ~/.ssh is masked. An absent socket proves nothing.
              for s in sudo-agent.sock piv-agent.sock; do
                try_deny "$s unreachable" 'o=$(SSH_AUTH_SOCK="$HOME/.ssh/'"$s"'" ssh-add -l 2>&1); rc=$?; case $o in *"No such file"*) exit 3 ;; esac; printf "%s\n" "$o"; exit $rc'
              done

              deny_path "PIV PIN cache unreadable" "$(/usr/bin/getconf DARWIN_USER_TEMP_DIR)piv"

              deny_path ".ssh unreadable" "$HOME/.ssh"
              deny_path ".config unreadable" "$HOME/.config"
              deny_path "Library unreadable" "$HOME/Library"
              deny_path "keyrings unreadable" "$HOME/.local/share/keyrings"
              deny_path ".gnupg unreadable" "$HOME/.gnupg"
              deny_path ".aws unreadable" "$HOME/.aws"
              deny_path ".kube unreadable" "$HOME/.kube"
              deny_path ".docker unreadable" "$HOME/.docker"
              deny_path ".cloudflared unreadable" "$HOME/.cloudflared"
              deny_path "vault ciphertext (Sync) unreadable" "$HOME/Sync"
              deny_path "memory state unreadable" "$HOME/.local/state/memory"
              deny_path "agent transcripts (.claude) unreadable" "$HOME/.claude"
              deny_path "agent transcripts (.codex) unreadable" "$HOME/.codex"

              try_deny "HOME not writable" 'touch "$HOME/.agent-sandbox-probe"'
              try_deny "LaunchAgents not writable" 'mkdir -p "$HOME/Library/LaunchAgents"'
              try_deny ".local/bin not writable" 'touch "$HOME/.local/bin/.probe"'
              try_deny "existing repo hooks not writable" '${repoSnippet}; touch "$r/.git/hooks/.agent-sandbox-probe"'
              try_deny "existing repo config not writable" '${repoSnippet}; touch "$r/.git/config"'
              # launchd's per-user scratch dirs are denied by regex; skip when there is nothing to observe.
              scratch=$(bash -c 'd=$(/usr/bin/getconf DARWIN_USER_TEMP_DIR); find "$d" -maxdepth 1 -name "com.apple.launchd*" -print' 2>&1) || true
              case $scratch in
                *"Operation not permitted"*) ok "launchd scratch denied" ;;
                "") skip "launchd scratch denied (no entry to observe)" ;;
                *) no "launchd scratch denied (was allowed)" "$scratch" ;;
              esac

              try_allow "code writable" 'touch "$HOME/code/.agent-sandbox-probe" && rm -f "$HOME/code/.agent-sandbox-probe"'
              try_allow "/tmp writable" 'd=$(mktemp -d) && rm -rf "$d"'
              try_allow "agent state writable" 'touch "$HOME/.local/state/agent/.probe" && rm -f "$HOME/.local/state/agent/.probe"'
              try_allow "sandbox gitconfig enforces signing" 'test "$(git config --get commit.gpgsign)" = true'
              try_allow "sops signing key readable" 'head -c1 "$HOME/.local/share/github/github-personal-signing-key" >/dev/null'
              try_allow "commit signed by the agent key verifies" '${repoSnippet}; s=$(git -C "$r" commit-tree -S -m sign-probe "HEAD^{tree}") || exit 1; test "$(git -C "$r" log -1 --format=%G? "$s")" = G'
              try_allow "maki runs" 'command -v maki >/dev/null || exit 3; maki --version >/dev/null'
              try_allow "gh via PAT" '${repoSnippet}; cd "$r" || exit 3; gh api /user --jq .login | grep -qx smores56'

              # Informational: reports what happens when the agent creates a repo, so docs stay honest.
              if bash -c 'd=$(mktemp -d)/repo; mkdir -p "$d" && cd "$d" && git init -q' >/dev/null 2>&1; then
                printf 'NOTE git init inside the boundary: allowed\n'
              else
                printf 'NOTE git init inside the boundary: denied (expected)\n'
              fi

              printf '\n%d passed, %d failed\n' "$pass" "$fail"
              test "$fail" -eq 0
            '';
          in
          if isDarwin then
            ''
              sb=${sandbox.agentSandbox}/bin/agent-sandbox
              printf 'host: macOS %s %s\n' "$(/usr/bin/sw_vers -productVersion)" "$(/usr/bin/uname -m)"
              # shellcheck disable=SC2016 # the inner script is expanded by bash
              "$sb" bash -c ${lib.escapeShellArg darwinCheck}
              echo "agent-sandbox-check: ok"
            ''
          else
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
