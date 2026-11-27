-- Trajectory view specs: the event-log projection, its tree rendering, and the
-- tab/buffer behaviour of :DshTrajectory.
-- Run with: nvim --headless -l scripts/trajectory_spec.lua
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h:h")
vim.opt.rtp:append(root)

local config = require("dsh.config")
config.setup({ notifications = false, treesitter = false })

-- Stub the transports: the projection, the buffer and the view orchestration
-- are real, the server and the socket are not.
local follow_attachments = {}
local follow_targets = {}
package.loaded["dsh.server"] = {
  context = function(callback)
    callback(nil, { url = "http://127.0.0.1:1", cookie = "cookie", mint = function()
      return "minted"
    end })
  end,
  describe = function()
    return { running = false }
  end,
  is_running = function()
    return false
  end,
  start = function() end,
  stop = function() end,
  mint_cookie = function()
    return "minted"
  end,
}
package.loaded["dsh.follow"] = {
  attach = function(_, target, callbacks)
    follow_targets[#follow_targets + 1] = target
    -- A subagent view follows through its parent-qualified address; every other
    -- view follows by session id.
    local key = type(target) == "table" and (target.sessionId or target.childSessionId) or target
    follow_attachments[key] = follow_attachments[key] or {}
    table.insert(follow_attachments[key], callbacks)
    return { detach = function() end, state = {} }
  end,
}
package.loaded["dsh.mux"] = {
  close = function() end,
  is_connected = function()
    return false
  end,
  acquire = function(_, callback)
    callback(nil)
  end,
  stream = function()
    return "events-stream"
  end,
  cancel = function() end,
  credential = function()
    return "minted"
  end,
}

local trajectory = require("dsh.trajectory")
local session = require("dsh.session")

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

local function event(kind, seq, time, data)
  return { type = "event", event = { type = kind, seq = seq, time = time, data = data } }
end

--- First row of `kind`, optionally the `nth` one.
local function row_of(rows, kind, nth)
  local seen = 0
  for _, row in ipairs(rows) do
    if row.kind == kind then
      seen = seen + 1
      if seen == (nth or 1) then
        return row
      end
    end
  end
  return nil
end

--- Every row of `kind`.
local function rows_of(rows, kind)
  local out = {}
  for _, row in ipairs(rows) do
    if row.kind == kind then
      out[#out + 1] = row
    end
  end
  return out
end

--- Whether a row text contains `needle`.
local function has(row, needle)
  return row ~= nil and type(row.text) == "string" and row.text:find(needle, 1, true) ~= nil
end

local function text_of(row)
  return row and row.text or ""
end

local function contains_line(lines, needle)
  for _, line in ipairs(lines) do
    if line:find(needle, 1, true) then
      return true
    end
  end
  return false
end

local function line_index(lines, needle)
  for index, line in ipairs(lines) do
    if line:find(needle, 1, true) then
      return index
    end
  end
  return nil
end

-- 1. Formatting helpers the labels are built from.
check("duration in milliseconds", trajectory.duration(320) == "320ms", trajectory.duration(320))
check("duration in seconds", trajectory.duration(4300) == "4.3s", trajectory.duration(4300))
check("duration in minutes", trajectory.duration(72000) == "1m 12s", trajectory.duration(72000))
check("duration rejects a missing value", trajectory.duration(nil) == nil)
check("reason: completed", trajectory.reason_label({ kind = "completed" }) == "completed")
check("reason: aborted names the canceller", trajectory.reason_label({ kind = "aborted", reason = { kind = "user" } }) == "aborted by user")
check("reason: max tokens", trajectory.reason_label({ kind = "max-tokens" }) == "max tokens")

-- Token timestamps ignore chunks that carry no text.
local first, last = trajectory.token_times({
  { type = "chunk", time = 50, chunk = { type = "block-start" } },
  { type = "text-chunks", time0 = 100, index = 0, dt = { 10, 20 }, texts = { "a", "b", "c" } },
  { type = "chunk", time = 900, chunk = { type = "finish" } },
})
check("token_times starts at the first delta", first == 100, tostring(first))
check("token_times ends at the last delta", last == 130, tostring(last))

-- 2. One turn, one step, one prompt, one tool exchange.
local basic = {
  event("permission/preset", 0, 800, { preset = "workspace-write" }),
  event("turn/start", 1, 900, { turn = 1 }),
  event("step/start", 2, 1000, { turn = 1, step = 1 }),
  event("system/message", 3, 1010, {
    turn = 1,
    step = 1,
    message = { role = "system", content = { { type = "text", text = "You are an agent.\nSecond line." } } },
  }),
  event("user/message", 4, 1020, {
    role = "user",
    content = { { type = "text", text = "fix the parser" } },
    source = { kind = "user" },
  }),
  event("user/message", 5, 1030, {
    role = "user",
    content = { { type = "text", text = "Current runtime context." } },
    source = { kind = "runtime-context" },
  }),
  event("request/header", 6, 1040, {
    header = {
      config = { provider = "p", model = "m", temperature = 0.2 },
      tools = { { name = "bash" }, { name = "read" } },
    },
    reason = "initial",
  }),
  event("assistant/message", 7, 1200, {
    turn = 1,
    step = 1,
    message = {
      role = "assistant",
      source = { kind = "model", provider = "p", model = "m" },
      content = {
        { type = "reasoning", text = "thinking hard" },
        { type = "text", text = "Looking at the grammar." },
        { type = "tool-call", id = "c1", name = "bash", arguments = "{}" },
      },
    },
    stream = { { type = "text-chunks", time0 = 1070, index = 0, dt = { 10, 20 }, texts = { "Look", "ing", "." } } },
    usage = { inputTokens = 163, outputTokens = 2, cacheReadTokens = 9728 },
  }),
  event("tool/call", 8, 1080, { turn = 1, step = 1, callId = "c1", name = "bash", arguments = '{"command":"ls"}' }),
  event("tool/result", 9, 1180, {
    turn = 1,
    step = 1,
    message = {
      role = "tool",
      source = { kind = "tool", callId = "c1" },
      toolCallId = "c1",
      content = { { type = "text", text = "a\nb\nc" } },
      isError = false,
    },
    meta = { cwd = "/tmp" },
  }),
  event("step/end", 10, 1200, { turn = 1, step = 1 }),
  event("turn/end", 11, 1300, { turn = 1, reason = { kind = "completed" } }),
  event("session/title", 12, 1400, { title = "Fallback title" }),
  event("session/title", 13, 1500, { title = "Parser fix" }),
}

local built = trajectory.build(basic, { session_id = "session-11111111-2222-3333-4444-555555555555" })
local rows = built.rows

check("title uses the latest session/title", built.title == "Parser fix", tostring(built.title))
check("session row leads the view", rows[1].kind == "session" and rows[1].text == "Session  Parser fix", text_of(rows[1]))
local meta_row = rows[2]
check("meta row sits under the title", meta_row.kind == "meta" and meta_row.depth == 1)
check("meta row names the session", has(meta_row, "session 11111111"), text_of(meta_row))
check("meta row counts turns and steps", has(meta_row, "1 turn") and has(meta_row, "1 step"), text_of(meta_row))
check("meta row totals tokens", has(meta_row, "in 163") and has(meta_row, "out 2"), text_of(meta_row))
check("meta row totals the cache", has(meta_row, "cache read 9.7k"), text_of(meta_row))
check("meta row counts ignored events", has(meta_row, "1 other event"), text_of(meta_row))

local turn = row_of(rows, "turn", 1)
check("turn row opens the turn", has(turn, "Turn 1"), text_of(turn))
check("turn row shows its duration", has(turn, "400ms"), text_of(turn))
check("turn row shows how it ended", has(turn, "completed"), text_of(turn))
check("turn sits at the first tree level", turn.depth == 1, tostring(turn.depth))

local step = row_of(rows, "step", 1)
check("step row sits under the turn", step.depth == 2, tostring(step.depth))
check("step row shows its duration", has(step, "Step 1") and has(step, "200ms"), text_of(step))
check("a closed step is not labelled running", not has(step, "running"), text_of(step))

local system = row_of(rows, "system", 1)
check("system prompt row counts lines", has(system, "System prompt") and has(system, "2 lines"), text_of(system))
check("records sit under the step", system.depth == 3, tostring(system.depth))

local user = row_of(rows, "user", 1)
check("a human prompt is a You row", has(user, "You") and has(user, '"fix the parser"'), text_of(user))
local context = row_of(rows, "context", 1)
check("injected context names its producer", has(context, "Context (runtime-context)"), text_of(context))

local request = row_of(rows, "request", 1)
check("request row names provider, model and tools", has(request, "p · m") and has(request, "2 tools") and has(request, "initial"), text_of(request))
check("request detail lists the config", contains_line(request.detail, "provider: p") and contains_line(request.detail, "temperature: 0.2"))
check("request detail lists the tools", contains_line(request.detail, "tools: bash, read"))

local assistant = row_of(rows, "assistant", 1)
check("assistant row names the model", has(assistant, "p · m"), text_of(assistant))
check("assistant row shows token usage", has(assistant, "in 163 → out 2"), text_of(assistant))
check("assistant row shows time to first token", has(assistant, "ttft 70ms"), text_of(assistant))
check("assistant row shows generation time", has(assistant, "gen 30ms"), text_of(assistant))
check("assistant preview keeps the text", has(assistant, "Looking at the grammar."), text_of(assistant))
check("assistant preview hides reasoning", not has(assistant, "thinking hard"), text_of(assistant))
check("assistant detail shows reasoning", contains_line(assistant.detail, "[reasoning] thinking hard"))

local tool = row_of(rows, "tool", 1)
check("tool row names the call and its arguments", has(tool, "⚙ bash") and has(tool, "command=ls"), text_of(tool))
check("tool row shows its duration", has(tool, "100ms"), text_of(tool))
check("tool row shows the result size", has(tool, "3 lines"), text_of(tool))
check("tool detail keeps the raw arguments", contains_line(tool.detail, '{"command":"ls"}'))
check("tool detail shows the result body", contains_line(tool.detail, "b"))
check("tool detail shows tool meta", contains_line(tool.detail, "meta:"))

-- 3. Flat rendering, indentation and expansion state.
local rendered = trajectory.lines(rows, {})
check("rendering produces one line per row", #rendered.lines == #rows, ("%d vs %d"):format(#rendered.lines, #rows))
check("indentation follows the tree", rendered.lines[1]:sub(1, 1) == "S" and rendered.lines[#rendered.lines]:sub(1, 6) == "      ", rendered.lines[#rendered.lines])
check("every line maps back to its row", #rendered.owner == #rendered.lines)

local user_index
for index, row in ipairs(rows) do
  if row == user then
    user_index = index
  end
end
local expanded = trajectory.lines(rows, { expanded = { [user.key] = true } })
check("an expanded row adds its detail lines", #expanded.lines == #rows + #user.detail, ("%d vs %d"):format(#expanded.lines, #rows + #user.detail))
check("detail lines are indented one level deeper", expanded.lines[expanded.row_line[user_index] + 1]:match("^        fix the parser") ~= nil, expanded.lines[expanded.row_line[user_index] + 1])
check("detail lines belong to the row", expanded.owner[expanded.row_line[user_index] + 1] == user_index)
check("row_line points at the row's first line", expanded.row_line[user_index] == rendered.row_line[user_index])

-- 4. Detail bodies are capped.
local long = {}
for index = 1, 5 do
  long[index] = ("line %d"):format(index)
end
local capped_build = trajectory.build({
  event("user/message", 1, 1000, {
    role = "user",
    content = { { type = "text", text = table.concat(long, "\n") } },
    source = { kind = "user" },
  }),
}, { detail_lines = 2 })
local capped_row = row_of(capped_build.rows, "user", 1)
check("detail keeps the configured number of lines", #capped_row.detail == 3, tostring(#capped_row.detail))
check("a capped detail says how much it cut", capped_row.detail[3] == "… 3 more lines", capped_row.detail[3])

-- 5. Turn endings, failures and interruptions.
local endings = trajectory.build({
  event("turn/start", 0, 1000, { turn = 1 }),
  event("step/start", 1, 1010, { turn = 1, step = 1 }),
  event("assistant/message", 2, 1100, {
    turn = 1,
    step = 1,
    message = { role = "assistant", source = { kind = "model", provider = "p", model = "m" }, content = { { type = "text", text = "partial" } } },
    stream = {},
    interrupted = true,
  }),
  event("step/end", 3, 1200, { turn = 1, step = 1 }),
  event("turn/end", 4, 1300, { turn = 1, reason = { kind = "aborted", reason = { kind = "user" } } }),
  event("turn/start", 5, 2000, { turn = 2 }),
  event("step/start", 6, 2010, { turn = 2, step = 1 }),
  event("assistant/attempt", 7, 2100, {
    turn = 2,
    step = 1,
    stream = { { type = "chunk", time = 2100, chunk = { type = "finish", reason = { kind = "error", failure = { message = "rate limited", code = "E_RATE" } } } } },
  }),
  event("step/end", 8, 2200, { turn = 2, step = 1 }),
  event("turn/end", 9, 2300, { turn = 2, reason = { kind = "error", error = { message = "model exploded", code = "E_MODEL" } } }),
})
local endings_rows = endings.rows
local aborted_turn = row_of(endings_rows, "turn", 1)
check("an aborted turn names the canceller", has(aborted_turn, "aborted by user"), text_of(aborted_turn))
local interrupted = row_of(endings_rows, "assistant", 1)
check("an interrupted assistant message says so", has(interrupted, "interrupted"), text_of(interrupted))
check("an interrupted assistant message is an error row", interrupted.hl == "DshTrajectoryError", tostring(interrupted.hl))
local attempt = row_of(endings_rows, "attempt", 1)
check("a failed attempt reports its error", has(attempt, "rate limited"), text_of(attempt))
local failed_turn = row_of(endings_rows, "turn", 2)
check("a failed turn says failed", has(failed_turn, "failed"), text_of(failed_turn))
check("a failed turn is painted as an error", failed_turn.hl == "DshTrajectoryError", tostring(failed_turn.hl))
local turned_error = row_of(endings_rows, "error", 1)
check("a failed turn keeps its error row", turned_error ~= nil and has(turned_error, "model exploded") and has(turned_error, "E_MODEL"), text_of(turned_error))

-- 6. Tools: a call without a result, a failed result, and an orphan result.
local tools = trajectory.build({
  event("turn/start", 0, 1000, { turn = 1 }),
  event("step/start", 1, 1010, { turn = 1, step = 1 }),
  event("tool/call", 2, 1020, { turn = 1, step = 1, callId = "c1", name = "bash", arguments = '{"command":"sleep 5"}' }),
  event("tool/call", 3, 1030, { turn = 1, step = 1, callId = "c2", name = "read", arguments = '{"file_path":"x"}' }),
  event("tool/result", 4, 1040, {
    turn = 1,
    step = 1,
    message = {
      role = "tool",
      source = { kind = "tool", callId = "c2" },
      toolCallId = "c2",
      content = { { type = "text", text = "cannot read" } },
      isError = true,
    },
    error = { name = "FsError", code = "ENOENT", reason = "no such file" },
  }),
  event("tool/result", 5, 1050, {
    turn = 1,
    step = 1,
    message = {
      role = "tool",
      source = { kind = "tool", callId = "gone" },
      toolCallId = "gone",
      content = { { type = "text", text = "orphan output" } },
      isError = false,
    },
  }),
  event("step/end", 6, 1060, { turn = 1, step = 1 }),
  event("turn/end", 7, 1070, { turn = 1, reason = { kind = "completed" } }),
})
local running_tool = row_of(tools.rows, "tool", 1)
check("a call without a result says running", has(running_tool, "running…"), text_of(running_tool))
check("a running call has no duration", not has(running_tool, "ms"), text_of(running_tool))
local failed_tool = row_of(tools.rows, "tool", 2)
check("a failed result shows the error code", has(failed_tool, "✖ ENOENT"), text_of(failed_tool))
check("a failed result keeps its reason", has(failed_tool, "no such file"), text_of(failed_tool))
check("a failed tool is painted as an error", failed_tool.hl == "DshTrajectoryError", tostring(failed_tool.hl))
local orphan = row_of(tools.rows, "tool", 3)
check("a result without its call is still shown", has(orphan, "(call not loaded)"), text_of(orphan))

-- 7. Compaction: inside a turn and standalone between turns.
local compaction = trajectory.build({
  event("turn/start", 0, 1000, { turn = 1 }),
  event("step/start", 1, 1010, { turn = 1, step = 1 }),
  event("step/end", 2, 1020, { turn = 1, step = 1 }),
  event("compaction/start", 3, 1030, { compactionId = "abcdef123456", turn = 1 }),
  event("compaction/summary", 4, 3000, {
    compactionId = "abcdef123456",
    summary = { { type = "text", text = "Everything before this is summarized." } },
    shadowedTokenCount = 12000,
    usage = { inputTokens = 900, outputTokens = 40 },
  }),
  event("user/message", 5, 3010, {
    role = "user",
    content = { { type = "text", text = "checkpoint" } },
    source = { kind = "compact-checkpoint", compactionId = "abcdef123456" },
    surfaceOp = { op = "replace", startSeq = 1, endSeq = 4 },
  }),
  event("compaction/end", 6, 3020, { compactionId = "abcdef123456", turn = 1 }),
  event("step/start", 7, 3030, { turn = 1, step = 2 }),
  event("step/end", 8, 3040, { turn = 1, step = 2 }),
  event("turn/end", 9, 3050, { turn = 1, reason = { kind = "completed" } }),
  event("compaction/start", 10, 4000, { compactionId = "standalone99", turn = nil }),
  event("compaction/end", 11, 5000, { compactionId = "standalone99", turn = nil, error = "summarization failed" }),
})
local compacted = row_of(compaction.rows, "compaction", 1)
check("a compaction inside a turn sits beside its steps", compacted.depth == 2, tostring(compacted.depth))
check("a compaction row carries its id and duration", has(compacted, "◆ Compaction") and has(compacted, "abcdef12") and has(compacted, "2.0s"), text_of(compacted))
check("a compaction row counts what it shadowed", has(compacted, "12.0k tokens"), text_of(compacted))
check("a compaction detail keeps the summary", contains_line(compacted.detail, "Everything before this is summarized."))
check("the compaction checkpoint message is not a context row", #rows_of(compaction.rows, "context") == 0)
local standalone = row_of(compaction.rows, "compaction", 2)
check("a standalone compaction sits at the top level", standalone.depth == 1, tostring(standalone.depth))
check("a failed compaction shows the failure", has(standalone, "✖ summarization failed"), text_of(standalone))
check("a failed compaction is painted as an error", standalone.hl == "DshTrajectoryError", tostring(standalone.hl))
check("compaction usage is counted", has(row_of(compaction.rows, "meta"), "in 900"), text_of(row_of(compaction.rows, "meta")))

-- 8. Nested PTC calls hang under the call that dispatched them.
local ptc = trajectory.build({
  event("turn/start", 0, 1000, { turn = 1 }),
  event("step/start", 1, 1010, { turn = 1, step = 1 }),
  event("tool/call", 2, 1020, { turn = 1, step = 1, callId = "root", name = "run_code", arguments = '{"code":"a"}' }),
  event("tool/ptc-dispatch-start", 3, 1030, {
    rootCallId = "root",
    parentCallId = "root",
    subCallId = "sub1",
    name = "read_file",
    arguments = '{"path":"x"}',
  }),
  event("tool/ptc-dispatch", 4, 1050, {
    rootCallId = "root",
    parentCallId = "root",
    subCallId = "sub1",
    name = "read_file",
    arguments = '{"path":"x"}',
    isError = false,
    content = { { type = "text", text = "file body" } },
  }),
  event("tool/ptc-dispatch-start", 5, 1060, {
    rootCallId = "root",
    parentCallId = "sub1",
    subCallId = "sub2",
    name = "grep",
    arguments = '{"pattern":"x"}',
  }),
  event("tool/ptc-dispatch", 6, 1080, {
    rootCallId = "root",
    parentCallId = "sub1",
    subCallId = "sub2",
    name = "grep",
    arguments = '{"pattern":"x"}',
    isError = true,
    content = { { type = "text", text = "no match" } },
    error = { name = "ToolError", code = "NO_MATCH" },
  }),
  event("tool/result", 7, 1100, {
    turn = 1,
    step = 1,
    message = {
      role = "tool",
      source = { kind = "tool", callId = "root" },
      toolCallId = "root",
      content = { { type = "text", text = "program output" } },
      isError = false,
    },
  }),
  event("step/end", 8, 1200, { turn = 1, step = 1 }),
  event("turn/end", 9, 1300, { turn = 1, reason = { kind = "completed" } }),
})
local root_call = row_of(ptc.rows, "tool", 1)
local sub_call = row_of(ptc.rows, "tool", 2)
local sub_sub = row_of(ptc.rows, "tool", 3)
check("a subtool is one level deeper than its caller", sub_call.depth == root_call.depth + 1, ("%d vs %d"):format(sub_call.depth, root_call.depth))
check("a subtool is marked in its label", has(sub_call, "↳ ⚙ read_file"), text_of(sub_call))
check("nesting repeats for deeper dispatches", sub_sub.depth == sub_call.depth + 1, ("%d vs %d"):format(sub_sub.depth, sub_call.depth))
check("a failed dispatch shows its error", has(sub_sub, "✖ NO_MATCH"), text_of(sub_sub))
check("the parent counts its subtools", has(root_call, "1 subtool") or has(root_call, "2 subtools"), text_of(root_call))
check("the root call still shows its own result", has(root_call, "8 lines") or has(root_call, "1 line"), text_of(root_call))

-- 9. A window that starts mid-turn still shows the containers it belongs to.
local midturn = trajectory.build({
  event("step/start", 0, 1000, { turn = 7, step = 3 }),
  event("user/message", 1, 1010, {
    role = "user",
    content = { { type = "text", text = "late prompt" } },
    source = { kind = "user" },
  }),
  event("step/end", 2, 1100, { turn = 7, step = 3 }),
  event("turn/end", 3, 1200, { turn = 7, reason = { kind = "completed" } }),
})
local partial_turn = row_of(midturn.rows, "turn", 1)
check("a mid-turn window opens the turn it saw", partial_turn ~= nil and has(partial_turn, "Turn 7"), text_of(partial_turn))
check("a mid-turn window opens the step it saw", row_of(midturn.rows, "step", 1) ~= nil)

-- 9b. A window cut at a message, not at a step start, keeps its records in the
-- step they belong to and does not invent a duration or a TTFT for it.
local cut = trajectory.build({
  event("user/message", 0, 1000, {
    role = "user",
    content = { { type = "text", text = "late context" } },
    source = { kind = "runtime-context" },
  }),
  event("request/header", 1, 1010, {
    header = { config = { provider = "p", model = "m" } },
    reason = "change",
  }),
  event("assistant/message", 2, 1500, {
    turn = 4,
    step = 2,
    message = {
      role = "assistant",
      source = { kind = "model", provider = "p", model = "m" },
      content = { { type = "text", text = "answer" } },
    },
    stream = { { type = "text-chunks", time0 = 1200, index = 0, dt = { 100 }, texts = { "a", "b" } } },
    usage = { inputTokens = 10, outputTokens = 2 },
  }),
  event("step/end", 3, 1600, { turn = 4, step = 2 }),
})
local cut_context = row_of(cut.rows, "context", 1)
check("a record cut from its step still lands inside it", cut_context.depth == 3, tostring(cut_context.depth))
local cut_assistant = row_of(cut.rows, "assistant", 1)
check("a cut step keeps its assistant row", cut_assistant.depth == 3, tostring(cut_assistant.depth))
check("a cut step does not invent a time to first token", not has(cut_assistant, "ttft"), text_of(cut_assistant))
local cut_step = row_of(cut.rows, "step", 1)
check("a cut step does not invent a duration", not has(cut_step, "ms") and not has(cut_step, "s"), text_of(cut_step))
local context_before_assistant
for index, row in ipairs(cut.rows) do
  if row == cut_context then
    context_before_assistant = true
  elseif row == cut_assistant then
    break
  elseif row.kind == "context" then
    context_before_assistant = false
  end
end
check("held records keep their order ahead of the step's own", context_before_assistant == true)

-- 10. Resumes are marked, forks are named.
local resumed = trajectory.build({
  event("session/end-seed", 0, 1000, {}),
  event("session/end-seed", 1, 2000, { inherited = true }),
})
check("a resume boundary is marked", has(row_of(resumed.rows, "boundary", 1), "session resumed"), text_of(row_of(resumed.rows, "boundary", 1)))
check("a fork boundary is named", has(row_of(resumed.rows, "boundary", 2), "inherited history"), text_of(row_of(resumed.rows, "boundary", 2)))

-- 11. Retries are visible with their delay and failure.
local retried = trajectory.build({
  event("turn/start", 0, 1000, { turn = 1 }),
  event("step/start", 1, 1010, { turn = 1, step = 1 }),
  event("llm/retry", 2, 1020, {
    turn = 1,
    step = 1,
    retry = 2,
    maxRetries = 5,
    delayMs = 500,
    failure = { message = "overloaded" },
  }),
})
local retry_row = row_of(retried.rows, "retry", 1)
check("a retry row shows the delay", retry_row ~= nil and has(retry_row, "in 500ms"), text_of(retry_row))
check("a retry row shows the failure", retry_row ~= nil and has(retry_row, "overloaded"), text_of(retry_row))

-- 12. An empty log still renders something usable.
local empty = trajectory.build({})
check("an empty log keeps a session header", #empty.rows == 2 and has(empty.rows[1], "untitled session"), text_of(empty.rows[1]))
check("an empty log says it has no events", has(empty.rows[2], "no events yet"), text_of(empty.rows[2]))

-- 13. The view: a tab of its own, a read-only buffer, and the keys.
local ui = require("dsh.ui.trajectory")
local sid = "session-99999999-8888-7777-6666-555555555555"

local function counts()
  return {
    tabs = #vim.api.nvim_list_tabpages(),
    wins = #vim.api.nvim_list_wins(),
    bufs = #vim.api.nvim_list_bufs(),
  }
end

local before = counts()
local entry = ui.open({ session_id = sid, title = "Spec session" })
local opened = counts()
check("trajectory opens one tab", opened.tabs == before.tabs + 1, ("%d -> %d"):format(before.tabs, opened.tabs))
check("the trajectory buffer is current", vim.api.nvim_get_current_buf() == entry.buf)
check("the buffer is named after the session", vim.api.nvim_buf_get_name(entry.buf):find("dsh%-trajectory://99999999") ~= nil, vim.api.nvim_buf_get_name(entry.buf))
check("the buffer carries its own filetype", vim.bo[entry.buf].filetype == "dshtrajectory", vim.bo[entry.buf].filetype)
check("the buffer stays out of buffer lists", vim.bo[entry.buf].buflisted == false)
check("the window folds on indentation", vim.wo[vim.api.nvim_get_current_win()].foldmethod == "indent")
check("the winbar names the view", vim.wo[vim.api.nvim_get_current_win()].winbar:find("trajectory", 1, true) ~= nil, vim.wo[vim.api.nvim_get_current_win()].winbar)

-- The view is fed by the follow stream; an update repaints the buffer.
local callbacks = follow_attachments[sid] and follow_attachments[sid][#follow_attachments[sid]]
check("the view subscribed to its session", callbacks ~= nil)
if callbacks then
  callbacks.on_update({
    records = basic,
    title = "Parser fix",
    header = { cwd = "/proj/dsh", agentPreset = "standard" },
    status = "idle",
  })
end
local lines = vim.api.nvim_buf_get_lines(entry.buf, 0, -1, false)
check("an update fills the buffer with the tree", contains_line(lines, "Session  Parser fix"), lines[1])
check("the tree shows the turn", contains_line(lines, "Turn 1"))
check("the header carries the session cwd", contains_line(lines, "/proj/dsh"))
check("the buffer is read-only", vim.bo[entry.buf].modifiable == false)
check("the winbar follows the title", vim.wo[vim.api.nvim_get_current_win()].winbar:find("Parser fix", 1, true) ~= nil, vim.wo[vim.api.nvim_get_current_win()].winbar)

-- <CR> expands the row under the cursor and collapses it again.
local user_line
for index, row in ipairs(entry.built.rows) do
  if row.kind == "user" then
    user_line = entry.rendered.row_line[index]
  end
end
check("the prompt row is in the buffer", user_line ~= nil)
if user_line then
  vim.api.nvim_win_set_cursor(0, { user_line, 0 })
  ui.toggle(sid)
  local expanded_lines = vim.api.nvim_buf_get_lines(entry.buf, 0, -1, false)
  check("expanding a row adds its detail", contains_line(expanded_lines, "fix the parser") and #expanded_lines == #lines + #entry.built.rows[entry.rendered.owner[user_line]].detail)
  check("the cursor stays on the expanded row", vim.api.nvim_win_get_cursor(0)[1] == user_line, tostring(vim.api.nvim_win_get_cursor(0)[1]))
  ui.toggle(sid)
  local collapsed = vim.api.nvim_buf_get_lines(entry.buf, 0, -1, false)
  check("toggling again collapses the row", #collapsed == #lines, ("%d vs %d"):format(#collapsed, #lines))
end

-- A row without a detail body does nothing.
local turn_line
for index, row in ipairs(entry.built.rows) do
  if row.kind == "turn" then
    turn_line = entry.rendered.row_line[index]
  end
end
if turn_line then
  vim.api.nvim_win_set_cursor(0, { turn_line, 0 })
  ui.toggle(sid)
  check("a row without a body does not expand", #vim.api.nvim_buf_get_lines(entry.buf, 0, -1, false) == #lines)
end

-- Refresh re-attaches the stream.
local attachments = #follow_attachments[sid]
ui.refresh(sid)
check("refresh re-opens the stream", #follow_attachments[sid] == attachments + 1, ("%d -> %d"):format(attachments, #follow_attachments[sid]))

-- Opening the same session again focuses the view instead of adding a tab.
local tabs_before = #vim.api.nvim_list_tabpages()
ui.open({ session_id = sid })
check("reopening focuses the existing view", #vim.api.nvim_list_tabpages() == tabs_before, ("%d -> %d"):format(tabs_before, #vim.api.nvim_list_tabpages()))
check("one view per session", ui.view_count() == 1, tostring(ui.view_count()))

-- q closes the tab and wipes the buffer.
local closed_buf = entry.buf
ui.close(sid)
local after_close = counts()
check("closing removes the tab", after_close.tabs == before.tabs, ("%d vs %d"):format(after_close.tabs, before.tabs))
check("closing wipes the buffer", not vim.api.nvim_buf_is_valid(closed_buf))
check("closing forgets the view", ui.view_count() == 0, tostring(ui.view_count()))

-- 14. A session can be named by an unambiguous prefix.
local real_list = session.list
session.list = function()
  return {
    { sessionId = "session-aaaabbbb-1111-2222-3333-444444444444", cwd = "/proj/a" },
    { sessionId = "session-ccccdddd-1111-2222-3333-444444444444", cwd = "/proj/b" },
  }
end
ui.open_session("ccc")
check("a unique prefix opens its session", ui.view_count() == 1 and vim.api.nvim_buf_get_name(0):find("ccccdddd", 1, true) ~= nil, vim.api.nvim_buf_get_name(0))
ui.close("session-ccccdddd-1111-2222-3333-444444444444")
check("the prefix view closed", ui.view_count() == 0, tostring(ui.view_count()))

local notified = {}
local real_notify = vim.notify
vim.notify = function(message)
  notified[#notified + 1] = message
end
ui.open_session("session-")
check("an ambiguous prefix does not open a view", ui.view_count() == 0, tostring(ui.view_count()))
check("an ambiguous prefix says so", #notified > 0 and notified[#notified]:find("matches 2 sessions", 1, true) ~= nil, notified[#notified])
vim.notify = real_notify
session.list = real_list

-- 14b. Sessions are addressed the way DSH requires.
check("a plain session id is a session address", session.address(sid).kind == "session")
local plain_address = session.address({ sessionId = sid, parentSessionId = "session-parent" })
check("a fork summary keeps the plain address", plain_address.kind == "session", plain_address.kind)
local child_address = session.address({
  sessionId = sid,
  parentSessionId = "session-parent",
  origin = "subagent",
})
check("a subagent summary carries its parent", child_address.kind == "subagent" and child_address.parentSessionId == "session-parent", vim.inspect(child_address))
check("a subagent address leaves the mode open", child_address.mode == "unknown", tostring(child_address.mode))
check("a summary without an id has no address", session.address({}) == nil)

-- session/page sends whichever address it was given.
local http = require("dsh.http")
local real_rpc = http.rpc
local sent
http.rpc = function(_, _, args)
  sent = args
  return { records = {}, hasMore = false }
end
session.page({ url = "http://x", cookie = "c" }, child_address, 42, 10)
check("session/page forwards a subagent address", sent and sent.request.address.kind == "subagent" and sent.request.address.childSessionId == sid, vim.inspect(sent and sent.request.address))
session.page({ url = "http://x", cookie = "c" }, sid, 42, 10)
check("session/page accepts a plain id", sent and sent.request.address.kind == "session", vim.inspect(sent and sent.request.address))
http.rpc = real_rpc

-- 14c. A subagent session is followed through its parent address.
local real_find = session.find
local real_page = session.page
session.find = function()
  return {
    sessionId = sid,
    parentSessionId = "session-parent",
    origin = "subagent",
    cwd = "/proj/a",
    projections = { asOfSeq = 100 },
  }
end

local child_view = ui.open({ session_id = sid })
local plain_target = follow_targets[#follow_targets]
check("a view opened by id follows the plain session first", plain_target == sid, tostring(plain_target))
local child_callbacks = follow_attachments[sid][#follow_attachments[sid]]
child_callbacks.on_status("error", "session/agent-busy: subagent Sessions require their durable parent address")
local retried_target = follow_targets[#follow_targets]
check("an agent-busy error retries with the parent address", type(retried_target) == "table" and retried_target.kind == "subagent", vim.inspect(retried_target))
check("the retry is not repeated", child_view.address_retried == true)

-- 14d. When the stream keeps failing the view still reads history over HTTP.
session.page = function()
  return { records = basic, hasMore = false }
end
local broken = follow_attachments[sid][#follow_attachments[sid]]
broken.on_status("error", "gateway: stream unavailable")
local offline_lines = vim.api.nvim_buf_get_lines(child_view.buf, 0, -1, false)
check("a failed stream falls back to history", contains_line(offline_lines, "Turn 1"), offline_lines[1])
check("the view says it went offline", child_view.status == "offline", tostring(child_view.status))
check("history fallback keeps the tree addressable", #child_view.built.rows > 2, tostring(#child_view.built.rows))
ui.close(sid)
session.find = real_find
session.page = real_page

-- 14e. `keymaps.global.trajectory` maps the command entry point.
require("dsh").setup({ notifications = false, treesitter = false, keymaps = { global = { trajectory = "<F13>" } } })
check("keymaps.global.trajectory is installed", vim.fn.maparg("<F13>", "n") ~= "", vim.fn.maparg("<F13>", "n"))
vim.keymap.del("n", "<F13>")

-- 15. The command is registered and opens the view.
dofile(root .. "/plugin/dsh.lua")
check(":DshTrajectory is a command", vim.fn.exists(":DshTrajectory") == 2)
vim.cmd("DshTrajectory " .. sid)
check(":DshTrajectory opens a trajectory view", ui.view_count() == 1, tostring(ui.view_count()))
ui.close(sid)
check(":DshTrajectory view closed", ui.view_count() == 0)

ui.shutdown()

print(("\n=== %d checks, %d failed ==="):format(checks, failures))
vim.cmd("cquit " .. (failures > 0 and 1 or 0))
