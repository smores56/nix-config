-- spawn_session: create a worktree and spawn a new smelt session in a
-- new Zellij tab, gated behind a confirmation dialog.
--
-- Caller (the LLM) is expected to generate the branch name beforehand:
--   agent-branch-name --slug <slug> --task "<task>"
-- and prepare the session prompt. This tool handles the interactive parts
-- (confirmation, worktree creation, Zellij tab spawning).
--
-- Prerequisites on PATH: wt (worktrunk), zellij, python3.
--
-- smelt's tool model differs from maki's: tools return a result table
-- synchronously from `execute` (no ctx:finish), subprocesses run via
-- smelt.process.run (yielding) or smelt.process.spawn_bg (fire-and-forget),
-- and confirmations use the coroutine-blocking smelt.dialog.open.

-- Nerd Font sushi glyph (nf-fae-sushi, U+E21A) prefixing the Zellij tab name,
-- so smelt tabs read " - <worktree>" — matching maki's " - <worktree>".
local sushi_icon = "\238\136\154"

-- Cheap presence check: smelt.process.run returns (nil, err) on spawn failure,
-- so a non-nil result means the executable exists on PATH.
local function have(cmd)
  return smelt.process.run(cmd, { "--version" }) ~= nil
end

if not (have("wt") and have("zellij") and have("python3")) then
  return
end

local function shell_quote(s)
  return "'" .. s:gsub("'", "'\\''") .. "'"
end

smelt.tools.register({
  name = "spawn_session",
  description = [[Spawn a new interactive smelt session in a new Zellij tab (with a worktree).

BEFORE calling this, generate the branch name via:
  agent-branch-name --slug <slug> --task "<task>"
and prepare the session prompt.

Workflow:
1. Shows a confirmation dialog with the branch name and task description
2. Creates the worktree via `wt switch --create --no-hooks --no-cd <branch> --format json`
3. Opens a new Zellij tab and runs smelt in the worktree directory

Use for long-running feature work that deserves its own isolated session.

This tool cannot be batched.]],
  effect = "user_interaction",
  execution_mode = "sequential",
  headless = false,
  permission_defaults = { normal = "allow", plan = "allow", apply = "allow", yolo = "allow" },
  parameters = {
    type = "object",
    required = { "branch", "prompt" },
    properties = {
      branch = {
        type = "string",
        description = [[Full branch name (e.g. "smores/my-feature"). Generate via:
agent-branch-name --slug <slug> --task "<task>"]],
      },
      prompt = {
        type = "string",
        description = "Full prompt for the new smelt session (e.g. 'Implement user authentication with OAuth2')",
      },
      task = {
        type = "string",
        description = "Short display label for the confirmation dialog (defaults to the worktree name, derived from the branch)",
      },
    },
  },
  summary = function(args)
    return args.task or (args.branch or ""):match("([^/]+)$") or "spawn session"
  end,
  execute = function(args)
    local branch = args.branch or ""
    local prompt = args.prompt or ""
    if branch == "" or prompt == "" then
      return { content = "error: branch and prompt are required", is_error = true }
    end

    local worktree_name = branch:match("([^/]+)$") or branch
    local display_label = args.task or worktree_name

    local prompt_preview = (prompt:match("^([^\n]+)") or prompt):gsub("%s+", " ")
    if #prompt_preview > 120 then
      prompt_preview = prompt_preview:sub(1, 117) .. "..."
    end

    local body = string.format(
      "Start a new session?\n\n- **Branch:** `%s`\n- **Worktree:** `%s`\n- **Prompt:** %s",
      branch, worktree_name, prompt_preview
    )

    local start_label = "Start: " .. display_label
    local md_leaf = smelt.dialog.markdown(body)
    local options_leaf = smelt.dialog.menu({
      { label = start_label, description = branch },
      { label = "Cancel", description = "dismiss" },
    }, { shortcuts = "select" })

    local picked = smelt.dialog.open({
      title = "spawn session",
      max_height = "100%",
      min_height = 0,
      panels = { { leaf = md_leaf, height = "fit" } },
      bottom_panels = { { leaf = options_leaf, height = "fit" } },
      focus = options_leaf,
    })

    if not picked or picked.index ~= 1 then
      return "(cancelled by user)"
    end

    -- 1. Create the worktree (synchronous, captures JSON path).
    local wt_res, wt_err = smelt.process.run(
      "wt",
      { "switch", "--create", "--no-hooks", "--no-cd", branch, "--format", "json" }
    )
    if wt_res == nil then
      return { content = "error creating worktree: " .. (wt_err or "spawn failed"), is_error = true }
    end
    if wt_res.exit_code ~= 0 then
      local msg = (wt_res.stdout or ""):match("^ERR:(.+)") or wt_res.stdout or wt_res.stderr or ""
      return { content = "error creating worktree: " .. msg, is_error = true }
    end

    local path = (wt_res.stdout or ""):match('"path":"([^"]*)"')
    if not path or path == "" then
      -- Fallback: derive the worktree path from the repo root + worktree name.
      local root_res = smelt.process.run("git", { "rev-parse", "--show-toplevel" })
      local root = root_res and root_res.stdout or ""
      root = root:gsub("%s+$", "")
      if root ~= "" then
        path = root .. "/.worktrees/" .. worktree_name
      end
    end
    if not path or path == "" then
      return { content = "error: could not determine worktree path", is_error = true }
    end

    -- 2. Open a new Zellij tab running smelt in the worktree (fire-and-forget:
    -- the new session outlives this tool call). smolvm-agent forwards args to
    -- the agent VM; the prompt rides in via an env var to avoid quoting hell.
    local tab_name = sushi_icon .. " - " .. worktree_name
    local script = string.format(
      "zellij action new-tab -n %s -c %s --close-on-exit -- smolvm-agent smelt -- \"$START_PROMPT\"",
      shell_quote(tab_name),
      shell_quote(path)
    )
    smelt.process.spawn_bg("START_PROMPT=" .. shell_quote(prompt) .. " " .. script)

    return string.format(
      "Started session in Zellij tab **%s**\n- Worktree: `%s`\n- Branch: `%s`",
      worktree_name, path, branch
    )
  end,
})
