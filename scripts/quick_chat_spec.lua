-- :DshQuickChat specs: Agent mode at creation, the nested split layout, the
-- Visual selection prefill, and the fallbacks (unknown mode, no selection).
-- Run with: nvim --headless -l scripts/quick_chat_spec.lua
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
-- Stubs: transports only; window layout, prefilling and orchestration are real.
--------------------------------------------------------------------------------
local context = { url = "http://test", cookie = "cookie", mint = function()
  return "minted"
end }
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
  is_starting = function()
    return false
  end,
  is_alive = function()
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
vim.notify = function(message)
  notified[#notified + 1] = message
end

local session_seq = 0
local created_ids = {}
local function mint_session(preset)
  session_seq = session_seq + 1
  local session_id = ("session-%08d-0000-0000-0000-000000000000"):format(session_seq)
  created_ids[#created_ids + 1] = session_id
  return { sessionId = session_id, agentPreset = preset }
end

handlers["workspace/create"] = function(args)
  return { workspace = { workspaceId = "ws-1", path = args.request.path } }
end
handlers["session/create"] = function(args)
  return mint_session(args.request.agentPreset)
end
handlers["session/prompt"] = function()
  return { accepted = true }
end

local chat = require("dsh.ui.chat")
local quick = require("dsh.ui.quick_chat")
local session = require("dsh.session")
local dsh = require("dsh")

vim.cmd("runtime plugin/dsh.lua")
check(":DshQuickChat is registered", vim.fn.exists(":DshQuickChat") == 2)
local command = vim.api.nvim_get_commands({}).DshQuickChat
check(":DshQuickChat takes an optional mode and a range", command ~= nil and command.nargs == "?" and command.range == ".", vim.inspect(command))

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------
local function window_showing(filetype)
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local buf = vim.api.nvim_win_get_buf(win)
    if vim.bo[buf].filetype == filetype then
      return win, buf
    end
  end
  return nil, nil
end

--- Run `:DshQuickChat` and wait for the prompt window it schedules.
--- @return boolean opened
local function quick_chat(command)
  local before = #vim.api.nvim_list_wins()
  vim.cmd(command or "DshQuickChat")
  local opened = vim.wait(2000, function()
    return #vim.api.nvim_list_wins() > before and window_showing("dsh-prompt") ~= nil
  end, 20)
  -- The prompt starts insert mode; headless Neovim reports normal mode anyway,
  -- but every later `vim.cmd` expects a settled editor.
  pcall(vim.cmd, "stopinsert")
  return opened and true or false
end

local function prompt_text()
  local _, buf = window_showing("dsh-prompt")
  if not buf then
    return nil
  end
  return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
end

--- Drop every window, buffer and RPC record left by one scenario.
local function reset()
  pcall(vim.cmd, "stopinsert")
  pcall(vim.cmd, "silent! enew")
  pcall(vim.cmd, "silent! tabonly")
  pcall(vim.cmd, "silent! only")
  vim.wait(20, function()
    return false
  end)
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    local name = vim.api.nvim_buf_get_name(buf)
    if vim.api.nvim_buf_is_valid(buf) and name:find("dsh://", 1, true) == 1 then
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end
  end
  vim.wait(20, function()
    return false
  end)
  rpc_calls = {}
  notified = {}
end

local function rpc(endpoint, index)
  local seen = 0
  for _, call in ipairs(rpc_calls) do
    if call.endpoint == endpoint then
      seen = seen + 1
      if seen == (index or 1) then
        return call
      end
    end
  end
  return nil
end

--- A buffer with a name and a filetype, like a real source file.
local function source_buffer(lines, name)
  vim.cmd("silent! enew")
  local buf = vim.api.nvim_get_current_buf()
  if name then
    pcall(vim.api.nvim_buf_set_name, buf, name)
  end
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].filetype = "lua"
  return buf
end

--- Leave Visual mode, so the marks are set the way `:` from Visual mode sets them.
local function leave_visual()
  vim.cmd("normal! \27")
end

--------------------------------------------------------------------------------
-- 1. One command: mode at creation, session view split, prompt split beside it.
--------------------------------------------------------------------------------
reset()
local origin_win = vim.api.nvim_get_current_win()
local origin_height = vim.api.nvim_win_get_height(origin_win)
local columns = vim.o.columns

check("quick chat opens the prompt", quick_chat())
local chat_win, chat_buf = window_showing("dshchat")
local prompt_win, prompt_buf = window_showing("dsh-prompt")
local chat_pos = chat_win and vim.api.nvim_win_get_position(chat_win)
local prompt_pos = prompt_win and vim.api.nvim_win_get_position(prompt_win)
local origin_pos = vim.api.nvim_win_get_position(origin_win)

check("a session view opened", chat_win ~= nil and chat_buf ~= nil)
check("a prompt window opened", prompt_win ~= nil and prompt_buf ~= nil)
check("the session view keeps the code window above it", chat_pos[1] > origin_pos[1], vim.inspect({ origin_pos, chat_pos }))
check(
  "the session view is a horizontal split",
  vim.api.nvim_win_get_height(origin_win) < origin_height,
  ("%d -> %d"):format(origin_height, vim.api.nvim_win_get_height(origin_win))
)
check(
  "the session view and prompt span the editor width",
  vim.api.nvim_win_get_width(chat_win) + vim.api.nvim_win_get_width(prompt_win) + 1 == columns,
  ("%d + %d + 1 vs %d"):format(vim.api.nvim_win_get_width(chat_win), vim.api.nvim_win_get_width(prompt_win), columns)
)
check(
  "the prompt is a vertical split of the session view",
  prompt_pos[1] == chat_pos[1] and prompt_pos[2] > chat_pos[2],
  vim.inspect({ chat_pos, prompt_pos })
)
check(
  "the prompt shares the session view's band",
  vim.api.nvim_win_get_height(prompt_win) == vim.api.nvim_win_get_height(chat_win),
  ("%d vs %d"):format(vim.api.nvim_win_get_height(prompt_win), vim.api.nvim_win_get_height(chat_win))
)
check("the prompt has the focus", vim.api.nvim_get_current_win() == prompt_win)
check("the prompt is a dsh-prompt buffer", vim.bo[prompt_buf].filetype == "dsh-prompt")
check("the prompt starts empty without a selection", vim.trim(prompt_text() or "x") == "", vim.inspect(prompt_text()))

local created = rpc("session/create")
check("the session was created in the workspace", created ~= nil and created.args.request.workspaceId == "ws-1", vim.inspect(created and created.args))
check(
  "the session composes quick_chat.mode",
  created ~= nil and created.args.request.agentPreset == "chat",
  vim.inspect(created and created.args)
)

--------------------------------------------------------------------------------
-- 2. Submitting the prompt sends it to that session and returns to the view.
--------------------------------------------------------------------------------
check("no prompt was sent yet", rpc("session/prompt") == nil)
vim.api.nvim_buf_set_lines(prompt_buf, 0, -1, false, { "what does this do?" })
vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<C-s>", true, false, true), "x", false)
vim.wait(2000, function()
  return not vim.api.nvim_win_is_valid(prompt_win)
end, 20)
local sent = rpc("session/prompt")
check("submitting closes the prompt", not vim.api.nvim_win_is_valid(prompt_win))
check("submitting returns to the session view", vim.api.nvim_get_current_win() == chat_win)
check("submitting sends the prompt text", sent ~= nil and sent.args.request.content[1].text == "what does this do?", vim.inspect(sent and sent.args))
check(
  "the prompt belongs to the new session",
  sent ~= nil and sent.args.request.sessionId == created_ids[#created_ids],
  vim.inspect({ sent and sent.args.request.sessionId, created_ids[#created_ids] })
)

--------------------------------------------------------------------------------
-- 3. A Visual selection is copied into the prompt, named and fenced.
--------------------------------------------------------------------------------
reset()
local sample = vim.fn.tempname() .. "-sample.lua"
source_buffer({ "local one = 1", "local two = 2", "local three = 3" }, sample)
vim.cmd("normal! 2GVj")
leave_visual()
check("the linewise marks are set", vim.fn.getpos("'<")[2] == 2 and vim.fn.getpos("'>")[2] == 3, vim.inspect({ vim.fn.getpos("'<"), vim.fn.getpos("'>") }))

check("quick chat opens the prompt", quick_chat())
local prefilled = prompt_text()
local prefilled_lines = prefilled and vim.split(prefilled, "\n", { plain = true }) or {}
check("the prefill names the file and the lines", prefilled ~= nil and prefilled:find("sample.lua (lines 2-3):", 1, true) ~= nil, vim.inspect(prefilled))
check("the prefill fences the filetype", prefilled_lines[2] == "```lua", vim.inspect(prefilled_lines))
check(
  "the prefill carries the selected lines",
  prefilled_lines[3] == "local two = 2" and prefilled_lines[4] == "local three = 3",
  vim.inspect(prefilled_lines)
)
check("the prefill closes the fence", prefilled_lines[5] == "```", vim.inspect(prefilled_lines))
check(
  "the cursor sits after the prefill",
  vim.api.nvim_win_get_cursor(0)[1] == #prefilled_lines,
  vim.inspect({ vim.api.nvim_win_get_cursor(0), #prefilled_lines })
)

--------------------------------------------------------------------------------
-- 4. `:'<,'>DshQuickChat` (pressing `:` in Visual mode) sees the same marks.
--------------------------------------------------------------------------------
reset()
source_buffer({ "a", "b", "c" })
vim.cmd("normal! 2GV")
leave_visual()
check("quick chat opens the prompt", quick_chat("'<,'>DshQuickChat"))
local ranged = prompt_text() or ""
check("the range form still prefills the selection", ranged:find("```lua\nb\n```", 1, true) ~= nil, vim.inspect(ranged))
check("an unnamed buffer has no file reference", ranged:find("lines 2-2:", 1, true) ~= nil, vim.inspect(ranged))

--------------------------------------------------------------------------------
-- 5. A mode the deployment does not publish falls back to its default.
--------------------------------------------------------------------------------
reset()
local real_create = handlers["session/create"]
local attempts = {}
handlers["session/create"] = function(args)
  attempts[#attempts + 1] = vim.deepcopy(args.request)
  if args.request.agentPreset == "chat" then
    return nil,
      "agent-preset/not-found: Unknown agent preset: chat",
      "agent-preset/not-found",
      { agentPreset = "chat", available = { "standard", "ptc", "minimal", "cordis" } }
  end
  return mint_session(args.request.agentPreset)
end

check("quick chat opens the prompt despite the unknown mode", quick_chat())
check("the requested mode is tried first", attempts[1] ~= nil and attempts[1].agentPreset == "chat", vim.inspect(attempts[1]))
check(
  "creation is retried without the mode",
  attempts[2] ~= nil and attempts[2].agentPreset == nil and attempts[2].workspaceId == "ws-1",
  vim.inspect(attempts[2])
)
local warning = table.concat(notified, "\n")
check("the fallback warns about the mode", warning:find('agent mode "chat" is not available', 1, true) ~= nil, warning)
check("the warning lists the published modes", warning:find("standard, ptc, minimal, cordis", 1, true) ~= nil, warning)
check("the chat still opens", window_showing("dshchat") ~= nil and window_showing("dsh-prompt") ~= nil)
handlers["session/create"] = real_create

-- 5b. The preset fallback composes with the workspace fallback: the session
-- still lands on a plain `cwd` session and both notices are reported.
reset()
local fallback_calls = {}
local real_create_handler = handlers["session/create"]
handlers["session/create"] = function(args)
  fallback_calls[#fallback_calls + 1] = vim.deepcopy(args.request)
  if args.request.agentPreset == "chat" then
    return nil, "agent-preset/not-found: Unknown agent preset: chat", "agent-preset/not-found", { available = { "standard" } }
  end
  if args.request.workspaceId then
    return nil, "workspace/not-found: no workspace", "workspace/not-found"
  end
  return mint_session(nil)
end
local fell_back, fallback_err, fallback_warning = session.create_in_workspace(context, vim.fn.getcwd(), { agentPreset = "chat" })
handlers["session/create"] = real_create_handler
check("the fallbacks still create a session", fell_back ~= nil, fallback_err)
check(
  "the workspace retry drops the mode",
  fallback_calls[2] ~= nil and fallback_calls[2].agentPreset == nil and fallback_calls[2].workspaceId == "ws-1",
  vim.inspect(fallback_calls[2])
)
check(
  "the cwd retry also drops the mode",
  fallback_calls[4] ~= nil and fallback_calls[4].agentPreset == nil and fallback_calls[4].cwd ~= nil,
  vim.inspect(fallback_calls[4])
)
check(
  "both fallbacks are reported",
  type(fallback_warning) == "string"
    and fallback_warning:find("workspace attach failed", 1, true) ~= nil
    and fallback_warning:find("agent mode", 1, true) ~= nil,
  fallback_warning
)

--------------------------------------------------------------------------------
-- 6. The command argument overrides the configured mode; none means none.
--------------------------------------------------------------------------------
reset()
check("quick chat opens the prompt", quick_chat("DshQuickChat standard"))
local argued = rpc("session/create")
check("the command argument names the mode", argued ~= nil and argued.args.request.agentPreset == "standard", vim.inspect(argued and argued.args))

reset()
config.options.quick_chat.mode = nil
check("quick chat opens the prompt", quick_chat())
local unnamed = rpc("session/create")
check("no mode is sent when no mode is configured", unnamed ~= nil and unnamed.args.request.agentPreset == nil, vim.inspect(unnamed and unnamed.args))

--------------------------------------------------------------------------------
-- 7. `quick_chat.chat` and `quick_chat.prompt` choose the orientations.
--------------------------------------------------------------------------------
reset()
config.setup({
  notifications = false,
  treesitter = false,
  quick_chat = {
    chat = { split = "vertical", width = 60, height = 20 },
    prompt = { split = "horizontal", width = 70, height = 6 },
  },
})
local vertical_origin = vim.api.nvim_get_current_win()
local vertical_origin_pos = vim.api.nvim_win_get_position(vertical_origin)
check("quick chat opens the prompt", quick_chat())
local side_win = window_showing("dshchat")
local under_win = window_showing("dsh-prompt")
local side_pos = side_win and vim.api.nvim_win_get_position(side_win)
local under_pos = under_win and vim.api.nvim_win_get_position(under_win)
check("the session view is a vertical split", side_pos ~= nil and side_pos[2] > vertical_origin_pos[2], vim.inspect({ vertical_origin_pos, side_pos }))
check(
  "the session view and prompt span the editor height",
  side_pos ~= nil
    and vim.api.nvim_win_get_height(side_win) + vim.api.nvim_win_get_height(under_win) + 1
      == vim.api.nvim_win_get_height(vertical_origin),
  vim.inspect({ vim.api.nvim_win_get_height(side_win), vim.api.nvim_win_get_height(under_win), vim.api.nvim_win_get_height(vertical_origin) })
)
check(
  "the prompt is a horizontal split of the session view",
  under_pos ~= nil and under_pos[2] == side_pos[2] and under_pos[1] > side_pos[1],
  vim.inspect({ side_pos, under_pos })
)
check(
  "the prompt keeps its configured height",
  under_pos ~= nil and vim.api.nvim_win_get_height(under_win) < vim.api.nvim_win_get_height(side_win),
  vim.inspect({ vim.api.nvim_win_get_height(under_win), vim.api.nvim_win_get_height(side_win) })
)

--------------------------------------------------------------------------------
-- 8. `quick_chat.selection` controls the prefill.
--------------------------------------------------------------------------------
reset()
config.setup({
  notifications = false,
  treesitter = false,
  quick_chat = { selection = { enabled = false } },
})
source_buffer({ "one", "two" })
vim.cmd("normal! 1GVj")
leave_visual()
check("quick chat opens the prompt", quick_chat())
local disabled = prompt_text()
check("selection.enabled = false leaves the prompt empty", disabled ~= nil and vim.trim(disabled) == "", vim.inspect(disabled))

local captured = {
  lines = { "first", "second", "third" },
  path = "lua/sample.lua",
  filetype = "lua",
  first = 4,
  last = 6,
}
local truncated = quick.prompt_text(captured, { max_lines = 2, reference = true })
check("a truncated selection reports what was dropped", truncated:find("[1 more line of the selection was not copied]", 1, true) ~= nil, vim.inspect(truncated))
local bare = quick.prompt_text(captured, { max_lines = 0, reference = false })
check("reference = false drops the file line", bare:find("lua/sample.lua", 1, true) == nil, vim.inspect(bare))
check("max_lines = 0 copies everything", bare:find("third", 1, true) ~= nil and bare:find("not copied", 1, true) == nil, vim.inspect(bare))

reset()
config.setup({
  notifications = false,
  treesitter = false,
  quick_chat = { selection = { max_lines = 1 } },
})
source_buffer({ "one", "two", "three" })
vim.cmd("normal! 1GVj")
leave_visual()
check("quick chat opens the prompt", quick_chat())
local capped = prompt_text()
check("max_lines caps the prefill", capped ~= nil and capped:find("three", 1, true) == nil, vim.inspect(capped))
check("the capped prefill says how much was left out", capped ~= nil and capped:find("[1 more line of the selection was not copied]", 1, true) ~= nil, vim.inspect(capped))

local nested = quick.prompt_text({
  lines = { "```lua", "print(1)", "```" },
  path = "doc/sample.md",
  filetype = "markdown",
  first = 1,
  last = 3,
}, { max_lines = 0, reference = true })
check("a selection with a fence gets a longer fence", nested:find("````markdown\n```lua", 1, true) ~= nil, vim.inspect(nested))

-- Blockwise and charwise selections keep their columns.
reset()
source_buffer({ "abcdef", "ghijkl", "mnopqr" })
vim.cmd("normal! gg0\22jjl")
leave_visual()
local block = quick.selection()
check("a blockwise selection is read", block ~= nil and #block.lines == 3, vim.inspect(block))
check(
  "the block keeps its columns",
  block ~= nil and block.lines[1] == "ab" and block.lines[3] == "mn",
  vim.inspect(block and block.lines)
)
check("the block records its line range", block ~= nil and block.first == 1 and block.last == 3, vim.inspect(block))
check("the block records the filetype", block ~= nil and block.filetype == "lua", vim.inspect(block))

vim.cmd("normal! gg0vjl")
leave_visual()
local chars = quick.selection()
check(
  "a charwise selection is read",
  chars ~= nil and chars.lines[1] == "abcdef" and chars.lines[2] == "gh",
  vim.inspect(chars and chars.lines)
)

-- Selecting blank lines only must not prefill an empty fence.
reset()
source_buffer({ "text", "", "text" })
vim.cmd("normal! 2GV")
leave_visual()
check("quick chat opens the prompt", quick_chat())
local blanks = prompt_text()
check("a blank selection leaves the prompt empty", blanks ~= nil and vim.trim(blanks) == "", vim.inspect(blanks))

--------------------------------------------------------------------------------
-- 9. The Lua entry point and `keymaps.global.quick_chat`.
--------------------------------------------------------------------------------
config.setup({ notifications = false, treesitter = false })
local real_open = quick.open
local forwarded
quick.open = function(opts)
  forwarded = opts
end
dsh.quick_chat({ mode = "ptc" })
check("dsh.quick_chat forwards the mode", forwarded ~= nil and forwarded.mode == "ptc", vim.inspect(forwarded))
quick.open = real_open

dsh.setup({ notifications = false, treesitter = false, keymaps = { global = { quick_chat = "<F12>" } } })
check("keymaps.global.quick_chat is installed", vim.fn.maparg("<F12>", "n") ~= "", vim.inspect(vim.fn.maparg("<F12>", "n", false, true)))

chat.shutdown()

print(("\n=== %d checks, %d failed ==="):format(checks, failures))
vim.cmd("cquit " .. (failures > 0 and 1 or 0))
