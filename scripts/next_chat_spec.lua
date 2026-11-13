-- :DshNextChat specs: cycling open session views and the non-chat fallback.
-- Run with: nvim --headless -l scripts/next_chat_spec.lua
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
-- Stubs: transports only; view orchestration and command wiring are real.
--------------------------------------------------------------------------------
package.loaded["dsh.server"] = {
  context = function(callback)
    callback(nil, { url = "http://test", cookie = "cookie", mint = function()
      return "minted"
    end })
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
}

local chat = require("dsh.ui.chat")
local dsh = require("dsh")

vim.cmd("runtime plugin/dsh.lua")
check("DshNextChat command is registered", vim.fn.exists(":DshNextChat") == 2)

local ids = {
  "session-aaaaaaaa-1111-1111-1111-111111111111",
  "session-bbbbbbbb-2222-2222-2222-222222222222",
  "session-cccccccc-3333-3333-3333-333333333333",
}
local opened = {}
for index, session_id in ipairs(ids) do
  chat.open(session_id, { title = "Chat " .. index })
  opened[index] = {
    session_id = session_id,
    buf = vim.api.nvim_get_current_buf(),
    win = vim.api.nvim_get_current_win(),
  }
end
check("three session views are tracked", chat.view_count() == 3, tostring(chat.view_count()))

--------------------------------------------------------------------------------
-- 1. The cycle follows buffer number order and wraps around.
--------------------------------------------------------------------------------
vim.api.nvim_set_current_win(opened[1].win)
check("starting on the first view", vim.api.nvim_get_current_buf() == opened[1].buf)

vim.cmd("DshNextChat")
check("next chat goes to the second view", vim.api.nvim_get_current_buf() == opened[2].buf, vim.api.nvim_buf_get_name(0))

vim.cmd("DshNextChat")
check("next chat goes to the third view", vim.api.nvim_get_current_buf() == opened[3].buf, vim.api.nvim_buf_get_name(0))

vim.cmd("DshNextChat")
check("next chat wraps to the first view", vim.api.nvim_get_current_buf() == opened[1].buf, vim.api.nvim_buf_get_name(0))

--------------------------------------------------------------------------------
-- 2. A view whose window now shows another buffer is restored, not merely
--    focused on the foreign buffer.
--------------------------------------------------------------------------------
local scratch = vim.api.nvim_create_buf(true, false)
vim.api.nvim_win_set_buf(opened[3].win, scratch)
vim.api.nvim_set_current_win(opened[2].win)
check("the third view's window was reused", vim.api.nvim_win_get_buf(opened[3].win) == scratch)

vim.cmd("DshNextChat")
check("the next view restores its buffer in the reused window", vim.api.nvim_get_current_buf() == opened[3].buf, vim.api.nvim_buf_get_name(0))
check("the reused window is the one focused", vim.api.nvim_get_current_win() == opened[3].win)

--------------------------------------------------------------------------------
-- 3. From a non-chat buffer the command starts a new session with a prompt.
--------------------------------------------------------------------------------
local real_new_session = chat.new_session
local created
chat.new_session = function(opts)
  created = opts
end

vim.cmd("enew")
check("left the session views", chat.current() == nil)
vim.cmd("DshNextChat")
check(
  "a non-chat buffer creates a session",
  type(created) == "table" and created.prompt == true,
  vim.inspect(created)
)

chat.new_session = real_new_session

--------------------------------------------------------------------------------
-- 4. With a single view, the cycle goes back to that view.
--------------------------------------------------------------------------------
chat.close(ids[2])
chat.close(ids[3])
vim.api.nvim_set_current_win(opened[1].win)
vim.api.nvim_set_current_buf(opened[1].buf)
check("one view remains", chat.view_count() == 1, tostring(chat.view_count()))

vim.cmd("DshNextChat")
check("a single view wraps to itself", vim.api.nvim_get_current_buf() == opened[1].buf, vim.api.nvim_buf_get_name(0))

chat.close(ids[1])
if vim.api.nvim_buf_is_valid(scratch) then
  vim.api.nvim_buf_delete(scratch, { force = true })
end
check("closing every view empties the cycle", chat.view_count() == 0, tostring(chat.view_count()))

--------------------------------------------------------------------------------
-- 5. keymaps.global.next_chat installs a mapping for the same action.
--------------------------------------------------------------------------------
dsh.setup({
  notifications = false,
  treesitter = false,
  chat = { open_in = "split", split = "vertical" },
  keymaps = { global = { next_chat = "<F11>" } },
})
local mapping = vim.fn.maparg("<F11>", "n", false, true)
check("global next_chat mapping is installed", vim.fn.maparg("<F11>", "n") ~= "", vim.inspect(mapping))
check("mapping carries a Lua callback", type(mapping) == "table" and type(mapping.callback) == "function", vim.inspect(mapping))

--------------------------------------------------------------------------------
-- 6. With `chat.open_in = "tab"`, the cycle switches tab pages.
--------------------------------------------------------------------------------
dsh.setup({
  notifications = false,
  treesitter = false,
  chat = { open_in = "tab" },
})
local tab_a = "session-dddddddd-4444-4444-4444-444444444444"
local tab_b = "session-eeeeeeee-5555-5555-5555-555555555555"
chat.open(tab_a)
local tab_buf_a = vim.api.nvim_get_current_buf()
local page_a = vim.api.nvim_get_current_tabpage()
chat.open(tab_b)
local tab_buf_b = vim.api.nvim_get_current_buf()
local page_b = vim.api.nvim_get_current_tabpage()

vim.api.nvim_set_current_tabpage(page_a)
vim.cmd("DshNextChat")
check(
  "next chat switches to the next tab",
  vim.api.nvim_get_current_tabpage() == page_b and vim.api.nvim_get_current_buf() == tab_buf_b,
  vim.api.nvim_buf_get_name(0)
)
vim.cmd("DshNextChat")
check(
  "next chat wraps tab pages",
  vim.api.nvim_get_current_tabpage() == page_a and vim.api.nvim_get_current_buf() == tab_buf_a,
  vim.api.nvim_buf_get_name(0)
)

chat.close(tab_a)
chat.close(tab_b)

chat.shutdown()

print(("\n=== %d checks, %d failed ==="):format(checks, failures))
vim.cmd("cquit " .. (failures > 0 and 1 or 0))
