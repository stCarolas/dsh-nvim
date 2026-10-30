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
package.loaded["dsh.follow"] = {
  attach = function()
    return { detach = function() end, state = {} }
  end,
}
package.loaded["dsh.mux"] = {
  close = function() end,
  is_connected = function()
    return false
  end,
}

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
check("no throwaway buffer", opened.bufs == before.bufs + 1, ("%d -> %d"):format(before.bufs, opened.bufs))
check("session tab is current", vim.api.nvim_get_current_tabpage() ~= origin_tab)

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

chat.shutdown()

print(("\n=== %d checks, %d failed ==="):format(checks, failures))
vim.cmd("cquit " .. (failures > 0 and 1 or 0))
