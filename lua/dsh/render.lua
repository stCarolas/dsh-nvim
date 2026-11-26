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

--- Tool results render as an indented code block nested under the
--- `  ⚙ name(args)` call line. Four spaces is Markdown's indented-code-block
--- level, and it aligns the code with the tool name after the call prefix.
local TOOL_CODE_INDENT = "    "

--- Winbar suffix shown while tool output or whole exchanges are toggled off.
local HIDDEN_TOOL_OUTPUT = " · output hidden"
local HIDDEN_TOOL_EXCHANGE = " · tools hidden"

--- Whether tool result bodies are rendered.
---
--- A caller passes the state of its view; without one the `show_tool_output`
--- config option decides, so a path that does not know about the toggle still
--- honours the user's setting.
--- @param opts {show_tool_output: boolean|nil, show_tool_exchange: boolean|nil}|nil
--- @return boolean
local function tool_output_shown(opts)
  if type(opts) == "table" and type(opts.show_tool_output) == "boolean" then
    return opts.show_tool_output
  end
  return config.options.show_tool_output ~= false
end

--- Whether whole tool exchanges — the call line and its result — are rendered.
--- @param opts {show_tool_output: boolean|nil, show_tool_exchange: boolean|nil}|nil
--- @return boolean
local function tool_exchange_shown(opts)
  if type(opts) == "table" and type(opts.show_tool_exchange) == "boolean" then
    return opts.show_tool_exchange
  end
  return config.options.show_tool_exchange ~= false
end

