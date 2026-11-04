# shellcheck shell=bash
# Restructure a dictated ramble (stdin) into markdown (stdout) via `maki -p`.
# Any failure or too-small input exits non-zero, which Helix `:pipe` treats as a no-op.

prompt_file="@PROMPT_FILE@"
model="${MD_STRUCTURE_MODEL:-neuralwatt/deepseek-v4.1-flash}"

# maki is user-installed (~/.local/bin), not on PATH under nix.
maki_bin="$(command -v maki 2>/dev/null || true)"
[[ -n "$maki_bin" ]] || maki_bin="$HOME/.local/bin/maki"

# `--system-prompt` is ignored on the `-p` text path, so the instruction is prepended.
# `-p` otherwise runs a tool-enabled, auto-approved agent: deny every tool.
tools='spawn_session,resume_session,memory_search,memory_write,index,webfetch,websearch,bash,batch,grep,glob,skill,question,todo_write,read,write,edit,multiedit,edit_lines,task,code_execution,view_image,list'

input="$(cat)"
trimmed="${input#"${input%%[![:space:]]*}"}"

# A no-selection `space m` pipes one cell; don't spend an LLM call on it.
if [[ -z "$trimmed" || "$trimmed" != *[[:space:]]* || ${#trimmed} -lt 8 ]]; then
  printf 'md-structure: input is not prose; nothing to do\n' >&2
  exit 3
fi

# Emit only on success so a failed run cannot replace the selection with a partial document.
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
