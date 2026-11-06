--- Live session follower built on the `session/follow` stream.
---
--- The opening frame is a snapshot (durable records, cursor, projections, and the
--- in-flight assistant stream). Afterwards DSH sends durable event frames and,
--- when `assistantStream` is requested, process-local assistant chunk frames that
--- carry token deltas before the durable assistant message exists.
local M = {}

local config = require("dsh.config")
local mux = require("dsh.mux")
local surface = require("dsh.surface")

local function empty_live()
  return { text = "", reasoning = "", active = false }
end

--- Accumulate text deltas from a reconnect baseline stream.
--- @param baseline table|nil SessionAssistantStreamBaseline
--- @return {text: string, reasoning: string, active: boolean}
local function seed_live(baseline)
  local live = empty_live()
  local attempt = baseline and baseline.activeAttempt
  if type(attempt) ~= "table" then
    return live
  end
  live.active = true
  for _, chunk in ipairs(attempt.stream or {}) do
    if type(chunk) == "table" then
      if chunk.type == "text-delta" and type(chunk.text) == "string" then
        live.text = live.text .. chunk.text
      elseif chunk.type == "reasoning-delta" and type(chunk.text) == "string" then
        live.reasoning = live.reasoning .. chunk.text
      end
    end
  end
  return live
end

--- Whether the newest durable turn in a record window is still open.
---
--- Snapshots may start mid-turn, so walk backwards to the nearest boundary.
--- @param records table[]
--- @return boolean
local function records_running(records)
  for index = #(records or {}), 1, -1 do
    local event = records[index].event
    local kind = type(event) == "table" and event.type or nil
    if kind == "turn/end" then
      return false
    elseif kind == "turn/start" then
      return true
    end
  end
  return false
end

--- Follow one session over the shared mux.
--- @param ctx {url: string, cookie: string}
--- @param session_id string
--- @param callbacks {on_update: fun(state:table)|nil, on_status: fun(status:string, message:string|nil)|nil}
--- @return table handle with `detach()`
function M.attach(ctx, session_id, callbacks)
  callbacks = callbacks or {}

  local state = {
    session_id = session_id,
    records = {},
    entries = {},
    title = nil,
    status = "connecting",
    live = empty_live(),
  }

  local interval = config.options.stream.render_interval
  local detached = false
  local pending = false
  local stream_id = nil

  local function rebuild()
    local built = surface.build(state.records)
    state.entries = built.entries
    if built.title then
      state.title = built.title
    end
    if state.live.text ~= "" or (config.options.show_reasoning and state.live.reasoning ~= "") then
      state.entries[#state.entries + 1] = {
        role = "live",
        text = state.live.text,
        reasoning = config.options.show_reasoning and state.live.reasoning or "",
      }
    end
  end

  --- Rebuild and publish, coalescing bursts of chunk frames into one render.
  --- @param immediate boolean|nil
  local function emit(immediate)
    if detached then
      return
    end
    if immediate then
      pending = false
      rebuild()
      if callbacks.on_update then
        callbacks.on_update(state)
      end
      return
    end
    if pending then
      return
    end
    pending = true
    vim.defer_fn(function()
      if detached or not pending then
        return
      end
      pending = false
      rebuild()
      if callbacks.on_update then
        callbacks.on_update(state)
      end
    end, interval)
  end

  local function set_status(status, message)
    state.status = status
    if message then
      state.error = message
    end
    if callbacks.on_status then
      callbacks.on_status(status, message)
    end
  end

  --- A live frame proves a turn is running even if its `turn/start` was missed.
  local function mark_streaming()
    if state.status ~= "streaming" then
      set_status("streaming")
    end
  end

  local function handle_live_frame(frame)
    if type(frame) ~= "table" then
      return
    end
    if frame.type == "start" then
      state.live = empty_live()
      state.live.active = true
      mark_streaming()
      emit(false)
    elseif frame.type == "chunk" then
      local chunk = frame.chunk
      if type(chunk) ~= "table" then
        return
      end
      if chunk.type == "text-delta" and type(chunk.text) == "string" then
        state.live.active = true
        state.live.text = state.live.text .. chunk.text
        mark_streaming()
        emit(false)
      elseif chunk.type == "reasoning-delta" and type(chunk.text) == "string" and config.options.show_reasoning then
        state.live.reasoning = state.live.reasoning .. chunk.text
        mark_streaming()
        emit(false)
      end
    elseif frame.type == "end" then
      local outcome = frame.outcome or {}
      if outcome.kind == "abandoned" then
        state.live = empty_live()
      else
        -- Keep the streamed text visible until its durable event replaces it.
        state.live.active = false
      end
      emit(false)
    end
  end

  local function handle_item(value)
    if type(value) ~= "table" then
      return
    end

    if value.type == "snapshot" then
      state.records = value.records or {}
      state.cursor = value.cursor
      local projections = value.projections or {}
      local values = projections.values or {}
      if type(values.title) == "string" and values.title ~= "" then
        state.title = values.title
      end
      state.live = seed_live(value.assistantStream)
      set_status((records_running(state.records) or state.live.active) and "streaming" or "idle")
      emit(true)
    elseif value.type == "event" then
      state.records[#state.records + 1] = value
      local event = value.event or {}
      if event.type == "assistant/message" then
        state.live = empty_live()
      elseif event.type == "turn/start" then
        set_status("streaming")
      elseif event.type == "turn/end" then
        set_status("idle")
      elseif event.type == "session/title" then
        local data = event.data or {}
        if type(data.title) == "string" and data.title ~= "" then
          state.title = data.title
        end
      end
      emit(false)
    elseif value.type == "assistant-stream" then
      handle_live_frame(value.frame)
    end
  end

  mux.acquire(ctx, function(err)
    if detached then
      return
    end
    if err then
      set_status("disconnected", err)
      return
    end

    stream_id = mux.stream("session/follow", {
      request = {
        address = { kind = "session", sessionId = session_id },
        assistantStream = true,
        maxMessages = config.options.max_messages,
      },
    }, {
      on_item = handle_item,
      on_end = function()
        set_status("ended")
      end,
      on_error = function(message)
        set_status("error", message)
      end,
    })

    if not stream_id then
      set_status("error", "cannot open session stream")
    end
  end)

  return {
    state = state,
    --- Stop following this session.
    detach = function()
      detached = true
      if stream_id then
        mux.cancel(stream_id)
        stream_id = nil
      end
    end,
  }
end

return M
