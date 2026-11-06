-- Nested `vim.ui` menu specs. No server and no buffers needed.
-- Run with: nvim --headless -l scripts/menu_spec.lua
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h:h")
vim.opt.rtp:append(root)

local config = require("dsh.config")
config.setup({ notifications = false })

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

local function contains(list, needle)
  for _, item in ipairs(list) do
    if item == needle or (type(item) == "string" and item:find(needle, 1, true)) then
      return true
    end
  end
  return false
end

--------------------------------------------------------------------------------
-- Stubs: menu is a pure UI orchestrator over chat/session/rpc.
--------------------------------------------------------------------------------
local chat_state = { current = nil, recent = nil }
local chat_calls = {}
local chat = {
  current = function()
    return chat_state.current
  end,
  recent_view = function()
    return chat_state.recent
  end,
  new_session = function()
    chat_calls.new_session = true
  end,
  pick = function()
    chat_calls.pick = true
  end,
  pick_session = function(callback)
    chat_calls.pick_session = callback
  end,
  open = function(session_id, opts)
    chat_calls.open = { id = session_id, opts = opts }
  end,
  prompt = function(session_id, opts)
    chat_calls.prompt = { id = session_id, opts = opts }
  end,
}
package.loaded["dsh.ui.chat"] = chat
package.loaded["dsh.session"] = {
  title = function(item)
    return item and item.title
  end,
}
package.loaded["dsh.server"] = {
  context = function(callback)
    callback(nil, { url = "http://test", cookie = "cookie" })
  end,
}

