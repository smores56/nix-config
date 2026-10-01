# Shared `theme-apply` script.
#
# The native appearance setting is the source of truth: Noctalia's hooks (Linux)
# and dark-mode-notify (macOS) call this with the new mode, and it activates the
# matching home-manager specialisation.
#
# Idempotence is tracked in a state file rather than by reading
# ~/.local/state/home-manager/gcroots/current-home: home-manager only repoints
# that root at the very end of activation, *after* `sd-switch` has run. Activating
# a specialisation restarts Noctalia (its systemd unit changes), whose `started`
# hook re-enters this script mid-activation — at which point `current-home` still
# names the old generation. The state file is written before activation, so the
# re-entrant call no-ops instead of ping-ponging.
{
  pkgs,
  lib,
}:
let
  baseGenFile = "$HOME/.cache/hm-base-generation";
  appliedStateFile = "$HOME/.cache/theme-applied";
in
pkgs.writeShellScriptBin "theme-apply" ''
  set -eu
  PATH=${
    lib.makeBinPath [
      pkgs.coreutils
      pkgs.util-linux
    ]
  }:$PATH

  mode="''${1:-}"
  case "$mode" in
    dark | light) ;;
    *)
      echo "usage: theme-apply <dark|light>" >&2
      exit 1
      ;;
  esac

  base_gen=$(cat ${baseGenFile} 2>/dev/null || true)
  if [ -z "$base_gen" ] || [ ! -d "$base_gen" ]; then
    echo "theme-apply: no base generation recorded in ${baseGenFile}" >&2
    exit 1
  fi

  target="$base_gen/specialisation/$mode/activate"
  [ -e "$target" ] || target="$base_gen/activate"
  target_gen=$(readlink -f "$(dirname "$target")")

  mkdir -p "$HOME/.cache"
  exec 9>"$HOME/.cache/theme-apply.lock"
  flock -w 120 9

  if [ "$(cat ${appliedStateFile} 2>/dev/null || true)" = "$target_gen" ]; then
    exit 0
  fi
  echo "$target_gen" > ${appliedStateFile}

  export HM_SPECIALISATION_SWITCH=1
  "$target"
''
