--- outline.nvim provider for rendered dsh session buffers.
---
--- outline.nvim ships no Tree-sitter provider of its own, and the third-party
--- `treesitter` provider (outline-treesitter-provider.nvim) nests symbols only
--- through Tree-sitter node ancestry. The dshchat grammar is line oriented, so
--- every message and tool call is a sibling `document` child and its outline is
--- necessarily flat.
---
--- This provider builds the turn hierarchy itself — see `dsh.outline` — so a
--- prompt's replies and its tool calls fold under it:
---
---   title
---   user prompt
---     assistant reply
---     Commands outputs
---       ⚙ tool call
---       ⚙ tool call
---
--- A turn's tool calls share one `Commands outputs` entry, so the command noise
--- of a long turn collapses in one step instead of one `<Tab>` per call.
---
--- Enable it by naming it in the provider priority. It has to come before
--- `lsp` (a session buffer has no language server, but another provider picking
--- the buffer first would win):
---
---   require("outline").setup({
---     providers = { priority = { "dshchat", "lsp", "markdown", "treesitter" } },
---   })
---
--- Folding uses outline's own keymaps: `<Tab>` toggles, `h`/`l` fold/unfold,
--- `W`/`E` fold/unfold everything. `symbol_folding.autofold_depth = false`
--- unfolds the whole tree when the outline opens.
local outline = require("dsh.outline")

local M = { name = "dshchat" }

--- Whether this provider takes the buffer.
--- outline.nvim calls this with the current buffer (0) when it opens.
--- @param bufnr integer|nil
--- @return boolean supported, table|nil info
function M.supports_buffer(bufnr)
  bufnr = bufnr and bufnr ~= 0 and bufnr or vim.api.nvim_get_current_buf()
  if vim.bo[bufnr].filetype ~= "dshchat" or not outline.available(bufnr) then
    return false
  end
  return true, { buf = bufnr }
end

--- Hand the nested symbols to outline.nvim.
--- @param on_symbols fun(symbols: table[], opts?: table)
--- @param opts table|nil outline's request options
--- @param info table|nil the table returned by `supports_buffer`
function M.request_symbols(on_symbols, opts, info)
  local bufnr = (info and info.buf) or vim.api.nvim_get_current_buf()
  if not vim.api.nvim_buf_is_valid(bufnr) then
    on_symbols({}, opts)
    return
  end
  on_symbols(outline.build(bufnr), opts)
end

return M
