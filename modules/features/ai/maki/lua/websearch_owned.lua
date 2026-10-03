-- Owned web search: queries the self-hosted SearXNG on smortress over the
-- tailnet, so search costs no vendor money. The bundled `websearch` plugin is
-- disabled in init.lua; this file reclaims its tool name, schema, and audiences
-- so nothing downstream (delegation, the interpreter) changes.
--
-- The endpoint is private: `net.allowed_private_hosts` in init.lua lists
-- "smortress:8888", which also keeps the plain http:// scheme that maki.net
-- would otherwise upgrade to https://.

local ENDPOINT = "http://smortress:8888/search"
local REQUEST_TIMEOUT_SECS = 25
local DEFAULT_NUM_RESULTS = 8
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
    local snippet = result.content or ""
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
  description = "Search the web for real-time information using a self-hosted SearXNG.\n\n"
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

    local url = ENDPOINT .. "?format=json&q=" .. urlencode(query)
    local resp, err = maki.net.request(url, {
      headers = { ["Accept"] = "application/json" },
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

    local text = format_results(data.results or {}, input.num_results or DEFAULT_NUM_RESULTS)
    return { llm_output = truncate(text, MAX_OUTPUT_LINES, MAX_OUTPUT_BYTES) }
  end,
})
