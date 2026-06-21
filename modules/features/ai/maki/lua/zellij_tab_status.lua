-- zellij_tab_status: Show agent status in the Zellij tab name.
--
-- Subscribes to maki lifecycle autocmds and appends a status suffix to
-- the current Zellij tab name while the agent is working.  Restores the
-- original name on normal turn completion.
--
-- Known limitation: cancelled turns (ESC / provider errors) don't fire
-- TurnEnd or TurnError, so the tab stays at "· working" until the next
-- normal completion or until maki exits.
--
-- Only activates when zellij is available on PATH and the autocmd API
-- is present (maki > 0.3.18).
-- Managed by home-manager. Manual edits are clobbered.

if maki.fn.executable("zellij") == 0
  or maki.api.create_autocmd == nil
then
  return
end

local original_name = nil

local function shell_quote(s)
  return "'" .. s:gsub("'", "'\\''") .. "'"
end

local function rename_tab(name)
  local cmd = "zellij action rename-tab -- " .. shell_quote(name)
  local job_id = maki.fn.jobstart(cmd, {})
  if job_id then
    maki.fn.jobwait(job_id, 2000)
  end
end

local function defer(fn)
  maki.async.run(fn)
end

local function save_original()
  if original_name then return end
  local job_id = maki.fn.jobstart("zellij action list-tabs --json --state", {})
  if not job_id then return end
  local result = maki.fn.jobwait(job_id)
  if not result or result.exit_code ~= 0 or not result.stdout then return end
  local last_name = nil
  for line in result.stdout:gmatch("[^\n]+") do
    local name = line:match('"name"%s*:%s*"([^"]*)"')
    if name then last_name = name end
    if line:find('"active"%s*:%s*true') and last_name then
      original_name = last_name
      return
    end
  end
end

maki.api.create_autocmd("TurnStart", {
  callback = function()
    defer(function()
      save_original()
      if original_name then
        rename_tab(original_name .. " · working")
      end
    end)
  end,
})

maki.api.create_autocmd("TurnEnd", {
  callback = function()
    defer(function()
      if original_name then rename_tab(original_name) end
    end)
  end,
})

maki.api.create_autocmd("TurnError", {
  callback = function()
    defer(function()
      if original_name then rename_tab(original_name) end
    end)
  end,
})
