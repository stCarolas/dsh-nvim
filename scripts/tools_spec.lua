-- Tool-exchange toggle specs: whole calls collapsing to a run summary, the
-- per-view state, its interaction with the output toggle, :DshToolsToggle and
-- the winbar marker.
-- Run with: nvim --headless -l scripts/tools_spec.lua
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h:h")
vim.opt.rtp:append(root)

local config = require("dsh.config")
config.setup({ notifications = false, treesitter = false, chat = { open_in = "split", split = "vertical" } })

-- Stub the transports: the renderer and the view orchestration are real.
local context = { url = "http://127.0.0.1:1", cookie = "cookie", mint = function() return "minted" end }
package.loaded["dsh.server"] = {
  context = function(callback)
    callback(nil, context)
  end,
  describe = function()
    return { running = false }
  end,
  is_running = function()
    return false
  end,
  start = function() end,
  stop = function() end,
  mint_cookie = function()
    return "minted"
  end,
}
local follow_attachments = {}
package.loaded["dsh.follow"] = {
  attach = function(_, session_id, callbacks)
    follow_attachments[session_id] = callbacks
    return { detach = function() end, state = {} }
  end,
}
package.loaded["dsh.mux"] = {
  close = function() end,
  is_connected = function()
    return false
  end,
  acquire = function(_, callback)
    callback(nil)
  end,
  stream = function()
    return "events-stream"
  end,
  cancel = function() end,
  credential = function()
    return "minted"
  end,
}

local render = require("dsh.render")
local chat = require("dsh.ui.chat")

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

--- A summary line the collapsed tool runs leave behind.
local CALL = "  ⚙ "
local TOOL_INDENT = "    "

local function contains(lines, text)
  for _, line in ipairs(lines) do
    if line == text then
      return true
    end
  end
  return false
end

local function count(lines, text)
  local found = 0
  for _, line in ipairs(lines) do
    if line == text then
      found = found + 1
    end
  end
  return found
end

--- Highlight group of the first line equal to `text`, or nil.
local function line_group(view, text)
  for index, line in ipairs(view.lines) do
    if line == text then
      return view.hl[index]
    end
  end
  return nil
end

local function lines_of(buf)
  return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
end

--- Rendered winbar text of a window.
local function winbar_text(win)
  return vim.api.nvim_eval_statusline(vim.wo[win].winbar, { winid = win }).str
end

