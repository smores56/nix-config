-- start_worktree_session: create a worktree and spawn a new maki session in a
-- new Zellij tab, gated behind a confirmation dialog.
--
-- Caller (the LLM) is expected to generate the branch name beforehand:
--   agent-branch-name --slug <slug> --task "<task>" --dry-run
-- and prepare the session prompt. This tool handles the interactive parts
-- (confirmation, worktree creation, Zellij tab spawning).
--
-- Prerequisites on PATH: wt (worktrunk), zellij, python3

local ListPicker = require("maki.list_picker")

if maki.fn.executable("wt") == 0
  or maki.fn.executable("zellij") == 0
  or maki.fn.executable("python3") == 0
then
  return
end

local function shell_quote(s)
  return "'" .. s:gsub("'", "'\\''") .. "'"
end

maki.api.register_tool({
  name = "start_worktree_session",
  kind = "execute",
  description = [[Create a worktree and spawn a new interactive maki session in a new Zellij tab.

BEFORE calling this, generate the branch name via:
  agent-branch-name --slug <slug> --task "<task>" --dry-run
and prepare the session prompt.

Workflow:
1. Shows a confirmation dialog with the branch name and task description
2. Creates the worktree via `wt switch --create <branch> --format json`
3. Opens a new Zellij tab and runs maki in the worktree directory

Use for long-running feature work that deserves its own isolated session and worktree.]],
  schema = {
    type = "object",
    required = { "branch", "prompt" },
    properties = {
      branch = {
        type = "string",
        description = [[Full branch name (e.g. "smores/my-feature"). Generate via:
agent-branch-name --slug <slug> --task "<task>" --dry-run]],
      },
      prompt = {
        type = "string",
        description = "Full prompt for the new maki session (e.g. 'Implement user authentication with OAuth2')",
      },
      task = {
        type = "string",
        description = "Short display label for the confirmation dialog (defaults to the worktree name, derived from the branch)",
      },
    },
  },
  audiences = { "main" },
  timeout = false,
  header = function(input)
    return input.task or input.branch or "start worktree session"
  end,
  handler = function(input, ctx)
    local branch = input.branch or ""
    local prompt = input.prompt or ""
    if branch == "" or prompt == "" then
      return { llm_output = "error: branch and prompt are required", is_error = true }
    end

    local worktree_name = branch:match("([^/]+)$") or branch
    local display_label = input.task or worktree_name

    -- Show confirmation dialog
    local confirm = ListPicker.open({
      { label = ("Start: %s"):format(display_label), detail = branch },
      { label = "Cancel" },
    }, {
      title = "New worktree session?",
    })
    if not confirm or confirm.type ~= "choice" or confirm.index ~= 1 then
      return { llm_output = "(cancelled by user)" }
    end

    -- Shell script: create worktree, extract path, and open a new Zellij tab
    -- running maki with the prompt piped via stdin (maki reads stdin as the
    -- initial prompt when no positional arg is given).
    --
    -- Login fish (-l) so conf.d/api-keys.fish is sourced at provider has_auth
    -- time (a non-login shell would skip it and maki would error "Token expired").
    --
    -- The prompt reaches the new pane through a temp file (not an env var)
    -- because `zellij action new-tab` spawns the pane in the zellij *server*
    -- process, which does NOT inherit the caller's exported environment
    -- (zellij #4031). A file survives that process boundary and sidesteps all
    -- bash→fish quoting.
    --
    -- The temp file is created by `mktemp` *inside the script* (maki's Lua
    -- sandbox forbids os.* — os.tmpname is nil — so the path cannot be
    -- generated in Lua). The script writes START_PROMPT to the file, bakes its
    -- path into the fish command, and rm -f's it on every failure-exit before
    -- echoing anything. The success-path cleanup runs in the pane itself: fish
    -- cats the file into maki's stdin, then rm's it once maki exits. There is no
    -- `exec` — exec would replace fish before the rm could run, leaking the file.
    local maki_cmd = "nono-agent maki"
    if maki.fn.executable("nono-agent") == 0 then
      maki_cmd = "maki"
    end
    local script = string.format(
      [[
prompt_file=$(mktemp) || { echo "ERR:mktemp failed"; exit 1; }
maki_cmd=%s
branch=%s

wt_output=$(wt switch --create "$branch" --format json 2>&1) || {
  rm -f "$prompt_file"
  echo "ERR:$wt_output"
  exit 1
}
path=$(printf "%%s" "$wt_output" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('path',''))" 2>/dev/null)
if [ -z "$path" ]; then
  path=$(printf "%%s" "$wt_output" | grep -o '"path":"[^"]*"' | head -1 | cut -d'"' -f4)
fi
if [ -z "$path" ]; then
  root=$(git rev-parse --show-toplevel 2>/dev/null) || root=""
  if [ -n "$root" ]; then
    path="$root/.worktrees/%s"
  fi
fi
if [ -z "$path" ]; then
  rm -f "$prompt_file"
  echo "ERR:could not determine worktree path"
  exit 1
fi

# Write the prompt into the temp file. The new fish pane reads it into a
# variable, deletes the file, then pipes it to maki. Cleanup cannot be a trap:
# the script returns right after `zellij action new-tab` (the tab is spawned
# asynchronously by the zellij server), so an EXIT trap would race — and win
# against — the pane opening the file. Each error branch rm's explicitly.
printf '%%s' "$START_PROMPT" > "$prompt_file"

# fish loads conf.d (provider auth) via -l. It then:
#  1. renames the pane to a clean label — otherwise Zellij shows the raw
#     `fish -l -c '...'` command as the pane border title;
#  2. reads the prompt file into a variable and deletes the file BEFORE
#     running maki, so cleanup always runs (file is gone before maki starts,
#     so even a kill -9 of maki leaves no leak);
#  3. runs maki fed from the variable, then explicitly closes the pane via
#     `zellij action close-pane`. Without close-pane, maki's exit leaves its
#     session-id stdout visible in a live fish pane, forcing a second ctrl-c
#     to close the tab. close-pane shuts the pane (and the tab, being its
#     only pane) the instant maki exits — one ctrl-c, clean exit, no leftover.
fish_cmd="zellij action rename-pane %s; set -l p (cat \"$prompt_file\"); rm -f \"$prompt_file\"; printf '%%s' \"$p\" | $maki_cmd; zellij action close-pane"
zellij action new-tab -n %s -c "$path" -- fish -l -c "$fish_cmd"
echo "OK:$path"
]],
      shell_quote(maki_cmd),
      shell_quote(branch),
      worktree_name,
      shell_quote(worktree_name),
      shell_quote(worktree_name)
    )

    -- Run the script and capture output
    local output_lines = {}
    maki.fn.jobstart(script, {
      env = { START_PROMPT = prompt },
      on_stdout = function(_, line)
        table.insert(output_lines, line)
      end,
      on_stderr = function(_, line)
        table.insert(output_lines, "stderr: " .. line)
      end,
      on_exit = function(_, code)
        local combined = table.concat(output_lines, "\n")
        if code ~= 0 then
          -- The script rm's the prompt file itself on every failure-exit.
          local err_msg = combined:match("^ERR:(.+)") or combined
          ctx:finish({
            llm_output = "error creating worktree session: " .. err_msg,
            is_error = true,
          })
          return
        end
        local path = combined:match("^OK:(.+)$")
        if path then
          ctx:finish({
            llm_output = ("Started session in Zellij tab **%s**\n- Worktree: `%s`\n- Branch: `%s`")
              :format(worktree_name, path, branch),
          })
        else
          ctx:finish({
            llm_output = "Session started in branch `" .. branch .. "` (Zellij tab: " .. worktree_name .. ")",
          })
        end
      end,
    })

    return nil -- async, result delivered via ctx:finish
  end,
})
