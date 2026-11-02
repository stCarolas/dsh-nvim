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
local tool_lines = compose_lines(surface.build(tool_records).entries)
check("tool call rendered", contains(tool_lines, "read("))
check("tool argument summarized", contains(tool_lines, "path=/tmp/x"))
check("tool output truncated", contains(tool_lines, "2 more lines"))
check("failed tool marked", contains(tool_lines, "exit code 1"))

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

-- 9. Prompt popup submits the typed text.
local prompt_ui = require("dsh.ui.prompt")
local submitted
prompt_ui.open({ title = "test" }, function(text)
  submitted = text
end)
local prompt_buf = vim.api.nvim_get_current_buf()
vim.api.nvim_buf_set_lines(prompt_buf, 0, -1, false, { "hello", "world" })
local keys = vim.api.nvim_replace_termcodes("<C-s>", true, false, true)
vim.api.nvim_feedkeys(keys, "x", false)
vim.wait(1000, function()
  return submitted ~= nil
end, 50)
check("prompt popup submits multiline text", submitted == "hello\nworld", tostring(submitted))
check("prompt popup window closed", not vim.api.nvim_buf_is_valid(prompt_buf))

print(("\n=== %d checks, %d failed ==="):format(checks, failures))
vim.cmd("cquit " .. (failures > 0 and 1 or 0))
