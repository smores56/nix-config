# agent-skill-mirror <claude-skills-dir> <agents-skills-dir>: exposes skills
# that other tools install into ~/.claude/skills (real directories with a
# SKILL.md, e.g. an employer's skill sync) to agents that read
# ~/.agents/skills, and drops mirror links whose skill was removed.
# Home Manager's own skills are store symlinks and deploy to both places
# already, so they are skipped. Never fails: it runs from activation.
{ pkgs }:
pkgs.writeShellApplication {
  name = "agent-skill-mirror";
  runtimeInputs = [ pkgs.coreutils ];
  text = ''
    [ $# -eq 2 ] || { printf 'usage: agent-skill-mirror <claude-skills-dir> <agents-skills-dir>\n' >&2; exit 2; }
    src=$1 dst=$2
    [ -d "$src" ] || exit 0
    mkdir -p -- "$dst" 2>/dev/null || { printf 'agent-skill-mirror: cannot create %s\n' "$dst" >&2; exit 0; }

    for skill in "$src"/*/; do
      skill=''${skill%/}
      [ -d "$skill" ] && [ ! -L "$skill" ] && [ -f "$skill/SKILL.md" ] || continue
      link=$dst/''${skill##*/}
      if [ -L "$link" ]; then
        [ "$(readlink "$link")" = "$skill" ] || printf 'agent-skill-mirror: %s is another link; leaving it\n' "$link" >&2
      elif [ -e "$link" ]; then
        printf 'agent-skill-mirror: %s exists; leaving it\n' "$link" >&2
      else
        ln -s -- "$skill" "$link" || printf 'agent-skill-mirror: could not link %s\n' "$link" >&2
      fi
    done

    for link in "$dst"/*; do
      [ -L "$link" ] || continue
      target=$(readlink "$link")
      case "$target" in
        "$src"/*) [ -e "$target" ] || rm -f -- "$link" ;;
      esac
    done
    exit 0
  '';
}
