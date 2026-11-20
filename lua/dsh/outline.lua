--- Nested outline symbols for a rendered `dshchat` session buffer.
---
--- outline.nvim has no Tree-sitter provider of its own, and its third-party
--- `treesitter` provider can only nest symbols through Tree-sitter node
--- ancestry. The dshchat grammar is line oriented on purpose, so every message,
--- tool call and notice is a sibling under `document` and the outline comes out
--- flat. This module walks the same AST and groups the transcript into turns:
---
---   title                      File
---   user message               Namespace
---     assistant message        Module
---     Commands outputs         Object
---       tool call              Method
---       tool call              Method
---     error / notice           Event / Constant
---
--- A turn's tool calls are gathered under one `Commands outputs` entry rather
--- than spread through its replies, so the command noise of a long turn folds
--- away in a single step.
---
--- Symbols use the LSP `DocumentSymbol` shape outline.nvim consumes (0-based
--- lines, `range` / `selectionRange`, nested `children`), which is also what
--- aerial.nvim and other symbol trees accept. `lua/outline/providers/dshchat.lua`
--- is the thin adapter; nothing here requires outline.nvim to be installed, so
--- the layout is testable on its own.
local M = {}

--- LSP `SymbolKind` numbers, named for readability.
local KIND = {
  File = 1,
  Module = 2,
  Namespace = 3,
  Method = 6,
  Constant = 14,
  Object = 19,
  Event = 24,
}

--- Marker widths of the rendered transcript. The renderer writes these
--- prefixes (`▌ You`, `▌ Assistant`, `  ⚙ name(args)`, `✖ …`, `· …`); the
--- outline labels are built from what follows them.
local USER_MARKER = "▌ You"
local ASSISTANT_MARKER = "▌ Assistant"

--- Umbrella entry that gathers a turn's tool calls.
local COMMANDS_MARKER = "Commands outputs"

--- Line text of a node, without the trailing EOL or surrounding blanks.
--- @param bufnr integer
--- @param node TSNode
--- @return string
local function text_of(bufnr, node)
  return vim.trim(vim.treesitter.get_node_text(node, bufnr))
end

--- @param text string
--- @param pattern string
--- @param replacement string
--- @return string
local function replace_first(text, pattern, replacement)
  return (text:gsub(pattern, replacement, 1))
end

--- @param name string
--- @param kind integer
--- @param line integer 0-based
--- @return table
local function symbol(name, kind, line)
  local position = { line = line, character = 0 }
  return {
    name = name,
    kind = kind,
    children = {},
    range = { start = vim.deepcopy(position), ["end"] = vim.deepcopy(position) },
    selectionRange = { start = position, ["end"] = vim.deepcopy(position) },
  }
end

--- Whether a dshchat parser can be loaded for the buffer.
--- @param bufnr integer|nil
--- @return boolean
function M.available(bufnr)
  bufnr = bufnr and bufnr ~= 0 and bufnr or vim.api.nvim_get_current_buf()
  if vim.bo[bufnr].filetype ~= "dshchat" then
    return false
  end
  return (pcall(vim.treesitter.get_parser, bufnr, "dshchat"))
end

