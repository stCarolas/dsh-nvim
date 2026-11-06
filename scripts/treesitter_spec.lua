-- Tree-sitter grammar, queries and wiring specs. No server needed.
-- Run with: nvim --headless -l scripts/treesitter_spec.lua
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h:h")
vim.opt.rtp:append(root)

local config = require("dsh.config")
local render = require("dsh.render")
local treesitter = require("dsh.treesitter")

config.setup({ notifications = false })
render.define_highlights()
treesitter.setup()

local failures = 0
local checks = 0

local function check(name, condition, detail)
  checks = checks + 1
  if not condition then
    failures = failures + 1
    print(("FAIL %s%s"):format(name, detail and (" — " .. detail) or ""))
  else
    print("PASS " .. name)
  end
end

--- Compile the vendored parser to a temporary .so when it is not already on
--- the runtimepath (scripts/build_parser.sh produces parser/dshchat.so).
local function ensure_parser()
  local existing = vim.api.nvim_get_runtime_file("parser/dshchat.so", false)[1]
  if existing then
    return existing
  end

  local grammar = assert(treesitter.grammar_dir(), "grammar directory missing")
  local source = grammar .. "/src/parser.c"
  check("generated parser source is committed", vim.fn.filereadable(source) == 1, source)

  local compiler = vim.fn.exepath("cc")
  if compiler == "" then
    compiler = vim.fn.exepath("gcc")
  end
  assert(compiler ~= "", "no C compiler found to build the dshchat parser")

  local output = vim.fn.tempname() .. ".so"
  local result = vim
    .system({ compiler, "-O2", "-fPIC", "-shared", "-I" .. grammar .. "/src", source, "-o", output })
    :wait(120000)
  assert(result.code == 0, "compiling the dshchat parser failed: " .. tostring(result.stderr))
  return output
end

-- 1. The grammar and its nvim-treesitter install spec are discoverable.
local grammar = treesitter.grammar_dir()
check("grammar directory found", grammar ~= nil, tostring(grammar))
check("grammar.js is on the runtimepath", grammar ~= nil and vim.fn.filereadable(grammar .. "/grammar.js") == 1)

local spec = treesitter.parser_config()
check("nvim-treesitter spec exists", spec ~= nil)
check("spec filetype is dshchat", spec and spec.filetype == "dshchat", spec and tostring(spec.filetype))
check("spec installs from the plugin checkout", spec and spec.install_info.url == grammar, spec and tostring(spec.install_info.url))
check(
  "spec points at the generated parser",
  spec and vim.deep_equal(spec.install_info.files, { "src/parser.c" }),
  spec and vim.inspect(spec.install_info.files)
)

-- 2. Wiring: language mapping and capture aliases.
check("dshchat maps to the dshchat language", vim.treesitter.language.get_lang("dshchat") == "dshchat", tostring(vim.treesitter.language.get_lang("dshchat")))
local alias = vim.api.nvim_get_hl(0, { name = "@DshTitle", link = true })
check("capture aliases link to render groups", alias.link == "DshTitle", vim.inspect(alias))
check("parser availability is reported", type(treesitter.parser_available()) == "boolean")
check("a missing parser is reported unavailable", treesitter.parser_available("dshchat-no-such-parser") == false)

local parser_path = ensure_parser()
check("parser library built", parser_path ~= nil and vim.fn.filereadable(parser_path) == 1, tostring(parser_path))
if vim.fn.filereadable(parser_path) == 1 then
  pcall(vim.treesitter.language.add, "dshchat", { path = parser_path })
end

-- 3. A rendered session buffer parses into structural nodes.
local sample = {
  "# Fix the flaky retry test",
  "",
  "▌ You",
  "fix the flaky retry test",
  "and a second prompt line",
  "",
  "▌ Assistant",
  "The retry loop copies the backoff value before the jitter is applied.",
  "Second line of the reply.",
  "",
  "• jitter is applied per attempt",
  "☐ timer cleared on abort",
  "1. first step",
  "│ plan review",
  "────────────────────────────────────────",
  "",
  "  local function retry(fn, opts)",
  "    return attempt(fn, { ...opts, jitter = true })",
  "  ",
  "  end",
  "",
  "  ⚙ read(path=src/retry.ts)",
  "    1  export function retry(fn, opts) {",
  "    2    return attempt(fn, opts)",
  "    3  }",
  "    … 42 more lines",
  "",
  "✖ something failed",
  "· a notice",
}

