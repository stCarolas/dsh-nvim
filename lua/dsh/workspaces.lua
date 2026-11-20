--- Workspace registry cache fed by the `workspace/follow` stream.
---
--- DSH exposes Workspaces only as a live stream: a baseline with every
--- visible Workspace, then `upsert`, `remove` and `order` frames. The
--- workspace picker needs that roster without opening the Web UI, so this
--- module keeps one subscription per connection and a client-side ordered
--- index. Frames carry `sessionIds`, so counts stay current as Sessions join
--- or leave a Workspace.
---
--- The subscription is lazy and fail-open: `:DshWorkspace` opens it on demand,
--- and a server without the stream is reported instead of stalling the
--- editor. The cache is dropped with the socket, so a reconnect cannot show a
--- roster from another server.
local M = {}

local mux = require("dsh.mux")

--- Default wait for the first baseline; the socket handshake is local.
local READY_TIMEOUT = 3000

local state = {
  --- Workspace ids in the Host's manual order.
  order = {},
  --- Workspace rows by id (`workspaceId`, `path`, `title`, `sessionIds`, ...).
  by_id = {},
  ready = false,
  unavailable = false,
  stream_id = nil,
  connecting = false,
  error = nil,
}

local listening = false

local function clear_items()
  state.order = {}
  state.by_id = {}
  state.ready = false
end

local function forget_stream()
  state.stream_id = nil
  state.ready = false
end

--- Subscribe to socket replacement once; cached rows belong to the old peer.
local function listen_close()
  if listening then
    return
  end
  listening = true
  if type(mux.on_close) == "function" then
    mux.on_close(function()
      forget_stream()
      clear_items()
    end)
  end
end

--- Replace the whole roster from a baseline or replace frame.
--- @param items table[]|nil
local function replace_items(items)
  local order, by_id = {}, {}
  for _, workspace in ipairs(type(items) == "table" and items or {}) do
    if type(workspace) == "table" and type(workspace.workspaceId) == "string" then
      by_id[workspace.workspaceId] = workspace
      order[#order + 1] = workspace.workspaceId
    end
  end
  state.order = order
  state.by_id = by_id
  state.ready = true
  state.unavailable = false
  state.error = nil
end

--- Apply an `order` frame, keeping rows this client has but the frame omits.
--- @param ids string[]|nil
local function apply_order(ids)
  local seen = {}
  local order = {}
  for _, id in ipairs(type(ids) == "table" and ids or {}) do
    if type(id) == "string" and state.by_id[id] and not seen[id] then
      seen[id] = true
      order[#order + 1] = id
    end
  end
  for _, id in ipairs(state.order) do
    if not seen[id] then
      order[#order + 1] = id
    end
  end
  state.order = order
end

--- Apply one `workspace/follow` frame.
--- @param frame table
local function apply(frame)
  if type(frame) ~= "table" then
    return
  end
  if frame.type == "baseline" or frame.type == "replace" then
    local value = type(frame.value) == "table" and frame.value or {}
    replace_items(value.items)
  elseif frame.type == "upsert" then
    local workspace = frame.workspace
    if type(workspace) == "table" and type(workspace.workspaceId) == "string" then
      if not state.by_id[workspace.workspaceId] then
        state.order[#state.order + 1] = workspace.workspaceId
      end
      state.by_id[workspace.workspaceId] = workspace
    end
  elseif frame.type == "remove" then
    local id = frame.workspaceId
    if state.by_id[id] then
      state.by_id[id] = nil
      for index, value in ipairs(state.order) do
        if value == id then
          table.remove(state.order, index)
          break
        end
      end
    end
  elseif frame.type == "order" then
    apply_order(frame.workspaceIds)
  end
end

local function open_stream()
  if state.stream_id or not mux.is_connected() then
    return
  end
  state.stream_id = mux.stream("workspace/follow", vim.empty_dict(), {
    on_item = apply,
    on_end = forget_stream,
    on_error = function(message)
      forget_stream()
      state.unavailable = true
      state.error = message
    end,
  })
  if not state.stream_id then
    state.unavailable = true
    state.error = state.error or "cannot open the workspace stream"
  end
end

--- Start (or resume) the workspace subscription without blocking.
---
--- Also connects the multiplexed socket when no session view opened it, which
--- is the case when the picker runs from a code buffer.
--- @param ctx table connection context from `server.context`
function M.begin(ctx)
  listen_close()
  -- A deliberate mux close (last view closed) does not call close listeners,
  -- so a cached stream may outlive its socket.
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
      state.error = err
      return
    end
    open_stream()
    if not state.stream_id then
      state.unavailable = true
      state.error = state.error or "cannot open the workspace stream"
    end
  end)
end

--- Wait for the first baseline, bounded by `timeout`.
--- @param ctx table
--- @param timeout number|nil milliseconds; defaults to 3000
--- @return boolean ok
--- @return string|nil error
function M.ensure(ctx, timeout)
  if state.ready and mux.is_connected() then
    return true
  end
  M.begin(ctx)
  if state.ready then
    return true
  end
  if state.unavailable then
    return nil, state.error or "workspace list unavailable"
  end

  vim.wait(timeout or READY_TIMEOUT, function()
    return state.ready or state.unavailable
  end, 10)
  if state.ready then
    return true
  end
  return nil, state.error or "timed out waiting for the workspace list"
end

--- Every cached Workspace in Host order.
--- @return table[]
function M.list()
  local items = {}
  for _, id in ipairs(state.order) do
    local workspace = state.by_id[id]
    if workspace then
      items[#items + 1] = workspace
    end
  end
  return items
end

--- Whether a baseline has arrived on the current socket.
--- @return boolean
function M.is_ready()
  return state.ready == true
end

--- Last stream failure, for diagnostics.
--- @return string|nil
function M.error()
  return state.error
end

return M
