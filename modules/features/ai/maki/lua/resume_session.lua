-- resume_session: search prior maki sessions (across all projects) by message
-- content and resume a chosen one in a new Zellij tab. Also exposed as the
-- /resume slash command.
--
-- Session parsing is delegated to the `maki-session-search` backend (`list
-- --json`), which already handles the header/meta/msg record formats and all
-- plausible session directories. A session already live in this UI is focused
-- instead of re-spawned, to avoid two writers appending to the same JSONL.
-- A session live in another process cannot be detected here; the tool result
-- notes that so the user can switch to it instead.
--
-- Prerequisites on PATH: maki-session-search, zellij

local ListPicker = require("maki.list_picker")
local shorten_path = require("maki.shorten_path")
local QuestionForm = require("question_form")

-- Nerd Font sushi glyph (nf-fae-sushi, U+E21A) prefixing the Zellij tab name,
-- matching spawn_session's convention.
local sushi_icon = "\238\136\154"
local LIST_TIMEOUT_MS = 60000

if maki.fn.executable("maki-session-search") == 0
  or maki.fn.executable("zellij") == 0
then
  return
end

local function shell_quote(s)
  return "'" .. s:gsub("'", "'\\''") .. "'"
end

local function age(updated_at)
  return maki.ui.humantime(math.max(os.time() - (updated_at or 0), 0))
end

-- Run `maki-session-search list --json` synchronously and decode each line.
-- Returns the session list (each: id, title, cwd, updated_at, search_text),
-- or nil plus an error message.
local function list_sessions_json()
  local job = maki.fn.jobstart("maki-session-search list --json")
  local res = maki.fn.jobwait(job, LIST_TIMEOUT_MS)
  if not res then
    return nil, "timed out listing sessions"
  end
  if res.exit_code ~= 0 then
    local msg = (res.stderr or ""):match("^([^\r\n]+)") or ("exit " .. res.exit_code)
    return nil, "maki-session-search failed: " .. msg
  end
  local sessions = {}
  for line in (res.stdout or ""):gmatch("[^\r\n]+") do
    if line ~= "" then
      local obj, err = maki.json.decode(line)
      if obj and not err and obj.id then
        sessions[#sessions + 1] = {
          id = obj.id,
          title = obj.title or "(untitled)",
          cwd = obj.cwd or "",
          updated_at = obj.updated_at or 0,
          search_text = obj.search_text or "",
        }
      end
    end
  end
  return sessions
end

