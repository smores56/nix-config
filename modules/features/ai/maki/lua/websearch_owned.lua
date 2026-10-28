-- Owned web search: TinyFish Search API.
--
-- The bundled `websearch` plugin is disabled in init.lua; this file reclaims its
-- tool name, schema, and audiences so nothing downstream (delegation, the
-- interpreter) changes. The key comes from `TINYFISH_API_KEY`, which the fish
-- init exports from the sops secret.

local ENDPOINT = "https://api.search.tinyfish.ai"
local REQUEST_TIMEOUT_SECS = 20
local DEFAULT_NUM_RESULTS = 8
-- One TinyFish page holds at most 10 results and there is no count parameter;
-- asking for more pages would only be discarded by MAX_OUTPUT_LINES.
local MAX_NUM_RESULTS = 10
local MAX_OUTPUT_LINES = 40
local MAX_OUTPUT_BYTES = 32 * 1024

local STATUS_HINTS = {
  [401] = "TinyFish rejected TINYFISH_API_KEY; rotate tinyfish-api-key in the sops secrets",
  [402] = "TinyFish allowance or credits exhausted (the daily reset clears only FREE_ALLOWANCE_EXHAUSTED)",
  [403] = "TinyFish rejected the request (account entitlement or credits)",
  [429] = "TinyFish rate limit exceeded",
}

local truncate = require("maki.truncate")

-- maki exposes no URL-encoder, and a raw query breaks on &, #, +, %, spaces,
-- and control characters (Lua's `.` never matches a newline).
local function urlencode(value)
  return (value:gsub("[^%w%-%._~]", function(c)
    return string.format("%%%02X", string.byte(c))
  end))
end

-- TinyFish returns plain text, but a hostile page can still smuggle terminal
-- escapes or line breaks through a title or snippet.
local function clean(value)
  return ((value or ""):gsub("%c", " "))
end

local function format_results(results, num_results)
  local count = math.min(#results, num_results)
  if count == 0 then
    return "No results."
  end

  local lines = {}
  for i = 1, count do
    local result = results[i]
    lines[#lines + 1] = "Title: " .. clean(result.title)
    lines[#lines + 1] = "URL: " .. clean(result.url)
    local snippet = clean(result.snippet)
    if snippet ~= "" then
      lines[#lines + 1] = "Snippet: " .. snippet
    end
    lines[#lines + 1] = ""
  end
  return table.concat(lines, "\n")
end

-- Run one TinyFish search. Returns the results array, or nil plus an error
-- string that still carries the API's own message so a 402/403 is diagnosable.
local function request_results(key, query)
  local url = ENDPOINT .. "?query=" .. urlencode(query)
  local resp, err = maki.net.request(url, {
    headers = {
      ["Accept"] = "application/json",
      ["X-API-Key"] = key,
    },
    timeout = REQUEST_TIMEOUT_SECS,
    -- maki retries 5xx three times by default, which would stall a turn.
    retry = 1,
  })
  if not resp then
    return nil, tostring(err)
  end
  local detail
  if resp.status < 200 or resp.status >= 300 then
    detail = clean(resp.body):sub(1, 200)
    local hint = STATUS_HINTS[resp.status]
    if hint then
      return nil, hint .. ": " .. detail
    end
    return nil, "HTTP " .. tostring(resp.status) .. ": " .. detail
  end

  local data, decode_err = maki.json.decode(resp.body)
  if not data then
    return nil, "invalid response: " .. tostring(decode_err)
  end
  return data.results or {}
end

maki.api.register_tool({
  name = "websearch",
  kind = "fetch",
  description = "Search the web for real-time information using the TinyFish Search API.\n\n"
    .. "Today's date is "
    .. os.date("%Y-%m-%d")
    .. ".\n\n"
    .. "- Use for current events, documentation, APIs, or anything not in local files.\n"
    .. "- Prefer specific, targeted queries over broad ones.\n"
    .. "- Results include page titles, URLs, and content snippets.",

  schema = {
    type = "object",
    properties = {
      query = { type = "string", description = "Search query" },
      num_results = { type = "integer", description = "Number of results to return (default 8, max 10)" },
    },
    required = { "query" },
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

    local key = maki.uv.os_getenv("TINYFISH_API_KEY")
    if not key or key == "" then
      return {
        llm_output = "error: TINYFISH_API_KEY is not set; add tinyfish-api-key to the sops secrets and open a new shell",
        is_error = true,
      }
    end

    local num = input.num_results
    if type(num) ~= "number" then
      num = tonumber(num)
    end
    num = math.floor(num or DEFAULT_NUM_RESULTS)
    num = math.max(1, math.min(num, MAX_NUM_RESULTS))
    local results, err = request_results(key, query)
    if not results then
      return { llm_output = "error: " .. err, is_error = true }
    end

    local text = format_results(results, num)
    return { llm_output = truncate(text, MAX_OUTPUT_LINES, MAX_OUTPUT_BYTES) }
  end,
})
