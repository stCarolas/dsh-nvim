--- Session operations. Thin, typed wrappers over the `session/*` Remote methods.
local M = {}

local config = require("dsh.config")
local http = require("dsh.http")
local workspace = require("dsh.workspace")

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

--- Canonical absolute form of a directory path, for talking to the server.
---
--- DSH records a Workspace under its `realpath` and validates that a Session's
--- cwd resolves to exactly that path. A Session created with a raw `cwd` keeps
--- the string it was given, though, so the same directory may appear as a
--- symlink in one place and as its target in another.
---
--- This is also the value sent to `workspace/create` and to a plain
--- `session/create`, so it keeps the on-disk spelling (case included); compare
--- paths through `comparison_key` instead.
--- @param path string|nil defaults to Neovim's current directory
--- @return string|nil
function M.canonical_path(path)
  path = path or vim.fn.getcwd()
  if type(path) ~= "string" or path == "" then
    return nil
  end
  -- A NUL makes `fnamemodify` raise E976; treat it as unusable instead.
  if path:find("\0", 1, true) then
    return nil
  end

  local absolute, expanded = pcall(vim.fn.fnamemodify, path, ":p")
  if not absolute or type(expanded) ~= "string" or expanded == "" then
    return nil
  end
  path = expanded

  local uv = vim.uv or vim.loop
  local ok, resolved = pcall(uv.fs_realpath, path)
  if ok and type(resolved) == "string" and resolved ~= "" then
    path = resolved
  end

  -- `realpath` drops trailing separators itself; the fallback path may not.
  -- Keep a filesystem root ("/", "C:\\") intact.
  if not path:match("^[/\\]$") and not path:match("^%a:[/\\]$") then
    path = path:gsub("[/\\]+$", "")
  end
  return path
end

--- Platform hints used for comparison folding.
--- @param platform {win32: boolean|nil, macos: boolean|nil}|nil defaults to the host
--- @return {win32: boolean, macos: boolean}
local function platform_of(platform)
  if type(platform) == "table" then
    return { win32 = platform.win32 == true, macos = platform.macos == true }
  end
  return {
    win32 = vim.fn.has("win32") == 1,
    macos = vim.fn.has("mac") == 1 or vim.fn.has("macunix") == 1,
  }
end

--- Comparison key for a cwd: the canonical path, folded per platform.
---
--- Windows and macOS compare directories case-insensitively by default and
--- Windows mixes separators, so the same directory can be spelled differently
--- by the client and the server. Only comparisons use this key; nothing sent
--- to DSH is case-folded.
--- @param path string|nil defaults to Neovim's current directory
--- @param platform {win32: boolean|nil, macos: boolean|nil}|nil injectable for tests
--- @return string|nil
function M.comparison_key(path, platform)
  local canonical = M.canonical_path(path)
  if not canonical then
    return nil
  end

  local env = platform_of(platform)
  if env.win32 then
    canonical = canonical:gsub("/", "\\")
  end
  if env.win32 or env.macos then
    canonical = canonical:lower()
  end
  return canonical
end

--- Whether a session summary is rooted at `cwd`.
--- @param item table SessionSummary
--- @param cwd string|nil defaults to Neovim's current directory
--- @param platform {win32: boolean|nil, macos: boolean|nil}|nil injectable for tests
--- @return boolean
function M.in_directory(item, cwd, platform)
  if type(item) ~= "table" or type(item.cwd) ~= "string" then
    return false
  end
  local target = M.comparison_key(cwd, platform)
  return target ~= nil and M.comparison_key(item.cwd, platform) == target
end