--- Replace each run of tool entries with one summary entry.
---
--- Tool calls and their results are separate entries, and a step can issue
--- several calls before the results arrive, so the run — not one call — is the
--- unit to collapse: the buffer keeps a single line saying how much work is
--- folded away, and a failure is counted there instead of disappearing.
--- @param entries table[]
--- @return table[]
local function collapse_tool_runs(entries)
  local out = {}
  local calls, results, failures = 0, 0, 0

  local function flush()
    if calls == 0 and results == 0 then
      return
    end
    out[#out + 1] = { role = "tool_summary", calls = calls, results = results, failures = failures }
    calls, results, failures = 0, 0, 0
  end

  for _, entry in ipairs(entries) do
    if entry.role == "tool" then
      calls = calls + 1
    elseif entry.role == "tool_result" then
      results = results + 1
      if entry.is_error then
        failures = failures + 1
      end
    else
      flush()
      out[#out + 1] = entry
    end
  end
  flush()

  return out
end

--- One-line stand-in for a tool result whose body is toggled off.
--- @param count integer output rows the result had
--- @return string
local function hidden_notice(count)
  if count == 0 then
    return "(empty)"
  end
  return ("… %d line%s hidden"):format(count, count == 1 and "" or "s")
end

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
--- @param opts {show_tool_output: boolean|nil, show_tool_exchange: boolean|nil}|nil
--- @return {lines: string[], hl: string[], spans: table[], virt: table[]}
function M.compose(entries, opts)
  local state = { lines = {}, hl = {}, spans = {}, virt = {} }
  local show_tool_output = tool_output_shown(opts)
  if not tool_exchange_shown(opts) then
    entries = collapse_tool_runs(entries)
  end

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
      -- The winbar already carries the title; this is the optional buffer line.
      if config.options.chat.show_title ~= false then
        state.push("# " .. entry.text, "DshTitle")
      end
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
      -- Tool results are arbitrary text — file contents, shell output, JSON —
      -- so they render like a Markdown code block: verbatim lines indented one
      -- level under the call and grouped under DshCodeBlock. A failed result
      -- keeps its error group so the failure stays visible.
      local body = lines_of(entry.text)
      if not show_tool_output and not entry.is_error then
        -- The call line above still says what ran; one muted line says how
        -- much its output would add. Failures are never collapsed: a hidden
        -- failure is a failure that is easy to miss.
        state.push(TOOL_CODE_INDENT .. hidden_notice(#body), "DshTool")
      else
        local limit = config.options.tool_output_lines
        local group = entry.is_error and "DshToolError" or "DshCodeBlock"
        local shown = math.min(#body, limit)
        for index = 1, shown do
          state.push(TOOL_CODE_INDENT .. body[index], group)
        end
        if #body == 0 then
          state.push(TOOL_CODE_INDENT .. "(empty)", "DshTool")
        elseif #body > shown then
          local omitted = #body - shown
          state.push(TOOL_CODE_INDENT .. ("… %d more line%s"):format(omitted, omitted == 1 and "" or "s"), "DshTool")
        end
      end
    elseif entry.role == "tool_summary" then
      -- What a run of hidden tool exchanges leaves behind: the call lines and
      -- their output are gone, the amount of work they did is not. A failed
      -- result is counted here in the error group, so a failure can still be
      -- noticed without the transcript it came with.
      local text
      if entry.calls > 0 then
        text = ("%d tool call%s hidden"):format(entry.calls, entry.calls == 1 and "" or "s")
      else
        text = "tool output hidden"
      end
      if entry.failures > 0 then
        text = text .. (", %d failed"):format(entry.failures)
      end
      state.push("  ⚙ " .. text, entry.failures > 0 and "DshToolError" or "DshTool")
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
--- @param opts {show_tool_output: boolean|nil, show_tool_exchange: boolean|nil}|nil
function M.render(buf, entries, win, opts)
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end

  local composed = M.compose(entries, opts)
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

--- Text that `'winbar'` shows literally.
---
--- `'winbar'` is evaluated like `'statusline'`, so a session title is not merely
--- display text: a `%{…}` run in it would evaluate Vimscript, and a lone `%`
--- makes the assignment raise E539/E542. Titles are agent-generated, so they are
--- treated as untrusted: escape the metacharacter and drop line breaks.
--- @param text string
--- @return string
local function literal(text)
  return (text:gsub("%%", "%%%%"):gsub("[\r\n]", " "))
end

--- Text of the newest assistant message in a view, collapsed to one line.
---
--- The in-progress message is the trailing `live` entry while a turn streams;
--- after it settles, the same text becomes an `assistant` entry. Missing or
--- blank messages are skipped so the winbar can fall back to the title.
--- @param entries table[]|nil
--- @return string|nil
function M.last_assistant(entries)
  for index = #(entries or {}), 1, -1 do
    local item = entries[index]
    if type(item) == "table" and (item.role == "live" or item.role == "assistant") then
      local text = item.text
      if type(text) == "string" then
        text = text:gsub("^%s+", "")
        if text ~= "" then
          -- 400 characters is plenty for any winbar; bound before collapsing
          -- whitespace so a long streamed message is not rescanned each tick.
          local one_line = vim.fn.strcharpart(text, 0, 400):gsub("%s+", " ")
          return (one_line:gsub("^%s+", ""):gsub("%s+$", ""))
        end
      end
    end
  end
end

--- Window bar describing the session.
---
--- The tool marker trails the status so a view whose tool display is toggled
--- off still says so while a turn streams and the title is replaced by the
--- preview. Hiding whole exchanges subsumes hiding their output, so that
--- marker wins when both are off.
--- @param title string|nil
--- @param status string|nil
--- @param preview string|nil shown instead of the title while streaming
--- @param opts {show_tool_output: boolean|nil, show_tool_exchange: boolean|nil}|nil
function M.winbar(title, status, preview, opts)
  local name
  if status == "streaming" and type(preview) == "string" and preview ~= "" then
    name = preview
  else
    name = (title and title ~= "") and title or "untitled"
  end
  local marker = ""
  if type(opts) == "table" then
    if opts.show_tool_exchange == false then
      marker = HIDDEN_TOOL_EXCHANGE
    elseif opts.show_tool_output == false then
      marker = HIDDEN_TOOL_OUTPUT
    end
  end
  if status and status ~= "" then
    return (" dsh · %s · %s%s "):format(literal(name), literal(status), marker)
  end
  return (" dsh · %s%s "):format(literal(name), marker)
end

return M
