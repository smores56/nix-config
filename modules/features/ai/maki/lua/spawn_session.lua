-- spawn_session: launch a new, independent maki coding session for a delegated
-- task, gated behind an in-handler confirmation dialog.
--
-- The dialog (ListPicker), NOT maki's permission system, is the confirmation
-- box: with always_yolo set, check_inner() returns Allowed on the allow_all
-- branch before force_prompt is ever consulted, so a permission_scopes
-- force_prompt would never fire. A handler-level UI prompt always shows.
--
-- Spawning routes through Paseo (`paseo run --provider maki --detach`) so the
-- new session is daemon-managed and attachable from both the CLI
-- (`paseo attach <id>`) and app.paseo.sh without a teardown/resume. No paseo on
-- PATH -> the tool is not registered (mirrors how the semble plugin self-gates).

local ListPicker = require("maki.list_picker")
local ToolView = require("maki.tool_view")
local truncate = require("maki.truncate")

if maki.fn.executable("paseo") == 0 then
  return
end

local function shell_quote(s)
  return "'" .. s:gsub("'", "'\\''") .. "'"
end

maki.api.register_tool({
  name = "spawn_session",
  kind = "execute",
  description = [[Spawn a new, independent maki coding session for a delegated task.

- Runs as a detached Paseo agent (provider: maki), separate from this session.
- The user is asked to confirm before anything is spawned.
- Returns the new agent's id/name; attach with `paseo attach <id>` or app.paseo.sh.
- Use for parallel, long-running, or context-isolated work. For in-session
  delegation prefer the built-in `task` tool.]],
  schema = {
    type = "object",
    required = { "task" },
    properties = {
      task = { type = "string", description = "Task prompt for the new maki session" },
      name = { type = "string", description = "Optional name for the spawned agent" },
    },
  },
  audiences = { "main" },
  timeout = false,
  header = function(input)
    return input.name or input.task or "spawn maki session"
  end,
  handler = function(input, ctx)
    local task = input.task
    if not task or task:match("^%s*$") then
      return { llm_output = "error: task is required", is_error = true }
    end

    local confirm = ListPicker.open({
      { label = "Spawn session", detail = "paseo run --provider maki --detach" },
      { label = "Cancel" },
    }, {
      title = "Spawn a new maki session?",
    })
    if not confirm or confirm.type ~= "choice" or confirm.index ~= 1 then
      return { llm_output = "(spawn cancelled by user)" }
    end

    local cmd = "paseo run --provider maki --detach"
    if input.name then
      cmd = cmd .. " --name " .. shell_quote(input.name)
    end
    cmd = cmd .. " " .. shell_quote(task)

    local config = ctx:config()
    local max_lines = (config and config.max_output_lines) or 2000
    local max_bytes = (config and config.max_output_bytes) or (50 * 1024)

    local buf = maki.ui.buf()
    local view = ToolView.new(buf, { max_lines = 5, keep = "tail" })
    view:append({ { "Spawning...", "dim" } })
    buf:on("click", function()
      view:toggle()
    end)

    local parts = {}
    local has_output = false

    maki.fn.jobstart(cmd, {
      on_stdout = function(_, line)
        if not has_output then
          has_output = true
          view:clear()
        end
        parts[#parts + 1] = line
        view:append(line)
      end,
      on_stderr = function(_, line)
        if not has_output then
          has_output = true
          view:clear()
        end
        parts[#parts + 1] = line
        view:append(line)
      end,
      on_exit = function(_, code)
        local output = table.concat(parts, "\n")
        local is_error = code ~= 0
        if output == "" then
          output = is_error and ("paseo run exited with code " .. code) or "spawned"
          view:clear()
          view:append({ { output, "dim" } })
        end
        view:finish()
        ctx:finish({
          llm_output = truncate(output, max_lines, max_bytes),
          is_error = is_error,
          body = buf,
        })
      end,
    })

    return nil
  end,
})