--- Keep only the sessions rooted at `cwd`, preserving their order.
---
--- Tolerant of whatever `session/list` returned: rows that are not tables, or
--- whose cwd cannot be resolved, are skipped rather than raising inside the
--- picker.
--- @param items table[]|nil
--- @param cwd string|nil defaults to Neovim's current directory
--- @param platform {win32: boolean|nil, macos: boolean|nil}|nil injectable for tests
--- @return table[]
function M.filter_directory(items, cwd, platform)
  local target = M.comparison_key(cwd, platform)
  if not target then
    return {}
  end

  -- Resolving every summary is cheap, but sessions in one directory repeat the
  -- same path (and the same failures); resolve each distinct cwd once.
  local cache = { [target] = target }
  local filtered = {}
  for _, item in ipairs(type(items) == "table" and items or {}) do
    if type(item) == "table" and type(item.cwd) == "string" then
      local key = cache[item.cwd]
      if key == nil then
        key = M.comparison_key(item.cwd, platform) or false
        cache[item.cwd] = key
      end
      if key == target then
        filtered[#filtered + 1] = item
      end
    end
  end
  return filtered
end

--- Whether a SessionSummary is a root session (not spawned by a subagent).
---
--- DSH marks child sessions with `origin = "subagent"` and/or the session that
--- spawned them; both are checked so older and newer server shapes work.
--- @param item table
--- @return boolean
function M.is_root(item)
  if type(item) ~= "table" then
    return false
  end
  local parent = item.parentSessionId
  if type(parent) == "string" and parent ~= "" then
    return false
  end
  return item.origin ~= "subagent"
end

--- Keep only root sessions.
--- @param items table[]
--- @return table[]
function M.filter_roots(items)
  local roots = {}
  for _, item in ipairs(type(items) == "table" and items or {}) do
    if M.is_root(item) then
      roots[#roots + 1] = item
    end
  end
  return roots
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

--- DSH errors that mean `session/create` failed before it created anything, so
--- retrying with a plain `cwd` cannot produce a second session.
local PRE_CREATION_ERRORS = {
  ["gateway/invocation-unavailable"] = true,
  ["gateway/method-unavailable"] = true,
  ["gateway/service-unavailable"] = true,
  ["workspace/invalid-path"] = true,
  ["workspace/not-found"] = true,
}

--- Create a session inside the Workspace for `cwd`, registering it if needed.
---
--- Sessions created with a bare `cwd` are not members of any Workspace, so the
--- web UI lists them ungrouped. Naming the Workspace instead makes the new
--- session appear under that project in every DSH surface.
---
--- `session/create` creates the session **before** attaching it, and DSH reports
--- a failed attach as `session/workspace-attach-failed` with the created
--- `sessionId` in the error details. That case returns the created session with
--- a warning instead of creating a second one; a retry would leave an orphan.
--- Only errors that provably happened before creation fall back to a plain
--- `cwd` session, and a missing Workspace registry does too.
--- @param ctx {url: string, cookie: string}
--- @param cwd string|nil defaults to Neovim's current directory
--- @return table|nil {sessionId, agentPreset}
--- @return string|nil error
--- @return string|nil warning set when creation fell back to a plain cwd session
function M.create_in_workspace(ctx, cwd)
  local path = M.canonical_path(cwd)
  if not path then
    return M.create(ctx, vim.fn.getcwd())
  end

  local project, workspace_err = workspace.ensure(ctx, path)
  if project then
    local value, err, code, details = http.rpc(ctx, "session/create", {
      request = { workspaceId = project.workspaceId },
    }, config.options.request_timeout)
    if value then
      return value, nil, nil
    end

    if code == "session/workspace-attach-failed" then
      local created = type(details) == "table" and details.sessionId or nil
      if type(created) == "string" and created ~= "" then
        return { sessionId = created },
          nil,
          ("session created but not attached to the workspace: %s"):format(err or code)
      end
      return nil, err or code
    end

    if PRE_CREATION_ERRORS[code or ""] then
      local fallback, fallback_err = M.create(ctx, path)
      if fallback then
        return fallback, nil, ("workspace attach failed: %s"):format(err or code)
      end
      return nil, fallback_err or err
    end

    -- Unknown or transport-level failure: the session may already exist, so do
    -- not create another one. The error is reported instead.
    return nil, err or "session/create failed"
  end

  local value, err = M.create(ctx, path)
  if value then
    return value, nil, workspace_err
  end
  return nil, err or workspace_err
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

--- Keep at most `limit` characters of `text`.
---
--- Tool arguments may contain any UTF-8 (paths, prompts, file contents). Byte
--- slicing can split a multibyte sequence and leave the chat buffer with bytes
--- `vim.fn.json_encode` (and completion clients) reject with E474, so truncation
--- must count characters, never bytes.
--- @param text string
--- @param limit integer
--- @return string
local function truncate(text, limit)
  if vim.fn.strchars(text) <= limit then
    return text
  end
  return vim.fn.strcharpart(text, 0, limit)
end

--- Pretty one-line tool arguments.
function M.summarize_arguments(raw)
  if type(raw) ~= "string" or raw == "" then
    return ""
  end
  local ok, decoded = pcall(json.decode, raw)
  if not ok or type(decoded) ~= "table" then
    return truncate(raw:gsub("%s+", " "), 120)
  end
  local parts = {}
  for key, value in pairs(decoded) do
    local rendered
    if type(value) == "string" then
      rendered = truncate(value:gsub("%s+", " "), 80)
    else
      rendered = json.encode(value)
    end
    parts[#parts + 1] = ("%s=%s"):format(key, rendered)
  end
  table.sort(parts)
  return truncate(table.concat(parts, " "), 160)
end

return M
