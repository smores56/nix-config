# `secret-sweep [path...]`: offline gitleaks scan (default $HOME). Agents read whatever
# the human can (#386), so a world-readable token is exposed; this finds them for cleanup and
# guards regressions. Exits 1 on any finding; secret values never reach the output.
#
# T9: the `--review` model triage is retired with the host LLM. gitleaks alone is the
# contract: no SSH relay, no model call, and the redacted report is the whole output.
{ pkgs, ... }:
let
  secretSweep = pkgs.writeShellApplication {
    name = "secret-sweep";
    runtimeInputs = [
      pkgs.gitleaks
      pkgs.coreutils
    ];
    text = ''
      if [ "$#" -eq 0 ]; then
        # ~/Library is never shared with the agent, and reading app containers there pops TCC
        # prompts, so the default walks the rest of $HOME.
        shopt -s dotglob nullglob
        for entry in "$HOME"/*; do
          [ "$(basename "$entry")" = Library ] && [ "$(uname)" = Darwin ] && continue
          set -- "$@" "$entry"
        done
      fi

      status=0
      for target in "$@"; do
        # --redact=100 replaces the whole value; --max-target-megabytes skips large binaries
        # (model weights, VM images) that dominate run time and cannot hold a pasted token.
        gitleaks dir "$target" --no-banner --redact=100 --verbose \
          --max-target-megabytes 20 --log-level warn || status=$?
      done
      exit "$status"
    '';
  };
in
{
  home.packages = [ secretSweep ];
}
