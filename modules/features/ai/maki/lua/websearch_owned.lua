-- Owned web search: Brave Search API.
--
-- The bundled `websearch` plugin is disabled in init.lua; this file reclaims its
-- tool name, schema, and audiences so nothing downstream (delegation, the
-- interpreter) changes. It uses the free Brave Search API tier; the key comes
-- from `BRAVE_API_KEY`, which the fish init exports from the sops secret.

local ENDPOINT = "https://api.search.brave.com/res/v1/web/search"
local REQUEST_TIMEOUT_SECS = 25
local DEFAULT_NUM_RESULTS = 8
local MAX_NUM_RESULTS = 20
local MAX_OUTPUT_LINES = 40
local MAX_OUTPUT_BYTES = 32 * 1024

local truncate = require("maki.truncate")

local UNRESERVED = {}
for c in ("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.~"):gmatch(".") do
  UNRESERVED[c] = true
end

-- maki exposes no URL-encoder, and a raw query breaks on &, #, +, % and spaces.
local function urlencode(value)
  return (value:gsub(".", function(c)
    if UNRESERVED[c] then
      return c
    end
    return string.format("%%%02X", string.byte(c))
  end))
end

local function format_results(results, num_results)
  local count = math.min(#results, num_results)
  if count == 0 then
    return "No results."
  end

  local lines = {}
  for i = 1, count do
    local result = results[i]
    lines[#lines + 1] = "Title: " .. (result.title or "")
    lines[#lines + 1] = "URL: " .. (result.url or "")
    -- Brave descriptions can contain highlight markup; keep the text.
    local snippet = (result.description or ""):gsub("<[^>]+>", "")
    if snippet ~= "" then
      lines[#lines + 1] = "Snippet: " .. snippet
    end
    lines[#lines + 1] = ""
  end
  return table.concat(lines, "\n")
end

maki.api.register_tool({
  name = "websearch",
  kind = "fetch",
  description = "Search the web for real-time information using the Brave Search API.\n\n"
    .. "Today's date is "
    .. os.date("%Y-%m-%d")
    .. ".\n\n"
    .. "- Use for current events, documentation, APIs, or anything not in local files.\n"
    .. "- Prefer specific, targeted queries over broad ones.\n"
    .. "- Results include page titles, URLs, and content snippets.",

  schema = {
    type = "object",
    properties = {
      query = { type = "string", description = "Search query", required = true },
      num_results = { type = "integer", description = "Number of results to return (default 8)" },
    },
  },
  permission = "net",
  permission_scopes = "query",
  audiences = { "main", "research_sub", "general_sub", "interpreter" },

  header = function(input)
    return input.query
  end,

  handler = function(input)
    local query = input.query
    if not query then
      return { llm_output = "error: query is required", is_error = true }
    end

    local key = maki.uv.os_getenv("BRAVE_API_KEY")
    if not key or key == "" then
      return {
        llm_output = "error: BRAVE_API_KEY is not set; add brave-api-key to the sops secrets and open a new shell",
        is_error = true,
      }
    end

    local num = math.max(1, math.min(input.num_results or DEFAULT_NUM_RESULTS, MAX_NUM_RESULTS))
    local url = ENDPOINT .. "?q=" .. urlencode(query) .. "&count=" .. tostring(num)
    local resp, err = maki.net.request(url, {
      headers = {
        ["Accept"] = "application/json",
        ["X-Subscription-Token"] = key,
      },
      timeout = REQUEST_TIMEOUT_SECS,
    })
    if not resp then
      return { llm_output = "error: " .. tostring(err), is_error = true }
    end
    if resp.status < 200 or resp.status >= 300 then
      return {
        llm_output = "error: HTTP " .. tostring(resp.status) .. ": " .. resp.body:sub(1, 200),
        is_error = true,
      }
    end

    local data, decode_err = maki.json.decode(resp.body)
    if not data then
      return { llm_output = "error: invalid response: " .. tostring(decode_err), is_error = true }
    end

    local results = (data.web and data.web.results) or {}
    local text = format_results(results, num)
    return { llm_output = truncate(text, MAX_OUTPUT_LINES, MAX_OUTPUT_BYTES) }
  end,
})