-- Fuzzy-filter by query over title + cwd + search_text (full-text). Empty
-- query keeps everything. The in-picker filter then narrows by title.
local function filter_by_query(sessions, query)
  local words = ListPicker.split_words(query)
  if #words == 0 then
    return sessions
  end
  local kept = {}
  for _, s in ipairs(sessions) do
    local hay = (s.title .. " " .. s.cwd .. " " .. s.search_text):lower()
    if ListPicker.matches(hay, words) then
      kept[#kept + 1] = s
    end
  end
  return kept
end

-- Live sessions in this UI, keyed by id. Empty set if the UI can't report.
local function live_ids()
  local live, err = maki.session.live()
  if err or not live then
    return {}
  end
  local ids = {}
  for _, s in ipairs(live) do
    ids[s.id] = true
  end
  return ids
end

local function cwd_exists(cwd)
  if cwd == "" then
    return false
  end
  local meta, err = maki.fs.metadata(cwd)
  return meta ~= nil and not err
end

-- Open the fuzzy picker over sessions matching `query`. Returns the chosen
-- session, or nil (no match / cancelled). Live sessions are listed first and
-- marked so the user knows choosing them switches to the existing tab.
local function open_picker(query, live)
  local sessions, err = list_sessions_json()
  if not sessions then
    maki.ui.flash(err or "failed to list sessions")
    return nil
  end
  local filtered = filter_by_query(sessions, query or "")
  local ordered = {}
  for _, s in ipairs(filtered) do
    if live[s.id] then
      ordered[#ordered + 1] = s
    end
  end
  for _, s in ipairs(filtered) do
    if not live[s.id] then
      ordered[#ordered + 1] = s
    end
  end
  if #ordered == 0 then
    maki.ui.flash("no sessions match")
    return nil
  end
  local items = {}
  for _, s in ipairs(ordered) do
    items[#items + 1] = {
      label = (live[s.id] and "\226\151\143 " or "  ") .. s.title,
      detail = shorten_path(s.cwd) .. " \194\183 " .. age(s.updated_at),
    }
  end
  local result = ListPicker.open(items, { title = " Resume session ", cursor = 1 })
  if result.type ~= "choice" then
    return nil
  end
  return ordered[result.index]
end

-- Deliver a result: to the model via ctx:finish (tool) or as a flash (command).
local function finish(ctx, result)
  if ctx then
    ctx:finish(result)
  else
    maki.ui.flash(result.llm_output or "")
  end
end

-- Spawn a new Zellij tab running `maki --session <id>` in the session's cwd.
-- cwd and id are single-quoted. If the session's cwd is gone, ask whether to
-- resume in the current directory instead. Async; resolves via finish().
local function spawn_tab(ctx, session)
  local id = session.id
  local cwd = session.cwd
  if not cwd_exists(cwd) then
    local cur = maki.uv.cwd() or ""
    local form = QuestionForm.open({
      {
        question = ("Session directory no longer exists:\n\n`%s`\n\nResume in the current directory `%s` instead?"):format(cwd, cur),
        options = {
          { label = "Resume here", description = cur },
        },
      },
    })
    if form.type ~= "submit" then
      finish(ctx, { llm_output = "(cancelled by user)" })
      return
    end
    cwd = cur
  end

  local label = sushi_icon .. " - " .. session.title
  local script = string.format(
    "zellij action new-tab -n %s -c %s --close-on-exit -- maki --session %s || exit 1",
    shell_quote(label),
    shell_quote(cwd),
    shell_quote(id)
  )
  maki.fn.jobstart(script, {
    on_exit = function(_, code)
      if code ~= 0 then
        finish(ctx, { llm_output = "error: failed to open Zellij tab", is_error = true })
        return
      end
      local base = cwd:gsub(".*[/\\]", "")
      if base == "" then
        base = cwd
      end
      finish(ctx, {
        llm_output = ("Resumed session `%s` from `%s` in Zellij tab `%s`.\n"
          .. "If this session is already open in another tab, switch to it there instead to avoid conflicting writes.")
          :format(id:sub(1, 8), base, session.title),
      })
    end,
  })
end

local function resume(query, ctx)
  local live = live_ids()
  local session = open_picker(query, live)
  if not session then
    finish(ctx, { llm_output = "(no session selected)" })
    return
  end
  if live[session.id] then
    local _, err = maki.session.focus(session.id)
    finish(ctx, {
      llm_output = err
          and ("error focusing session: " .. err)
        or ("Switched to live session `" .. session.id:sub(1, 8) .. "` — " .. session.title),
      is_error = err and true or nil,
    })
    return
  end
  spawn_tab(ctx, session)
end

maki.api.register_tool({
  name = "resume_session",
  kind = "execute",
  audiences = { "main" },
  timeout = false,
  description = [[Search prior maki sessions (across all projects) by message content and resume a chosen one in a new Zellij tab.

Provide a `query` matched against session titles, paths, and message text; an interactive fuzzy picker opens for the user to choose. An empty `query` lists recent sessions. A session already live in this UI is focused instead of re-spawned. The resumed session continues in place (`maki --session <id>`) in its original directory.

This tool cannot be batched and requires user interaction.]],
  schema = {
    type = "object",
    properties = {
      query = {
        type = "string",
        description = "Search terms matched against session titles, paths, and message text. Empty lists recent sessions.",
      },
    },
  },
  header = function(input)
    return (input.query and input.query ~= "") and ("resume: " .. input.query) or "resume session"
  end,
  handler = function(input, ctx)
    resume(input.query, ctx)
    return nil -- async; result delivered via ctx:finish
  end,
})

maki.api.register_command({
  name = "/resume",
  description = "Search and resume a prior maki session in a new Zellij tab",
  nargs = "*",
  handler = function(opts)
    local q = opts.args or ""
    if type(q) == "table" then
      q = table.concat(q, " ")
    end
    resume(q, nil)
  end,
})
