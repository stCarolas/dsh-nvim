--- Session operations. Thin, typed wrappers over the `session/*` Remote methods.
local M = {}

local config = require("dsh.config")
local http = require("dsh.http")

local json = vim.json

--- Mint a request id for one prompt. DSH persists it on the accepted user message.
--- @return string
function M.request_id()
  local hex = vim.fn.sha256(
    tostring(vim.uv.hrtime()) .. tostring(math.random()) .. tostring(os.time()) .. tostring(vim.uv.os_getpid())
  )
  return ("%s-%s-4%s-%s-%s"):format(
    hex:sub(1, 8),
    hex:sub(9, 12),
    hex:sub(14, 16),
    hex:sub(17, 20),
    hex:sub(21, 32)
  )
end

--- Order session summaries by recency of use.
---
--- DSH returns `session/list` ordered by activity (most recent first), while the
--- picker is usually more useful with the stalest session on top.
--- @param items table[]
--- @return table[]
function M.order(items)
  local order = config.options.sessions and config.options.sessions.order or "oldest"
  if order == "none" then
    return items
  end

  local newest_first = order == "newest"
  table.sort(items, function(left, right)
    local left_time = left.updatedAt or 0
    local right_time = right.updatedAt or 0
    if left_time == right_time then
      -- Deterministic tie-break so equal timestamps do not shuffle between calls.
      return tostring(left.sessionId) < tostring(right.sessionId)
    end
    if newest_first then
      return left_time > right_time
    end
    return left_time < right_time
  end)
  return items
end

--- Every visible session, ordered by `sessions.order`.
--- @param ctx {url: string, cookie: string}
--- @return table[]|nil items
--- @return string|nil error
function M.list(ctx)
  local value, err = http.rpc(ctx, "session/list", { _request = vim.empty_dict() }, config.options.request_timeout)
  if not value then
    return nil, err
  end
  return M.order(value.items or {})
end

--- Create (or reuse) a session rooted at `cwd`.
--- @return table|nil {sessionId, agentPreset}
function M.create(ctx, cwd)
  return http.rpc(ctx, "session/create", {
    request = { cwd = cwd or vim.fn.getcwd() },
  }, config.options.request_timeout)
end

--- Read one backwards history page ending at `through_seq`.
--- @param through_seq number cursor (`projections.asOfSeq`), NOT an arbitrary large number
--- @return {records: table[], hasMore: boolean}|nil
function M.page(ctx, session_id, through_seq, max_messages)
  return http.rpc(ctx, "session/page", {
    request = {
      address = { kind = "session", sessionId = session_id },
      throughSeq = through_seq,
      maxMessages = max_messages or config.options.max_messages,
    },
  }, config.options.request_timeout)
end

--- Queue a user message. Returns once DSH has accepted it into the agent inbox.
function M.prompt(ctx, session_id, text)
  return http.rpc(ctx, "session/prompt", {
    request = {
      requestId = M.request_id(),
      sessionId = session_id,
      mode = "queue",
      content = { { type = "text", text = text } },
    },
  }, config.options.request_timeout)
end

--- Ask the live agent to stop the current turn.
function M.cancel(ctx, session_id)
  return http.rpc(ctx, "session/cancel", {
    request = { sessionId = session_id },
  }, config.options.request_timeout)
end

--- Rename a session (DSH normally titles sessions itself from the first prompt).
function M.rename(ctx, session_id, title)
  return http.rpc(ctx, "session/rename", {
    request = { sessionId = session_id, title = title },
  }, config.options.request_timeout)
end

--- Find one session summary by id.
--- @return table|nil
function M.find(ctx, session_id)
  local items, err = M.list(ctx)
  if not items then
    return nil, err
  end
  for _, item in ipairs(items) do
    if item.sessionId == session_id then
      return item
    end
  end
  return nil
end

--- Current history cursor for a session. `session/page` rejects a `throughSeq`
--- beyond this value, so it is required rather than optional.
--- @return number|nil
function M.cursor(ctx, session_id)
  local item = M.find(ctx, session_id)
  local projections = item and item.projections
  if projections and projections.asOfSeq then
    return projections.asOfSeq
  end

  local value = http.rpc(ctx, "session/projections", {
    request = { sessionId = session_id },
  }, config.options.request_timeout)
  if type(value) == "table" and value.asOfSeq then
    return value.asOfSeq
  end
  return nil
end

--- Title DSH derived for a session, when one exists.
function M.title(item)
  local projections = item and item.projections
  local values = projections and projections.values
  local title = values and values.title
  if type(title) == "string" and title ~= "" then
    return title
  end
  return nil
end

--- Compact display id, e.g. `session-1a2b3c4d…` -> `1a2b3c4d`.
function M.short_id(session_id)
  local id = session_id:gsub("^session%-", "")
  return id:sub(1, 8)
end

--- Pretty one-line tool arguments.
function M.summarize_arguments(raw)
  if type(raw) ~= "string" or raw == "" then
    return ""
  end
  local ok, decoded = pcall(json.decode, raw)
  if not ok or type(decoded) ~= "table" then
    return raw:gsub("%s+", " "):sub(1, 120)
  end
  local parts = {}
  for key, value in pairs(decoded) do
    local rendered
    if type(value) == "string" then
      rendered = value:gsub("%s+", " "):sub(1, 80)
    else
      rendered = json.encode(value)
    end
    parts[#parts + 1] = ("%s=%s"):format(key, rendered)
  end
  table.sort(parts)
  return table.concat(parts, " "):sub(1, 160)
end

return M
