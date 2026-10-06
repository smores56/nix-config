# work-repo-links [--migrate] <flat-dir> <host-dir> <org>...: points each
# <host-dir>/<org> at the flat work folder (dotfiles.work.flatRepos).
#
# Default mode (run by activation) never fails and never moves data: it
# links missing paths and empty dirs (ignoring .DS_Store) and warns about
# the rest. --migrate moves a real org dir's entries into the flat folder,
# refusing name collisions, repairs moved repos' worktree links, then links.
{ pkgs }:
pkgs.writeShellApplication {
  name = "work-repo-links";
  runtimeInputs = [
    pkgs.coreutils
    pkgs.findutils
    pkgs.git
  ];
  text = ''
    unset CDPATH
    migrate=false
    if [ "''${1-}" = --migrate ]; then
      migrate=true
      shift
    fi
    [ $# -ge 2 ] || { printf 'usage: work-repo-links [--migrate] <flat-dir> <host-dir> <org>...\n' >&2; exit 2; }
    flat=$1 root=$2
    shift 2
    status=0

    warn() {
      printf 'work-repo-links: %s\n' "$*" >&2
      status=1
    }

    physical() {
      (cd -- "$1" 2>/dev/null && pwd -P)
    }

    # True when the dir holds nothing but Finder litter.
    only_litter() {
      [ -z "$(find "$1" -mindepth 1 -maxdepth 1 ! -name .DS_Store -print -quit)" ]
    }

    move_into_flat() {
      local dir=$1 entry name moved=true
      for entry in "$dir"/* "$dir"/.[!.]* "$dir"/..?*; do
        [ -e "$entry" ] || [ -L "$entry" ] || continue
        name=''${entry##*/}
        [ "$name" != .DS_Store ] || continue
        if [ -e "$flat/$name" ] || [ -L "$flat/$name" ]; then
          warn "$flat/$name already exists; not moving $entry (the flat folder holds one checkout per name)"
          moved=false
          continue
        fi
        mv -- "$entry" "$flat/$name" || { warn "could not move $entry"; moved=false; continue; }
        # Worktree links are absolute paths; re-point the moved ones.
        if [ -d "$flat/$name/.worktrees" ] && git -C "$flat/$name" rev-parse --git-dir >/dev/null 2>&1; then
          find "$flat/$name/.worktrees" -mindepth 1 -maxdepth 1 -type d -exec git -C "$flat/$name" worktree repair {} + \
            || warn "git worktree repair failed in $flat/$name"
        fi
      done
      $moved
    }

    link_org() {
      local link=$1
      if [ -L "$link" ]; then
        [ "$(physical "$link")" = "$(physical "$flat")" ] || warn "$link points to $(readlink "$link"), not $flat; leaving it"
      elif [ -d "$link" ]; then
        if ! only_litter "$link" && $migrate; then
          move_into_flat "$link" || return 0
        fi
        if only_litter "$link"; then
          rm -f -- "$link/.DS_Store"
          if ! { rmdir -- "$link" && ln -s -- "$flat" "$link"; }; then
            warn "could not replace empty $link with a link"
          fi
        else
          warn "$link is a real directory with checkouts; run \`work-repo-links --migrate\` to move them into $flat"
        fi
      elif [ -e "$link" ]; then
        warn "$link exists and is not a directory; leaving it"
      else
        ln -s -- "$flat" "$link" || warn "could not link $link"
      fi
    }

    if ! mkdir -p -- "$flat" "$root" 2>/dev/null || [ ! -d "$flat" ] || [ ! -d "$root" ]; then
      warn "could not create $flat and $root; skipping"
    else
      for org in "$@"; do
        link_org "$root/$org"
      done
    fi

    # Activation must never fail a switch over this; --migrate reports.
    if $migrate; then exit "$status"; fi
    exit 0
  '';
}
