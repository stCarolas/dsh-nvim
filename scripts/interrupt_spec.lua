-- Interrupt command specs: :DshInterrupt resolves the session in view (or the
-- most recently used view) and asks DSH to stop its running turn.
-- Run with: nvim --headless -l scripts/interrupt_spec.lua
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h:h")
vim.opt.rtp:append(root)

local config = require("dsh.config")
config.setup({ notifications = false, treesitter = false, chat = { open_in = "split", split = "vertical" } })

local checks = 0
local failures = 0

local function check(name, condition, detail)
  checks = checks + 1
  if not condition then
    failures = failures + 1
    print(("FAIL %s%s"):format(name, detail and (" — " .. detail) or ""))
  else
    print("PASS " .. name)
  end
end

--------------------------------------------------------------------------------
-- Stubs: transports only; the view orchestration and command wiring are real.
--------------------------------------------------------------------------------
local context = { url = "http://test", cookie = "cookie" }
package.loaded["dsh.server"] = {
  context = function(callback)
    callback(nil, context)
  end,
  describe = function()
    return { running = false }
  end,
  is_running = function()
    return true
  end,
  start = function() end,
  stop = function() end,
  mint_cookie = function()
    return "minted"
  end,
}
package.loaded["dsh.follow"] = {
  attach = function()
    return { detach = function() end, state = {} }
  end,
}
package.loaded["dsh.mux"] = {
  is_connected = function()
    return false
  end,
  acquire = function(_, callback)
    callback(nil)
  end,
  stream = function()
    return nil
  end,
  cancel = function() end,
  close = function() end,
  credential = function()
    return nil
  end,
  on_close = function()
    return function() end
  end,
}

local rpc_calls = {}
local handlers = {}
package.loaded["dsh.http"] = {
  rpc = function(_, endpoint, args)
    rpc_calls[#rpc_calls + 1] = { endpoint = endpoint, args = args }
    local handler = handlers[endpoint]
    if type(handler) == "function" then
      return handler(args)
    end
    return nil, "no stub for " .. endpoint
  end,
}

local notified = {}
vim.notify = function(message, level)
  notified[#notified + 1] = { message = message, level = level }
end

local chat = require("dsh.ui.chat")

local function reset()
  rpc_calls = {}
  notified = {}
end

local function cancels()
  local found = {}
  for _, call in ipairs(rpc_calls) do
    if call.endpoint == "session/cancel" then
      found[#found + 1] = call
    end
  end
  return found
end

local function notification_contains(needle)
  for _, entry in ipairs(notified) do
    if tostring(entry.message):find(needle, 1, true) then
      return true
    end
  end
  return false
end

--------------------------------------------------------------------------------
-- 1. Both commands are registered; :DshInterrupt is the announcing form.
--------------------------------------------------------------------------------
vim.cmd("runtime plugin/dsh.lua")
check("DshInterrupt command is registered", vim.fn.exists(":DshInterrupt") == 2)
check("DshCancel command is still registered", vim.fn.exists(":DshCancel") == 2)

handlers["session/cancel"] = function()
  return { accepted = true }
end

local sid = "session-11111111-2222-3333-4444-555555555555"
local other = "session-99999999-8888-7777-6666-555555555555"

--------------------------------------------------------------------------------
-- 2. From the session buffer itself: the view under the cursor wins.
--------------------------------------------------------------------------------
chat.open(sid, { title = "Interrupt me" })
check("session view opened", vim.bo[vim.api.nvim_get_current_buf()].filetype == "dshchat")

reset()
vim.cmd("DshInterrupt")
local calls = cancels()
check(
  "DshInterrupt cancels the session in view",
  #calls == 1 and calls[1].args.request.sessionId == sid,
  vim.inspect(rpc_calls)
)
check("cancel uses the session/cancel endpoint", #calls == 1 and calls[1].endpoint == "session/cancel")
check(
  "accepted interrupt is reported with the title",
  notification_contains("interrupt requested: Interrupt me"),
  vim.inspect(notified)
)

--------------------------------------------------------------------------------
-- 3. From another buffer, the most recently used open view is interrupted.
--------------------------------------------------------------------------------
chat.open(other, { title = "Second session" })
vim.cmd("enew")
check("left the session buffer", chat.current() == nil)

reset()
vim.cmd("DshCancel")
calls = cancels()
check(
  "DshCancel resolves the most recently viewed session",
  #calls == 1 and calls[1].args.request.sessionId == other,
  vim.inspect(rpc_calls)
)
check("DshCancel stays quiet on success", not notification_contains("interrupt requested"), vim.inspect(notified))

reset()
vim.cmd("DshInterrupt")
calls = cancels()
check(
  "DshInterrupt resolves the most recently viewed session",
  #calls == 1 and calls[1].args.request.sessionId == other,
  vim.inspect(rpc_calls)
)
check(
  "the fallback target is named in the notice",
  notification_contains("interrupt requested: Second session"),
  vim.inspect(notified)
)

--------------------------------------------------------------------------------
-- 4. No open view: warn instead of guessing or calling DSH.
--------------------------------------------------------------------------------
chat.close(other)
chat.close(sid)
reset()
vim.cmd("DshInterrupt")
check("does not call DSH without an open view", #cancels() == 0, vim.inspect(rpc_calls))
check("warns that no session is open", notification_contains("no open DSH session"), vim.inspect(notified))

--------------------------------------------------------------------------------
-- 5. Rejections: an idle (not attached) session is reported as not running,
--    while other errors keep DSH's message.
--------------------------------------------------------------------------------
handlers["session/cancel"] = function()
  return nil, "session/not-found: session not found (not attached)", "session/not-found"
end
chat.open(sid, { title = "Rejected" })
reset()
vim.cmd("DshInterrupt")
check("an unattached session is reported as not running", notification_contains("session is not running"), vim.inspect(notified))
check(
  "an unattached session is not announced as accepted",
  not notification_contains("interrupt requested"),
  vim.inspect(notified)
)

handlers["session/cancel"] = function()
  return nil, "gateway/service-unavailable: service unavailable", "gateway/service-unavailable"
end
reset()
vim.cmd("DshInterrupt")
check("other failures keep the DSH error", notification_contains("gateway/service-unavailable"), vim.inspect(notified))

--------------------------------------------------------------------------------
-- 6. keymaps.global.interrupt installs a mapping to the same action.
--------------------------------------------------------------------------------
handlers["session/cancel"] = function()
  return { accepted = true }
end
local dsh = require("dsh")
dsh.setup({
  notifications = false,
  treesitter = false,
  chat = { open_in = "split", split = "vertical" },
  keymaps = { global = { interrupt = "<F12>" } },
})
check("global interrupt mapping is installed", vim.fn.maparg("<F12>", "n") ~= "", vim.inspect(vim.fn.maparg("<F12>", "n")))

reset()
local mapping = vim.fn.maparg("<F12>", "n", false, true)
check("mapping carries a Lua callback", type(mapping) == "table" and type(mapping.callback) == "function", vim.inspect(mapping))
mapping.callback()
calls = cancels()
check(
  "the global mapping interrupts the session in view",
  #calls == 1 and calls[1].args.request.sessionId == sid,
  vim.inspect(rpc_calls)
)

print(("\n=== %d checks, %d failed ==="):format(checks, failures))
vim.cmd("cquit " .. (failures > 0 and 1 or 0))