local buf = vim.api.nvim_create_buf(false, true)
vim.bo[buf].filetype = "dshchat"
vim.api.nvim_buf_set_lines(buf, 0, -1, false, sample)
local parser = assert(vim.treesitter.get_parser(buf, "dshchat"))
local tree = parser:parse()[1]
local document = tree:root()

check("document parses without errors", not document:has_error())

local counts = {}
local function count(node)
  counts[node:type()] = (counts[node:type()] or 0) + 1
  for child in node:iter_children() do
    count(child)
  end
end
count(document)

check("title parsed", counts.title == 1, tostring(counts.title))
check("user header parsed", counts.user_header == 1, tostring(counts.user_header))
check("assistant header parsed", counts.assistant_header == 1, tostring(counts.assistant_header))
check("first user text is the user prompt", counts.user_prompt == 1, tostring(counts.user_prompt))
check("first assistant text is the message header", counts.assistant_message_header == 1, tostring(counts.assistant_message_header))
check("later message lines stay plain text", counts.text == 2, tostring(counts.text))
check("bullet, task, ordered and quote parsed", counts.bullet == 1 and counts.task == 1 and counts.ordered == 1 and counts.quote == 1)
check("rule parsed", counts.rule == 1)
check("code block groups its lines", counts.code_block == 1 and counts.code == 4, ("%s/%s"):format(counts.code_block, counts.code))
check(
  "tool exchange groups call and output",
  counts.tool_exchange == 1 and counts.tool_call == 1 and counts.tool_output_block == 1 and counts.tool_output == 4,
  vim.inspect(counts)
)
check("error and notice parsed", counts.error == 1 and counts.notice == 1)
check("no ERROR node", counts.ERROR == nil, tostring(counts.ERROR))

--- First named child of `node` with type `type_`.
local function find_child(node, type_)
  for child in node:iter_children() do
    if child:named() and child:type() == type_ then
      return child
    end
  end
  return nil
end

local user_header = find_child(document, "user_header")
local assistant_header = find_child(document, "assistant_header")
local user_prompt = user_header and user_header:next_named_sibling()
local assistant_text = assistant_header and assistant_header:next_named_sibling()
check("user prompt immediately follows the user header", user_prompt and user_prompt:type() == "user_prompt", user_prompt and user_prompt:type())
check(
  "assistant message header immediately follows the assistant header",
  assistant_text and assistant_text:type() == "assistant_message_header",
  assistant_text and assistant_text:type()
)

-- A non-text first line leaves the header standing alone (and no ERROR).
local fallback_buf = vim.api.nvim_create_buf(false, true)
vim.bo[fallback_buf].filetype = "dshchat"
vim.api.nvim_buf_set_lines(fallback_buf, 0, -1, false, { "▌ Assistant", "• bullet first", "body line" })
local fallback_parser = assert(vim.treesitter.get_parser(fallback_buf, "dshchat"))
local fallback_tree = fallback_parser:parse()[1]
local fallback_root = fallback_tree:root()
check("non-text first line does not error", not fallback_root:has_error())
check("fallback has no assistant message header", find_child(fallback_root, "assistant_message_header") == nil)
check("fallback keeps the assistant header", find_child(fallback_root, "assistant_header") ~= nil)

-- 4. Highlight and fold queries resolve against the tree.
local highlights = vim.treesitter.query.get("dshchat", "highlights")
check("highlights query found", highlights ~= nil)
local captures = {}
if highlights then
  for id in highlights:iter_captures(document, buf) do
    captures[highlights.captures[id]] = true
  end
end
check("title capture", captures.DshTitle == true)
check("user header capture", captures.DshUserHeader == true)
check("assistant header capture", captures.DshAssistantHeader == true)
check("tool call capture", captures.DshTool == true)
check("code block capture", captures.DshCodeBlock == true)
check("error capture", captures.DshError == true)
check("notice capture", captures.DshNotice == true)

