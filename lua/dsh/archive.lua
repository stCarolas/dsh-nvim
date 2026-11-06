--- Archived-session visibility.
---
--- DSH has no hard delete: `workspace/archiveSession` hides a session from
--- Workspace and picker surfaces and keeps its transcript. The archive set is
--- registry-global and reaches clients through the `workspace/follow` stream,
--- so this module keeps a live copy over the shared mux and filters pickers.
--- A session deleted in this Neovim is hidden immediately, before the server
--- confirms the archive.
local M = {}

local mux = require("dsh.mux")

local state = {
  --- @type table<string, boolean>
  archived = {},
  --- Sessions `:DshDelete` removed here; kept hidden for this Neovim session.
  --- @type table<string, boolean>
  hidden = {},
  ready = false,
  unavailable = false,
  stream_id = nil,
  connecting = false,
}

local listening = false

--- Replace the cached archive set from a baseline or "archived" frame.
--- @param ids string[]|nil
local function set_archived(ids)
  local next_archived = {}
  for _, session_id in ipairs(ids or {}) do
    next_archived[session_id] = true
  end
  state.archived = next_archived
  state.ready = true
  state.unavailable = false
end

--- Apply one `workspace/follow` frame.
--- @param frame table
local function apply(frame)
  if type(frame) ~= "table" then
    return
  end
  if frame.type == "baseline" or frame.type == "replace" then
    local value = type(frame.value) == "table" and frame.value or {}
    set_archived(value.archivedSessionIds)
  elseif frame.type == "archived" then
    set_archived(frame.archivedSessionIds)
  end
end

--- Reset the socket projection after a mux close or stream failure.
local function forget_stream()
  state.stream_id = nil
  state.ready = false
end

local function open_stream()
  if state.stream_id or not mux.is_connected() then
    return
  end
  state.stream_id = mux.stream("workspace/follow", {}, {
    on_item = apply,
    on_end = forget_stream,
    on_error = function()
      forget_stream()
      state.unavailable = true
    end,
  })
  if not state.stream_id then
    state.unavailable = true
  end
end

local function listen_close()
  if listening then
    return
  end
  listening = true
  if type(mux.on_close) == "function" then
    mux.on_close(forget_stream)
  end
end

--- Start (or resume) the archive subscription without blocking.
--- @param ctx table connection context from `server.context`
function M.begin(ctx)
  listen_close()
  -- A deliberate mux close (last view closed) does not call the close
  -- listeners, so a cached stream may outlive its socket.
  if state.stream_id and not mux.is_connected() then
    state.stream_id = nil
    state.ready = false
  end
  if state.ready or state.stream_id or state.connecting then
    return
  end

  state.unavailable = false
  if mux.is_connected() then
    open_stream()
    return
  end

  state.connecting = true
  mux.acquire(ctx, function(err)
    state.connecting = false
    if err then
      state.unavailable = true
      return
    end
    open_stream()
    if not state.stream_id then
      state.unavailable = true
    end
  end)
end

--- Wait for the first archive baseline, bounded by `timeout`.
---
--- Fails open: when the workspace stream cannot be opened in time, pickers
--- simply keep whatever archived set is cached (or none), instead of failing.
--- @param ctx table
--- @param timeout number|nil
function M.ensure(ctx, timeout)
  if state.ready and mux.is_connected() then
    return
  end
  M.begin(ctx)
  if state.ready or state.unavailable then
    return
  end
  vim.wait(timeout or 1000, function()
    return state.ready or state.unavailable
  end, 10)
end

--- Hide a session immediately, before the archive baseline catches up.
--- @param session_id string
function M.hide(session_id)
  if type(session_id) == "string" and session_id ~= "" then
    state.hidden[session_id] = true
  end
end

--- Whether a session is archived or was deleted in this Neovim.
--- @param session_id string
--- @return boolean
function M.is_hidden(session_id)
  return state.hidden[session_id] == true or state.archived[session_id] == true
end

--- Whether the archive baseline has arrived.
--- @return boolean
function M.is_ready()
  return state.ready
end

--- Drop archived sessions from a picker list.
--- @param items table[]
--- @param include_archived boolean|nil keep server-archived sessions visible
--- @return table[]
function M.filter(items, include_archived)
  local kept = {}
  for _, item in ipairs(type(items) == "table" and items or {}) do
    local session_id = type(item) == "table" and item.sessionId or nil
    local hidden = type(session_id) == "string"
      and (state.hidden[session_id] == true or (include_archived ~= true and state.archived[session_id] == true))
    if not hidden then
      kept[#kept + 1] = item
    end
  end
  return kept
end

return M
