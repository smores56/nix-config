# work-repo-links <flat-dir> <code-root>/<host> <org>...: points each
# <code-root>/<host>/<org> at the flat work folder (dotfiles.work.flatRepos).
# Replaces only missing paths and empty directories; anything else is
# reported, never moved, so activation can't destroy checkouts.
{ pkgs }:
pkgs.writeShellApplication {
  name = "work-repo-links";
  runtimeInputs = [ pkgs.coreutils ];
  text = ''
    [ $# -ge 2 ] || { printf 'usage: work-repo-links <flat-dir> <host-dir> <org>...\n' >&2; exit 2; }
    flat=$1 root=$2
    shift 2
    mkdir -p "$flat" "$root"
    for org in "$@"; do
      link=$root/$org
      if [ -L "$link" ]; then
        target=$(readlink "$link")
        [ "$target" = "$flat" ] || printf 'work-repo-links: %s points to %s, not %s; leaving it\n' "$link" "$target" "$flat" >&2
      elif [ -d "$link" ]; then
        if rmdir "$link" 2>/dev/null; then
          ln -s "$flat" "$link"
        else
          printf 'work-repo-links: %s is a real directory; move its repos into %s, remove it, and switch again\n' "$link" "$flat" >&2
        fi
      elif [ -e "$link" ]; then
        printf 'work-repo-links: %s exists and is not a directory; leaving it\n' "$link" >&2
      else
        ln -s "$flat" "$link"
      fi
    done
  '';
}