local folds = vim.treesitter.query.get("dshchat", "folds")
check("folds query found", folds ~= nil)
local fold_count = 0
if folds then
  for _ in folds:iter_captures(document, buf) do
    fold_count = fold_count + 1
  end
end
check("code and tool blocks are foldable", fold_count == 2, tostring(fold_count))

-- 5. Header-looking prompt text must not produce a parse error.
local hostile = {
  "▌ You",
  "▌ Assistant  (interrupted) is just my prompt",
  "  ⚙ but not a tool call either",
  "# and not a title",
  "    4-space indented prompt line",
}
local hostile_buf = vim.api.nvim_create_buf(false, true)
vim.bo[hostile_buf].filetype = "dshchat"
vim.api.nvim_buf_set_lines(hostile_buf, 0, -1, false, hostile)
local hostile_parser = assert(vim.treesitter.get_parser(hostile_buf, "dshchat"))
local hostile_tree = hostile_parser:parse()[1]
check("header-looking prompt text does not error", not hostile_tree:root():has_error())

-- 6. The real renderer output (not just a hand-written sample) parses cleanly.
local surface = require("dsh.surface")
local function record(kind, seq, data)
  return { type = "event", event = { type = kind, seq = seq, time = 0, data = data } }
end
local records = {
  record("session/title", 1, { title = "Fix the flaky retry test" }),
  record("user/message", 2, {
    role = "user",
    content = { { type = "text", text = "fix the flaky retry test" } },
    source = { kind = "user" },
  }),
  record("assistant/message", 3, {
    turn = 1,
    step = 1,
    message = {
      role = "assistant",
      source = { provider = "p", model = "m" },
      content = {
        {
          type = "text",
          text = "## Cause\n\n- jitter is applied per attempt\n\n1. inspect the timer\n\n> the abort path is untested\n\n---\n\n```lua\nlocal x = 1\nreturn x\n```\n",
        },
      },
    },
    stream = {},
  }),
  record("tool/call", 4, { turn = 1, step = 1, callId = "c1", name = "read", arguments = '{"path":"src/retry.ts"}' }),
  record("tool/result", 5, {
    turn = 1,
    step = 1,
    message = { role = "tool", isError = false, content = { { type = "text", text = "line1\nline2" } } },
  }),
}
local composed = render.compose(surface.build(records).entries)
local rendered_buf = vim.api.nvim_create_buf(false, true)
vim.bo[rendered_buf].filetype = "dshchat"
vim.api.nvim_buf_set_lines(rendered_buf, 0, -1, false, composed.lines)
local rendered_parser = assert(vim.treesitter.get_parser(rendered_buf, "dshchat"))
local rendered_tree = rendered_parser:parse()[1]
check("renderer output parses without errors", not rendered_tree:root():has_error())

local rendered_counts = {}
local function count_rendered(node)
  rendered_counts[node:type()] = (rendered_counts[node:type()] or 0) + 1
  for child in node:iter_children() do
    count_rendered(child)
  end
end
count_rendered(rendered_tree:root())
check("renderer title/headers parsed", rendered_counts.title == 1 and rendered_counts.user_header == 1 and rendered_counts.assistant_header == 1)
check(
  "renderer names the first text after each header",
  rendered_counts.user_prompt == 1 and rendered_counts.assistant_message_header == 1,
  vim.inspect({ user_prompt = rendered_counts.user_prompt, assistant_message_header = rendered_counts.assistant_message_header })
)
check("renderer lists and quotes parsed", (rendered_counts.bullet or 0) == 1 and (rendered_counts.ordered or 0) == 1 and (rendered_counts.quote or 0) == 1)
check("renderer code block parsed", (rendered_counts.code_block or 0) == 1)
check("renderer tool exchange parsed", (rendered_counts.tool_exchange or 0) == 1)

-- 7. The plugin can start the highlighter on a dshchat buffer.
local started = treesitter.start(buf)
local active = vim.treesitter.highlighter and vim.treesitter.highlighter.active
check("treesitter.start attaches the highlighter", started and active ~= nil and active[buf] ~= nil)
if active and active[buf] then
  vim.treesitter.stop(buf)
end

print(("\n=== %d checks, %d failed ==="):format(checks, failures))
vim.cmd("cquit " .. (failures > 0 and 1 or 0))