local rpc_handlers = {}
local rpc_calls = {}
package.loaded["dsh.http"] = {
  rpc = function(_, endpoint, args)
    rpc_calls[#rpc_calls + 1] = { endpoint = endpoint, args = args }
    local handler = rpc_handlers[endpoint]
    if handler then
      return handler(args)
    end
    return nil, "unexpected rpc " .. endpoint
  end,
}

local notified = {}
local original_notify = vim.notify
vim.notify = function(message)
  notified[#notified + 1] = message
end

local selections = {}
local select_calls = {}
vim.ui.select = function(labels, opts, callback)
  select_calls[#select_calls + 1] = { prompt = opts and opts.prompt, labels = labels }
  local wanted = table.remove(selections, 1)
  if wanted == nil then
    callback(nil)
    return
  end
  for _, label in ipairs(labels) do
    if label == wanted or label:find(wanted, 1, true) then
      callback(label)
      return
    end
  end
  error(("no label matching %q in %s"):format(wanted, vim.inspect(labels)))
end

local inputs = {}
local input_calls = {}
vim.ui.input = function(opts, callback)
  input_calls[#input_calls + 1] = opts
  if #inputs == 0 then
    callback(nil)
    return
  end
  callback(table.remove(inputs, 1))
end

local menu = require("dsh.ui.menu")

local function reset()
  chat_state.current = nil
  chat_state.recent = nil
  chat_calls = {}
  rpc_handlers = {}
  rpc_calls = {}
  notified = {}
  selections = {}
  select_calls = {}
  inputs = {}
  input_calls = {}
end

--------------------------------------------------------------------------------
-- 1. Top-level menu shape and cancellation.
--------------------------------------------------------------------------------
reset()
menu.open()
check("menu uses vim.ui", #select_calls == 1)
check("menu prompt", select_calls[1].prompt == "DSH menu", tostring(select_calls[1].prompt))
check(
  "menu items in order",
  vim.deep_equal(select_calls[1].labels, {
    "0) new session",
    "1) open session…",
    "2) dsh skills…",
    "3) dsh commands…",
  }),
  vim.inspect(select_calls[1].labels)
)
check("cancelling the menu runs nothing", next(chat_calls) == nil)

-- 2. New session.
reset()
selections = { "0) new session" }
menu.open()
check("new session item", chat_calls.new_session == true)

-- 3. Open session picker.
reset()
selections = { "1) open session…" }
menu.open()
check("open session item", chat_calls.pick == true)

--------------------------------------------------------------------------------
-- 4. Skills submenu for the current session.
--------------------------------------------------------------------------------
reset()
chat_state.current = "session-one"
rpc_handlers["skills/list"] = function()
  return {
    skills = {
      { name = "lesson", description = "Save a hard-won rule", modelInvocable = true },
      { name = "recap", description = "Summarize recent sessions" },
    },
  }
end
selections = { "2) dsh skills…", "lesson" }
menu.open()

check("skills submenu shown", select_calls[2] and select_calls[2].prompt == "DSH skills", select_calls[2] and select_calls[2].prompt)
check("skill label has description", select_calls[2] and contains(select_calls[2].labels, "lesson — Save a hard-won rule"))
check("skills rpc uses the current session", rpc_calls[1] and rpc_calls[1].endpoint == "skills/list" and rpc_calls[1].args.request.sessionId == "session-one")
check("choosing a skill opens the prompt", chat_calls.prompt and chat_calls.prompt.id == "session-one")
check(
  "skill prompt is prefilled with the /name gesture",
  chat_calls.prompt and chat_calls.prompt.opts.initial == "/lesson ",
  chat_calls.prompt and vim.inspect(chat_calls.prompt.opts)
)
check("skill prompt names the skill", chat_calls.prompt and chat_calls.prompt.opts.title:find("lesson", 1, true) ~= nil)

-- 5. Skills without a current view pick a session first, then list skills.
reset()
rpc_handlers["skills/list"] = function()
  return { skills = { { name = "recap", description = "Summarize recent sessions" } } }
end
selections = { "2) dsh skills…", "recap" }
menu.open()
check("session picker requested before skills", type(chat_calls.pick_session) == "function")
check("skills wait for the picked session", #select_calls == 1)

chat_calls.pick_session({ sessionId = "session-two", title = "Picked session" })
check(
  "picked session is opened",
  chat_calls.open and chat_calls.open.id == "session-two" and chat_calls.open.opts.title == "Picked session",
  vim.inspect(chat_calls.open)
)
check("skills listed for the picked session", select_calls[2] and select_calls[2].prompt == "DSH skills")
check("skill rpc uses the picked session", rpc_calls[1].args.request.sessionId == "session-two")
check("skill prompt targets the picked session", chat_calls.prompt and chat_calls.prompt.id == "session-two")

-- 5b. A session left open in another tab/window is used without the picker.
reset()
chat_state.current = nil
chat_state.recent = "session-open"
rpc_handlers["skills/list"] = function()
  return { skills = { { name = "lesson", description = "Save a hard-won rule" } } }
end
selections = { "2) dsh skills…", "lesson" }
menu.open()
check("open background session skips the session picker", chat_calls.pick_session == nil)
check("skills listed for the background session", select_calls[2] and select_calls[2].prompt == "DSH skills", select_calls[2] and select_calls[2].prompt)
check("skills rpc uses the background session", rpc_calls[1] and rpc_calls[1].args.request.sessionId == "session-open")
check("skill prompt targets the background session", chat_calls.prompt and chat_calls.prompt.id == "session-open")

-- 5c. Commands use the open background session too.
reset()
chat_state.current = nil
chat_state.recent = "session-open"
rpc_handlers["commands/list"] = function()
  return { { name = "compact", description = "Compact older conversation history" } }
end
rpc_handlers["commands/execute"] = function()
  return { commandId = "cmd-1", result = { kind = "success", text = "done" } }
end
selections = { "3) dsh commands…", "compact" }
menu.open()
check("commands listed for the background session", select_calls[2] and select_calls[2].prompt == "DSH commands", select_calls[2] and select_calls[2].prompt)
check("commands rpc uses the background session", rpc_calls[1] and rpc_calls[1].args.agentId == "session-open")
check("command executed against the background session", rpc_calls[#rpc_calls].args.agentId == "session-open", vim.inspect(rpc_calls[#rpc_calls]))
check("background command still skips the picker", chat_calls.pick_session == nil)

-- 5d. The target session is captured when the menu opens, so a picker whose
-- callback runs after focus moved still lists the catalog instead of asking.
reset()
chat_state.current = "session-one"
rpc_handlers["skills/list"] = function()
  return { skills = { { name = "lesson", description = "Save a hard-won rule" } } }
end
local sync_select = vim.ui.select
vim.ui.select = function(labels, opts, callback)
  select_calls[#select_calls + 1] = { prompt = opts and opts.prompt, labels = labels }
  if opts and opts.prompt == "DSH menu" then
    -- Telescope-style providers dispatch the choice after the picker closed.
    chat_state.current = nil
    callback("2) dsh skills…")
    return
  end
  callback(nil)
end
menu.open()
vim.ui.select = sync_select
check("menu resolves the session before its picker runs", select_calls[2] and select_calls[2].prompt == "DSH skills", select_calls[2] and select_calls[2].prompt)
check("captured session is used for skills", rpc_calls[1] and rpc_calls[1].args.request.sessionId == "session-one")
check("no session picker when the menu captured the session", chat_calls.pick_session == nil)

-- 6. Empty catalogs and RPC errors are reported.
reset()
chat_state.current = "session-one"
rpc_handlers["skills/list"] = function()
  return { skills = {} }
end
selections = { "2) dsh skills…" }
menu.open()
check("empty skill catalog notifies", #notified == 1 and notified[1]:find("no skills", 1, true) ~= nil, vim.inspect(notified))
check("empty skill catalog opens no prompt", chat_calls.prompt == nil)

reset()
chat_state.current = "session-one"
rpc_handlers["skills/list"] = function()
  return nil, "skills unavailable"
end
selections = { "2) dsh skills…" }
menu.open()
check("skill rpc error notifies", #notified == 1 and notified[1]:find("skills unavailable", 1, true) ~= nil, vim.inspect(notified))

-- 7. Commands execute directly, or ask for advertised input first.
reset()
chat_state.current = "session-one"
rpc_handlers["commands/list"] = function()
  return {
    { name = "compact", description = "Compact older conversation history" },
    { name = "feedback", description = "Record feedback about this session", input = { hint = "<text>" } },
  }
end
rpc_handlers["commands/execute"] = function()
  return { commandId = "cmd-1", result = { kind = "success", text = "done" } }
end
selections = { "3) dsh commands…", "compact" }
menu.open()
check("commands submenu shown", select_calls[2] and select_calls[2].prompt == "DSH commands", select_calls[2] and select_calls[2].prompt)
check("command labels include descriptions", select_calls[2] and contains(select_calls[2].labels, "compact — Compact older conversation history"))
check("commands list uses the current session", rpc_calls[1].endpoint == "commands/list" and rpc_calls[1].args.agentId == "session-one")
local execute = rpc_calls[#rpc_calls]
check("command executed without input", execute.endpoint == "commands/execute" and execute.args.line == "/compact", vim.inspect(execute))
check("command result notified", contains(notified, "done"), vim.inspect(notified))

reset()
chat_state.current = "session-one"
rpc_handlers["commands/list"] = function()
  return { { name = "feedback", description = "Record feedback", input = { hint = "<text>" } } }
end
rpc_handlers["commands/execute"] = function()
  return { commandId = "cmd-2", result = { kind = "success", text = "recorded" } }
end
inputs = { "great session" }
selections = { "3) dsh commands…", "feedback" }
menu.open()
check("command input prompt shows the hint", #input_calls == 1 and input_calls[1].prompt:find("<text>", 1, true) ~= nil, vim.inspect(input_calls))
check("command executed with typed input", rpc_calls[#rpc_calls].args.line == "/feedback great session", vim.inspect(rpc_calls[#rpc_calls]))

reset()
chat_state.current = "session-one"
rpc_handlers["commands/list"] = function()
  return { { name = "feedback", description = "Record feedback", input = { hint = "<text>" } } }
end
selections = { "3) dsh commands…", "feedback" }
menu.open()
check("cancelled command input runs nothing", #rpc_calls == 1, tostring(#rpc_calls))
check("cancelled command input says nothing", #notified == 0, vim.inspect(notified))

-- 8. Empty command catalog and unknown execution results.
reset()
chat_state.current = "session-one"
rpc_handlers["commands/list"] = function()
  return {}
end
selections = { "3) dsh commands…" }
menu.open()
check("empty command catalog notifies", #notified == 1 and notified[1]:find("no commands", 1, true) ~= nil, vim.inspect(notified))

reset()
chat_state.current = "session-one"
rpc_handlers["commands/list"] = function()
  return { { name = "ghost", description = "Not really there" } }
end
rpc_handlers["commands/execute"] = function()
  return nil
end
selections = { "3) dsh commands…", "ghost" }
menu.open()
check("unknown command result notifies", #notified == 1 and notified[1]:find("not recognized", 1, true) ~= nil, vim.inspect(notified))

-- 9. Cancelling a nested menu does nothing further.
reset()
chat_state.current = "session-one"
rpc_handlers["skills/list"] = function()
  return { skills = { { name = "lesson", description = "Save a hard-won rule" } } }
end
selections = { "2) dsh skills…" }
menu.open()
check("cancelling the skill list opens no prompt", chat_calls.prompt == nil)
check("cancelling the skill list sends no prompt", #rpc_calls == 1)

vim.notify = original_notify

print(("\n=== %d checks, %d failed ==="):format(checks, failures))
vim.cmd("cquit " .. (failures > 0 and 1 or 0))
