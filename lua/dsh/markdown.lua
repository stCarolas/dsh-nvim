--- Markdown renderer for agent output.
---
--- DSH answers in Markdown, so rendering it as raw text wastes the buffer. This
--- module turns one Markdown message into presentation lines plus styled spans:
--- headings, lists, quotes, rules, fenced code, and inline emphasis. It depends on
--- nothing beyond Neovim; fenced code is highlighted with treesitter when a parser
--- for that language happens to be installed.
local M = {}

--- Group used for inline code and for fenced blocks respectively.
local INLINE_CODE = "DshCode"
local BLOCK_CODE = "DshCodeBlock"
local LINK = "DshLink"
local BOLD = "DshBold"
local ITALIC = "DshItalic"
local STRIKE = "DshStrike"
local BULLET = "DshBullet"

--- Bytes that can start an inline construct.
local SPECIAL = "[`!<*_~\\[]"

--- Length in bytes of the UTF-8 character whose first byte is `byte`.
--- @param byte integer
--- @return integer
local function utf8_size(byte)
  if byte >= 0xF0 then
    return 4
  elseif byte >= 0xE0 then
    return 3
  elseif byte >= 0xC0 then
    return 2
  end
  return 1
end

--- Parse inline Markdown, appending spans with absolute rows.
---
--- The scan is linear: patterns are anchored and given an init index instead of
--- re-slicing the remaining text at every byte, and a run of plain characters is
--- emitted in one slice. The previous version copied the whole suffix per byte,
--- which made rendering quadratic in message size.
--- @param text string
--- @param row number 1-based row the rendered text lands on
--- @param offset number column where the text starts (after any prefix)
--- @param spans table[] accumulator of {row, start_col, end_col, group}
--- @return string rendered text
local function inline(text, row, offset, spans)
  local out = {}
  local col = offset
  local index = 1
  local length = #text

  -- Link and image syntax needs a "]( " somewhere. Without that literal, the
  -- lazy scans below would backtrack over the whole remainder at every "[",
  -- which a bracketed message turns quadratic.
  local may_link = text:find("](", 1, true) ~= nil

  local function emit(chunk, group)
    if chunk == "" then
      return
    end
    out[#out + 1] = chunk
    if group then
      spans[#spans + 1] = { row = row, start_col = col, end_col = col + #chunk, group = group }
    end
    col = col + #chunk
  end

  while index <= length do
    local consumed, chunk, group
    local char = text:sub(index, index)

    -- An anchored pattern with an init index tries only at that index, so
    -- `finish - index + 1` is exactly the number of bytes consumed. A trailing
    -- `()` position capture must not be used here: it is a 1-based "one past
    -- the end" index, so treating it as a length skips the byte after each run
    -- — the space (or comma, or letter) that follows inline code, emphasis or
    -- a link.
    if char == "`" then
      local _, finish, code = text:find("^`([^`]+)`", index)
      if finish then
        consumed, chunk, group = finish - index + 1, code, INLINE_CODE
      end
    elseif may_link and char == "[" then
      local _, finish, label, target = text:find("^%[(.-)%]%((.-)%)", index)
      if finish then
        consumed, chunk, group = finish - index + 1, label ~= "" and label or target, LINK
      end
    elseif may_link and char == "!" and text:sub(index + 1, index + 1) == "[" then
      local _, finish, alt = text:find("^!%[(.-)%]%((.-)%)", index)
      if finish then
        consumed, chunk, group = finish - index + 1, alt ~= "" and alt or "image", LINK
      end
    elseif char == "<" then
      local _, finish, auto = text:find("^<(https?://[^>]+)>", index)
      if finish then
        consumed, chunk, group = finish - index + 1, auto, LINK
      end
    elseif char == "*" or char == "_" then
      local _, finish, bold
      if char == "*" then
        _, finish, bold = text:find("^%*%*(.-)%*%*", index)
      end
      if not finish then
        _, finish, bold = text:find("^__(.-)__", index)
      end
      if finish then
        consumed, chunk, group = finish - index + 1, bold, BOLD
      elseif char == "*" then
        local _, italic_finish, italic = text:find("^%*(.-)%*", index)
        if italic_finish then
          consumed, chunk, group = italic_finish - index + 1, italic, ITALIC
        end
      end
    elseif char == "~" then
      local _, finish, strike = text:find("^~~(.-)~~", index)
      if finish then
        consumed, chunk, group = finish - index + 1, strike, STRIKE
      end
    elseif char == "\\" then
      local _, finish, escaped = text:find("^\\(.)", index)
      if finish then
        consumed, chunk, group = finish - index + 1, escaped, nil
      end
    end

    if consumed then
      emit(chunk, group)
      index = index + consumed
    else
      -- No construct starts here: copy plain bytes up to the next candidate in
      -- one slice. The search starts past this character so a lone special
      -- character is still emitted as text, and it stops before an ASCII byte,
      -- which can never split a UTF-8 sequence.
      local stop = text:find(SPECIAL, index + utf8_size(text:byte(index))) or (length + 1)
      emit(text:sub(index, stop - 1))
      index = stop
    end
  end

  return table.concat(out)
end

--- Highlight one fenced block with its language parser, when available.
--- @param code string[] block lines without the fence
--- @param lang string
--- @param first_row number row of the first rendered code line
--- @param spans table[] accumulator
--- @return boolean highlighted
local function highlight_code(code, lang, first_row, spans)
  local ok = pcall(function()
    if not vim.treesitter.language.add(lang) then
      error("no parser")
    end

    local source = table.concat(code, "\n") .. "\n"
    local parser = vim.treesitter.get_string_parser(source, lang)
    local tree = parser:parse()[1]
    local query = vim.treesitter.query.get(lang, "highlights")
    if not tree or not query then
      error("no query")
    end

    for id, node in query:iter_captures(tree:root(), source, 0, -1) do
      local name = query.captures[id]
      if name and not name:find("spell", 1, true) and not name:find("injection", 1, true) then
        local start_row, start_col, end_row, end_col = node:range()
        local group = "@" .. name .. "." .. lang
        if start_row == end_row then
          spans[#spans + 1] = {
            row = first_row + start_row,
            start_col = 2 + start_col,
            end_col = 2 + end_col,
            group = group,
          }
        else
          for row = start_row, end_row do
            local from = row == start_row and start_col or 0
            local to = row == end_row and end_col or #(code[row + 1] or "")
            spans[#spans + 1] = {
              row = first_row + row,
              start_col = 2 + from,
              end_col = 2 + to,
              group = group,
            }
          end
        end
      end
    end
  end)
  return ok
end

--- Render Markdown text into presentation lines.
--- @param text string
--- @param opts {code_highlight: boolean|nil, show_language: boolean|nil, max_highlight_lines: number|nil}|nil
--- @return {lines: string[], spans: table[], virt: table[], groups: table<number,string>}
function M.render(text, opts)
  opts = opts or {}
  local max_highlight = opts.max_highlight_lines or 300

  local lines, spans, virt, groups = {}, {}, {}, {}

  local function row_count()
    return #lines
  end

  --- Emit one line built from a prefix plus inline Markdown.
  local function emit(source, prefix, group, bullet)
    local row = row_count() + 1
    local prefix_text = prefix or ""
    local rendered = inline(source or "", row, #prefix_text, spans)
    lines[row] = prefix_text .. rendered
    if group then
      groups[row] = group
    end
    if bullet and #prefix_text > 0 then
      spans[#spans + 1] = { row = row, start_col = 0, end_col = #prefix_text, group = BULLET }
    end
    return row
  end

  local in_fence = false
  local fence_marker = nil
  local fence_lang = nil
  local code = {}

  local function flush_code()
    in_fence = false
    if #code == 0 then
      code = {}
      return
    end

    local first_row = row_count() + 1
    for _, line in ipairs(code) do
      lines[#lines + 1] = "  " .. line
      groups[#lines] = BLOCK_CODE
    end

    if opts.code_highlight ~= false and #code <= max_highlight then
      highlight_code(code, fence_lang, first_row, spans)
    end

    if opts.show_language ~= false and fence_lang and fence_lang ~= "" then
      local target = lines[first_row] or ""
      virt[#virt + 1] = { row = first_row, col = #target, text = " " .. fence_lang .. " ", group = "DshCodeLang" }
    end

    code = {}
  end

  local source = text .. "\n"
  for raw in source:gmatch("([^\n]*)\n") do
    raw = raw:gsub("\r$", "")

    if in_fence then
      local closing = raw:match("^%s*(`+)%s*$")
      if closing and #closing >= #fence_marker then
        flush_code()
      else
        code[#code + 1] = raw
      end
    else
      local open_marker, lang = raw:match("^%s*(`+)([%w_+%-]*)%s*$")
      if open_marker and #open_marker >= 3 then
        in_fence = true
        fence_marker = open_marker
        fence_lang = (lang ~= "" and lang) or nil
      elseif raw:match("^%s*$") then
        -- Collapse runs of blank lines.
        if row_count() > 0 and lines[#lines] ~= "" then
          lines[#lines + 1] = ""
        end
      else
        local hashes, heading = raw:match("^(#+)%s+(.*)$")
        if hashes then
          local level = math.min(#hashes, 6)
          local body = heading:gsub("%s*#+%s*$", "")
          emit(body, nil, "DshH" .. level)
        elseif raw:match("^%s*[-*_]%s*[-*_]%s*[-*_][%s%-%*_]*$") then
          lines[#lines + 1] = string.rep("─", 40)
          groups[#lines] = "DshHr"
        else
          local quote_indent, quoted = raw:match("^(%s*)>%s?(.*)$")
          if quote_indent then
            emit(quoted, quote_indent .. "│ ", "DshQuote")
          else
            local task_indent, tick, task = raw:match("^(%s*)[-*+]%s+%[([ xX])%]%s+(.*)$")
            if task_indent then
              local box = (tick == "x" or tick == "X") and "☑ " or "☐ "
              emit(task, task_indent .. box, nil, true)
            else
              local bullet_indent, _, bullet_body = raw:match("^(%s*)([-*+])%s+(.*)$")
              local ordered_indent, number, ordered_body = raw:match("^(%s*)(%d+[.)])%s+(.*)$")
              if bullet_indent then
                emit(bullet_body, bullet_indent .. "• ", nil, true)
              elseif ordered_indent then
                emit(ordered_body, ordered_indent .. number .. " ", nil, true)
              else
                emit(raw, nil, nil)
              end
            end
          end
        end
      end
    end
  end

  if in_fence then
    flush_code()
  end

  -- Leading blanks cannot occur (they are skipped above); trim trailing ones.
  while #lines > 0 and lines[#lines] == "" do
    table.remove(lines)
  end

  return { lines = lines, spans = spans, virt = virt, groups = groups }
end

M.inline = inline

return M