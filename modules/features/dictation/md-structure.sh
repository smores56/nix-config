# shellcheck shell=bash
# `md-structure` — restructure a dictated ramble (stdin) into clean markdown
# (stdout) via `maki -p` and the faithful-restructure system prompt.
#
# Runs as a Helix `:pipe` filter over an explicit selection. It exits non-zero
# on any failure or on input too small to be prose, and `:pipe` leaves the
# buffer untouched on a non-zero exit — so a stray keypress is a no-op and a
# failed clean can never delete the ramble.

prompt_file="@PROMPT_FILE@"
model="${MD_STRUCTURE_MODEL:-neuralwatt/deepseek-v4.1-flash}"

# maki is user-installed (~/.local/bin), not a nix package, so fall back to
# that path when it is not already on PATH.
maki_bin="$(command -v maki 2>/dev/null || true)"
[[ -n "$maki_bin" ]] || maki_bin="$HOME/.local/bin/maki"

# maki's `--system-prompt` is SDK-only and silently ignored on the `-p` text
# path, so the instruction is prepended to the prompt instead. `-p` otherwise
# runs the full coding agent with tools enabled and permissions auto-approved
# (always_yolo), so deny every tool and skip user/project plugins and commands:
# this is a plain text transform, not an agent with shell access.
tools='spawn_session,resume_session,memory_search,memory_write,index,webfetch,websearch,bash,batch,grep,glob,skill,question,todo_write,read,write,edit,multiedit,edit_lines,task,code_execution,view_image,list'

input="$(cat)"
trimmed="${input#"${input%%[![:space:]]*}"}"

# A normal-mode `space m` with no selection pipes a single cell; refuse that
# and anything else too small to be prose rather than spending an LLM call to
# replace one character.
if [[ -z "$trimmed" || "$trimmed" != *[[:space:]]* || ${#trimmed} -lt 8 ]]; then
  printf 'md-structure: input is not prose; nothing to do\n' >&2
  exit 3
fi

# Buffer the output and only emit it on success, so a failed run cannot
# replace the selection with a partial document.
output="$(
  {
    cat "$prompt_file"
    printf '\n\n---\n\n%s' "$input"
  } | "$maki_bin" -p \
        --no-plugins \
        --no-commands \
        --disallowed-tools "$tools" \
        -m "$model"
)"

if [[ -z "${output//[[:space:]]/}" ]]; then
  printf 'md-structure: model returned no text\n' >&2
  exit 4
fi

printf '%s\n' "$output"
