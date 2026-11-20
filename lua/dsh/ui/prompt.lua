--- Prompt input: a floating popup or a scratch buffer in a split window.
---
--- Both surfaces share one lifecycle. `<C-s>` sends from insert and normal
--- mode, normal-mode `<CR>` sends, and normal-mode `q` cancels. The floating
--- popup also cancels on `<Esc>` in either mode, because it is not meant for
--- normal-mode editing; the split window leaves `<Esc>` alone so the prompt can
--- be edited like any other buffer and is only dismissed with `q`.
local M = {}

local config = require("dsh.config")

local namespace = vim.api.nvim_create_namespace("dsh-prompt")
local group = vim.api.nvim_create_augroup("dsh-prompt", { clear = true })

--- Prompt buffers are named `dsh://prompt/<n>`; the counter keeps a second
--- prompt's name unique while the first one is still open.
local counter = 0

local function build_lines(initial)
  local lines = vim.split(initial or "", "\n", { plain = true })
  if #lines == 0 then
    lines = { "" }
  end
  return lines
end

--- Escape a title for the winbar and keep it on one line.
--- @param text string
--- @return string
local function literal(text)
  return (text:gsub("%%", "%%%%"):gsub("[\r\n]", " "))
end

--- Give a prompt buffer its unique `dsh://prompt/<n>` name.
--- @param buf integer
local function name_buffer(buf)
  for _ = 1, 100 do
    counter = counter + 1
    if pcall(vim.api.nvim_buf_set_name, buf, ("dsh://prompt/%d"):format(counter)) then
      return
    end
  end
  -- A user autocmd may be rejecting every name; the name is cosmetic, so an
  -- unnamed prompt buffer is still usable.
end

--- Buffer-local keys for one prompt.
--- @param buf integer
--- @param submit fun()
--- @param cancel fun()
--- @param close_on_escape boolean
local function map_keys(buf, submit, cancel, close_on_escape)
  local function map(mode, lhs, rhs)
    vim.keymap.set(mode, lhs, rhs, { buffer = buf, nowait = true, silent = true })
  end

  map({ "n", "i" }, "<C-s>", submit)
  map("n", "<CR>", submit)
  map("n", "q", cancel)
  if close_on_escape then
    map({ "n", "i" }, "<Esc>", cancel)
  end
end

--- Close a prompt and drop its buffer, returning to the window it came from.
---
--- Idempotent: closing the window or wiping the buffer fires WinClosed /
--- BufWipeout, which call back here for the half that is still alive.
--- @param state {buf: integer, win: integer, origin: integer, closed: boolean}
local function close_prompt(state)
  if state.closed then
    return
  end
  state.closed = true

  if vim.api.nvim_win_is_valid(state.win) then
    -- The last window cannot be closed; buffer cleanup below still runs.
    pcall(vim.api.nvim_win_close, state.win, true)
  end
  if vim.api.nvim_buf_is_valid(state.buf) then
    pcall(vim.api.nvim_buf_delete, state.buf, { force = true })
  end
  if vim.api.nvim_win_is_valid(state.origin) and vim.api.nvim_get_current_win() ~= state.origin then
    pcall(vim.api.nvim_set_current_win, state.origin)
  end
  -- Prompts are typed in insert mode; do not hand that mode back to the window
  -- underneath. A chat buffer is not modifiable, so typing there would fail.
  pcall(vim.cmd, "stopinsert")
end

--- Wire submit/cancel keys and cleanup autocmds for one prompt.
--- @param buf integer
--- @param win integer
--- @param origin integer
--- @param on_submit fun(text: string)
--- @param close_on_escape boolean
local function attach(buf, win, origin, on_submit, close_on_escape)
  local state = { buf = buf, win = win, origin = origin, closed = false }

  local function close()
    close_prompt(state)
  end

  local function submit()
    local text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
    if vim.trim(text) == "" then
      close()
      return
    end
    close()
    on_submit(text)
  end

  map_keys(buf, submit, close, close_on_escape)

  -- `:q`, `:close`, `:bdelete`, `:bwipeout` and friends must not leave a
  -- prompt window or buffer behind. The cleanup is deferred: closing a window
  -- or deleting a buffer from inside its own WinClosed/BufWipeout autocmd can
  -- trip "E937: Attempt to delete a buffer that is in use" (for example when
  -- `:enew` replaces the prompt buffer in its window).
  local function cleanup_later()
    if not state.closed then
      vim.schedule(close)
    end
  end

  vim.api.nvim_create_autocmd("WinClosed", {
    group = group,
    pattern = tostring(win),
    once = true,
    callback = cleanup_later,
  })
  vim.api.nvim_create_autocmd("BufWipeout", {
    group = group,
    buffer = buf,
    once = true,
    callback = cleanup_later,
  })
end

