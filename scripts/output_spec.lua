-- Tool-output toggle specs: how hidden output renders, the per-view state,
-- :DshOutputToggle and the winbar marker.
-- Run with: nvim --headless -l scripts/output_spec.lua
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h:h")
vim.opt.rtp:append(root)

local config = require("dsh.config")
config.setup({ notifications = false, treesitter = false, chat = { open_in = "split", split = "vertical" } })

-- Stub the transports: the renderer and the view orchestration are real.
package.loaded["dsh.server"] = {
  context = function(callback)
    callback(nil, { url = "http://127.0.0.1:1", cookie = "cookie", mint = function()
      return "minted"
    end })
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

local TOOL_INDENT = "    "

local function contains(lines, text)
  for _, line in ipairs(lines) do
    if line == text then
      return true
    end
  end
  return false
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
-- 1. Tool results render by default, and the existing truncation still applies.
--------------------------------------------------------------------------------
local ENTRIES = {
  { role = "user", text = "fix the flaky retry test" },
  { role = "tool", name = "read", text = "path=src/retry.ts" },
  { role = "tool_result", text = "line one\nline two\nline three" },
  { role = "assistant", text = "The retry loop copies the backoff value." },
}

local shown = render.compose(ENTRIES)
check("output shows by default", contains(shown.lines, TOOL_INDENT .. "line one"))
check("the call line is rendered", contains(shown.lines, "  ⚙ read(path=src/retry.ts)"))
check(
  "shown output keeps the code-block group",
  line_group(shown, TOOL_INDENT .. "line one") == "DshCodeBlock",
  tostring(line_group(shown, TOOL_INDENT .. "line one"))
)

--------------------------------------------------------------------------------
-- 2. Hidden output keeps the call and collapses the body to one marker line.
--------------------------------------------------------------------------------
local hidden = render.compose(ENTRIES, { show_tool_output = false })
check("hidden output drops the body", not contains(hidden.lines, TOOL_INDENT .. "line one"))
check("hidden output keeps the call line", contains(hidden.lines, "  ⚙ read(path=src/retry.ts)"))
check("hidden output says how much it hides", contains(hidden.lines, TOOL_INDENT .. "… 3 lines hidden"))
check(
  "the hidden marker is muted chrome, not code",
  line_group(hidden, TOOL_INDENT .. "… 3 lines hidden") == "DshTool",
  tostring(line_group(hidden, TOOL_INDENT .. "… 3 lines hidden"))
)
check("hidden output keeps the conversation", contains(hidden.lines, "The retry loop copies the backoff value."))
check("hiding output removes lines", #hidden.lines < #shown.lines, ("%d vs %d"):format(#hidden.lines, #shown.lines))

local single = render.compose({ { role = "tool_result", text = "only" } }, { show_tool_output = false })
check("a one-line body reads singular", contains(single.lines, TOOL_INDENT .. "… 1 line hidden"))

local empty = render.compose({ { role = "tool_result", text = "" } }, { show_tool_output = false })
check("an empty hidden body is still marked", contains(empty.lines, TOOL_INDENT .. "(empty)"))

--------------------------------------------------------------------------------
-- 3. A failed result is never collapsed: hiding a failure would hide the error.
--------------------------------------------------------------------------------
local failed = render.compose({
  { role = "tool", name = "bash", text = "command=npm test" },
  { role = "tool_result", text = "exit code 1", is_error = true },
}, { show_tool_output = false })
check("failed output stays visible when output is hidden", contains(failed.lines, TOOL_INDENT .. "exit code 1"))
check(
  "failed output keeps its error group",
  line_group(failed, TOOL_INDENT .. "exit code 1") == "DshToolError",
  tostring(line_group(failed, TOOL_INDENT .. "exit code 1"))
)

--------------------------------------------------------------------------------
-- 4. The config decides when the caller passes no view state.
--------------------------------------------------------------------------------
config.options.show_tool_output = false
local by_config = render.compose(ENTRIES)
check("compose follows show_tool_output", contains(by_config.lines, TOOL_INDENT .. "… 3 lines hidden"))
config.options.show_tool_output = true
check("views still pass their own state", contains(render.compose(ENTRIES).lines, TOOL_INDENT .. "line one"))

--------------------------------------------------------------------------------
-- 5. The winbar says when output is hidden, and stays a valid statusline.
--------------------------------------------------------------------------------
local marked = render.winbar("Fix the flaky retry test", "idle", nil, { show_tool_output = false })
check("winbar marks hidden output", marked:find("output hidden", 1, true) ~= nil, marked)
check("winbar keeps the title", marked:find("Fix the flaky retry test", 1, true) ~= nil, marked)
local unmarked = render.winbar("Fix the flaky retry test", "idle", nil, { show_tool_output = true })
check("shown output has no marker", unmarked:find("output hidden", 1, true) == nil, unmarked)
local streaming_marked = render.winbar("Fix the flaky retry test", "streaming", "preview", { show_tool_output = false })
check(
  "the marker survives a streaming preview",
  streaming_marked:find("preview", 1, true) ~= nil and streaming_marked:find("output hidden", 1, true) ~= nil,
  streaming_marked
)

--------------------------------------------------------------------------------
-- 6. The command is registered; with no view open it warns instead of failing.
--------------------------------------------------------------------------------
vim.cmd("runtime plugin/dsh.lua")
check("DshOutputToggle command is registered", vim.fn.exists(":DshOutputToggle") == 2)

reset_notifications()
vim.cmd("DshOutputToggle")
check("no open view is reported", notification_contains("no open DSH session"), vim.inspect(notified))

--------------------------------------------------------------------------------
-- 7. Toggling a view re-renders it, and toggling back restores the output.
--------------------------------------------------------------------------------
local sid = "session-11111111-2222-3333-4444-555555555555"
chat.open(sid, { title = "Output toggle" })
local view_win = vim.api.nvim_get_current_win()
local view_buf = vim.api.nvim_get_current_buf()
check("view buffer is a dshchat buffer", vim.bo[view_buf].filetype == "dshchat")

follow_attachments[sid].on_update({ entries = ENTRIES, title = "Output toggle", last_seq = 4 })
check("history renders tool output", contains(lines_of(view_buf), TOOL_INDENT .. "line one"))
check("shown output has no winbar marker", winbar_text(view_win):find("output hidden", 1, true) == nil, winbar_text(view_win))

reset_notifications()
check("toggle_output returns the new state", chat.toggle_output() == false)
vim.cmd("DshOutputToggle") -- and the command toggles it back
check("the command restores the output", contains(lines_of(view_buf), TOOL_INDENT .. "line one"))
check("the command reports the state", notification_contains("tool output shown"), vim.inspect(notified))

vim.cmd("DshOutputToggle")
check("hidden state hides the body in the buffer", not contains(lines_of(view_buf), TOOL_INDENT .. "line one"))
check("hidden state keeps the call in the buffer", contains(lines_of(view_buf), "  ⚙ read(path=src/retry.ts)"))
check("hidden state leaves the marker line", contains(lines_of(view_buf), TOOL_INDENT .. "… 3 lines hidden"))
check(
  "the buffer stays read-only after a toggle",
  vim.bo[view_buf].modifiable == false,
  tostring(vim.bo[view_buf].modifiable)
)
check("hidden state is announced", notification_contains("tool output hidden"), vim.inspect(notified))
check("hidden state shows in the winbar", winbar_text(view_win):find("output hidden", 1, true) ~= nil, winbar_text(view_win))

-- A stream update while hidden keeps the view hidden.
follow_attachments[sid].on_update({ entries = ENTRIES, title = "Output toggle", last_seq = 5 })
check("stream updates keep the hidden state", not contains(lines_of(view_buf), TOOL_INDENT .. "line one"))
check("stream updates keep the marker", winbar_text(view_win):find("output hidden", 1, true) ~= nil, winbar_text(view_win))

--------------------------------------------------------------------------------
-- 8. Each view toggles on its own.
--------------------------------------------------------------------------------
local sid2 = "session-66666666-2222-3333-4444-555555555555"
chat.open(sid2, { title = "Second view" })
local view2_buf = vim.api.nvim_get_current_buf()
follow_attachments[sid2].on_update({ entries = ENTRIES, title = "Second view", last_seq = 1 })
check("a new view starts with output shown", contains(lines_of(view2_buf), TOOL_INDENT .. "line one"))

chat.toggle_output(sid2)
check("the second view hides its own output", not contains(lines_of(view2_buf), TOOL_INDENT .. "line one"))
check("the first view is still hidden", not contains(lines_of(view_buf), TOOL_INDENT .. "line one"))

chat.toggle_output(sid)
check("toggling the first view restores it", contains(lines_of(view_buf), TOOL_INDENT .. "line one"))
check("the second view stays hidden", not contains(lines_of(view2_buf), TOOL_INDENT .. "line one"))

--------------------------------------------------------------------------------
-- 9. The command resolves the most recently viewed session from any buffer.
--------------------------------------------------------------------------------
-- Focus the second view (still hidden) and leave for a scratch buffer: the
-- command must still reach it, as :DshInterrupt does from a prompt window.
chat.open(sid2)
vim.cmd("enew")
check("left the session buffer", chat.current() == nil)

reset_notifications()
vim.cmd("DshOutputToggle")
check("toggling from another buffer follows the recent view", contains(lines_of(view2_buf), TOOL_INDENT .. "line one"))
check("the notice names what changed", notification_contains("tool output shown"), vim.inspect(notified))
chat.toggle_output(sid2) -- hide it again for the config check below

--------------------------------------------------------------------------------
-- 10. show_tool_output sets what a view starts with; open views keep their own.
--------------------------------------------------------------------------------
config.setup({ notifications = false, treesitter = false, show_tool_output = false, chat = { open_in = "split", split = "vertical" } })
check(
  "the config does not retoggle open views",
  contains(lines_of(view_buf), TOOL_INDENT .. "line one") and not contains(lines_of(view2_buf), TOOL_INDENT .. "line one")
)

local sid3 = "session-77777777-2222-3333-4444-555555555555"
chat.open(sid3, { title = "Config default" })
local view3_buf = vim.api.nvim_get_current_buf()
follow_attachments[sid3].on_update({ entries = ENTRIES, title = "Config default", last_seq = 1 })
check("a view can start hidden from the config", not contains(lines_of(view3_buf), TOOL_INDENT .. "line one"))
check("the hidden config view keeps the calls", contains(lines_of(view3_buf), "  ⚙ read(path=src/retry.ts)"))

config.setup({ notifications = false, treesitter = false, chat = { open_in = "split", split = "vertical" } })

--------------------------------------------------------------------------------
-- 11. keymaps.output maps the same toggle inside the session buffer.
--------------------------------------------------------------------------------
config.setup({
  notifications = false,
  treesitter = false,
  chat = { open_in = "split", split = "vertical" },
  keymaps = { output = "gz" },
})
local sid4 = "session-88888888-2222-3333-4444-555555555555"
chat.open(sid4, { title = "Mapped toggle" })
local view4_win = vim.api.nvim_get_current_win()
local view4_buf = vim.api.nvim_get_current_buf()
follow_attachments[sid4].on_update({ entries = ENTRIES, title = "Mapped toggle", last_seq = 1 })

local mapped
for _, item in ipairs(vim.api.nvim_buf_get_keymap(view4_buf, "n")) do
  if item.lhs == "gz" then
    mapped = item
  end
end
check("keymaps.output is mapped in the view", mapped ~= nil)
check("the mapping is described", mapped ~= nil and type(mapped.desc) == "string" and mapped.desc:find("tool output", 1, true) ~= nil, mapped and mapped.desc)
if mapped and type(mapped.callback) == "function" then
  mapped.callback()
  check("the mapping toggles the view", not contains(lines_of(view4_buf), TOOL_INDENT .. "line one"))
  check("the mapping updates the winbar", winbar_text(view4_win):find("output hidden", 1, true) ~= nil, winbar_text(view4_win))
end

--------------------------------------------------------------------------------
-- 12. A hostile title cannot break the winbar through the marker path.
--------------------------------------------------------------------------------
local sid5 = "session-99999999-2222-3333-4444-555555555555"
chat.open(sid5, { title = "50% done" })
local view5_win = vim.api.nvim_get_current_win()
chat.toggle_output(sid5)
local ok, evaluated = pcall(winbar_text, view5_win)
check("a percent in the title evaluates", ok, tostring(evaluated))
check("the escaped title is shown", ok and evaluated:find("50% done", 1, true) ~= nil, tostring(evaluated))
check("the marker is shown", ok and evaluated:find("output hidden", 1, true) ~= nil, tostring(evaluated))

vim.notify = real_notify
chat.close(sid)
chat.close(sid2)
chat.close(sid3)
chat.close(sid4)
chat.close(sid5)
chat.shutdown()

print(("\n=== %d checks, %d failed ==="):format(checks, failures))
vim.cmd("cquit " .. (failures > 0 and 1 or 0))
