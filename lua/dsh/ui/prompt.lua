--- Floating prompt input.
local M = {}

local namespace = vim.api.nvim_create_namespace("dsh-prompt")

local function build_lines(initial)
  local lines = vim.split(initial or "", "\n", { plain = true })
  if #lines == 0 then
    lines = { "" }
  end
  return lines
end

--- Open a centered floating prompt. Submits on <C-s>, cancels on <Esc>.
--- @param opts {title: string|nil, initial: string|nil, on_submit: fun(text: string)}
function M.open(opts, on_submit)
  local width = math.max(40, math.min(math.floor(vim.o.columns * 0.6), 100))
  local height = 5

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, build_lines(opts.initial))
  vim.bo[buf].modifiable = true

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

  local closed = false

  local function close()
    if closed then
      return
    end
    closed = true
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
    if vim.api.nvim_buf_is_valid(buf) then
      vim.api.nvim_buf_delete(buf, { force = true })
    end
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

  local function map(mode, lhs, rhs)
    vim.keymap.set(mode, lhs, rhs, { buffer = buf, nowait = true, silent = true })
  end

  map({ "n", "i" }, "<C-s>", submit)
  map("n", "<CR>", submit)
  map({ "n", "i" }, "<Esc>", close)
  map("n", "q", close)

  vim.cmd("startinsert!")
end

return M
