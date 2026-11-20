--- Quick chat: one command for "new session, session view, prompt".
---
--- `:DshQuickChat` composes a new Session in a chosen Agent mode, opens its
--- view in one split, and opens the prompt in a second split beside it. The
--- Visual selection that was active when the command ran is copied into the
--- prompt together with its file name and line range, so the first message can
--- be "look at this" without copying anything by hand.
---
--- The layout lives in `quick_chat.chat` (session view) and `quick_chat.prompt`
--- (prompt); both default to what the command is for — a horizontal split for
--- the session view and a vertical split of that same window for the prompt —
--- so code, conversation and the input line stay on screen together.
local M = {}

local config = require("dsh.config")
local chat = require("dsh.ui.chat")

--- Prompt text for one captured selection.
---
--- The reference line names the file and the line range; the fenced block
--- keeps the selection's filetype so the Agent (and the rendering) sees it as
--- code. A selection longer than `settings.max_lines` is cut and the prompt
--- says how much was dropped.
--- @param selection {lines: string[], path: string|nil, filetype: string|nil, first: integer, last: integer}
--- @param settings {enabled: boolean|nil, max_lines: integer|nil, reference: boolean|nil}|nil
--- @return string
function M.prompt_text(selection, settings)
  settings = type(settings) == "table" and settings or {}
  if settings.max_lines == nil then
    local defaults = (config.defaults.quick_chat or {}).selection or {}
    settings = vim.tbl_extend("keep", settings, defaults)
  end

  local lines = selection.lines
  local dropped = 0
  local max_lines = tonumber(settings.max_lines) or 0
  if max_lines > 0 and #lines > max_lines then
    dropped = #lines - max_lines
    lines = vim.list_slice(lines, 1, max_lines)
  end

  local parts = {}
  if settings.reference ~= false then
    if selection.path then
      parts[#parts + 1] = ("%s (lines %d-%d):"):format(selection.path, selection.first, selection.last)
    else
      parts[#parts + 1] = ("lines %d-%d:"):format(selection.first, selection.last)
    end
  end
  -- A selection that already contains a fence (Markdown, a transcript) needs a
  -- longer fence of its own, or the block would end in the middle of it.
  local fence = "```"
  for _, line in ipairs(lines) do
    if line:find("```", 1, true) then
      fence = "````"
      break
    end
  end
  parts[#parts + 1] = fence .. (selection.filetype or "")
  vim.list_extend(parts, lines)
  parts[#parts + 1] = fence
  if dropped > 0 then
    parts[#parts + 1] = ("[%d more line%s of the selection %s not copied]"):format(
      dropped,
      dropped == 1 and "" or "s",
      dropped == 1 and "was" or "were"
    )
  end
  return table.concat(parts, "\n")
end

--- Path shown above a copied selection: relative to Neovim's cwd when it is
--- under it, `~/...` when it is under the home directory, absolute otherwise.
--- @param buf integer
--- @return string|nil
local function buffer_path(buf)
  local name = vim.api.nvim_buf_get_name(buf)
  if type(name) ~= "string" or name == "" then
    return nil
  end
  local path = vim.fn.fnamemodify(name, ":~:.")
  return type(path) == "string" and path ~= "" and path or nil
end

--- Selection type for `getregion`.
---
--- `visualmode()` is the authority on charwise/linewise/blockwise. It is empty
--- when `'<` and `'>` were set by a script rather than a Visual mode, so the
--- marks decide then: a linewise selection ends with column `v:maxcol`.
--- @param first integer[] `'<` position
--- @param last integer[] `'>` position
--- @return string "v", "V" or blockwise
local function selection_mode(first, last)
  local mode = vim.fn.visualmode()
  if mode == "v" or mode == "V" or mode == "\22" then
    return mode
  end
  if first[3] == vim.v.maxcol or last[3] == vim.v.maxcol then
    return "V"
  end
  return "v"
end

--- The Visual selection that was active in the current buffer, if any.
---
--- The `'<` and `'>` marks are buffer-local and are set when Visual mode ends,
--- which the `:` opening the command line already does. `:'<,'>DshQuickChat`,
--- a `<C-u>` mapping, and a plain `:DshQuickChat` after leaving Visual mode
--- therefore all see the same selection, and a buffer that never had one
--- reports none. Only the current buffer is read: run the command from the
--- buffer holding the selection.
--- @return {lines: string[], path: string|nil, filetype: string|nil, first: integer, last: integer}|nil
function M.selection()
  local buf = vim.api.nvim_get_current_buf()
  local first, last = vim.fn.getpos("'<"), vim.fn.getpos("'>")
  -- Unset marks read as lnum 0 (and an unset mark in this buffer is all zeros).
  if first[2] < 1 or last[2] < 1 or #first < 4 or #last < 4 then
    return nil
  end
  if first[1] ~= 0 and first[1] ~= buf then
    return nil
  end

  local ok, lines = pcall(vim.fn.getregion, first, last, { type = selection_mode(first, last) })
  if not ok or type(lines) ~= "table" or #lines == 0 then
    return nil
  end

  local filetype = vim.bo[buf].filetype
  return {
    lines = lines,
    path = buffer_path(buf),
    filetype = type(filetype) == "string" and filetype ~= "" and filetype or nil,
    first = math.min(first[2], last[2]),
    last = math.max(first[2], last[2]),
  }
end

--- Prompt text for the current buffer's Visual selection, if there was one.
--- @param settings table|nil `quick_chat.selection` options
--- @return string|nil
function M.prefill(settings)
  local selection = M.selection()
  if not selection then
    return nil
  end
  -- Selecting only blank lines would prefill the prompt with an empty fence.
  local meaningful = false
  for _, line in ipairs(selection.lines) do
    if vim.trim(line) ~= "" then
      meaningful = true
      break
    end
  end
  if not meaningful then
    return nil
  end
  return M.prompt_text(selection, settings)
end

--- Start a quick chat: new Session, its view in one split, prompt in another.
--- @param opts {mode: string|nil}|nil Agent preset id for this call, overriding `quick_chat.mode`
function M.open(opts)
  opts = type(opts) == "table" and opts or {}
  local settings = config.options.quick_chat or config.defaults.quick_chat
  local defaults = config.defaults.quick_chat

  local mode = opts.mode
  if type(mode) ~= "string" or vim.trim(mode) == "" then
    mode = settings.mode
  end
  mode = type(mode) == "string" and vim.trim(mode) or ""

  -- Read the marks before anything moves: they belong to the buffer the
  -- command ran from, and a slow server boot must not lose them. A session
  -- view that fails to open then leaves no half-filled prompt behind.
  local initial
  local selection_settings = settings.selection or defaults.selection
  if selection_settings.enabled ~= false then
    initial = M.prefill(selection_settings)
  end

  local layout = settings.chat or defaults.chat
  local surface = settings.prompt or defaults.prompt
  chat.new_session({
    mode = mode ~= "" and mode or nil,
    layout = { split = layout.split, width = layout.width, height = layout.height },
    prompt = {
      initial = initial,
      split = surface.split,
      width = surface.width,
      height = surface.height,
      anchor = "view",
    },
  })
end

return M
