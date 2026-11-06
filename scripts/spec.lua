-- Rendering and UI specs against synthetic DSH history.
-- Run with: nvim --headless -l scripts/spec.lua
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h:h")
vim.opt.rtp:append(root)

local config = require("dsh.config")
local markdown = require("dsh.markdown")
local render = require("dsh.render")
local surface = require("dsh.surface")

--- Compose entries and return just the rendered lines.
local function compose_lines(entries)
  return render.compose(entries).lines
end

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

local function event(kind, seq, data, extra)
  local value = { type = "event", event = { type = kind, seq = seq, time = 0, data = data } }
  for key, val in pairs(extra or {}) do
    value.event[key] = val
  end
  return value
end

local function contains(lines, needle)
  for _, line in ipairs(lines) do
    if line:find(needle, 1, true) then
      return true
    end
  end
  return false
end

-- 1. Surface filtering: only real user messages and model output survive.
local records = {
  event("permission/preset", 0, { preset = "workspace-write" }),
  event("agent/inbox/spliced", 1, { target = "next-turn", start = 0, inserted = {} }),
  event("system/message", 2, { turn = 1, step = 1, message = { role = "system", content = { { type = "text", text = "you are an agent" } } } }),
  event("user/message", 3, { role = "user", content = { { type = "text", text = "hello there" } }, source = { kind = "user" } }),
  event("user/message", 4, { role = "user", content = { { type = "text", text = "Current runtime context…" } }, source = { kind = "runtime-context" } }),
  event("assistant/message", 5, {
    turn = 1,
    step = 1,
    message = {
      role = "assistant",
      source = { provider = "p", model = "m" },
      content = {
        { type = "reasoning", text = "thinking hard" },
        { type = "text", text = "hi, I can help" },
      },
    },
    stream = {},
  }),
  event("session/title", 6, { title = "Greeting" }),
}

local built = surface.build(records)
local lines = compose_lines(built.entries)
check("title extracted", built.title == "Greeting", built.title)
check("assistant rendered", contains(lines, "hi, I can help"))
check("user rendered", contains(lines, "hello there"))
check("system prompt filtered", not contains(lines, "you are an agent"))
check("runtime context filtered", not contains(lines, "Current runtime context"))
check("reasoning hidden by default", not contains(lines, "thinking hard"))
check("title line rendered", contains(lines, "# Greeting"))

-- The title line is optional; the winbar keeps the title either way.
config.options.chat.show_title = false
local without_title = compose_lines(surface.build(records).entries)
check("title line hidden when chat.show_title = false", not contains(without_title, "# Greeting"))
check("messages still rendered without the title line", contains(without_title, "hello there"))
config.options.chat.show_title = true

-- 2. Reasoning is opt-in.
config.options.show_reasoning = true
local with_reasoning = compose_lines(surface.build(records).entries)
check("reasoning shown when enabled", contains(with_reasoning, "thinking hard"))
config.options.show_reasoning = false

-- 3. Tool calls and results, including truncation.
config.options.tool_output_lines = 2
local tool_records = {
  event("tool/call", 1, { turn = 1, step = 1, callId = "c1", name = "read", arguments = '{"path":"/tmp/x","limit":10}' }),
  event("tool/result", 2, {
    turn = 1,
    step = 1,
    message = { role = "tool", isError = false, content = { { type = "text", text = "line1\nline2\nline3\nline4" } } },
  }),
  event("tool/call", 3, { turn = 1, step = 1, callId = "c2", name = "bash", arguments = "not json" }),
  event("tool/result", 4, {
    turn = 1,
    step = 1,
    message = { role = "tool", isError = true, content = { { type = "text", text = "exit code 1" } } },
  }),
}
local tool_view = render.compose(surface.build(tool_records).entries)
local tool_lines = tool_view.lines
check("tool call rendered", contains(tool_lines, "read("))
check("tool argument summarized", contains(tool_lines, "path=/tmp/x"))
check("tool output truncated", contains(tool_lines, "2 more lines"))
check("failed tool marked", contains(tool_lines, "exit code 1"))

--- Highlight group of the first line equal to `text`, or nil.
local function line_group(view, text)
  for index, line in ipairs(view.lines) do
    if line == text then
      return view.hl[index]
    end
  end
  return nil
end

