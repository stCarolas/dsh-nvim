-- WebSocket transport test: handshake, follow stream, live events, heartbeat, multiplexing.
-- Run with: nvim --headless -l scripts/ws_spec.lua
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h:h")
vim.opt.rtp:append(root)

require("dsh").setup({
  notifications = false,
  startup_timeout = 180000,
  request_timeout = 60000,
})

local server = require("dsh.server")
local mux = require("dsh.mux")
local session = require("dsh.session")
local ws = require("dsh.ws")

local steps = {}
local failed = 0

local function step(name, ok, detail)
  steps[#steps + 1] = { name = name, ok = ok, detail = detail or "" }
  if not ok then
    failed = failed + 1
  end
end

local function report()
  print("\n=== websocket results ===")
  for _, entry in ipairs(steps) do
    print(("%s %-34s %s"):format(entry.ok and "PASS" or "FAIL", entry.name, entry.detail))
  end
  print(("=== %d failed ==="):format(failed))
  vim.cmd("cquit " .. (failed > 0 and 1 or 0))
end

-- Unit checks that need no server.
step("base64 encode", ws.base64("Man") == "TWFu", ws.base64("Man"))
step("base64 padding", ws.base64("Ma") == "TWE=", ws.base64("Ma"))
step("split_url", select(1, ws.split_url("http://127.0.0.1:3080")) == "127.0.0.1")

local frame = ws.encode_frame(ws.OPCODE.text, "hello")
step("client frame is masked", bit.band(frame:byte(2), 0x80) ~= 0)
step("client frame opcode", bit.band(frame:byte(1), 0x0F) == 1)

local decoder = ws.Parser.new(function(fin, opcode, payload)
  step("parser reads server frame", fin and opcode == ws.OPCODE.text and payload == "world", payload)
end)
-- Unmasked server frame: FIN|text, length 5, payload.
decoder:feed(string.char(0x81, 5) .. "world")

local done = false

server.start(function(started, start_err)
  step("server start", started, start_err or server.describe().url)
  if not started then
    done = true
    return
  end

  server.context(function(ctx_err, ctx)
    step("connection context", ctx_err == nil, ctx_err or ctx.url)
    if ctx_err then
      done = true
      return
    end

    mux.acquire(ctx, function(mux_err)
      step("websocket handshake", mux_err == nil, mux_err or "101 switching protocols")
      if mux_err then
        done = true
        return
      end
      step("mux reports connected", mux.is_connected())

      local created, create_err = session.create(ctx, vim.fn.getcwd())
      step("session created over HTTP", created ~= nil, create_err or (created and created.sessionId))
      if not created then
        done = true
        return
      end
      local session_id = created.sessionId

      local saw_snapshot = false
      local saw_user = false
      local saw_turn_end = false
      local saw_stream_chunk = false
      local stream_errors = {}

      local stream_id = mux.stream("session/follow", {
        request = {
          address = { kind = "session", sessionId = session_id },
          assistantStream = true,
          maxMessages = 100,
        },
      }, {
        on_item = function(value)
          if type(value) ~= "table" then
            return
          end
          if value.type == "snapshot" then
            saw_snapshot = type(value.cursor) == "number"
          elseif value.type == "assistant-stream" then
            local frame = value.frame or {}
            local chunk = frame.chunk or {}
            if frame.type == "chunk" and chunk.type == "text-delta" and type(chunk.text) == "string" then
              saw_stream_chunk = true
            end
          elseif value.type == "event" then
            local event = value.event or {}
            if event.type == "user/message" then
              local data = event.data or {}
              if type(data.source) == "table" and data.source.kind == "user" then
                saw_user = true
              end
            elseif event.type == "turn/end" then
              saw_turn_end = true
            end
          end
        end,
        on_end = function()
          stream_errors[#stream_errors + 1] = "stream ended"
        end,
        on_error = function(message)
          stream_errors[#stream_errors + 1] = message
        end,
      })

      step("stream opened", stream_id ~= nil, tostring(stream_id))
      vim.wait(15000, function()
        return saw_snapshot
      end, 50)
      step("snapshot received", saw_snapshot)

      local accepted, prompt_err = session.prompt(ctx, session_id, "ws smoke: reply with OK")
      step("prompt accepted over HTTP", accepted ~= nil, prompt_err or "accepted")

      vim.wait(60000, function()
        return saw_user and saw_turn_end
      end, 100)
      step("user message arrived as a live event", saw_user)
      step("turn/end arrived as a live event", saw_turn_end)
      step("assistant text streamed as chunks", saw_stream_chunk)
      step("no stream errors", #stream_errors == 0, table.concat(stream_errors, "; "))

      -- The server pings every 2s and terminates peers that miss two pongs.
      vim.wait(9000, function()
        return false
      end, 500)
      step("socket survives heartbeats", mux.is_connected())

      -- A second logical stream on the same socket proves multiplexing.
      local second_snapshot = false
      mux.stream("session/follow", {
        request = {
          address = { kind = "session", sessionId = session_id },
          maxMessages = 10,
        },
      }, {
        on_item = function(value)
          if type(value) == "table" and value.type == "snapshot" then
            second_snapshot = true
          end
        end,
      })
      vim.wait(15000, function()
        return second_snapshot
      end, 50)
      step("second stream multiplexed", second_snapshot)

      -- Re-acquire after an explicit close must mint a fresh socket and stream.
      mux.close()
      local reacquired, reacquire_err = nil, nil
      mux.acquire(ctx, function(err)
        reacquired = err == nil
        reacquire_err = err
      end)
      vim.wait(15000, function()
        return reacquired ~= nil
      end, 50)
      step("re-acquire after close", reacquired == true, reacquire_err)

      local reopened_snapshot = false
      if reacquired then
        mux.stream("session/follow", {
          request = {
            address = { kind = "session", sessionId = session_id },
            maxMessages = 10,
          },
        }, {
          on_item = function(value)
            if type(value) == "table" and value.type == "snapshot" then
              reopened_snapshot = true
            end
          end,
        })
        vim.wait(15000, function()
          return reopened_snapshot
        end, 50)
      end
      step("stream works after reconnect", reopened_snapshot)

      mux.close()
      vim.wait(1000, function()
        return not mux.is_connected()
      end, 50)
      step("socket closed", not mux.is_connected())

      -- The socket's peer is disposed on close; the long-lived HTTP peer must survive.
      local after_items, after_err = session.list(ctx)
      step("HTTP survives socket close", after_items ~= nil, after_err or ("%d sessions"):format(after_items and #after_items or 0))
      done = true
    end)
  end)
end)

if not vim.wait(300000, function()
  return done
end, 200) then
  step("overall", false, "timed out")
end

mux.close()
server.stop()
report()
