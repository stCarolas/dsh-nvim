--- Chat buffer rendering: entries to styled lines.
---
--- Assistant text is Markdown, so it goes through `dsh.markdown` for structure and
--- inline styling, while chat chrome (message headers, tool calls) keeps its own
--- highlight groups. Spans are applied as extmarks so each line can mix styles.
local M = {}

local config = require("dsh.config")
local markdown = require("dsh.markdown")

local namespace = vim.api.nvim_create_namespace("dsh-chat")

local BASE_PRIORITY = 4096
local SPAN_PRIORITY = 4100

--- Default highlight groups.
function M.define_highlights()
  local groups = {
    DshUser = { default = true, link = "Directory" },
    DshUserHeader = { default = true, link = "Directory" },
    DshAssistantHeader = { default = true, link = "Title" },
    DshTool = { default = true, link = "Comment" },
    DshToolError = { default = true, link = "DiagnosticError" },
    DshError = { default = true, link = "DiagnosticError" },
    DshNotice = { default = true, link = "DiagnosticInfo" },
    DshTitle = { default = true, link = "Title" },

    DshH1 = { default = true, link = "Title", bold = true },
    DshH2 = { default = true, link = "Title", bold = true },
    DshH3 = { default = true, link = "Function", bold = true },
    DshH4 = { default = true, link = "Function" },
    DshH5 = { default = true, link = "Identifier" },
    DshH6 = { default = true, link = "Identifier" },
    DshBold = { default = true, bold = true },
    DshItalic = { default = true, italic = true },
    DshStrike = { default = true, strikethrough = true },
    DshCode = { default = true, link = "Constant" },
    DshCodeBlock = { default = true, link = "NormalFloat" },
    DshCodeLang = { default = true, link = "Comment" },
    DshLink = { default = true, link = "Underlined" },
    DshQuote = { default = true, link = "Comment" },
    DshBullet = { default = true, link = "Special" },
    DshHr = { default = true, link = "Comment" },
  }
  for name, spec in pairs(groups) do
    vim.api.nvim_set_hl(0, name, spec)
  end
end

--- Split text into lines, dropping a trailing blank line.
local function lines_of(text)
  local out = vim.split(text or "", "\n", { plain = true })
  while #out > 0 and out[#out]:match("^%s*$") do
    table.remove(out)
  end
  return out
end

