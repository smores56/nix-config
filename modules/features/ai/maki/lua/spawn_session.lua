-- spawn_session: create a worktree and spawn a new maki session in a
-- new Zellij tab, gated behind a confirmation question.
--
-- The worktree (and its branch, and any required Linear ticket) is created
-- by the canonical `worktrees` tool — the same one AGENTS.md tells agents to
-- use directly. That tool owns branch naming (sam.mohr/7AI-<n>-<slug> for
-- work repos, smores/<slug> for personal), so the branch name is always
-- well-formed. The agent supplies a slug/task/ticket, never a raw branch
-- name — which previously let it hand-roll mangled names like
-- `sammohr/7ai-...` via worktrunk's `wt switch --create`.
--
-- Prerequisites on PATH: worktrees, zellij, python3

local QuestionForm = require("question_form")

-- Nerd Font sushi glyph (nf-fae-sushi, U+E21A) prefixing the Zellij tab name.
local sushi_icon = "\238\136\154"

if maki.fn.executable("worktrees") == 0
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

Provide a kebab `slug` and the session `prompt`; optionally a `task` (description, also the Linear ticket title), an explicit `ticket` (7AI-<n>), and a `base` ref. The worktree + branch + ticket are created by the canonical `worktrees` tool, which owns branch naming — do not supply a branch name.

Workflow:
1. Shows a confirmation question (bottom of window) with the slug, ticket, and prompt
2. Creates the worktree via `worktrees new --slug <slug> [--task <task>] [--ticket <ticket>] [--base <base>]`
3. Opens a new Zellij tab and runs maki in the worktree directory

For work repos without a `ticket`, `worktrees` auto-creates a Linear ticket (requires the `linear` CLI on PATH). Use for long-running feature work that deserves its own isolated session.

This tool cannot be batched.]],
  schema = {
    type = "object",
    required = { "slug", "prompt" },
    properties = {
      slug = {
        type = "string",
        description = "Kebab-case worktree/branch slug (e.g. 'fix-auth-flow').",
      },
      prompt = {
        type = "string",
        description = "Full prompt for the new maki session (e.g. 'Implement user authentication with OAuth2')",
      },
      task = {
        type = "string",
        description = "Task description; passed to `worktrees --task` (Linear ticket title + 7AI-<n> extraction). Defaults to the slug.",
      },
      ticket = {
        type = "string",
        description = "Explicit Linear ticket (e.g. '7AI-12345'). Skips auto-creation.",
      },
      base = {
        type = "string",
        description = "Base ref for the new branch (defaults to origin's default branch).",
      },
    },
  },
  audiences = { "main" },
  timeout = false,
  header = function(input)
    return input.task or input.slug or "spawn session"
  end,
  handler = function(input, ctx)
    local slug = input.slug or ""
    local prompt = input.prompt or ""
    if slug == "" or prompt == "" then
      return { llm_output = "error: slug and prompt are required", is_error = true }
    end
    local task = input.task or ""
    local ticket = input.ticket or ""
    local base = input.base or ""

    -- Worktree directory name = <ticket>-<slug> or <slug>; also the Zellij tab label.
    local worktree_name = (ticket ~= "" and ticket .. "-" or "") .. slug
    local ticket_disp = (ticket ~= "") and ticket or "(new Linear ticket)"

    local start_label = ("Start: %s"):format(slug)
    local prompt_preview = (prompt:match("^([^\n]+)") or prompt):gsub("%s+", " ")
    if #prompt_preview > 120 then
      prompt_preview = prompt_preview:sub(1, 117) .. "..."
    end
    local question_text = ("Start a new session?\n\n"
      .. "- **Slug:** `%s`\n"
      .. "- **Ticket:** %s\n"
      .. "- **Worktree:** `.worktrees/%s`\n"
      .. "- **Prompt:** %s")
      :format(slug, ticket_disp, worktree_name, prompt_preview)

    -- Bottom-of-window question form. Escape/Ctrl-C/close dismisses
    -- (result.type == "dismiss"); no explicit Cancel option needed.
    local result = QuestionForm.open({
      {
        question = question_text,
        options = {
          { label = start_label, description = slug },
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

    -- Build the `worktrees new` arg list with each value shell-quoted.
    local wt_args = "--slug " .. shell_quote(slug)
    if task ~= "" then
      wt_args = wt_args .. " --task " .. shell_quote(task)
    end
    if ticket ~= "" then
      wt_args = wt_args .. " --ticket " .. shell_quote(ticket)
    end
    if base ~= "" then
      wt_args = wt_args .. " --base " .. shell_quote(base)
    end

    local script = string.format(
      [[
out=$(worktrees new %s 2>&1) || {
  echo "ERR:$out"
  exit 1
}
# worktrees prints a single JSON line on stdout; isolate it from any git
# fetch noise on stderr so JSON parsing is robust.
json=$(printf "%%s" "$out" | grep -E '^\{' | tail -1)
path=$(printf "%%s" "$json" | python3 -c "import sys,json; print(json.load(sys.stdin).get('path',''))" 2>/dev/null)
if [ -z "$path" ]; then
  path=$(printf "%%s" "$json" | grep -o '"path":"[^"]*"' | head -1 | cut -d'"' -f4)
fi
branch=$(printf "%%s" "$json" | python3 -c "import sys,json; print(json.load(sys.stdin).get('branch',''))" 2>/dev/null)
if [ -z "$branch" ]; then
  branch=$(printf "%%s" "$json" | grep -o '"branch":"[^"]*"' | head -1 | cut -d'"' -f4)
fi
if [ -z "$path" ]; then
  echo "ERR:could not determine worktree path: $out"
  exit 1
fi

zellij action new-tab -n %s -c "$path" --close-on-exit -- exec agentbox maki -- "$START_PROMPT"
echo "OK:$path"
echo "BRANCH:$branch"
]],
      wt_args,
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
          local err_msg = combined:match("^ERR:(.+)") or combined
          ctx:finish({
            llm_output = "error spawning session: " .. err_msg,
            is_error = true,
          })
          return
        end
        local path = combined:match("OK:([^\n]+)") or ""
        local branch = combined:match("BRANCH:([^\n]+)") or "(unknown)"
        ctx:finish({
          llm_output = ("Started session in Zellij tab **%s**\n- Worktree: `%s`\n- Branch: `%s`")
            :format(worktree_name, path, branch),
        })
      end,
    })

    return nil -- async, result delivered via ctx:finish
  end,
})
