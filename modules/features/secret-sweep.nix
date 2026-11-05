# `secret-sweep [path...]`: offline, redacted gitleaks scan (default $HOME). Agents read whatever the
# human can (#386), so a world-readable token is exposed; this finds them for cleanup and guards
# regressions. Exits 1 on any finding; secret values never reach the output.
{ pkgs, ... }:
let
  secretSweep = pkgs.writeShellApplication {
    name = "secret-sweep";
    runtimeInputs = [ pkgs.gitleaks ];
    text = ''
      if [ "$#" -eq 0 ]; then
        set -- "$HOME"
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