--- Open the centered floating popup (the original prompt surface).
--- @param opts {title: string|nil, initial: string|nil}
--- @param on_submit fun(text: string)
local function open_float(opts, on_submit)
  local width = math.max(40, math.min(math.floor(vim.o.columns * 0.6), 100))
  local height = 5
  local origin = vim.api.nvim_get_current_win()

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, build_lines(opts.initial))
  vim.bo[buf].modifiable = true
  -- Plugin-owned input buffer: never show it in `:ls` or a buffer list.
  vim.bo[buf].buflisted = false

  local row = math.max(1, math.floor((vim.o.lines - height) / 2) - 1)
  local col = math.max(0, math.floor((vim.o.columns - width) / 2))

  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = row,
    col = col,
    style = "minimal",
    border = "rounded",
    title = " " .. (opts.title or "DSH prompt") .. " ",
    title_pos = "center",
  })

  vim.wo[win].winhl = "Normal:NormalFloat,FloatBorder:FloatBorder"
  vim.wo[win].wrap = true
  vim.wo[win].number = false
  vim.api.nvim_buf_add_highlight(buf, namespace, "Comment", 0, 0, -1)

  attach(buf, win, origin, on_submit, true)
  -- A selection prefix can span several lines: type after it, not into it.
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  vim.api.nvim_win_set_cursor(win, { #lines, #(lines[#lines] or "") })
  vim.cmd("startinsert!")
end

--- Split a window and return the new one.
---
--- A prompt opened from `:DshQuickChat` belongs beside the session view that
--- opened it, so it splits that window instead of taking a full-height (or
--- full-width) edge of the editor. `'splitright'`/`'splitbelow'` place the new
--- window and are restored afterwards; without an anchor the historical edge
--- split is kept, and a failed anchored split falls back to it.
--- @param anchor integer|nil window to split
--- @param vertical boolean
--- @return integer win
local function split_window(anchor, vertical)
  local function edge()
    vim.cmd(vertical and "botright vsplit" or "botright split")
    return vim.api.nvim_get_current_win()
  end

  if not (anchor and vim.api.nvim_win_is_valid(anchor)) then
    return edge()
  end

  local splitright, splitbelow = vim.o.splitright, vim.o.splitbelow
  vim.o.splitright, vim.o.splitbelow = true, true
  local ok, win = pcall(function()
    local created
    vim.api.nvim_win_call(anchor, function()
      vim.cmd(vertical and "vsplit" or "split")
      created = vim.api.nvim_get_current_win()
    end)
    return created
  end)
  vim.o.splitright, vim.o.splitbelow = splitright, splitbelow

  if not ok or not (win and vim.api.nvim_win_is_valid(win)) then
    return edge()
  end
  return win
end

--- Open the prompt as a named scratch buffer in its own split window.
---
--- `opts.split`, `opts.width` and `opts.height` override `prompt.open_in =
--- "split"` settings for one call, and `opts.anchor` is the window the prompt
--- splits (the session view, for `:DshQuickChat`).
--- @param opts {title: string|nil, initial: string|nil, split: string|nil, width: integer|nil, height: integer|nil, anchor: integer|nil}
--- @param on_submit fun(text: string)
local function open_split(opts, on_submit)
  local settings = config.options.prompt or config.defaults.prompt
  local defaults = config.defaults.prompt
  local vertical = (opts.split or settings.split or defaults.split) == "vertical"
  local origin = vim.api.nvim_get_current_win()

  -- Keep the window inside the editor even if the configured size is huge.
  local width = tonumber(opts.width) or settings.width or defaults.width
  local height = tonumber(opts.height) or settings.height or defaults.height
  width = math.max(10, math.min(width, math.max(10, vim.o.columns - 10)))
  height = math.max(3, math.min(height, math.max(3, vim.o.lines - 6)))

  local buf = vim.api.nvim_create_buf(true, false)
  name_buffer(buf)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, build_lines(opts.initial))
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].modifiable = true
  -- Plugin-owned input buffer: never show it in `:ls` or a buffer list.
  vim.bo[buf].buflisted = false
  -- A hook for user settings such as `autocmd FileType dsh-prompt setlocal spell`.
  vim.bo[buf].filetype = "dsh-prompt"

  local win = split_window(opts.anchor, vertical)
  vim.api.nvim_win_set_buf(win, buf)
  vim.api.nvim_set_current_win(win)
  if vertical then
    pcall(vim.api.nvim_win_set_width, win, width)
  else
    pcall(vim.api.nvim_win_set_height, win, height)
  end

  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].signcolumn = "no"
  vim.wo[win].foldcolumn = "0"
  vim.wo[win].wrap = true
  vim.wo[win].linebreak = true
  vim.wo[win].winbar = (" %s   <C-s> send   q cancel "):format(literal(opts.title or "DSH prompt"))

  attach(buf, win, origin, on_submit, false)

  -- Start at the end of the initial text, ready to type.
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  vim.api.nvim_win_set_cursor(win, { #lines, #(lines[#lines] or "") })
  vim.cmd("startinsert!")
end

--- Open a prompt. Submits on `<C-s>` / normal-mode `<CR>`, cancels on `q`; the
--- floating popup also cancels on `<Esc>`.
---
--- `prompt.open_in = "float"` (default) uses the centered popup;
--- `"split"` opens the scratch buffer in its own window. A call may override
--- the surface per invocation: `opts.split` ("vertical" or "horizontal")
--- forces the split window with `opts.width`/`opts.height`, and `opts.anchor`
--- is the window it splits instead of the editor edge.
--- @param opts {title: string|nil, initial: string|nil, split: string|nil, width: integer|nil, height: integer|nil, anchor: integer|nil}
--- @param on_submit fun(text: string)
function M.open(opts, on_submit)
  opts = opts or {}
  local settings = config.options.prompt or config.defaults.prompt
  if opts.split or settings.open_in == "split" then
    open_split(opts, on_submit)
  else
    open_float(opts, on_submit)
  end
end

return M
