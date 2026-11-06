-- Session deletion (DSH archive) specs: RPC shape, archive visibility, the
-- confirmation flow, and picker filtering.
-- Run with: nvim --headless -l scripts/delete_spec.lua
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h:h")
vim.opt.rtp:append(root)

local config = require("dsh.config")
config.setup({ notifications = false, chat = { open_in = "split", split = "vertical" } })

local failures = 0
local checks = 0

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
-- Stubs: transports and pickers only; the view orchestration is real.
--------------------------------------------------------------------------------
local context = { url = "http://test", cookie = "cookie", mint = function() return "minted" end }
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

local mux_state = { connected = false, streams = {} }
package.loaded["dsh.mux"] = {
  is_connected = function()
    return mux_state.connected
  end,
  acquire = function(_, callback)
    callback(nil)
  end,
  stream = function(endpoint, _, handlers)
    mux_state.streams[endpoint] = handlers
    return "stream-" .. endpoint
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
vim.notify = function(message)
  notified[#notified + 1] = message
end

local selections = {}
local selects = {}
vim.ui.select = function(labels, opts, callback)
  selects[#selects + 1] = { prompt = opts and opts.prompt, labels = labels }
  local wanted = table.remove(selections, 1)
  if wanted == nil then
    callback(nil)
    return
  end
  for _, label in ipairs(labels) do
    if label == wanted then
      callback(label)
      return
    end
  end
  error(("no label %q in %s"):format(wanted, vim.inspect(labels)))
end

local archive = require("dsh.archive")
local workspace = require("dsh.workspace")
local chat = require("dsh.ui.chat")

local function reset()
  rpc_calls = {}
  notified = {}
  selects = {}
  selections = {}
end

--------------------------------------------------------------------------------
-- 1. Archive RPC shape: DSH's session "delete" is workspace/archiveSession.
--------------------------------------------------------------------------------
reset()
handlers["workspace/archiveSession"] = function()
  return { archivedSessionIds = { "session-a" } }
end
local deleted = workspace.archive_session(context, "session-a", true)
check("archive returns the server value", deleted ~= nil)
check("archive calls workspace/archiveSession", rpc_calls[1] and rpc_calls[1].endpoint == "workspace/archiveSession")
check(
  "archive names the session and stops work",
  rpc_calls[1] and rpc_calls[1].args.request.sessionId == "session-a" and rpc_calls[1].args.request.stopActivity == true,
  vim.inspect(rpc_calls[1] and rpc_calls[1].args)
)

--------------------------------------------------------------------------------
-- 2. Archive visibility follows the workspace/follow stream.
--------------------------------------------------------------------------------
reset()
mux_state.connected = true
archive.begin(context)
local follow_handlers = mux_state.streams["workspace/follow"]
check("workspace archive stream opened", follow_handlers ~= nil)
if follow_handlers then
  follow_handlers.on_item({ type = "baseline", value = { archivedSessionIds = { "archived-1" } } })
  check("baseline hides archived sessions", archive.is_hidden("archived-1") == true)
  check("baseline marks the archive set ready", archive.is_ready() == true)
  follow_handlers.on_item({ type = "archived", archivedSessionIds = {} })
  check("archive increment updates visibility", archive.is_hidden("archived-1") == false)
end

--------------------------------------------------------------------------------
-- 3. Deleting the current view: confirm, archive, close, hide.
--------------------------------------------------------------------------------
reset()
handlers["workspace/archiveSession"] = function()
  return { archivedSessionIds = { "session-del" } }
end
chat.open("session-del", { title = "Delete me" })
local delete_buf = vim.api.nvim_get_current_buf()
local delete_win = vim.api.nvim_get_current_win()

selections = { "Delete session" }
chat.delete()
check("delete asks for confirmation", selects[1] ~= nil and selects[1].prompt:find("Delete me", 1, true) ~= nil, selects[1] and selects[1].prompt)
check(
  "delete archives through the workspace RPC",
  rpc_calls[1] and rpc_calls[1].endpoint == "workspace/archiveSession"
    and rpc_calls[1].args.request.sessionId == "session-del"
    and rpc_calls[1].args.request.stopActivity == true,
  vim.inspect(rpc_calls[1] and rpc_calls[1].args)
)
check("delete closes the view window", not vim.api.nvim_win_is_valid(delete_win))
check("delete wipes the view buffer", not vim.api.nvim_buf_is_valid(delete_buf))
check("delete hides the session from pickers", archive.is_hidden("session-del") == true)
check("delete reports success", notified[1] ~= nil and notified[1]:find("deleted session", 1, true) ~= nil, vim.inspect(notified))

--------------------------------------------------------------------------------
-- 4. Cancelling the confirmation changes nothing.
--------------------------------------------------------------------------------
reset()
handlers["workspace/archiveSession"] = function()
  return { archivedSessionIds = {} }
end
chat.open("session-keep", { title = "Keep me" })
local keep_win = vim.api.nvim_get_current_win()
selections = { "Cancel" }
chat.delete()
check("cancel sends no archive RPC", #rpc_calls == 0, vim.inspect(rpc_calls))
check("cancel keeps the view", vim.api.nvim_win_is_valid(keep_win))
chat.close()

--------------------------------------------------------------------------------
-- 5. `skip_confirm` (the bang) deletes without a prompt.
--------------------------------------------------------------------------------
reset()
handlers["workspace/archiveSession"] = function()
  return { archivedSessionIds = {} }
end
chat.open("session-bang", { title = "Bang" })
local bang_buf = vim.api.nvim_get_current_buf()
local prompt_calls = #selects
chat.delete(nil, { skip_confirm = true })
check("bang skips the confirmation prompt", #selects == prompt_calls)
check("bang still archives", rpc_calls[1] and rpc_calls[1].args.request.sessionId == "session-bang")
check("bang closes the view", not vim.api.nvim_buf_is_valid(bang_buf))

--------------------------------------------------------------------------------
-- 6. Server failure keeps the view and reports the error.
--------------------------------------------------------------------------------
reset()
handlers["workspace/archiveSession"] = function()
  return nil, "workspace/session-not-found: gone"
end
chat.open("session-missing", { title = "Missing" })
local missing_win = vim.api.nvim_get_current_win()
selections = { "Delete session" }
chat.delete()
check(
  "failed delete reports the server error",
  notified[1] ~= nil and notified[1]:find("session-not-found", 1, true) ~= nil,
  vim.inspect(notified)
)
check("failed delete keeps the view", vim.api.nvim_win_is_valid(missing_win))
chat.close()

--------------------------------------------------------------------------------
-- 7. Pickers omit deleted sessions; `include_archived` restores server archives.
--------------------------------------------------------------------------------
reset()
config.setup({ notifications = false, sessions = { scope = "all", include_archived = false } })
handlers["session/list"] = function()
  return {
    items = {
      { sessionId = "session-del", updatedAt = 3, cwd = vim.fn.getcwd(), projections = { values = { title = "Deleted" } } },
      { sessionId = "session-live", updatedAt = 2, cwd = vim.fn.getcwd(), projections = { values = { title = "Live" } } },
    },
  }
end
chat.pick_session(function() end)
local labels = selects[#selects] and selects[#selects].labels or {}
local joined = table.concat(labels, "\n")
check("deleted session is absent from the picker", not joined:find("Deleted", 1, true), joined)
check("live session stays in the picker", joined:find("Live", 1, true) ~= nil, joined)

-- Server archives stay hidden by default, but `include_archived = true`
-- brings them back; sessions deleted here stay hidden either way.
local archive_stream = mux_state.streams["workspace/follow"]
if archive_stream then
  archive_stream.on_item({ type = "baseline", value = { archivedSessionIds = { "session-archived" } } })
end
handlers["session/list"] = function()
  return {
    items = {
      { sessionId = "session-del", updatedAt = 3, cwd = vim.fn.getcwd(), projections = { values = { title = "Deleted" } } },
      { sessionId = "session-archived", updatedAt = 2, cwd = vim.fn.getcwd(), projections = { values = { title = "Archived" } } },
      { sessionId = "session-live", updatedAt = 1, cwd = vim.fn.getcwd(), projections = { values = { title = "Live" } } },
    },
  }
end

chat.pick_session(function() end)
local default_labels = table.concat(selects[#selects] and selects[#selects].labels or {}, "\n")
check("server-archived session is hidden by default", not default_labels:find("Archived", 1, true), default_labels)

reset()
config.setup({ notifications = false, sessions = { scope = "all", include_archived = true } })
chat.pick_session(function() end)
local all_labels = table.concat(selects[#selects] and selects[#selects].labels or {}, "\n")
check("include_archived shows server archives", all_labels:find("Archived", 1, true) ~= nil, all_labels)
check("locally deleted sessions stay hidden", not all_labels:find("Deleted", 1, true), all_labels)

--------------------------------------------------------------------------------
-- 8. The user command is registered and its bang skips the prompt.
--------------------------------------------------------------------------------
reset()
vim.cmd("runtime plugin/dsh.lua")
check("DshDelete command is registered", vim.fn.exists(":DshDelete") == 2)
handlers["workspace/archiveSession"] = function()
  return { archivedSessionIds = { "session-cmd" } }
end
chat.open("session-cmd", { title = "Command" })
local command_buf = vim.api.nvim_get_current_buf()
vim.cmd("DshDelete!")
check(
  "DshDelete! archives without prompting",
  rpc_calls[1] and rpc_calls[1].args.request.sessionId == "session-cmd",
  vim.inspect(rpc_calls[1] and rpc_calls[1].args)
)
check("DshDelete! closes the view", not vim.api.nvim_buf_is_valid(command_buf))

print(("\n=== %d checks, %d failed ==="):format(checks, failures))
vim.cmd("cquit " .. (failures > 0 and 1 or 0))
