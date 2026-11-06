--- Tree-sitter wiring for the `dshchat` filetype.
---
--- The grammar lives in `tree-sitter-dshchat/` and its generated `src/parser.c`
--- is committed, so `:TSInstall dshchat` can build it from the plugin checkout
--- without network access (nvim-treesitter accepts a directory as `url`).
--- Queries live in `queries/dshchat/` on the plugin runtimepath.
---
--- The rendered buffer is already styled with extmarks; Tree-sitter is
--- additive: it provides structure for folds, incremental selection and
--- `:InspectTree`. Highlight captures use the same `Dsh…` groups so the parser
--- is useful even when extmark styling is not applied.
local M = {}

--- Captures used by `queries/dshchat/highlights.scm`, mapped to the render
--- groups. `@DshFoo.dshchat` falls back to `@DshFoo` in Neovim.
local CAPTURES = {
  "DshTitle",
  "DshUserHeader",
  "DshUser",
  "DshAssistantHeader",
  "DshTool",
  "DshToolError",
  "DshError",
  "DshNotice",
  "DshCodeBlock",
  "DshCode",
  "DshCodeLang",
  "DshQuote",
  "DshBullet",
  "DshHr",
}

--- Directory holding the vendored grammar.
--- @return string|nil
function M.grammar_dir()
  local found = vim.api.nvim_get_runtime_file("tree-sitter-dshchat/grammar.js", false)[1]
  if found then
    return vim.fn.fnamemodify(found, ":p:h")
  end
  return nil
end

--- Parser config for nvim-treesitter, or nil when the grammar is not on the
--- runtimepath. `url` is a local directory; nvim-treesitter compiles from it.
--- @return table|nil
function M.parser_config()
  local grammar = M.grammar_dir()
  if not grammar then
    return nil
  end
  return {
    install_info = {
      -- A committed parser.c means no tree-sitter CLI or npm is required.
      url = grammar,
      files = { "src/parser.c" },
    },
    filetype = "dshchat",
    maintainers = { "@stCarolas" },
  }
end

--- Define `@Dsh…` capture aliases accepted by the highlight query.
function M.define_captures()
  for _, group in ipairs(CAPTURES) do
    vim.api.nvim_set_hl(0, "@" .. group, { default = true, link = group })
  end
end

--- Add the parser to nvim-treesitter when it is loaded.
---
--- No negative result is cached: nvim-treesitter may be loaded lazily, after
--- the plugin setup ran, and the next session buffer retries the registration.
function M.register_parser()
  local ok, parsers = pcall(require, "nvim-treesitter.parsers")
  if ok then
    local config = M.parser_config()
    if config then
      local configs = parsers.get_parser_configs()
      if not configs.dshchat then
        -- The parsers table registers the filetype mapping through __newindex.
        configs.dshchat = config
      end
    end
  end

  -- Without nvim-treesitter the language name still maps to the filetype.
  pcall(vim.treesitter.language.register, "dshchat", "dshchat")
end

--- Whether a Tree-sitter parser can be loaded from the runtimepath.
--- `language.add` returns true only when the library was loaded; it returns
--- nil with an error message for a missing parser.
--- @param lang string|nil defaults to "dshchat"
--- @return boolean
function M.parser_available(lang)
  local ok, added = pcall(vim.treesitter.language.add, lang or "dshchat")
  return ok and added == true
end

--- Start Tree-sitter on a session buffer when a parser is installed.
--- @param buf integer
--- @return boolean started
function M.start(buf)
  M.define_captures()
  M.register_parser()

  if not M.parser_available() then
    return false
  end

  local highlighter = vim.treesitter.highlighter
  if highlighter and highlighter.active and highlighter.active[buf] then
    return true
  end

  local ok = pcall(vim.treesitter.start, buf, "dshchat")
  return ok
end

--- Configure the Tree-sitter integration.
function M.setup()
  M.define_captures()
  M.register_parser()
end

return M
