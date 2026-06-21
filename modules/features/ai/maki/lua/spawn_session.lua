-- spawn_session: create a worktree and spawn a new maki session in a
-- new Zellij tab, gated behind a confirmation question.
--
-- Caller (the LLM) is expected to generate the branch name beforehand:
--   agent-branch-name --slug <slug> --task "<task>" --dry-run
-- and prepare the session prompt. This tool handles the interactive parts
-- (confirmation, worktree creation, Zellij tab spawning).
--
-- Prerequisites on PATH: wt (worktrunk), zellij, python3

local QuestionForm = require("question_form")

-- Nerd Font sushi glyph (nf-fae-sushi, U+E21A) prefixing the Zellij tab name,
-- so maki tabs read " - <worktree> — matching oh-my-pi's "π - <worktree>".
local sushi_icon = "\238\136\154"

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
  name = "spawn_session",
  kind = "execute",
  description = [[Spawn a new interactive maki session in a new Zellij tab (with a worktree).

BEFORE calling this, generate the branch name via:
  agent-branch-name --slug <slug> --task "<task>" --dry-run
and prepare the session prompt.

Workflow:
1. Shows a confirmation question (bottom of window) with the branch name and task description
2. Creates the worktree via `wt switch --create <branch> --format json`
3. Opens a new Zellij tab and runs maki in the worktree directory

Use for long-running feature work that deserves its own isolated session.]],
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
        description = "Short display label for the confirmation question (defaults to the worktree name, derived from the branch)",
      },
    },
  },
  audiences = { "main" },
  timeout = false,
  header = function(input)
    return input.task or input.branch or "spawn session"
  end,
  handler = function(input, ctx)
    local branch = input.branch or ""
    local prompt = input.prompt or ""
    if branch == "" or prompt == "" then
      return { llm_output = "error: branch and prompt are required", is_error = true }
    end

    local worktree_name = branch:match("([^/]+)$") or branch
    local display_label = input.task or worktree_name

    local start_label = ("Start: %s"):format(display_label)
    local prompt_preview = (prompt:match("^([^\n]+)") or prompt):gsub("%s+", " ")
    if #prompt_preview > 120 then
      prompt_preview = prompt_preview:sub(1, 117) .. "..."
    end
    local question_text = ("Start a new session?\n\n"
      .. "- **Branch:** `%s`\n"
      .. "- **Worktree:** `%s`\n"
      .. "- **Prompt:** %s")
      :format(branch, worktree_name, prompt_preview)

    -- Bottom-of-window question form. Escape/Ctrl-C/close dismisses
    -- (result.type == "dismiss"); no explicit Cancel option needed.
    local result = QuestionForm.open({
      {
        question = question_text,
        options = {
          { label = start_label, description = branch },
        },
      },
    })
    if result.type ~= "submit" then
      return { llm_output = "(cancelled by user)" }
    end
    local chosen = result.answers and result.answers[1] and result.answers[1][1]
    if chosen ~= start_label then
      return { llm_output = "(cancelled by user)" }
    end

    local script = string.format(
      [[
branch=%s

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
    path=$root/.worktrees/%s
  fi
fi
if [ -z "$path" ]; then
  rm -f "$prompt_file"
  echo "ERR:could not determine worktree path"
  exit 1
fi

zellij action new-tab -n %s -c "$path" --close-on-exit -- nono run -s -- maki -- "$START_PROMPT"
]],
      shell_quote(branch),
      shell_quote(worktree_name),
      shell_quote(sushi_icon .. " - " .. worktree_name)
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
            llm_output = "error spawning session: " .. err_msg,
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
