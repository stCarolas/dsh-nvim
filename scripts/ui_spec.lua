-- View placement specs: tab vs split, reopen focus, close cleanup.
-- Run with: nvim --headless -l scripts/ui_spec.lua
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h:h")
vim.opt.rtp:append(root)

local config = require("dsh.config")
config.setup({ notifications = false })

-- Stub the transports: opening a view must need no server and no socket.
package.loaded["dsh.server"] = {
  context = function(callback)
    callback(nil, { url = "http://127.0.0.1:1", cookie = "cookie", mint = function() return "minted" end })
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

local chat = require("dsh.ui.chat")
local session = require("dsh.session")

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

local function counts()
  return {
    tabs = #vim.api.nvim_list_tabpages(),
    wins = #vim.api.nvim_list_wins(),
    bufs = #vim.api.nvim_list_bufs(),
  }
end

local function current_name()
  return vim.api.nvim_buf_get_name(0)
end

local sid = "session-11111111-2222-3333-4444-555555555555"

-- 1. Tab placement.
config.setup({ notifications = false, chat = { open_in = "tab" } })

local before = counts()
local origin_tab = vim.api.nvim_get_current_tabpage()

chat.open(sid)
local opened = counts()

check("open_in=tab creates one tab", opened.tabs == before.tabs + 1, ("%d -> %d"):format(before.tabs, opened.tabs))
check("session buffer is shown", current_name():find("dsh://11111111", 1, true) ~= nil, current_name())
check("session buffer is unlisted", vim.bo[vim.api.nvim_get_current_buf()].buflisted == false)
local ls_after_open = vim.api.nvim_exec2("ls", { output = true }).output
check("session buffer is absent from :ls", ls_after_open:find("dsh://", 1, true) == nil, ls_after_open)
check("no throwaway buffer", opened.bufs == before.bufs + 1, ("%d -> %d"):format(before.bufs, opened.bufs))
check("session tab is current", vim.api.nvim_get_current_tabpage() ~= origin_tab)
check("open view reports its session open", chat.is_open(sid))
check("is_open rejects sessions without a view", not chat.is_open("session-ffffffff-0000-0000-0000-000000000000"))

-- 2. Re-open focuses the existing tab instead of making another.
vim.api.nvim_set_current_tabpage(origin_tab)
local before_reopen = counts()
chat.open(sid)
check("reopen returns to the session tab", vim.api.nvim_get_current_tabpage() ~= origin_tab)
check("reopen creates no tab", counts().tabs == before_reopen.tabs, ("%d vs %d"):format(counts().tabs, before_reopen.tabs))
check("reopen reuses the buffer", current_name():find("dsh://11111111", 1, true) ~= nil)

-- 3. Closing removes the tab it owns.
chat.close(sid)
local closed = counts()
check("close removes the session tab", closed.tabs == before.tabs, ("%d vs %d"):format(closed.tabs, before.tabs))
check("close removes the buffer", closed.bufs == before.bufs, ("%d vs %d"):format(closed.bufs, before.bufs))
check("close leaves one window", closed.wins == before.wins, ("%d vs %d"):format(closed.wins, before.wins))
check("closed view is no longer open", not chat.is_open(sid))

-- 4. Split placement still works and creates no tab.
config.setup({ notifications = false, chat = { open_in = "split", split = "vertical" } })
local sid2 = "session-aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
local before_split = counts()
chat.open(sid2)
local in_split = counts()
check("open_in=split adds a window", in_split.wins == before_split.wins + 1, ("%d -> %d"):format(before_split.wins, in_split.wins))
check("open_in=split adds no tab", in_split.tabs == before_split.tabs)
chat.close(sid2)
check("split close restores windows", counts().wins == before_split.wins)

-- 5. The legacy `split = "tab"` spelling is still honoured.
config.setup({ notifications = false, chat = { split = "tab" } })
local sid3 = "session-99999999-8888-7777-6666-555555555555"
local before_legacy = counts()
chat.open(sid3)
check("legacy split=tab opens a tab", counts().tabs == before_legacy.tabs + 1)
chat.close(sid3)
check("legacy tab close cleans up", counts().tabs == before_legacy.tabs)

-- 6. Two sessions open in two tabs at once.
config.setup({ notifications = false, chat = { open_in = "tab" } })
local id_a = "session-aaaaaaaa-1111-1111-1111-111111111111"
local id_b = "session-bbbbbbbb-2222-2222-2222-222222222222"
local before_multi = counts()
chat.open(id_a)
chat.open(id_b)
check("each session gets its own tab", counts().tabs == before_multi.tabs + 2, ("%d -> %d"):format(before_multi.tabs, counts().tabs))

-- Closing one view leaves the other tab intact.
chat.close(id_a)
check("closing one keeps the other tab", counts().tabs == before_multi.tabs + 1, ("%d -> %d"):format(before_multi.tabs, counts().tabs))
chat.close(id_b)
check("closing both restores the layout", counts().tabs == before_multi.tabs and counts().wins == before_multi.wins)

-- 6b. `recent_view()` remembers the last session view for the menu, which can
-- run from another buffer or tab.
config.setup({ notifications = false, chat = { open_in = "split", split = "vertical" } })
local id_c = "session-cccccccc-3333-3333-3333-333333333333"
local id_d = "session-dddddddd-4444-4444-4444-444444444444"
local wins_before_recent = #vim.api.nvim_list_wins()
chat.open(id_c)
local win_c = vim.api.nvim_get_current_win()
chat.open(id_d)
local win_d = vim.api.nvim_get_current_win()

check("recent view is the newest view", chat.current() == id_d and chat.recent_view() == id_d, tostring(chat.recent_view()))

-- Leaving the session buffer (as `:DshMenu` from another tab would) keeps it.
local scratch_buf = vim.api.nvim_create_buf(true, false)
vim.api.nvim_win_set_buf(win_d, scratch_buf)
check("current view is nil outside a session buffer", chat.current() == nil)
check("recent view falls back to an open session", chat.recent_view() == id_d, tostring(chat.recent_view()))

-- Visiting another view updates which session the menu would target.
vim.api.nvim_set_current_win(win_c)
check("recent view follows the last visited view", chat.recent_view() == id_c, tostring(chat.recent_view()))

vim.api.nvim_win_set_buf(win_c, scratch_buf)
chat.close(id_c)
chat.close(id_d)
vim.api.nvim_buf_delete(scratch_buf, { force = true })
check("recency probe restores the window layout", #vim.api.nvim_list_wins() == wins_before_recent, ("%d vs %d"):format(#vim.api.nvim_list_wins(), wins_before_recent))

-- 7. Session buffers are named after the DSH session title.
config.setup({ notifications = false, chat = { open_in = "split", split = "vertical" } })
local sid_title = "session-12345678-aaaa-bbbb-cccc-dddddddddddd"
chat.open(sid_title)
local title_buf = vim.api.nvim_get_current_buf()
check("untitled session buffer keeps the id name", vim.api.nvim_buf_get_name(title_buf) == "dsh://12345678", vim.api.nvim_buf_get_name(title_buf))

local attachment = follow_attachments[sid_title]
check("follow attachment captured", attachment ~= nil and attachment.on_update ~= nil)

attachment.on_update({ entries = {}, title = "Fix the flaky retry test", last_seq = 1 })
check(
  "buffer name follows the session title",
  vim.api.nvim_buf_get_name(title_buf) == "dsh://Fix the flaky retry test",
  vim.api.nvim_buf_get_name(title_buf)
)

attachment.on_update({ entries = {}, title = "Retry loop jitter", last_seq = 2 })
check(
  "buffer name follows a session retitle",
  vim.api.nvim_buf_get_name(title_buf) == "dsh://Retry loop jitter",
  vim.api.nvim_buf_get_name(title_buf)
)

attachment.on_update({ entries = {}, title = "  spaced\n\ttitle  ", last_seq = 3 })
check(
  "buffer name flattens control characters",
  vim.api.nvim_buf_get_name(title_buf) == "dsh://spaced title",
  vim.api.nvim_buf_get_name(title_buf)
)

-- Duplicate titles are disambiguated with the session id.
attachment.on_update({ entries = {}, title = "Shared title", last_seq = 4 })
local sid_dup = "session-87654321-aaaa-bbbb-cccc-dddddddddddd"
chat.open(sid_dup)
local dup_buf = vim.api.nvim_get_current_buf()
follow_attachments[sid_dup].on_update({ entries = {}, title = "Shared title", last_seq = 1 })
check(
  "duplicate title gets the session id suffix",
  vim.api.nvim_buf_get_name(dup_buf) == "dsh://Shared title (87654321)",
  vim.api.nvim_buf_get_name(dup_buf)
)

-- A title hint from the session list names the buffer before the stream starts.
local sid_hint = "session-abcdef12-aaaa-bbbb-cccc-dddddddddddd"
chat.open(sid_hint, { title = "Hinted title" })
check(
  "title hint names the buffer at open",
  vim.api.nvim_buf_get_name(vim.api.nvim_get_current_buf()) == "dsh://Hinted title",
  vim.api.nvim_buf_get_name(vim.api.nvim_get_current_buf())
)

chat.close(sid_title)
chat.close(sid_dup)
chat.close(sid_hint)

-- 8. Submitting a prompt returns to the view in normal mode, at its newest line.
config.setup({
  notifications = false,
  chat = { open_in = "split", split = "vertical" },
  prompt = { open_in = "split", split = "horizontal" },
})
local sid_focus = "session-55555555-1111-2222-3333-444444444444"
chat.open(sid_focus)
local view_win = vim.api.nvim_get_current_win()
local view_buf = vim.api.nvim_get_current_buf()
follow_attachments[sid_focus].on_update({
  entries = {
    { role = "user", text = "first" },
    { role = "assistant", text = "reply" },
  },
  title = "Focus test",
  last_seq = 5,
})
check("view has history before the prompt", vim.api.nvim_buf_line_count(view_buf) > 1, tostring(vim.api.nvim_buf_line_count(view_buf)))

-- Browse history away from the end before prompting.
vim.api.nvim_win_set_cursor(view_win, { 1, 0 })

local real_prompt = session.prompt
session.prompt = function()
  return { ok = true }
end
chat.prompt(sid_focus)
local prompt_win = vim.api.nvim_get_current_win()
local prompt_buf = vim.api.nvim_get_current_buf()
check("prompt opens in another window", prompt_win ~= view_win)
vim.api.nvim_buf_set_lines(prompt_buf, 0, -1, false, { "hello" })

-- Headless Neovim never really enters insert mode, so record the command that
-- hands the view back in normal mode instead.
local commands = {}
local real_cmd = vim.cmd
vim.cmd = function(command)
  commands[#commands + 1] = type(command) == "string" and command or "<fn>"
  return real_cmd(command)
end
vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<C-s>", true, false, true), "x", false)
vim.wait(1000, function()
  return not vim.api.nvim_win_is_valid(prompt_win)
end, 50)
vim.cmd = real_cmd
session.prompt = real_prompt

check("closing the prompt stops insert mode", vim.tbl_contains(commands, "stopinsert"), table.concat(commands, ","))
check("submit returns to the session window", vim.api.nvim_get_current_win() == view_win)
check("submit returns in normal mode", vim.api.nvim_get_mode().mode == "n", vim.api.nvim_get_mode().mode)
check(
  "submit puts the cursor on the newest line",
  vim.api.nvim_win_get_cursor(view_win)[1] == vim.api.nvim_buf_line_count(view_buf),
  ("%d / %d"):format(vim.api.nvim_win_get_cursor(view_win)[1], vim.api.nvim_buf_line_count(view_buf))
)

-- Streamed output must keep the view pinned to the bottom.
follow_attachments[sid_focus].on_update({
  entries = {
    { role = "user", text = "first" },
    { role = "assistant", text = "reply" },
    { role = "user", text = "hello" },
    { role = "live", text = "streaming answer" },
  },
  title = "Focus test",
  last_seq = 6,
})
check(
  "streamed output keeps the cursor at the bottom",
  vim.api.nvim_win_get_cursor(view_win)[1] == vim.api.nvim_buf_line_count(view_buf),
  ("%d / %d"):format(vim.api.nvim_win_get_cursor(view_win)[1], vim.api.nvim_buf_line_count(view_buf))
)

-- While a turn streams, the winbar previews the newest assistant message;
-- once the turn is idle, the title comes back.
local function winbar_text()
  return vim.api.nvim_eval_statusline(vim.wo[view_win].winbar, { winid = view_win }).str
end

follow_attachments[sid_focus].on_status("streaming")
follow_attachments[sid_focus].on_update({
  entries = {
    { role = "user", text = "hello" },
    { role = "live", text = "Working on the retry loop\nwith jitter." },
  },
  title = "Focus test",
  last_seq = 7,
})
check(
  "streaming winbar shows the assistant message",
  winbar_text():find("Working on the retry loop", 1, true) ~= nil,
  winbar_text()
)
check("streaming winbar hides the title", winbar_text():find("Focus test", 1, true) == nil, winbar_text())
check("streaming winbar keeps the status", winbar_text():find("streaming", 1, true) ~= nil, winbar_text())

follow_attachments[sid_focus].on_status("idle")
check("idle winbar restores the title", winbar_text():find("Focus test", 1, true) ~= nil, winbar_text())
check("idle winbar drops the preview", winbar_text():find("Working on the retry loop", 1, true) == nil, winbar_text())

follow_attachments[sid_focus].on_status("streaming")
follow_attachments[sid_focus].on_update({
  entries = { { role = "live", text = string.rep("long streaming text ", 40) } },
  title = "Focus test",
  last_seq = 8,
})
check(
  "streaming preview fits the window",
  vim.fn.strdisplaywidth(winbar_text()) <= vim.api.nvim_win_get_width(view_win),
  ("%d > %d"):format(vim.fn.strdisplaywidth(winbar_text()), vim.api.nvim_win_get_width(view_win))
)
check("streaming preview is ellipsized", winbar_text():find("…", 1, true) ~= nil, winbar_text())
follow_attachments[sid_focus].on_status("idle")

-- A prefilled prompt backs the menu's skill entries.
session.prompt = function()
  return { ok = true }
end
chat.prompt(sid_focus, { title = "DSH skill: lesson", initial = "/lesson " })
local prefilled_win = vim.api.nvim_get_current_win()
local prefilled_buf = vim.api.nvim_get_current_buf()
check("prefilled prompt opens in a window", prefilled_win ~= view_win)
check(
  "prefilled prompt contains the initial text",
  table.concat(vim.api.nvim_buf_get_lines(prefilled_buf, 0, -1, false), "\n") == "/lesson ",
  vim.inspect(vim.api.nvim_buf_get_lines(prefilled_buf, 0, -1, false))
)
check("prefilled prompt uses the given title", vim.wo[prefilled_win].winbar:find("DSH skill: lesson", 1, true) ~= nil, vim.wo[prefilled_win].winbar)
vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("q", true, false, true), "x", false)
vim.wait(1000, function()
  return not vim.api.nvim_win_is_valid(prefilled_win)
end, 50)
session.prompt = real_prompt
check("cancelling the prefilled prompt closes it", not vim.api.nvim_win_is_valid(prefilled_win))
check("cancelling the prefilled prompt returns to the view", vim.api.nvim_get_current_win() == view_win)

chat.close(sid_focus)

chat.shutdown()

print(("\n=== %d checks, %d failed ==="):format(checks, failures))
vim.cmd("cquit " .. (failures > 0 and 1 or 0))