local notified = {}
local real_notify = vim.notify
vim.notify = function(message, level)
  notified[#notified + 1] = { message = tostring(message), level = level }
end

local function reset_notifications()
  notified = {}
end

local function notification_contains(needle)
  for _, entry in ipairs(notified) do
    if entry.message:find(needle, 1, true) then
      return true
    end
  end
  return false
end

--------------------------------------------------------------------------------
-- 1. A tool exchange renders as the call line plus its indented output.
--------------------------------------------------------------------------------
local ENTRIES = {
  { role = "user", text = "fix the flaky retry test" },
  { role = "assistant", text = "Reading the retry helper." },
  { role = "tool", name = "read", text = "path=src/retry.ts" },
  { role = "tool_result", text = "line one\nline two" },
  { role = "tool", name = "bash", text = "command=npm test" },
  { role = "tool_result", text = "exit code 1", is_error = true },
  { role = "assistant", text = "The retry loop copies the backoff value." },
}

local shown = render.compose(ENTRIES)
check("exchanges show by default", contains(shown.lines, CALL .. "read(path=src/retry.ts)"))
check("their output shows by default", contains(shown.lines, TOOL_INDENT .. "line one"))
check("no summary is rendered while shown", not contains(shown.lines, CALL .. "2 tool calls hidden"))

--------------------------------------------------------------------------------
-- 2. Hiding exchanges drops the call lines and their output, keeping one
-- summary line per run that still counts failures.
--------------------------------------------------------------------------------
local hidden = render.compose(ENTRIES, { show_tool_exchange = false })
check("hidden exchanges drop the call line", not contains(hidden.lines, CALL .. "read(path=src/retry.ts)"))
check("hidden exchanges drop the second call", not contains(hidden.lines, CALL .. "bash(command=npm test)"))
check("hidden exchanges drop the output", not contains(hidden.lines, TOOL_INDENT .. "line one"))
check("hidden exchanges drop the failed output", not contains(hidden.lines, TOOL_INDENT .. "exit code 1"))
check("a run collapses to one summary line", contains(hidden.lines, CALL .. "2 tool calls hidden, 1 failed"))
check(
  "the summary is muted chrome when nothing failed",
  line_group(render.compose({ { role = "tool", name = "read", text = "path=a" } }, { show_tool_exchange = false }), CALL .. "1 tool call hidden")
    == "DshTool"
)
check(
  "the summary takes the error group when something failed",
  line_group(hidden, CALL .. "2 tool calls hidden, 1 failed") == "DshToolError",
  tostring(line_group(hidden, CALL .. "2 tool calls hidden, 1 failed"))
)
check("hidden exchanges keep the conversation", contains(hidden.lines, "The retry loop copies the backoff value."))
check("hidden exchanges keep the prompts", contains(hidden.lines, "fix the flaky retry test"))
check("hiding exchanges removes lines", #hidden.lines < #shown.lines, ("%d vs %d"):format(#hidden.lines, #shown.lines))

local single = render.compose({
  { role = "tool", name = "read", text = "path=a" },
  { role = "tool_result", text = "one" },
}, { show_tool_exchange = false })
check("one call reads singular", contains(single.lines, CALL .. "1 tool call hidden"))

-- A result is never dropped silently, even when its call line is missing.
local orphan = render.compose({ { role = "tool_result", text = "orphan output" } }, { show_tool_exchange = false })
check("a result without a call still leaves a summary", contains(orphan.lines, CALL .. "tool output hidden"))

--------------------------------------------------------------------------------
-- 3. Runs stay separate: a message between two exchanges keeps two summaries.
--------------------------------------------------------------------------------
local two_runs = render.compose({
  { role = "tool", name = "read", text = "path=a" },
  { role = "tool_result", text = "x" },
  { role = "assistant", text = "First part done." },
  { role = "tool", name = "bash", text = "command=ls" },
  { role = "tool_result", text = "y" },
}, { show_tool_exchange = false })
check("each run gets its own summary", count(two_runs.lines, CALL .. "1 tool call hidden") == 2, vim.inspect(two_runs.lines))
check("the message between runs stays", contains(two_runs.lines, "First part done."))

--------------------------------------------------------------------------------
-- 4. The two toggles compose: exchanges win while hidden, output applies after.
--------------------------------------------------------------------------------
local both = render.compose(ENTRIES, { show_tool_exchange = false, show_tool_output = false })
check(
  "hiding exchanges hides output too",
  not contains(both.lines, TOOL_INDENT .. "line one") and contains(both.lines, CALL .. "2 tool calls hidden, 1 failed")
)

local output_only = render.compose(ENTRIES, { show_tool_exchange = true, show_tool_output = false })
check("output-only hiding keeps the call line", contains(output_only.lines, CALL .. "read(path=src/retry.ts)"))
check("output-only hiding keeps the output marker", contains(output_only.lines, TOOL_INDENT .. "… 2 lines hidden"))

--------------------------------------------------------------------------------
-- 5. The config decides when the caller passes no view state.
--------------------------------------------------------------------------------
config.options.show_tool_exchange = false
local by_config = render.compose(ENTRIES)
check("compose follows show_tool_exchange", contains(by_config.lines, CALL .. "2 tool calls hidden, 1 failed"))
config.options.show_tool_exchange = true
check("views still pass their own state", contains(render.compose(ENTRIES).lines, CALL .. "read(path=src/retry.ts)"))

--------------------------------------------------------------------------------
-- 6. The winbar names the coarser state, and a valid statusline either way.
--------------------------------------------------------------------------------
local exchange_marked = render.winbar("Title", "idle", nil, { show_tool_exchange = false, show_tool_output = true })
check("winbar marks hidden exchanges", exchange_marked:find("tools hidden", 1, true) ~= nil, exchange_marked)
local both_marked = render.winbar("Title", "idle", nil, { show_tool_exchange = false, show_tool_output = false })
check("hidden exchanges win over hidden output", both_marked:find("tools hidden", 1, true) ~= nil and both_marked:find("output hidden", 1, true) == nil, both_marked)
local output_marked = render.winbar("Title", "idle", nil, { show_tool_exchange = true, show_tool_output = false })
check("the output marker stays when only output is hidden", output_marked:find("output hidden", 1, true) ~= nil, output_marked)
local plain = render.winbar("Title", "idle", nil, nil)
check("nothing is marked by default", plain:find("hidden", 1, true) == nil, plain)

--------------------------------------------------------------------------------
-- 7. The command is registered; with no view open it warns instead of failing.
--------------------------------------------------------------------------------
vim.cmd("runtime plugin/dsh.lua")
check("DshToolsToggle command is registered", vim.fn.exists(":DshToolsToggle") == 2)

reset_notifications()
vim.cmd("DshToolsToggle")
check("no open view is reported", notification_contains("no open DSH session"), vim.inspect(notified))

--------------------------------------------------------------------------------
-- 8. Toggling a view re-renders it; the two states are independent.
--------------------------------------------------------------------------------
local sid = "session-11111111-2222-3333-4444-555555555555"
chat.open(sid, { title = "Tools toggle" })
local view_win = vim.api.nvim_get_current_win()
local view_buf = vim.api.nvim_get_current_buf()
follow_attachments[sid].on_update({ entries = ENTRIES, title = "Tools toggle", last_seq = 4 })
check("history renders the exchange", contains(lines_of(view_buf), CALL .. "read(path=src/retry.ts)"))
check("shown exchanges have no winbar marker", winbar_text(view_win):find("tools hidden", 1, true) == nil, winbar_text(view_win))

reset_notifications()
check("toggle_tools returns the new state", chat.toggle_tools() == false)
check("the call line is gone", not contains(lines_of(view_buf), CALL .. "read(path=src/retry.ts)"))
check("the output is gone", not contains(lines_of(view_buf), TOOL_INDENT .. "line one"))
check("the summary replaces the run", contains(lines_of(view_buf), CALL .. "2 tool calls hidden, 1 failed"))
check("the change is announced", notification_contains("tools hidden"), vim.inspect(notified))
check("the winbar shows the marker", winbar_text(view_win):find("tools hidden", 1, true) ~= nil, winbar_text(view_win))
check("the buffer stays read-only", vim.bo[view_buf].modifiable == false, tostring(vim.bo[view_buf].modifiable))

-- Hiding the output of an already hidden exchange changes nothing visible,
-- but it is remembered: showing the exchanges reveals calls + collapsed output.
chat.toggle_output(sid)
check("the summary is unchanged while hidden", contains(lines_of(view_buf), CALL .. "2 tool calls hidden, 1 failed"))
chat.toggle_tools(sid)
check("showing the exchanges restores the call line", contains(lines_of(view_buf), CALL .. "read(path=src/retry.ts)"))
check("the remembered output state applies", contains(lines_of(view_buf), TOOL_INDENT .. "… 2 lines hidden"))
check("the output toggle hid the body", not contains(lines_of(view_buf), TOOL_INDENT .. "line one"))
check("the winbar switches to the output marker", winbar_text(view_win):find("output hidden", 1, true) ~= nil, winbar_text(view_win))
check("the tools marker is gone", winbar_text(view_win):find("tools hidden", 1, true) == nil, winbar_text(view_win))

chat.toggle_output(sid)
check("restoring the output shows the body", contains(lines_of(view_buf), TOOL_INDENT .. "line one"))
check("nothing is marked once both are shown", winbar_text(view_win):find("hidden", 1, true) == nil, winbar_text(view_win))

-- A stream update while hidden keeps the view hidden.
chat.toggle_tools(sid)
follow_attachments[sid].on_update({ entries = ENTRIES, title = "Tools toggle", last_seq = 5 })
check("stream updates keep the hidden state", not contains(lines_of(view_buf), CALL .. "read(path=src/retry.ts)"))
check("stream updates keep the summary", contains(lines_of(view_buf), CALL .. "2 tool calls hidden, 1 failed"))

--------------------------------------------------------------------------------
-- 9. Each view toggles on its own.
--------------------------------------------------------------------------------
local sid2 = "session-66666666-2222-3333-4444-555555555555"
chat.open(sid2, { title = "Second view" })
local view2_buf = vim.api.nvim_get_current_buf()
follow_attachments[sid2].on_update({ entries = ENTRIES, title = "Second view", last_seq = 1 })
check("a new view starts with exchanges shown", contains(lines_of(view2_buf), CALL .. "read(path=src/retry.ts)"))
chat.toggle_tools(sid2)
check("the second view hides its own exchanges", not contains(lines_of(view2_buf), CALL .. "read(path=src/retry.ts)"))
check("the first view stays hidden", not contains(lines_of(view_buf), CALL .. "read(path=src/retry.ts)"))

--------------------------------------------------------------------------------
-- 10. The command resolves the most recently viewed session from any buffer.
--------------------------------------------------------------------------------
chat.open(sid2) -- focus the hidden view, then leave for a scratch buffer
vim.cmd("enew")
check("left the session buffer", chat.current() == nil)
reset_notifications()
vim.cmd("DshToolsToggle")
check("toggling from another buffer follows the recent view", contains(lines_of(view2_buf), CALL .. "read(path=src/retry.ts)"))
check("the notice names what changed", notification_contains("tools shown"), vim.inspect(notified))

--------------------------------------------------------------------------------
-- 11. show_tool_exchange sets what a view starts with.
--------------------------------------------------------------------------------
config.setup({ notifications = false, treesitter = false, show_tool_exchange = false, chat = { open_in = "split", split = "vertical" } })
local sid3 = "session-77777777-2222-3333-4444-555555555555"
chat.open(sid3, { title = "Config default" })
local view3_buf = vim.api.nvim_get_current_buf()
follow_attachments[sid3].on_update({ entries = ENTRIES, title = "Config default", last_seq = 1 })
check("a view can start with exchanges hidden", not contains(lines_of(view3_buf), CALL .. "read(path=src/retry.ts)"))
check("the config view keeps the conversation", contains(lines_of(view3_buf), "The retry loop copies the backoff value."))
config.setup({ notifications = false, treesitter = false, chat = { open_in = "split", split = "vertical" } })

--------------------------------------------------------------------------------
-- 12. keymaps.tools maps the same toggle inside the session buffer.
--------------------------------------------------------------------------------
config.setup({
  notifications = false,
  treesitter = false,
  chat = { open_in = "split", split = "vertical" },
  keymaps = { tools = "gT" },
})
local sid4 = "session-88888888-2222-3333-4444-555555555555"
chat.open(sid4, { title = "Mapped toggle" })
local view4_win = vim.api.nvim_get_current_win()
local view4_buf = vim.api.nvim_get_current_buf()
follow_attachments[sid4].on_update({ entries = ENTRIES, title = "Mapped toggle", last_seq = 1 })

local mapped
for _, item in ipairs(vim.api.nvim_buf_get_keymap(view4_buf, "n")) do
  if item.lhs == "gT" then
    mapped = item
  end
end
check("keymaps.tools is mapped in the view", mapped ~= nil)
check("the mapping is described", mapped ~= nil and type(mapped.desc) == "string" and mapped.desc:find("tool calls", 1, true) ~= nil, mapped and mapped.desc)
if mapped and type(mapped.callback) == "function" then
  mapped.callback()
  check("the mapping hides the exchanges", not contains(lines_of(view4_buf), CALL .. "read(path=src/retry.ts)"))
  check("the mapping updates the winbar", winbar_text(view4_win):find("tools hidden", 1, true) ~= nil, winbar_text(view4_win))
end

--------------------------------------------------------------------------------
-- 13. A transcript without tool calls is untouched by the toggle.
--------------------------------------------------------------------------------
local no_tools = render.compose({
  { role = "user", text = "hello" },
  { role = "assistant", text = "hi" },
}, { show_tool_exchange = false })
check("a tool-free transcript keeps its lines", contains(no_tools.lines, "hello") and contains(no_tools.lines, "hi"))
check("a tool-free transcript gets no summary", not contains(no_tools.lines, CALL .. "0 tool calls hidden"))

vim.notify = real_notify
chat.close(sid)
chat.close(sid2)
chat.close(sid3)
chat.close(sid4)
chat.shutdown()

print(("\n=== %d checks, %d failed ==="):format(checks, failures))
vim.cmd("cquit " .. (failures > 0 and 1 or 0))