-- Tool results are tabulated one level under the "  ⚙ name(args)" call line.
local TOOL_INDENT = "    "
check("tool output is an indented code block", contains(tool_lines, TOOL_INDENT .. "line1") and contains(tool_lines, TOOL_INDENT .. "line2"))
check("tool output drops the result marker", not contains(tool_lines, "↳"))
local function tool_call_line()
  for _, line in ipairs(tool_lines) do
    if line:find("⚙ read(", 1, true) then
      return line
    end
  end
  return nil
end
check(
  "tool output is tabulated under the call",
  tool_call_line() ~= nil and tool_call_line():match("^  ⚙ ") ~= nil and contains(tool_lines, TOOL_INDENT .. "line1"),
  tostring(tool_call_line())
)
check(
  "tool output uses the code-block group",
  line_group(tool_view, TOOL_INDENT .. "line1") == "DshCodeBlock",
  tostring(line_group(tool_view, TOOL_INDENT .. "line1"))
)
check(
  "truncation notice is labeled, not code",
  line_group(tool_view, TOOL_INDENT .. "… 2 more lines") == "DshTool",
  tostring(line_group(tool_view, TOOL_INDENT .. "… 2 more lines"))
)
check(
  "failed tool output keeps the error group",
  line_group(tool_view, TOOL_INDENT .. "exit code 1") == "DshToolError",
  tostring(line_group(tool_view, TOOL_INDENT .. "exit code 1"))
)
local empty_tool = render.compose({ { role = "tool_result", text = "" } })
check("empty tool output is marked", contains(empty_tool.lines, TOOL_INDENT .. "(empty)"))

