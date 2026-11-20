--- Transcript search front end.
---
--- `dsh.transcript` produces the rows; this module labels them, then hands the
--- list to Telescope when it is installed and to `vim.ui.select` otherwise (so
--- telescope-ui-select, fzf-lua, snacks or a plain prompt all work). Selecting
--- a row puts the cursor on the message in the session buffer.
local config = require("dsh.config")
local transcript = require("dsh.transcript")

local M = {}

--- Row prefix per entry kind.
local LABELS = {
  title = "title",
  prompt = "You",
  reply = "Assistant",
  tool = "tool",
  error = "error",
  notice = "notice",
}

--- Longest message snippet kept in a row (the match text keeps everything).
local SNIPPET_WIDTH = 96

M.scopes = transcript.scopes

--- Row label and fuzzy-match text for an entry.
---
--- The label shows the kind and the start of the message; the match text is
--- the whole message flattened to one line, so `/retry.ts` finds a reply that
--- mentions the file five lines in.
---
--- @param item {kind: string, text: string}
--- @return string display, string ordinal
function M.format(item)
  local label = LABELS[item.kind] or item.kind
  local text = (item.text:gsub("%s+", " "))
  local snippet = text
  if vim.fn.strchars(snippet) > SNIPPET_WIDTH then
    snippet = vim.fn.strcharpart(snippet, 0, SNIPPET_WIDTH) .. "…"
  end
  return ("%-9s %s"):format(label, snippet), ("%s %s"):format(label, text)
end

--- Picker rows for a transcript: entries plus display and match text.
--- @param bufnr integer
--- @param scope string|nil
--- @return table[]
function M.rows(bufnr, scope)
  local rows = transcript.entries(bufnr, scope)
  for _, item in ipairs(rows) do
    item.display, item.ordinal = M.format(item)
    item.bufnr = bufnr
  end
  return rows
end

--- The session buffer to search.
---
--- The session under the cursor wins; from a prompt or another buffer, the
--- session view in this tab is used, then the first open session buffer.
--- @return integer|nil
function M.target_bufnr()
  local function is_session(buf)
    return vim.api.nvim_buf_is_valid(buf) and vim.bo[buf].filetype == "dshchat"
  end

  local current = vim.api.nvim_get_current_buf()
  if is_session(current) then
    return current
  end
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local buf = vim.api.nvim_win_get_buf(win)
    if is_session(buf) then
      return buf
    end
  end
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if is_session(buf) then
      return buf
    end
  end
  return nil
end

--- Put the cursor on an entry's line.
--- @param item table|nil row from `M.rows`
function M.jump(item)
  if not item or not item.bufnr or not vim.api.nvim_buf_is_valid(item.bufnr) then
    return
  end
  local win = vim.fn.bufwinid(item.bufnr)
  if win == -1 then
    win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(win, item.bufnr)
  end
  vim.api.nvim_set_current_win(win)
  local lines = vim.api.nvim_buf_line_count(item.bufnr)
  local lnum = math.max(1, math.min(item.lnum + 1, lines))
  vim.api.nvim_win_set_cursor(win, { lnum, 0 })
  vim.cmd("normal! zz")
end

--- Whether Telescope can render the picker.
--- @return boolean
local function has_telescope()
  return (pcall(require, "telescope"))
end

--- Open the Telescope picker. Returns false when it refused the picker, so the
--- caller can fall back to `vim.ui.select`.
--- @param rows table[]
--- @param opts table|nil
--- @param title string
--- @return boolean opened
local function with_telescope(rows, opts, title)
  local ok, err = pcall(function()
    local pickers = require("telescope.pickers")
    local finders = require("telescope.finders")
    local conf = require("telescope.config").values
    local actions = require("telescope.actions")
    local action_state = require("telescope.actions.state")

    pickers.new(opts.telescope or {}, {
      prompt_title = title,
      finder = finders.new_table({
        results = rows,
        entry_maker = function(item)
          return {
            value = item,
            display = item.display,
            ordinal = item.ordinal,
            lnum = item.lnum + 1,
          }
        end,
      }),
      sorter = conf.generic_sorter({}),
      attach_mappings = function(prompt_bufnr)
        actions.select_default:replace(function()
          local selection = action_state.get_selected_entry()
          actions.close(prompt_bufnr)
          if selection then
            M.jump(selection.value)
          end
        end)
        return true
      end,
    }):find()
  end)
  if not ok and config.options.notifications then
    vim.notify(("dsh: telescope picker failed: %s"):format(err), vim.log.levels.WARN)
  end
  return ok
end

--- Search the session transcript.
---
--- @param opts {scope: string|nil, telescope: table|nil}|nil
function M.open(opts)
  opts = opts or {}

  local bufnr = M.target_bufnr()
  if not bufnr then
    if config.options.notifications then
      vim.notify("dsh: no session buffer to search", vim.log.levels.WARN)
    end
    return
  end

  local defaults = config.options.search or {}
  local scope = opts.scope or defaults.scope or "all"
  local rows = M.rows(bufnr, scope)
  if #rows == 0 then
    if config.options.notifications then
      vim.notify(("dsh: no %s to search in this transcript"):format(scope == "all" and "messages" or scope))
    end
    return
  end

  local title = ("DSH transcript (%s)"):format(scope)
  if has_telescope() and with_telescope(rows, opts, title) then
    return
  end

  vim.ui.select(rows, {
    prompt = title,
    format_item = function(item)
      return item.display
    end,
  }, function(choice)
    if choice then
      M.jump(choice)
    end
  end)
end

return M
