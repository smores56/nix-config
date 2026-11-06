# `secret-sweep [--review] [path...]`: offline gitleaks scan (default $HOME). Agents read whatever
# the human can (#386), so a world-readable token is exposed; this finds them for cleanup and guards
# regressions. Exits 1 on any finding; secret values never reach the output.
#
# --review triages the findings with the local model on smortress (review.py): values exist only in
# a private temp dir that is removed on exit, inside the ssh session, and on the model's loopback.
{ pkgs, ... }:
let
  secretReview = pkgs.writers.writePython3Bin "secret-review" {
    flakeIgnore = [
      "E501"
      "E203"
    ];
  } (builtins.readFile ./review.py);

  secretSweep = pkgs.writeShellApplication {
    name = "secret-sweep";
    runtimeInputs = [
      pkgs.gitleaks
      pkgs.coreutils
      pkgs.openssh
      secretReview
    ];
    text = ''
      review=
      if [ "''${1:-}" = --review ]; then
        review=1
        shift
      fi
      if [ "$#" -eq 0 ]; then
        # ~/Library is never shared with the agent, and reading app containers there pops TCC
        # prompts, so the default walks the rest of $HOME.
        shopt -s dotglob nullglob
        for entry in "$HOME"/*; do
          [ "$(basename "$entry")" = Library ] && [ "$(uname)" = Darwin ] && continue
          set -- "$@" "$entry"
        done
      fi

      if [ -z "$review" ]; then
        status=0
        for target in "$@"; do
          # --redact=100 replaces the whole value; --max-target-megabytes skips large binaries
          # (model weights, VM images) that dominate run time and cannot hold a pasted token.
          gitleaks dir "$target" --no-banner --redact=100 --verbose \
            --max-target-megabytes 20 --log-level warn || status=$?
        done
        exit "$status"
      fi

      # Unredacted reports live only here: 0700, removed on any exit.
      umask 077
      work=$(mktemp -d "''${XDG_RUNTIME_DIR:-''${TMPDIR:-/tmp}}/secret-review.XXXXXX")
      trap 'rm -rf "$work"' EXIT
      reports=()
      i=0
      for target in "$@"; do
        i=$((i + 1))
        gitleaks dir "$target" --no-banner --redact=0 --report-format json \
          --report-path "$work/report-$i.json" --max-target-megabytes 20 --log-level error \
          >/dev/null || true
        [ -s "$work/report-$i.json" ] && reports+=("$work/report-$i.json")
      done
      if [ "''${#reports[@]}" -eq 0 ]; then
        echo "secret-review: no findings"
        exit 0
      fi
      secret-review prepare "''${reports[@]}" >"$work/items.jsonl"
      echo "secret-review: $(wc -l <"$work/items.jsonl") distinct values to classify" >&2

      host=''${SECRET_REVIEW_HOST:-smortress}
      if [ "$(hostname -s)" = "$host" ]; then
        secret-review classify <"$work/items.jsonl" >"$work/verdicts.jsonl"
      else
        # ssh is end to end through the tunnel, so the relay sees only ciphertext.
        ssh -o ForwardAgent=no -o ClearAllForwardings=yes "$host" secret-review classify \
          <"$work/items.jsonl" >"$work/verdicts.jsonl"
      fi
      secret-review report "$work/verdicts.jsonl" "''${reports[@]}"
      exit 1
    '';
  };
in
{
  home.packages = [
    secretSweep
    secretReview
  ];
}
