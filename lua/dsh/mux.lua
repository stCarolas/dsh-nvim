--- DSH Remote stream mux over one shared WebSocket.
---
--- DSH's `/api/remote.mux` carries logical streams as JSON text frames:
---   client -> {"type":"open","streamId":…,"endpoint":…,"payload":{"args":{…}}}
---             {"type":"item","streamId":…,"value":…}
---             {"type":"end"|"cancel","streamId":…}
---   server -> {"type":"item","streamId":…,"value":…}
---             {"type":"end","streamId":…}
---             {"type":"error","streamId":…,"error":{code,message,details}}
---
--- Only stream-mode Remote methods can be opened here; DSH rejects unary methods
--- with `gateway/signature-invalid`, so those stay on the HTTP carrier.
---
--- The server claims exclusive socket ownership per authenticated peer, so every
--- logical stream shares this one connection.
local M = {}

local ws = require("dsh.ws")

local json = vim.json

local shared = {
  conn = nil,
  url = nil,
  cookie = nil,
  connecting = false,
  waiters = {},
  streams = {},
  listeners = {},
  next_id = 0,
}

--- True when a multiplexed socket is usable.
function M.is_connected()
  return shared.conn ~= nil and shared.conn.open == true
end

--- Credential of the peer that owns the open socket.
---
--- DSH ties forwarded human interactions to the peer that opened their stream:
--- another peer's answer is rejected. Answer RPCs that belong to a stream on
--- this socket must therefore send this cookie, not the long-lived HTTP one.
--- @return string|nil
function M.credential()
  if shared.conn and shared.conn.open then
    return shared.cookie
  end
  return nil
end

local function dispatch(text)
  local ok, message = pcall(json.decode, text)
  if not ok or type(message) ~= "table" then
    return
  end

  local stream = shared.streams[message.streamId]
  if not stream then
    return
  end

  if message.type == "item" then
    if stream.on_item then
      stream.on_item(message.value)
    end
  elseif message.type == "end" then
    shared.streams[message.streamId] = nil
    if stream.on_end then
      stream.on_end()
    end
  elseif message.type == "error" then
    shared.streams[message.streamId] = nil
    local err = message.error or {}
    local text = err.message or "stream failed"
    if err.code then
      text = err.code .. ": " .. text
    end
    if stream.on_error then
      stream.on_error(text)
    end
  end
end

--- Reset shared state after the socket closes, failing pending work exactly once.
local function handle_close(reason)
  local had_connection = shared.conn ~= nil
  shared.conn = nil
  shared.url = nil
  shared.cookie = nil
  shared.connecting = false

  local waiters = shared.waiters
  local streams = shared.streams
  shared.waiters = {}
  shared.streams = {}

  for _, waiter in ipairs(waiters) do
    waiter(reason or "connection closed")
  end
  if not had_connection then
    return
  end
  for _, stream in pairs(streams) do
    if stream.on_error then
      stream.on_error(reason or "connection closed")
    end
  end
  for _, listener in ipairs(shared.listeners) do
    listener(reason or "connection closed")
  end
end

--- Register a callback fired whenever the socket closes unexpectedly.
--- @param listener fun(reason: string)
function M.on_close(listener)
  shared.listeners[#shared.listeners + 1] = listener
  return function()
    for index, existing in ipairs(shared.listeners) do
      if existing == listener then
        table.remove(shared.listeners, index)
        return
      end
    end
  end
end

--- Ensure a multiplexed connection for `ctx`.
--- @param ctx {url: string, cookie: string, mint: fun(): string|nil|nil}
--- @param callback fun(err: string|nil)
function M.acquire(ctx, callback)
  if shared.conn and shared.conn.open and shared.url == ctx.url then
    callback(nil)
    return
  end

  shared.waiters[#shared.waiters + 1] = callback
  if shared.connecting then
    return
  end

  if shared.conn then
    shared.conn:close("reconnecting")
    shared.conn = nil
  end

  -- Claim a disposable peer for this socket; the HTTP cookie must stay unused.
  local cookie = ctx.cookie
  if type(ctx.mint) == "function" then
    local minted = ctx.mint()
    if minted then
      cookie = minted
    end
  end

  shared.connecting = true
  shared.url = ctx.url
  shared.cookie = cookie

  -- A replaced socket's late close must not fail waiters belonging to the new one.
  local conn_ref
  local ok, created = pcall(ws.connect, {
    url = ctx.url,
    path = "/api/remote.mux",
    cookie = cookie,
    on_open = function()
      shared.connecting = false
      local waiters = shared.waiters
      shared.waiters = {}
      for _, waiter in ipairs(waiters) do
        waiter(nil)
      end
    end,
    on_message = dispatch,
    on_close = function(reason)
      if shared.conn ~= conn_ref then
        return
      end
      handle_close(reason)
    end,
  })
  conn_ref = created

  if not ok then
    shared.connecting = false
    shared.url = nil
    shared.cookie = nil
    local waiters = shared.waiters
    shared.waiters = {}
    for _, waiter in ipairs(waiters) do
      waiter("cannot open websocket: " .. tostring(created))
    end
    return
  end

  shared.conn = created
end

--- Open one logical stream.
--- @param endpoint string e.g. "session/follow"
--- @param args table named arguments (the `args` object)
--- @param handlers {on_item: fun(value:any), on_end: fun()|nil, on_error: fun(message:string)|nil}
--- @return string|nil stream_id
function M.stream(endpoint, args, handlers)
  handlers = handlers or {}
  if not shared.conn or not shared.conn.open then
    if handlers.on_error then
      handlers.on_error("websocket is not connected")
    end
    return nil
  end

  shared.next_id = shared.next_id + 1
  local stream_id = "nvim-" .. tostring(shared.next_id)
  shared.streams[stream_id] = handlers

  local ok, err = shared.conn:send_text(json.encode({
    type = "open",
    streamId = stream_id,
    endpoint = endpoint,
    payload = { args = args or vim.empty_dict() },
  }))
  if not ok then
    shared.streams[stream_id] = nil
    if handlers.on_error then
      handlers.on_error(tostring(err))
    end
    return nil
  end

  return stream_id
end

--- Cancel one logical stream.
--- @param stream_id string|nil
function M.cancel(stream_id)
  if not stream_id then
    return
  end
  shared.streams[stream_id] = nil
  if shared.conn and shared.conn.open then
    shared.conn:send_text(json.encode({ type = "cancel", streamId = stream_id }))
  end
end

--- Close the shared socket. Streams fail through their own `on_error`.
function M.close()
  local conn = shared.conn
  shared.conn = nil
  shared.url = nil
  shared.cookie = nil
  shared.connecting = false
  shared.streams = {}
  shared.waiters = {}
  if conn then
    conn:close("closed by client")
  end
end

return M