--- Build the nested symbol tree for a session buffer.
---
--- The transcript is linear, so one pass is enough: a `user_header` opens a
--- turn, an `assistant_header` opens a section under it, and tool calls,
--- errors and notices belong to the section that is open. Every symbol then
--- takes its range from the line before the next symbol at the same or a
--- shallower depth, which is what outline uses to highlight the block.
---
--- @param bufnr integer|nil defaults to the current buffer
--- @return table[] symbols
function M.build(bufnr)
  bufnr = bufnr and bufnr ~= 0 and bufnr or vim.api.nvim_get_current_buf()

  local parser_ok, parser = pcall(vim.treesitter.get_parser, bufnr, "dshchat")
  if not parser_ok or not parser then
    return {}
  end
  local tree_ok, trees = pcall(parser.parse, parser)
  if not tree_ok or not trees or not trees[1] then
    return {}
  end

  local document = trees[1]:root()
  local last_line = math.max(0, vim.api.nvim_buf_line_count(bufnr) - 1)

  --- @type table[] Symbols at the top of the tree.
  local top = {}
  --- @type {symbol: table, line: integer, depth: integer}[] Symbols in document order.
  local order = {}

  --- @param item table
  --- @param parent table|nil
  --- @param depth integer 0 for a top-level turn
  --- @param line integer 0-based
  local function add(item, parent, depth, line)
    table.insert(parent and parent.children or top, item)
    order[#order + 1] = { symbol = item, line = line, depth = depth }
  end

  --- @type table|nil
  local user
  --- @type table|nil
  local assistant
  local assistant_interrupted = false
  local title_done = false

  --- Wrapper and the turn it belongs to, plus every wrapper created (their
  --- ranges are fixed up after the pass).
  --- @type table|nil
  local commands
  --- @type table|nil
  local commands_turn
  --- @type table[]
  local wrappers = {}

  --- The `tool_call` node of a `tool_exchange` line, or nil.
  --- @param node TSNode
  --- @return TSNode|nil
  local function tool_call_of(node)
    for child in node:iter_children() do
      if child:named() and child:type() == "tool_call" then
        return child
      end
    end
    return nil
  end

  --- The `Commands outputs` wrapper of a turn, created on its first call.
  --- @param turn table|nil the turn the calls belong to
  --- @param line integer 0-based
  --- @return table wrapper
  local function commands_wrapper(turn, line)
    if commands and commands_turn == turn then
      return commands
    end
    commands_turn = turn
    commands = symbol(COMMANDS_MARKER, KIND.Object, line)
    add(commands, turn, turn and 1 or 0, line)
    wrappers[#wrappers + 1] = commands
    return commands
  end

  for node in document:iter_children() do
    if node:named() then
      local kind = node:type()
      local line = node:start()

      if kind == "title" and not title_done then
        -- The renderer writes the title first, as `# <title>`. A later `#`
        -- line is prompt text echoed verbatim, not a second document title.
        title_done = true
        local name = replace_first(text_of(bufnr, node), "^#+%s*", "")
        if name == "" then
          name = "Session"
        end
        add(symbol(name, KIND.File, line), nil, 0, line)
        user, assistant = nil, nil
        commands, commands_turn = nil, nil
      elseif kind == "user_header" then
        user = symbol(USER_MARKER, KIND.Namespace, line)
        assistant, assistant_interrupted = nil, false
        commands, commands_turn = nil, nil
        add(user, nil, 0, line)
      elseif kind == "user_prompt" then
        -- The first line of the prompt is the turn's label.
        local prompt = text_of(bufnr, node)
        if user and prompt ~= "" then
          user.name = prompt
        elseif not user then
          user = symbol(prompt ~= "" and prompt or USER_MARKER, KIND.Namespace, line)
          assistant, assistant_interrupted = nil, false
          add(user, nil, 0, line)
        end
      elseif kind == "assistant_header" then
        local header = text_of(bufnr, node)
        assistant_interrupted = header:find("%(interrupted%)") ~= nil
        local name = replace_first(header, "^▌%s*", "")
        if name == "" then
          name = "Assistant"
        end
        assistant = symbol(name, KIND.Module, line)
        -- Replies hang under the prompt they answer; a stray reply (a prompt
        -- that never rendered its header) stays at the top level.
        if user then
          add(assistant, user, 1, line)
        else
          add(assistant, nil, 0, line)
        end
      elseif kind == "assistant_message_header" then
        -- The first line of the reply says more than the marker does. The
        -- renderer's "(no text)" placeholder is not a label.
        local reply = text_of(bufnr, node)
        if assistant and reply ~= "" and reply ~= "(no text)" then
          local note = assistant_interrupted and "  (interrupted)" or ""
          assistant.name = reply .. note
        end
      elseif kind == "tool_exchange" or kind == "tool_call" then
        -- A finished tool call is wrapped in a `tool_exchange` that also holds
        -- its output; a call still running stands alone.
        local call = kind == "tool_call" and node or tool_call_of(node)
        if call then
          local name = replace_first(text_of(bufnr, call), "^⚙%s*", "")
          local item = symbol(name ~= "" and name or "tool", KIND.Method, call:start())
          -- A turn's calls are gathered under one wrapper; a call that arrives
          -- before any header still gets one, at the top level.
          local turn = user or assistant
          local wrapper = commands_wrapper(turn, call:start())
          add(item, wrapper, turn and 2 or 1, call:start())
        end
      elseif kind == "error" or kind == "notice" then
        local item
        if kind == "error" then
          local name = replace_first(text_of(bufnr, node), "^✖%s*", "")
          item = symbol(name ~= "" and name or "error", KIND.Event, line)
        else
          local name = replace_first(text_of(bufnr, node), "^·%s*", "")
          item = symbol(name ~= "" and name or "notice", KIND.Constant, line)
        end
        local parent, depth = assistant, 2
        if not parent then
          parent, depth = user, 1
        end
        add(item, parent, depth, line)
      end
    end
  end

  for index, entry in ipairs(order) do
    local stop = last_line
    for next_index = index + 1, #order do
      if order[next_index].depth <= entry.depth then
        stop = order[next_index].line - 1
        break
      end
    end
    if stop < entry.line then
      stop = entry.line
    end
    entry.symbol.range["end"].line = stop
    entry.symbol.selectionRange["end"].line = stop
  end

  -- A wrapper's calls are not contiguous in the buffer: replies sit between
  -- them, so the turn-level range stop above would cut the wrapper short (or
  -- run it past its last call). Span the calls it groups instead.
  for _, wrapper in ipairs(wrappers) do
    local last = wrapper.children[#wrapper.children]
    if last then
      wrapper.range["end"].line = last.range["end"].line
    end
  end

  return top
end

return M