--- Append rendered Markdown to the composition state.
local function push_markdown(state, text)
  local md = markdown.render(text, {
    code_highlight = config.options.markdown.code_highlight,
    show_language = config.options.markdown.show_language,
    max_highlight_lines = config.options.markdown.max_highlight_lines,
  })

  local spans_by_row, virt_by_row = {}, {}
  for _, span in ipairs(md.spans) do
    spans_by_row[span.row] = spans_by_row[span.row] or {}
    table.insert(spans_by_row[span.row], span)
  end
  for _, item in ipairs(md.virt) do
    virt_by_row[item.row] = virt_by_row[item.row] or {}
    table.insert(virt_by_row[item.row], item)
  end

  for index, line in ipairs(md.lines) do
    local row = state.push(line, md.groups[index])
    for _, span in ipairs(spans_by_row[index] or {}) do
      state.spans[#state.spans + 1] = {
        row = row,
        start_col = span.start_col,
        end_col = span.end_col,
        group = span.group,
      }
    end
    for _, item in ipairs(virt_by_row[index] or {}) do
      state.virt[#state.virt + 1] = { row = row, col = item.col, text = item.text, group = item.group }
    end
  end
end

--- Render entries into lines, per-line highlight groups, and styled spans.
--- @param entries table[]
--- @return {lines: string[], hl: string[], spans: table[], virt: table[]}
function M.compose(entries)
  local state = { lines = {}, hl = {}, spans = {}, virt = {} }

  --- Append one line and return its row.
  function state.push(text, group)
    -- A nil group would not advance a Lua sequence and would shift every later
    -- highlight, so absent groups are stored as an empty string.
    state.lines[#state.lines + 1] = text
    state.hl[#state.hl + 1] = group or ""
    return #state.lines
  end

  local function blank()
    if #state.lines > 0 and state.lines[#state.lines] ~= "" then
      state.push("", nil)
    end
  end

  local use_markdown = config.options.markdown.enabled

  for _, entry in ipairs(entries) do
    if entry.role == "title" then
      state.push("# " .. entry.text, "DshTitle")
    elseif entry.role == "user" then
      blank()
      state.push("▌ You", "DshUserHeader")
      -- Prompts are echoed literally: Markdown syntax there is the user's text.
      for _, line in ipairs(lines_of(entry.text)) do
        state.push(line, "DshUser")
      end
    elseif entry.role == "assistant" then
      blank()
      local header = "▌ Assistant"
      if entry.interrupted then
        header = header .. "  (interrupted)"
      end
      state.push(header, "DshAssistantHeader")
      local body = entry.text or ""
      if vim.trim(body) == "" then
        state.push("(no text)", nil)
      elseif use_markdown then
        push_markdown(state, body)
      else
        for _, line in ipairs(lines_of(body)) do
          state.push(line, nil)
        end
      end
    elseif entry.role == "live" then
      blank()
      state.push("▌ Assistant", "DshAssistantHeader")
      if entry.reasoning and entry.reasoning ~= "" then
        for _, line in ipairs(lines_of(entry.reasoning)) do
          state.push(line, "DshTool")
        end
      end
      local body = entry.text or ""
      if vim.trim(body) == "" then
        state.push("▍", nil)
      elseif use_markdown then
        push_markdown(state, body)
        state.lines[#state.lines] = (state.lines[#state.lines] or "") .. "▍"
      else
        for _, line in ipairs(lines_of(body)) do
          state.push(line, nil)
        end
        state.lines[#state.lines] = (state.lines[#state.lines] or "") .. "▍"
      end
    elseif entry.role == "tool" then
      local call = entry.text ~= "" and ("%s(%s)"):format(entry.name or "tool", entry.text) or (entry.name or "tool")
      state.push("  ⚙ " .. call, "DshTool")
    elseif entry.role == "tool_result" then
      local body = lines_of(entry.text)
      local limit = config.options.tool_output_lines
      local group = entry.is_error and "DshToolError" or "DshTool"
      if #body == 0 then
        state.push("  ↳ (empty)", group)
      else
        for index, line in ipairs(body) do
          if index > limit then
            state.push(("  ↳ … %d more lines"):format(#body - limit), group)
            break
          end
          state.push("  ↳ " .. line, group)
        end
      end
    elseif entry.role == "error" then
      blank()
      state.push("✖ " .. entry.text, "DshError")
    elseif entry.role == "notice" then
      state.push("· " .. entry.text, "DshNotice")
    end
  end

  if #state.lines == 0 then
    state.lines = { "No messages yet — press <CR> to send a prompt." }
    state.hl = { "DshNotice" }
  end

  return { lines = state.lines, hl = state.hl, spans = state.spans, virt = state.virt }
end

--- Replace the buffer with the composed view.
--- @param buf number
--- @param entries table[]
--- @param win number|nil
function M.render(buf, entries, win)
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end

  local composed = M.compose(entries)
  local lines = composed.lines

  local at_bottom = true
  if win and vim.api.nvim_win_is_valid(win) then
    local cursor = vim.api.nvim_win_get_cursor(win)
    at_bottom = cursor[1] >= vim.api.nvim_buf_line_count(buf)
  end

  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_buf_clear_namespace(buf, namespace, 0, -1)

  -- Base group per line, coalescing consecutive equal groups into one extmark.
  local index = 1
  while index <= #lines do
    local group = composed.hl[index]
    if group and group ~= "" then
      local finish = index
      while finish + 1 <= #lines and composed.hl[finish + 1] == group do
        finish = finish + 1
      end
      vim.api.nvim_buf_set_extmark(buf, namespace, index - 1, 0, {
        end_row = finish,
        end_col = 0,
        hl_group = group,
        priority = BASE_PRIORITY,
      })
      index = finish + 1
    else
      index = index + 1
    end
  end

  -- Inline spans on top of the line group.
  for _, span in ipairs(composed.spans) do
    if span.end_col > span.start_col and span.row >= 1 and span.row <= #lines then
      vim.api.nvim_buf_set_extmark(buf, namespace, span.row - 1, span.start_col, {
        end_col = span.end_col,
        hl_group = span.group,
        priority = SPAN_PRIORITY,
      })
    end
  end

  -- Virtual text (e.g. a fence language) never enters the buffer contents.
  for _, item in ipairs(composed.virt) do
    if item.row >= 1 and item.row <= #lines then
      vim.api.nvim_buf_set_extmark(buf, namespace, item.row - 1, math.min(item.col, #(lines[item.row] or "")), {
        virt_text = { { item.text, item.group } },
        virt_text_pos = "eol",
      })
    end
  end

  vim.bo[buf].modifiable = false

  if win and vim.api.nvim_win_is_valid(win) and at_bottom then
    vim.api.nvim_win_set_cursor(win, { #lines, 0 })
  end
end

--- Window bar describing the session.
--- @param title string|nil
--- @param status string|nil
function M.winbar(title, status)
  local name = (title and title ~= "") and title or "untitled"
  if status and status ~= "" then
    return (" dsh · %s · %s "):format(name, status)
  end
  return (" dsh · %s "):format(name)
end

return M