-- Code blocks are verbatim: Markdown inside tool output must not be styled.
local verbatim_tool = render.compose({ { role = "tool_result", text = "# not a heading\n**not bold**" } })
check(
  "tool output is not interpreted as Markdown",
  contains(verbatim_tool.lines, TOOL_INDENT .. "# not a heading")
    and contains(verbatim_tool.lines, TOOL_INDENT .. "**not bold**")
    and #verbatim_tool.spans == 0,
  ("%d styled spans"):format(#verbatim_tool.spans)
)

-- 4. Compaction: surfaceOp replace drops the messages it shadowed.
local compaction = {
  event("user/message", 1, { role = "user", content = { { type = "text", text = "old question" } }, source = { kind = "user" } }),
  event("assistant/message", 2, {
    turn = 1,
    step = 1,
    message = { role = "assistant", source = { provider = "p", model = "m" }, content = { { type = "text", text = "old answer" } } },
    stream = {},
  }),
  event("user/message", 3, {
    role = "user",
    content = { { type = "text", text = "[summary of earlier turns]" } },
    source = { kind = "user" },
  }, { surfaceOp = { op = "replace", startSeq = 1, endSeq = 2 } }),
}
local compacted = compose_lines(surface.build(compaction).entries)
check("replaced user message dropped", not contains(compacted, "old question"))
check("replaced assistant message dropped", not contains(compacted, "old answer"))
check("summary kept", contains(compacted, "summary of earlier turns"))

-- 5. Failures surface even when only an attempt was logged.
local failure = {
  event("assistant/attempt", 5, {
    turn = 1,
    step = 1,
    stream = { { type = "chunk", chunk = { type = "finish", reason = { kind = "error", failure = { code = "MISSING_CREDENTIAL", message = "no API key" } } } } },
  }),
  event("turn/end", 6, { turn = 1, reason = { kind = "error", error = { message = "no API key" } } }),
}
local failure_lines = compose_lines(surface.build(failure).entries)
check("turn error rendered", contains(failure_lines, "no API key"))

-- 6. Interrupted assistant turns are labeled.
local interrupted = {
  event("assistant/message", 1, {
    turn = 1,
    step = 1,
    interrupted = true,
    message = { role = "assistant", source = { provider = "p", model = "m" }, content = { { type = "text", text = "partial" } } },
    stream = {},
  }),
}
check("interrupted labeled", contains(compose_lines(surface.build(interrupted).entries), "interrupted"))

-- 9. Session list ordering.
local session = require("dsh.session")

-- 9b. Multibyte tool arguments are truncated on character boundaries.
-- Byte slicing used to cut Cyrillic text in half and leave buffer lines that
-- `vim.fn.json_encode` (and completion clients such as windsurf.nvim) reject
-- with E474.
local multibyte_arguments = vim.json.encode({
  command = string.rep("Цели сбора ", 30),
  description = "Verify donation goal widget title/type)",
})
local multibyte_summary = session.summarize_arguments(multibyte_arguments)
check("summarized arguments stay valid UTF-8", pcall(vim.fn.json_encode, multibyte_summary))
check(
  "summarized arguments truncate by characters",
  vim.fn.strchars(multibyte_summary) <= 160,
  tostring(vim.fn.strchars(multibyte_summary))
)
local multibyte_view = render.compose(surface.build({
  event("tool/call", 1, { turn = 1, step = 1, callId = "c1", name = "bash", arguments = multibyte_arguments }),
  event("tool/result", 2, {
    turn = 1,
    step = 1,
    message = { role = "tool", isError = false, content = { { type = "text", text = "console:200" } } },
  }),
}).entries)
local multibyte_valid = true
for _, line in ipairs(multibyte_view.lines) do
  if not pcall(vim.fn.json_encode, line) then
    multibyte_valid = false
  end
end
check("multibyte tool call lines stay valid UTF-8", multibyte_valid, vim.inspect(multibyte_view.lines))
check("multibyte tool call keeps its summary", contains(multibyte_view.lines, "description=Verify"))

local sample = {
  { sessionId = "b", updatedAt = 300 },
  { sessionId = "a", updatedAt = 100 },
  { sessionId = "c", updatedAt = 200 },
  { sessionId = "d" },
}

local function ids(items)
  local out = {}
  for _, item in ipairs(items) do
    out[#out + 1] = item.sessionId
  end
  return table.concat(out, ",")
end

config.options.sessions.order = "oldest"
local oldest = session.order(vim.deepcopy(sample))
check("sessions ordered least recent first", ids(oldest) == "d,a,c,b", ids(oldest))

config.options.sessions.order = "none"
local untouched = session.order(vim.deepcopy(sample))
check("order=none keeps server order", ids(untouched) == "b,a,c,d", ids(untouched))

config.options.sessions.order = "newest"
local newest = session.order(vim.deepcopy(sample))
check("order=newest puts recent first", ids(newest) == "b,c,a,d", ids(newest))

local ties = session.order({
  { sessionId = "z", updatedAt = 5 },
  { sessionId = "a", updatedAt = 5 },
})
check("equal timestamps tie-break by id", ids(ties) == "a,z", ids(ties))

config.options.sessions.order = "oldest"

-- 10. Markdown rendering of agent output.
local source = table.concat({
  "# Release notes",
  "",
  "Some **bold**, `inline code` and a [label](https://example.com).",
  "",
  "- first item",
  "- [x] finished task",
  "",
  "> quoted line",
  "",
  "---",
  "",
  "```lua",
  "local x = 1",
  "```",
}, "\n")

local composed = render.compose({
  { role = "user", text = "**literal prompt**" },
  { role = "assistant", text = source },
})

local function span_text(result, group)
  for _, span in ipairs(result.spans) do
    if span.group == group then
      local line = result.lines[span.row] or ""
      return line:sub(span.start_col + 1, span.end_col)
    end
  end
  return nil
end

check("heading marker stripped", contains(composed.lines, "Release notes") and not contains(composed.lines, "# Release"))
check("bold span", span_text(composed, "DshBold") == "bold", tostring(span_text(composed, "DshBold")))
check("inline code span", span_text(composed, "DshCode") == "inline code", tostring(span_text(composed, "DshCode")))
check("link span", span_text(composed, "DshLink") == "label", tostring(span_text(composed, "DshLink")))
check("list bullet", contains(composed.lines, "• first item"))
check("task checkbox", contains(composed.lines, "☑ finished task"))
check("blockquote bar", contains(composed.lines, "│ quoted line"))
check("horizontal rule", contains(composed.lines, "────"))
check("code block indented", contains(composed.lines, "  local x = 1"))
check("code block grouped", (function()
  for _, group in ipairs(composed.hl) do
    if group == "DshCodeBlock" then
      return true
    end
  end
  return false
end)())
check("fence language virtual text", (function()
  for _, item in ipairs(composed.virt) do
    if item.text:find("lua", 1, true) then
      return true
    end
  end
  return false
end)())
check("user prompt stays literal", contains(composed.lines, "**literal prompt**"))
check("user prompt not styled bold", (function()
  for _, span in ipairs(composed.spans) do
    if span.group == "DshBold" and (composed.lines[span.row] or ""):find("literal", 1, true) then
      return false
    end
  end
  return true
end)())

-- 10b. Inline markup must not swallow the byte after it. Every run used to be
-- advanced by its 1-based end position instead of its length, skipping the
-- character that followed — usually the space around `code` and **bold**.
local inline_cases = {
  { "The `variable` holds a value.", "The variable holds a value." },
  { "Some **bold**, then more.", "Some bold, then more." },
  { "A *slight* pause, then text.", "A slight pause, then text." },
  { "See [the docs](https://x.dev) for detail.", "See the docs for detail." },
  { "This ~~old~~ thing stays.", "This old thing stays." },
  { "Visit <https://x.dev> now.", "Visit https://x.dev now." },
  { "Glue **a**`b`**c**. end", "Glue abc. end" },
  { "Escaped \\* star.", "Escaped * star." },
  { "Run `x` → done, 日本語.", "Run x → done, 日本語." },
}

for _, case in ipairs(inline_cases) do
  local rendered = markdown.render(case[1], { code_highlight = false })
  local line = rendered.lines[1]
  check("inline text intact: " .. case[1], line == case[2], tostring(line))
  local code_span = span_text(rendered, "DshCode")
  if case[1]:find("`", 1, true) then
    local expected = case[1]:match("`([^`]+)`")
    check("inline code span aligns: " .. case[1], code_span == expected, tostring(code_span))
  end
end

-- The same guarantee holds end to end, through the composed chat view.
check(
  "inline spacing survives composition",
  contains(compose_lines({
    { role = "assistant", text = "Set the `variable` and **retry** the call." },
  }), "Set the variable and retry the call.")
)

-- 10c. Incomplete constructs render literally instead of being dropped.
local degenerate_cases = {
  { "`unclosed code", "`unclosed code" },
  { "__unclosed bold", "__unclosed bold" },
  { "~~unclosed strike", "~~unclosed strike" },
  { "[label](unclosed", "[label](unclosed" },
  { "<https://unclosed", "<https://unclosed" },
  { "\\", "\\" },
  { "a**b**c*d*e", "abcde" },
  { "plain [[[[ text ]]]] tail", "plain [[[[ text ]]]] tail" },
  { "mixed `a` and **b** and *c* end", "mixed a and b and c end" },
}

for _, case in ipairs(degenerate_cases) do
  local rendered = markdown.render(case[1], { code_highlight = false })
  check("degenerate inline: " .. case[1], rendered.lines[1] == case[2], tostring(rendered.lines[1]))
end

-- 10d. Rendering stays linear. The scanner used to re-slice the remaining text
-- at every byte, so a long message was quadratic (hundreds of KiB froze the UI).
local big_message = string.rep("plain words and `code` ", 9000)
local started = (vim.uv or vim.loop).hrtime()
markdown.render(big_message, { code_highlight = false })
local elapsed_ms = ((vim.uv or vim.loop).hrtime() - started) / 1e6
check("large message renders quickly", elapsed_ms < 3000, ("%.0f ms"):format(elapsed_ms))

-- 10e. A session title is untrusted: `'winbar'` must show it literally and
-- never evaluate it. The title is LLM-generated, and `%{…}` is Vimscript.
local escaped_plain = render.winbar("Improve 50% coverage", "idle")
local ok_plain, plain_error = pcall(function()
  vim.wo.winbar = escaped_plain
end)
check("winbar accepts a percent title", ok_plain, tostring(plain_error))
local ok_view, viewed = pcall(vim.api.nvim_eval_statusline, vim.wo.winbar, {
  winid = vim.api.nvim_get_current_win(),
})
check(
  "winbar shows the percent literally",
  ok_view and viewed.str:find("50% coverage", 1, true) ~= nil,
  ok_view and tostring(viewed.str) or tostring(viewed)
)

vim.g.dsh_winbar_pwned = nil
local hostile = render.winbar("%{execute('let g:dsh_winbar_pwned = 1')}", "idle")
local ok_hostile, hostile_error = pcall(function()
  vim.wo.winbar = hostile
end)
check("winbar accepts an expression title", ok_hostile, tostring(hostile_error))
local ok_hostile_view, hostile_view = pcall(vim.api.nvim_eval_statusline, vim.wo.winbar, {
  winid = vim.api.nvim_get_current_win(),
})
check("winbar does not execute the title", vim.g.dsh_winbar_pwned == nil, tostring(vim.g.dsh_winbar_pwned))
check(
  "winbar shows the expression literally",
  ok_hostile_view and hostile_view.str:find("%{execute", 1, true) ~= nil,
  ok_hostile_view and tostring(hostile_view.str) or tostring(hostile_view)
)
vim.wo.winbar = ""
check("winbar flattens line breaks", not render.winbar("line one\nline two", nil):find("\n", 1, true))

-- 10f. While a turn streams, the winbar previews the newest assistant message.
local preview_entries = {
  { role = "assistant", text = "older answer" },
  { role = "user", text = "next question" },
  { role = "live", text = "working on it\nnow" },
}
check(
  "last assistant prefers the live message",
  render.last_assistant(preview_entries) == "working on it now",
  tostring(render.last_assistant(preview_entries))
)
check(
  "last assistant falls back to a completed message",
  render.last_assistant({ { role = "assistant", text = " done " } }) == "done"
)
check(
  "last assistant skips blank messages",
  render.last_assistant({ { role = "assistant", text = "  " }, { role = "user", text = "hi" } }) == nil
)
check("last assistant handles an empty view", render.last_assistant(nil) == nil)

local streaming_bar = render.winbar("Session title", "streaming", "working on it now")
local ok_stream, stream_view = pcall(vim.api.nvim_eval_statusline, streaming_bar, {
  winid = vim.api.nvim_get_current_win(),
})
check(
  "streaming winbar shows the preview",
  ok_stream and stream_view.str:find("working on it now", 1, true) ~= nil,
  ok_stream and tostring(stream_view.str) or tostring(stream_view)
)
check(
  "streaming winbar hides the title",
  ok_stream and stream_view.str:find("Session title", 1, true) == nil,
  ok_stream and tostring(stream_view.str) or tostring(stream_view)
)
check(
  "streaming winbar keeps the status",
  ok_stream and stream_view.str:find("streaming", 1, true) ~= nil,
  ok_stream and tostring(stream_view.str) or tostring(stream_view)
)

local idle_bar = render.winbar("Session title", "idle", "working on it now")
local ok_idle, idle_view = pcall(vim.api.nvim_eval_statusline, idle_bar, {
  winid = vim.api.nvim_get_current_win(),
})
check(
  "idle winbar restores the title",
  ok_idle and idle_view.str:find("Session title", 1, true) ~= nil,
  ok_idle and tostring(idle_view.str) or tostring(idle_view)
)
check(
  "idle winbar drops the preview",
  ok_idle and idle_view.str:find("working on it now", 1, true) == nil,
  ok_idle and tostring(idle_view.str) or tostring(idle_view)
)
check(
  "winbar without a preview keeps the title",
  render.winbar("Session title", "streaming", ""):find("Session title", 1, true) ~= nil
)

vim.g.dsh_winbar_preview_pwned = nil
local hostile_preview = render.winbar("t", "streaming", "%{execute('let g:dsh_winbar_preview_pwned = 1')}")
local ok_preview, preview_view = pcall(vim.api.nvim_eval_statusline, hostile_preview, {
  winid = vim.api.nvim_get_current_win(),
})
check("winbar preview is not evaluated", vim.g.dsh_winbar_preview_pwned == nil, tostring(vim.g.dsh_winbar_preview_pwned))
check(
  "winbar preview is displayed literally",
  ok_preview and preview_view.str:find("%{execute", 1, true) ~= nil,
  ok_preview and tostring(preview_view.str) or tostring(preview_view)
)
vim.wo.winbar = ""

-- 10. Markdown can be disabled.
config.options.markdown.enabled = false
local plain = compose_lines({ { role = "assistant", text = "# Release notes" } })
check("markdown disabled keeps source", contains(plain, "# Release notes"))
config.options.markdown.enabled = true

-- 11. Live streamed assistant text renders with a cursor marker.
local live_lines = compose_lines({
  { role = "user", text = "hi" },
  { role = "live", text = "partial ans" },
})
check("live block rendered", contains(live_lines, "partial ans"))
check("live cursor marker", contains(live_lines, "▍"))
check("live block has assistant header", contains(live_lines, "▌ Assistant"))

-- 8. Empty history has a helpful placeholder.
local empty_lines = compose_lines(surface.build({}).entries)
check("empty placeholder", contains(empty_lines, "No messages yet"))

-- 8. Highlights land on the right lines.
local hl_buf = vim.api.nvim_create_buf(false, true)
render.render(hl_buf, surface.build(records).entries)
local namespace = vim.api.nvim_get_namespaces()["dsh-chat"]
local marks = vim.api.nvim_buf_get_extmarks(hl_buf, namespace, 0, -1, { details = true })
check("extmarks applied", #marks > 0, ("%d marks"):format(#marks))
local groups = {}
for _, mark in ipairs(marks) do
  groups[mark[4].hl_group] = true
end
check("user header highlighted", groups.DshUserHeader == true)
check("title highlighted", groups.DshTitle == true)
local hl_lines = vim.api.nvim_buf_get_lines(hl_buf, 0, -1, false)
local user_line
for index, line in ipairs(hl_lines) do
  if line:find("▌ You", 1, true) then
    user_line = index
  end
end
check("user header present in buffer", user_line ~= nil)
if user_line then
  local covered = false
  for _, mark in ipairs(marks) do
    local row, end_row = mark[2], mark[4].end_row
    if mark[4].hl_group == "DshUserHeader" and row <= user_line - 1 and (end_row == nil or end_row >= user_line) then
      covered = true
    end
  end
  check("user header highlight covers its line", covered)
end

-- 9. The floating prompt cancels on <Esc>/q and submits on <C-s>.
local prompt_ui = require("dsh.ui.prompt")
local function buffer_has_map(buf, mode, lhs)
  for _, map in ipairs(vim.api.nvim_buf_get_keymap(buf, mode)) do
    if map.lhs == lhs then
      return true
    end
  end
  return false
end
local esc_key = vim.api.nvim_replace_termcodes("<Esc>", true, false, true)

local escaped_submit = false
prompt_ui.open({ title = "esc cancel" }, function()
  escaped_submit = true
end)
local esc_win = vim.api.nvim_get_current_win()
local esc_buf = vim.api.nvim_get_current_buf()
check("prompt popup cancels on normal-mode Esc", buffer_has_map(esc_buf, "n", "<Esc>"))
check("prompt popup cancels on insert-mode Esc", buffer_has_map(esc_buf, "i", "<Esc>"))
check("prompt popup keeps insert-mode q free", not buffer_has_map(esc_buf, "i", "q"))
vim.api.nvim_feedkeys(esc_key, "x", false)
vim.wait(1000, function()
  return not vim.api.nvim_win_is_valid(esc_win)
end, 50)
check("Esc closes the prompt popup", not vim.api.nvim_win_is_valid(esc_win) and not vim.api.nvim_buf_is_valid(esc_buf))
check("Esc does not submit", escaped_submit == false)

local submitted
prompt_ui.open({ title = "test" }, function(text)
  submitted = text
end)
local prompt_buf = vim.api.nvim_get_current_buf()
check("prompt popup buffer is unlisted", vim.bo[prompt_buf].buflisted == false)
check("prompt popup maps normal-mode q to cancel", buffer_has_map(prompt_buf, "n", "q"))
vim.api.nvim_buf_set_lines(prompt_buf, 0, -1, false, { "hello", "world" })
local keys = vim.api.nvim_replace_termcodes("<C-s>", true, false, true)
vim.api.nvim_feedkeys(keys, "x", false)
vim.wait(1000, function()
  return submitted ~= nil
end, 50)
check("prompt popup submits multiline text", submitted == "hello\nworld", tostring(submitted))
check("prompt popup window closed", not vim.api.nvim_buf_is_valid(prompt_buf))

-- 9b. `prompt.open_in = "split"` opens the prompt in its own buffer window.
config.setup({ notifications = false, prompt = { open_in = "split", split = "horizontal", height = 6 } })
local origin = vim.api.nvim_get_current_win()
local windows_before = #vim.api.nvim_list_wins()
local window_submitted
prompt_ui.open({ title = "window prompt" }, function(text)
  window_submitted = text
end)
local window_win = vim.api.nvim_get_current_win()
local window_buf = vim.api.nvim_get_current_buf()

check("split prompt opens a separate window", #vim.api.nvim_list_wins() == windows_before + 1)
check("split prompt buffer is named", vim.api.nvim_buf_get_name(window_buf):match("^dsh://prompt/") ~= nil, vim.api.nvim_buf_get_name(window_buf))
check(
  "split prompt buffer is special",
  vim.bo[window_buf].buftype == "nofile" and vim.bo[window_buf].bufhidden == "wipe" and not vim.bo[window_buf].swapfile,
  ("buftype=%s bufhidden=%s"):format(vim.bo[window_buf].buftype, vim.bo[window_buf].bufhidden)
)
check("split prompt buffer is unlisted", vim.bo[window_buf].buflisted == false)
local prompt_ls = vim.api.nvim_exec2("ls", { output = true }).output
check("split prompt buffer is absent from :ls", prompt_ls:find("dsh://prompt", 1, true) == nil, prompt_ls)
check("split prompt window has a winbar", vim.wo[window_win].winbar:find("window prompt", 1, true) ~= nil, vim.wo[window_win].winbar)
check("split prompt keeps normal-mode Esc free", not buffer_has_map(window_buf, "n", "<Esc>"))
check("split prompt keeps insert-mode Esc free", not buffer_has_map(window_buf, "i", "<Esc>"))
check("split prompt keeps insert-mode q free", not buffer_has_map(window_buf, "i", "q"))
vim.api.nvim_feedkeys(esc_key, "x", false)
check("Esc does not close the split prompt", vim.api.nvim_win_is_valid(window_win) and vim.api.nvim_buf_is_valid(window_buf))

vim.api.nvim_buf_set_lines(window_buf, 0, -1, false, { "first", "second" })
vim.api.nvim_feedkeys(keys, "x", false)
vim.wait(1000, function()
  return window_submitted ~= nil
end, 50)
check("split prompt submits multiline text", window_submitted == "first\nsecond", tostring(window_submitted))
check("split prompt window closes", not vim.api.nvim_win_is_valid(window_win))
check("split prompt buffer is wiped", not vim.api.nvim_buf_is_valid(window_buf))
check("split prompt returns to the origin window", vim.api.nvim_get_current_win() == origin)

-- 9c. Cancelling from the split window wipes it without submitting.
config.setup({ notifications = false, prompt = { open_in = "split", split = "vertical", width = 50 } })
local cancelled = false
prompt_ui.open({ title = "cancel prompt" }, function()
  cancelled = true
end)
local cancel_win = vim.api.nvim_get_current_win()
local cancel_buf = vim.api.nvim_get_current_buf()
local expected_width = math.max(10, math.min(50, math.max(10, vim.o.columns - 10)))
check("vertical split prompt uses the configured width", vim.api.nvim_win_get_width(cancel_win) == expected_width, ("%d vs %d"):format(vim.api.nvim_win_get_width(cancel_win), expected_width))
vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("q", true, false, true), "x", false)
vim.wait(1000, function()
  return not vim.api.nvim_win_is_valid(cancel_win)
end, 50)
check("q cancels the split prompt", not vim.api.nvim_win_is_valid(cancel_win))
check("q does not submit", cancelled == false)
check("q wipes the prompt buffer", not vim.api.nvim_buf_is_valid(cancel_buf))

-- 9d. Closing the prompt window directly cleans up the buffer.
prompt_ui.open({ title = "close prompt" }, function() end)
local closed_buf = vim.api.nvim_get_current_buf()
vim.cmd("close")
vim.wait(1000, function()
  return not vim.api.nvim_buf_is_valid(closed_buf)
end, 50)
check("closing the prompt window wipes its buffer", not vim.api.nvim_buf_is_valid(closed_buf))

-- Replacing the buffer in the prompt window must still close the window; the
-- cleanup runs deferred because doing it inside BufWipeout trips E937.
prompt_ui.open({ title = "enew prompt" }, function() end)
local enew_win = vim.api.nvim_get_current_win()
local enew_buf = vim.api.nvim_get_current_buf()
local enew_ok, enew_err = pcall(vim.cmd, "enew")
vim.wait(1000, function()
  return not vim.api.nvim_win_is_valid(enew_win)
end, 50)
check(":enew in the prompt window does not error", enew_ok, tostring(enew_err))
check(":enew in the prompt window closes it", not vim.api.nvim_win_is_valid(enew_win))
check(":enew wipes the prompt buffer", not vim.api.nvim_buf_is_valid(enew_buf))

-- 9e. Unknown prompt values are normalized instead of failing later.
local prompt_warnings = {}
local original_notify = vim.notify
vim.notify = function(message)
  prompt_warnings[#prompt_warnings + 1] = message
end
config.setup({ prompt = { open_in = "popup", split = "diagonal", width = -1, height = 0 } })
vim.notify = original_notify
check("invalid prompt.open_in falls back to float", config.options.prompt.open_in == "float", tostring(config.options.prompt.open_in))
check("invalid prompt.split falls back to horizontal", config.options.prompt.split == "horizontal", tostring(config.options.prompt.split))
check(
  "invalid prompt size falls back to the defaults",
  config.options.prompt.width == 80 and config.options.prompt.height == 10,
  ("%s x %s"):format(tostring(config.options.prompt.width), tostring(config.options.prompt.height))
)
check("invalid prompt values are reported", #prompt_warnings == 2, tostring(#prompt_warnings))
config.setup({ notifications = false, prompt = { open_in = "split" } })
check(
  "partial prompt config keeps the other defaults",
  config.options.prompt.split == "horizontal" and config.options.prompt.width == 80,
  ("split=%s width=%s"):format(tostring(config.options.prompt.split), tostring(config.options.prompt.width))
)
config.setup({ notifications = false })

-- 13. Follow status tracks turn boundaries, not merely the open stream.
local follow_handlers
package.loaded["dsh.mux"] = {
  acquire = function(_, callback)
    callback(nil)
  end,
  stream = function(_, _, handlers)
    follow_handlers = handlers
    return "stream-follow"
  end,
  cancel = function() end,
  close = function() end,
}
local follow = require("dsh.follow")
local follow_statuses = {}
local follow_handle = follow.attach({ url = "http://test" }, "session-follow", {
  on_status = function(status)
    follow_statuses[#follow_statuses + 1] = status
  end,
})

follow_handlers.on_item({ type = "snapshot", cursor = 0, records = {}, projections = {}, header = {} })
check("idle snapshot reports idle", follow_statuses[#follow_statuses] == "idle", vim.inspect(follow_statuses))

follow_handlers.on_item({ type = "event", event = { type = "turn/start", seq = 1, data = {} } })
check("turn start reports streaming", follow_statuses[#follow_statuses] == "streaming", vim.inspect(follow_statuses))

follow_handlers.on_item({ type = "assistant-stream", frame = { type = "start" } })
follow_handlers.on_item({
  type = "assistant-stream",
  frame = { type = "chunk", chunk = { type = "text-delta", text = "hello" } },
})
check("live chunks keep streaming", follow_statuses[#follow_statuses] == "streaming", vim.inspect(follow_statuses))

follow_handlers.on_item({ type = "event", event = { type = "turn/end", seq = 2, data = {} } })
check("turn end reports idle", follow_statuses[#follow_statuses] == "idle", vim.inspect(follow_statuses))

follow_handlers.on_item({
  type = "snapshot",
  cursor = 3,
  projections = {},
  records = {
    { event = { type = "turn/start", seq = 3, data = {} } },
    { event = { type = "assistant/message", seq = 4, data = {} } },
  },
})
check("mid-turn snapshot reports streaming", follow_statuses[#follow_statuses] == "streaming", vim.inspect(follow_statuses))

follow_handlers.on_item({
  type = "snapshot",
  cursor = 5,
  projections = {},
  records = {
    { event = { type = "turn/start", seq = 3, data = {} } },
    { event = { type = "turn/end", seq = 5, data = {} } },
  },
})
check("completed snapshot reports idle", follow_statuses[#follow_statuses] == "idle", vim.inspect(follow_statuses))
follow_handle.detach()

print(("\n=== %d checks, %d failed ==="):format(checks, failures))
vim.cmd("cquit " .. (failures > 0 and 1 or 0))
