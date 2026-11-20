--- Searchable entries of a rendered `dshchat` session buffer.
---
--- A session buffer is one long transcript: a title, `▌ You` prompts,
--- `▌ Assistant` replies with their tool calls, and the errors and notices the
--- harness printed. `vim.fn.matchfuzzy` over the whole buffer would row-by-row
--- match half a message, so `:DshSearch` instead lists one row per message and
--- searches the text that belongs to it.
---
--- This module walks the same Tree-sitter AST as `dsh.outline` and returns flat
--- `{ kind, lnum, text }` entries in transcript order. A tool call is its own
--- entry and keeps its output, which is what makes "which call read that file"
--- searchable. No UI and no outline.nvim dependency: `dsh.ui.search` renders
--- the rows.
local M = {}

--- Node types that belong to the message being read (its own lines).
local TEXT_NODES = {
  user_prompt = true,
  assistant_message_header = true,
  text = true,
  bullet = true,
  task = true,
  ordered = true,
  quote = true,
  rule = true,
  code_block = true,
  code = true,
}

--- Scopes accepted by `:DshSearch` and `M.entries`.
M.scopes = { "all", "prompts", "replies", "tools", "notes" }

--- Which entry kinds a scope returns. `all` keeps everything.
local SCOPE_KINDS = {
  prompts = { prompt = true },
  replies = { reply = true },
  tools = { tool = true },
  notes = { error = true, notice = true },
}

--- @param bufnr integer
--- @param node TSNode
--- @return string
local function text_of(bufnr, node)
  return vim.trim(vim.treesitter.get_node_text(node, bufnr))
end

--- @param kind string
--- @param lnum integer 0-based
--- @return table
local function entry(kind, lnum)
  return { kind = kind, lnum = lnum, text = "" }
end

--- Add a line of message text to an entry.
--- @param target table
--- @param piece string
local function append(target, piece)
  piece = vim.trim(piece)
  if piece == "" then
    return
  end
  target.text = target.text == "" and piece or (target.text .. "\n" .. piece)
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

--- Entries of a transcript, in buffer order.
---
--- `lnum` is 0-based, like the outline symbols, and points at the header (or
--- tool call) a selection should jump to. Entries without text are dropped:
--- an empty reply is not something to search for.
---
--- @param bufnr integer|nil defaults to the current buffer
--- @param scope string|nil "all" (default), "prompts", "replies", "tools" or "notes"
--- @return {kind: string, lnum: integer, text: string}[]
function M.entries(bufnr, scope)
  bufnr = bufnr and bufnr ~= 0 and bufnr or vim.api.nvim_get_current_buf()
  scope = scope or "all"
  local kinds = SCOPE_KINDS[scope]

  local parser_ok, parser = pcall(vim.treesitter.get_parser, bufnr, "dshchat")
  if not parser_ok or not parser then
    return {}
  end
  local tree_ok, trees = pcall(parser.parse, parser)
  if not tree_ok or not trees or not trees[1] then
    return {}
  end

  --- @type table[]
  local entries = {}
  --- The message the following text lines belong to.
  local current
  local title_done = false

  --- @param kind string
  --- @param lnum integer
  --- @return table
  local function start(kind, lnum)
    local item = entry(kind, lnum)
    if kinds == nil or kinds[kind] then
      entries[#entries + 1] = item
    end
    return item
  end

  for node in trees[1]:root():iter_children() do
    if node:named() then
      local kind = node:type()
      local line = node:start()

      if kind == "title" then
        -- The session title is the first `#` line; a later one is echoed
        -- prompt text and stays with its message.
        if not title_done then
          title_done = true
          append(start("title", line), (text_of(bufnr, node):gsub("^#+%s*", "")))
          current = nil
        end
      elseif kind == "user_header" then
        current = start("prompt", line)
      elseif kind == "assistant_header" then
        current = start("reply", line)
      elseif kind == "tool_exchange" or kind == "tool_call" then
        -- A finished call wraps its output; a running one stands alone. The
        -- marker is the renderer's, not something to search for.
        append(start("tool", line), (text_of(bufnr, node):gsub("^%s*⚙%s*", "")))
      elseif kind == "error" or kind == "notice" then
        local marker = kind == "error" and "^✖%s*" or "^·%s*"
        append(start(kind, line), (text_of(bufnr, node):gsub(marker, "")))
      elseif TEXT_NODES[kind] and current then
        append(current, text_of(bufnr, node))
      end
    end
  end

  local textful = {}
  for _, item in ipairs(entries) do
    if item.text ~= "" then
      textful[#textful + 1] = item
    end
  end
  return textful
end

return M
