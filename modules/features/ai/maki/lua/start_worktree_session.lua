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

    -- Shell script: create worktree, extract path, open Zellij tab, run maki.
    -- Uses --cwd for the worktree dir + ${var@Q} quoting for the prompt to
    -- avoid nested shell quoting issues with `zellij run`. Outputs OK:<path>
    -- on success, ERR:<msg> on failure.
    --
    -- Launch via a LOGIN fish shell (matches the `m` abbr) so conf.d is sourced
    -- and API-key env vars are present at provider `has_auth` time. `zellij run
    -- -- bash -c` instead starts a non-login shell with a stripped env: bash never
    -- sources fish's conf.d/api-keys.fish, so the custom providers' bearer tokens
    -- are absent, has_auth returns false, and maki falls back to OAuth and errors
    -- "Token expired. Run `maki auth login`" even though the user is logged in.
    -- Wrap in nono when enabled to match `m`/herdr's sandbox profile (nono does
    -- not strip env vars; ${VAR:-} expansions still resolve inside the sandbox).
    --
    -- The prompt is handed to maki via the MAKI_PROMPT env var rather than a
    -- shell-quoted argv token: it crosses a bash -> fish -c handoff, and a prompt
    -- containing $VAR / `cmd` / $(...) / unmatched quotes would otherwise be
    -- re-expanded or mis-parsed by fish. An env var is never re-parsed, so the
    -- prompt survives verbatim; maki reads it as an argv element on the far side.
    -- --allow-connect-port 22 + 443 matches wrapAgent in shell.nix: ssh transport
    -- for git push/pull using the host agent's keys.
    local maki_cmd = "nono run -s -p maki --allow-cwd --allow-connect-port 22 --allow-connect-port 443 -- maki"
    if maki.fn.executable("nono") == 0 then
      maki_cmd = "exec maki"
    end
    local script = string.format(
      [[
branch=%s
export MAKI_PROMPT=%s

wt_output=$(wt switch --create "$branch" --format json 2>&1) || {
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
  echo "ERR:could not determine worktree path"
  exit 1
fi

zellij action new-tab -n %s
sleep 0.1
zellij run --in-place --cwd "$path" -- fish -l -c %s
echo "OK:$path"
]],
      shell_quote(branch),
      shell_quote(prompt),
      worktree_name,
      shell_quote(worktree_name),
      shell_quote(maki_cmd .. ' "$MAKI_PROMPT"')
    )

    -- Run the script and capture output
    local output_lines = {}
    maki.fn.jobstart(script, {
      on_stdout = function(_, line)
        table.insert(output_lines, line)
      end,
      on_stderr = function(_, line)
        table.insert(output_lines, "stderr: " .. line)
      end,
      on_exit = function(_, code)
        local combined = table.concat(output_lines, "\n")
        if code ~= 0 then
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
