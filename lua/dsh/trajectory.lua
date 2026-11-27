--- The DSH session trajectory as a turn/step tree.
---
--- DSH's web UI builds its Trajectory tab client-side: `session/page` and
--- `session/follow` hand a client the raw session event log — turns, steps,
--- prompts, injected context, system prompt revisions, assistant messages, tool
--- calls and their results, nested PTC dispatches, compaction markers, request
--- headers and usage — and the ledger is a projection of that log. This module
--- is that projection for Neovim, so `:DshTrajectory` can show the same facts
--- without a browser.
---
--- The projection is a tree of nodes that is then flattened into rows. A row
--- carries the depth it sits at, the highlight group to paint, and an optional
--- detail body; `M.lines` adds the indentation, which is what makes the buffer
--- text a tree (and what `'foldmethod' = "indent"` folds on). Rows are also the
--- unit of interaction: the trajectory buffer expands the row under the cursor
--- with <CR>, so a buffer line maps back to the row that produced it.
---
--- Nothing here talks to the server: `dsh.ui.trajectory` owns the buffer, the
--- stream and the keymaps, and hands records to `M.build`.
local surface = require("dsh.surface")
local session = require("dsh.session")

local M = {}

--- Deepest nesting rendered. PTC calls nest under the call that dispatched
--- them; the cap keeps an adversarial chain from walking off the screen.
local MAX_DEPTH = 12

--- Highlight group of each row kind. `finalize` overrides a few of them
--- (a failed tool call, a failed turn) once the outcome is known.
local HL = {
  session = "DshTrajectoryTitle",
  meta = "DshTrajectoryMeta",
  turn = "DshTrajectoryTurn",
  step = "DshTrajectoryStep",
  user = "DshTrajectoryUser",
  context = "DshTrajectoryContext",
  developer = "DshTrajectoryContext",
  system = "DshTrajectoryContext",
  assistant = "DshTrajectoryAssistant",
  attempt = "DshTrajectoryToolError",
  tool = "DshTrajectoryTool",
  request = "DshTrajectoryMeta",
  compaction = "DshTrajectoryCompaction",
  retry = "DshTrajectoryMeta",
  boundary = "DshTrajectoryMeta",
  error = "DshTrajectoryError",
}

--- Stream record types that carry generated tokens, for TTFT and generation
--- time. `dsh-llm` packs deltas into `*-chunks` runs; every other chunk (block
--- boundaries, usage, finish) is a `chunk` record that is not a token.
local TOKEN_CHUNKS = { ["text-delta"] = true, ["reasoning-delta"] = true, ["tool-call-delta"] = true }

--- Content blocks of a message as text. Tool-call blocks are skipped: they
--- repeat the `tool/call` events, which get their own rows and their own
--- arguments preview.
--- @param blocks table[]|nil
--- @param opts {reasoning: boolean|nil}|nil include reasoning blocks
--- @return string
local function blocks_text(blocks, opts)
  local out = {}
  for _, block in ipairs(type(blocks) == "table" and blocks or {}) do
    local kind = type(block) == "table" and block.type or nil
    if kind == "text" and type(block.text) == "string" then
      out[#out + 1] = block.text
    elseif kind == "reasoning" and type(block.text) == "string" then
      if type(opts) == "table" and opts.reasoning then
        out[#out + 1] = "[reasoning] " .. block.text
      end
    elseif kind == "image" then
      out[#out + 1] = "[image]"
    elseif kind == "file" then
      out[#out + 1] = "[file]"
    end
  end
  return table.concat(out, "\n")
end

--- Message body with trailing whitespace removed.
--- @param blocks table[]|nil
--- @param opts {reasoning: boolean|nil}|nil
--- @return string
local function body_text(blocks, opts)
  return (blocks_text(blocks, opts):gsub("%s+$", ""))
end

--- Split text into lines, dropping trailing blank ones.
--- @param text string|nil
--- @return string[]
local function lines_of(text)
  local out = {}
  for line in ((text or "") .. "\n"):gmatch("(.-)\n") do
    out[#out + 1] = line
  end
  while #out > 0 and out[#out]:match("^%s*$") do
    table.remove(out)
  end
  return out
end

--- Keep at most `limit` characters, appending an ellipsis when cut.
---
--- Byte slicing can split a multibyte sequence, so the cut counts characters
--- like the rest of the plugin does.
--- @param text string
--- @param limit integer
--- @return string
local function clip(text, limit)
  if vim.fn.strchars(text) <= limit then
    return text
  end
  return vim.fn.strcharpart(text, 0, limit) .. "…"
end

--- Collapse whitespace and clip to one line.
--- @param text string|nil
--- @param limit integer
--- @return string
local function one_line(text, limit)
  local flat = vim.trim(((text or ""):gsub("%s+", " ")))
  return clip(flat, limit)
end

--- A one-line preview of a body, quoted; nil when there is no text.
--- @param text string|nil
--- @param limit integer
--- @return string|nil
local function quoted(text, limit)
  local line = one_line(text, limit)
  return line ~= "" and ('"' .. line .. '"') or nil
end

--- Number of non-blank lines in a body.
--- @param text string|nil
--- @return integer
local function line_count(text)
  local count = 0
  for line in ((text or "") .. "\n"):gmatch("(.-)\n") do
    if line:match("%S") then
      count = count + 1
    end
  end
  return count
end

--- Join the non-empty parts of a row label with ` · `.
---
--- Varargs, not a table: a missing part is `nil`, and a `nil` inside a table
--- truncates it — every part after the first gap would silently disappear.
--- @param ... string|nil
--- @return string
local function join(...)
  local kept = {}
  for index = 1, select("#", ...) do
    local part = select(index, ...)
    if type(part) == "string" and part ~= "" then
      kept[#kept + 1] = part
    end
  end
  return table.concat(kept, " · ")
end

--- Short duration: `320ms`, `4.2s`, `1m 12s`.
--- @param ms any
--- @return string|nil
local function duration(ms)
  if type(ms) ~= "number" or ms ~= ms or ms < 0 then
    return nil
  end
  if ms < 1000 then
    return ("%dms"):format(math.floor(ms + 0.5))
  end
  local seconds = ms / 1000
  if seconds < 60 then
    return ("%.1fs"):format(seconds)
  end
  return ("%dm %02ds"):format(math.floor(seconds / 60), math.floor(seconds % 60))
end
M.duration = duration

--- Compact token count: `812`, `12.1k`, `1.2M`.
--- @param count any
--- @return string|nil
local function tokens(count)
  if type(count) ~= "number" or count < 0 or count ~= count then
    return nil
  end
  if count < 1000 then
    return ("%d"):format(math.floor(count))
  end
  if count < 1000000 then
    return ("%.1fk"):format(count / 1000)
  end
  return ("%.1fM"):format(count / 1000000)
end

--- Local wall-clock time of an epoch-millisecond timestamp.
--- @param ms any
--- @return string|nil
local function clock(ms)
  if type(ms) ~= "number" then
    return nil
  end
  return os.date("%H:%M:%S", math.floor(ms / 1000))
end

--- Session id shortened for a label, e.g. `session-1a2b…` -> `1a2b3c4d`.
--- @param id string|nil
--- @return string|nil
local function short_id(id)
  if type(id) ~= "string" or id == "" then
    return nil
  end
  return (id:gsub("^session%-", ""):sub(1, 8))
end

--- Why a turn ended, as a label.
--- @param reason table|nil TurnEndReason
--- @return string|nil
local function reason_label(reason)
  if type(reason) ~= "table" then
    return nil
  end
  local kind = reason.kind
  if kind == "completed" then
    return "completed"
  elseif kind == "aborted" then
    local cause = reason.reason
    local by = type(cause) == "table" and cause.kind or nil
    return by and ("aborted by " .. tostring(by)) or "aborted"
  elseif kind == "error" then
    return "failed"
  elseif kind == "max-tokens" then
    return "max tokens"
  elseif kind == "blocked" then
    return "blocked"
  elseif kind == "interrupted" then
    return "interrupted"
  elseif kind == "forked" then
    return "forked"
  end
  return type(kind) == "string" and kind or nil
end
M.reason_label = reason_label

--- First and last token timestamp of a recorded assistant stream.
---
--- DSH stores deltas as packed runs (`time0` plus per-delta gaps) and any other
--- chunk as a raw record. Only token-bearing records count: a `finish` or
--- `usage` chunk arrives after the last token and would overstate generation.
--- @param stream table[]|nil AssistantStreamRecord[]
--- @return number|nil first epoch milliseconds
--- @return number|nil last
function M.token_times(stream)
  local first, last
  local function see(time)
    if type(time) ~= "number" then
      return
    end
    if not first or time < first then
      first = time
    end
    if not last or time > last then
      last = time
    end
  end

  for _, record in ipairs(type(stream) == "table" and stream or {}) do
    local kind = type(record) == "table" and record.type or nil
    if kind == "text-chunks" or kind == "reasoning-chunks" or kind == "tool-call-chunks" then
      local time = record.time0
      if type(time) == "number" then
        local finish = time
        for _, gap in ipairs(type(record.dt) == "table" and record.dt or {}) do
          if type(gap) == "number" then
            finish = finish + gap
          end
        end
        see(time)
        see(finish)
      end
    elseif kind == "chunk" then
      local chunk = record.chunk
      if type(chunk) == "table" and TOKEN_CHUNKS[chunk.type] then
        see(record.time)
      end
    end
  end

  return first, last
end

--- Cap a detail body, saying how much was cut off.
--- @param lines string[]
--- @param limit integer
--- @return string[]
local function capped(lines, limit)
  if #lines <= limit then
    return lines
  end
  local out = {}
  for index = 1, limit do
    out[index] = lines[index]
  end
  out[#out + 1] = ("… %d more lines"):format(#lines - limit)
  return out
end

--- JSON-encode a value for a one-line detail note.
--- @param value any
--- @param limit integer
--- @return string|nil
local function json_line(value, limit)
  local ok, encoded = pcall(vim.json.encode, value)
  if not ok or type(encoded) ~= "string" then
    return nil
  end
  return one_line(encoded, limit)
end

--- Label and detail body of a tool node, once its result is known.
--- @param node table
--- @param opts {preview_chars: integer}
local function finalize_tool(node, opts)
  local parts = { ("⚙ %s"):format(node.name or "tool") }
  -- The raw arguments JSON stays in the detail body; the label uses the same
  -- `key=value` summary the chat view shows, which fits one line.
  local arguments = clip(session.summarize_arguments(node.arguments), opts.preview_chars)
  if arguments ~= "" then
    parts[#parts + 1] = arguments
  end
  if node.subtool then
    parts[1] = "↳ " .. parts[1]
  end

  local timed = duration(node.finish and node.start and (node.finish - node.start))
  if timed then
    parts[#parts + 1] = timed
  elseif not node.finish then
    parts[#parts + 1] = "running…"
  end

  local result = type(node.result) == "table" and node.result or {}
  if node.is_error then
    local error_info = type(node.error) == "table" and node.error or {}
    local label = error_info.code or error_info.name
    local reason = error_info.reason or one_line(body_text(result.content, {}), opts.preview_chars)
    -- The code names the failure; the reason is the tool's own sentence.
    local failure = label and (reason ~= "" and (label .. " " .. reason) or label) or (reason ~= "" and reason or "failed")
    parts[#parts + 1] = "✖ " .. failure
  elseif node.finish then
    local body = body_text(result.content, {})
    local count = line_count(body)
    parts[#parts + 1] = count > 0 and ("%d line%s"):format(count, count == 1 and "" or "s") or "(empty)"
  end

  local subtools = 0
  for _, child in ipairs(node.children or {}) do
    if child.kind == "tool" then
      subtools = subtools + 1
    end
  end
  if subtools > 0 then
    parts[#parts + 1] = ("%d subtool%s"):format(subtools, subtools == 1 and "" or "s")
  end

  node.text = join(table.unpack(parts))
  node.hl = node.is_error and HL.error or HL.tool

  local detail = {}
  if type(node.arguments) == "string" and node.arguments ~= "" then
    detail[#detail + 1] = "arguments:"
    for _, line in ipairs(lines_of(node.arguments)) do
      detail[#detail + 1] = line
    end
  end
  if type(node.error) == "table" then
    local identity = join(node.error.name, node.error.code)
    detail[#detail + 1] = identity ~= "" and ("error: " .. identity) or "error:"
    if type(node.error.reason) == "string" and node.error.reason ~= "" then
      detail[#detail + 1] = node.error.reason
    end
  end
  if node.finish then
    local body = body_text(result.content, { reasoning = true })
    detail[#detail + 1] = node.is_error and "result (failed):" or "result:"
    local body_lines = lines_of(body)
    if #body_lines == 0 then
      detail[#detail + 1] = "(empty)"
    end
    for _, line in ipairs(body_lines) do
      detail[#detail + 1] = line
    end
    if result.meta ~= nil then
      local meta = json_line(result.meta, 200)
      if meta then
        detail[#detail + 1] = "meta: " .. meta
      end
    end
  end
  node.detail = detail
end

--- Build the trajectory of one session from its durable records.
--- @param records table[]|nil `{event = SessionEvent}` entries, as `session/page`
--- returns them and `session/follow` snapshots and appends them
--- @param opts {session_id: string|nil, header: table|nil, expanded: table<string, boolean>|nil,
---   detail_lines: integer|nil, preview_chars: integer|nil}|nil
--- @return {rows: table[], title: string|nil, counts: table}
function M.build(records, opts)
  opts = type(opts) == "table" and opts or {}
  local preview = math.max(16, tonumber(opts.preview_chars) or 64)
  local limits = { preview_chars = preview }

  local root = { kind = "session", children = {} }
  local title
  local counts = { turns = 0, steps = 0, tools = 0, inputTokens = 0, outputTokens = 0, cacheRead = 0, ignored = 0 }
  local first_time

  --- Turn nodes by turn number, step nodes by `turn:step`.
  local turns, steps, calls = {}, {}, {}
  --- The step and turn that later turn-less events belong to.
  local current_step, current_turn
  --- The first turn of the window, for held records when no step ever arrives.
  local first_turn
  --- Records that arrived before any container they belong to.
  local pending = {}

  --- @param parent table
  --- @param node table
  --- @return table
  local function add(parent, node)
    parent.children[#parent.children + 1] = node
    return node
  end

  --- Move held records to the head of the container that turned out to own
  --- them. A history page is cut at a message, not at a step start, so the
  --- first records of a window usually arrive before the `step/start` that
  --- would have told the projection where they go.
  --- @param container table
  local function flush_pending(container)
    if #pending == 0 then
      return
    end
    for index = #pending, 1, -1 do
      table.insert(container.children, 1, pending[index])
    end
    pending = {}
  end

  --- @param number any
  --- @param time number|nil
  --- @param exact boolean|nil `time` is the turn's own `turn/start`
  --- @return table|nil
  local function open_turn(number, time, exact)
    if type(number) ~= "number" then
      return nil
    end
    local existing = turns[number]
    if existing then
      existing.start = existing.start or time
      if exact and not existing.exact_start then
        existing.exact_start = time
      end
      return existing
    end
    local node = add(root, {
      kind = "turn",
      turn = number,
      start = time,
      exact_start = exact and time or nil,
      children = {},
    })
    turns[number] = node
    counts.turns = counts.turns + 1
    first_turn = first_turn or node
    return node
  end

  --- @param turn_number any
  --- @param step_number any
  --- @param time number|nil
  --- @param exact boolean|nil `time` is the step's own `step/start`
  --- @return table|nil
  local function open_step(turn_number, step_number, time, exact)
    if type(turn_number) ~= "number" or type(step_number) ~= "number" then
      return nil
    end
    local key = turn_number .. ":" .. step_number
    local existing = steps[key]
    if existing then
      existing.start = existing.start or time
      if exact and not existing.exact_start then
        existing.exact_start = time
      end
      return existing
    end
    local turn = open_turn(turn_number, time)
    if not turn then
      return nil
    end
    local node = add(turn, {
      kind = "step",
      turn = turn_number,
      step = step_number,
      start = time,
      exact_start = exact and time or nil,
      children = {},
    })
    steps[key] = node
    counts.steps = counts.steps + 1
    flush_pending(node)
    return node
  end

  --- Place a record in the step or turn it belongs to.
  ---
  --- `turn`/`step` are the numbers the event itself carries, when it carries
  --- any; the containers are created if the window cut them away. A record that
  --- names no container goes to the one currently open, and is held back when
  --- the window has not opened one yet.
  --- @param node table
  --- @param turn_number any
  --- @param step_number any
  --- @param time number|nil
  local function attach(node, turn_number, step_number, time)
    local step = open_step(turn_number, step_number, time)
    if step then
      add(step, node)
      return
    end
    local parent = current_step or current_turn
    if parent then
      add(parent, node)
    else
      pending[#pending + 1] = node
    end
  end

  --- Count token usage of an assistant or compaction payload.
  --- @param usage table|nil
  local function count_usage(usage)
    if type(usage) ~= "table" then
      return
    end
    if type(usage.inputTokens) == "number" then
      counts.inputTokens = counts.inputTokens + usage.inputTokens
    end
    if type(usage.outputTokens) == "number" then
      counts.outputTokens = counts.outputTokens + usage.outputTokens
    end
    if type(usage.cacheReadTokens) == "number" then
      counts.cacheRead = counts.cacheRead + usage.cacheReadTokens
    end
  end

  --- Row of one assistant message.
  --- @param seq number|nil
  --- @param time number|nil
  --- @param data table
  --- @param parent table
  --- @param step table|nil the step the request belongs to
  --- @return table
  local function assistant_node(seq, time, data, parent, step)
    local message = type(data.message) == "table" and data.message or {}
    local source = type(message.source) == "table" and message.source or {}
    local usage = type(data.usage) == "table" and data.usage or {}
    count_usage(usage)

    local first, last = M.token_times(data.stream)
    -- TTFT is only meaningful against the step's own start: a step inferred
    -- from the message it settled would put the token before it.
    local started = step and step.exact_start

    local model = join(source.provider, source.model)
    local parts = { "Assistant", model }
    if type(usage.inputTokens) == "number" or type(usage.outputTokens) == "number" then
      parts[#parts + 1] = ("in %s → out %s"):format(tokens(usage.inputTokens) or "?", tokens(usage.outputTokens) or "?")
    end
    if first and started then
      parts[#parts + 1] = "ttft " .. (duration(first - started) or "?")
    end
    if first and last and last > first then
      parts[#parts + 1] = "gen " .. (duration(last - first) or "?")
    end
    if data.interrupted then
      parts[#parts + 1] = "interrupted"
    end
    local preview_text = body_text(message.content, {})
    local preview_part = quoted(preview_text, preview)
    if preview_part then
      parts[#parts + 1] = preview_part
    end

    local detail = {}
    local metrics = join(
      type(usage.inputTokens) == "number" and ("in " .. tokens(usage.inputTokens)) or nil,
      type(usage.outputTokens) == "number" and ("out " .. tokens(usage.outputTokens)) or nil,
      type(usage.cacheReadTokens) == "number" and ("cache read " .. tokens(usage.cacheReadTokens)) or nil,
      type(usage.reasoningTokens) == "number" and ("reasoning " .. tokens(usage.reasoningTokens)) or nil,
      time and ("at " .. clock(time))
    )
    if metrics ~= "" then
      detail[#detail + 1] = "usage: " .. metrics
    end
    local body = body_text(message.content, { reasoning = true })
    local body_lines = lines_of(body)
    if #body_lines == 0 then
      detail[#detail + 1] = "(no text)"
    end
    for _, line in ipairs(body_lines) do
      detail[#detail + 1] = line
    end

    local node = add(parent, {
      kind = "assistant",
      seq = seq,
      text = join(table.unpack(parts)),
      detail = detail,
      children = {},
    })
    if data.interrupted then
      node.hl = HL.error
    end
    return node
  end

  --- Compaction rows are looked up by id, so `summary`/`end` find their start.
  local compactions = {}

  for _, record in ipairs(type(records) == "table" and records or {}) do
    local event = type(record) == "table" and record.event or nil
    if type(event) == "table" then
      local kind, data = event.type, type(event.data) == "table" and event.data or {}
      local seq = event.seq
      local time = type(event.time) == "number" and event.time or nil
      if time and (not first_time or time < first_time) then
        first_time = time
      end

      if kind == "session/title" then
        if type(data.title) == "string" and data.title ~= "" then
          -- Latest wins: DSH refines a fallback title into an LLM one.
          title = data.title
        end
      elseif kind == "turn/start" then
        current_turn = open_turn(data.turn, time, true)
        current_step = nil
      elseif kind == "turn/end" then
        local turn = turns[data.turn]
        if not turn and type(data.turn) == "number" then
          -- A page can start after the opening event but still names the turn.
          turn = add(root, { kind = "turn", turn = data.turn, children = {} })
          turns[data.turn] = turn
          counts.turns = counts.turns + 1
        end
        if turn then
          turn.finish = time
          turn.reason = data.reason
          local reason = type(data.reason) == "table" and data.reason or {}
          if reason.kind == "error" then
            local error_info = type(reason.error) == "table" and reason.error or {}
            local message = one_line(error_info.message, 200)
            if message == "" then
              message = "turn failed"
            end
            local code = type(error_info.code) == "string" and error_info.code or nil
            add(turn, {
              kind = "error",
              seq = seq,
              text = "✖ " .. message .. (code and (" (" .. code .. ")") or ""),
              detail = lines_of(json_line(reason.error, 400) or message),
            })
          end
        end
        current_turn, current_step = nil, nil
      elseif kind == "step/start" then
        current_step = open_step(data.turn, data.step, time, true)
        current_turn = turns[data.turn] or current_turn
      elseif kind == "step/end" then
        local step = steps[("%s:%s"):format(tostring(data.turn), tostring(data.step))]
        if step then
          step.finish = time
        end
        current_step = nil
      elseif kind == "user/message" then
        local source = type(data.source) == "table" and data.source or {}
        local source_kind = type(source.kind) == "string" and source.kind or nil
        -- The surface effect of a compaction is the checkpoint message that
        -- replaces the shadowed range; the compaction row already says so.
        if source_kind ~= "compact-checkpoint" then
          local label
          if source_kind == "user" then
            label = "You"
          elseif source_kind then
            label = ("Context (%s)"):format(source_kind)
          else
            label = "Message"
          end
          local body = body_text(data.content, {})
          attach({
            kind = source_kind == "user" and "user" or "context",
            seq = seq,
            text = join(label, quoted(body, preview)),
            detail = lines_of(body_text(data.content, { reasoning = true })),
          })
        end
      elseif kind == "developer/message" then
        local message = type(data.message) == "table" and data.message or {}
        local body = body_text(message.content, {})
        attach({
          kind = "developer",
          seq = seq,
          text = join("Developer", quoted(body, preview)),
          detail = lines_of(body_text(message.content, { reasoning = true })),
        }, data.turn, data.step, time)
      elseif kind == "system/message" then
        local message = type(data.message) == "table" and data.message or {}
        local body = body_text(message.content, {})
        local count = line_count(body)
        attach({
          kind = "system",
          seq = seq,
          text = join(
            "System prompt",
            count > 0 and ("%d line%s"):format(count, count == 1 and "" or "s") or "(empty)",
            quoted(body, preview)
          ),
          detail = lines_of(body),
        }, data.turn, data.step, time)
      elseif kind == "assistant/message" then
        local step = open_step(data.turn, data.step, time) or current_step
        current_step = step or current_step
        assistant_node(seq, time, data, step or current_turn or root, step)
      elseif kind == "assistant/attempt" then
        local failure = surface.attempt_error(data.stream)
        attach({
          kind = "attempt",
          seq = seq,
          text = join("Attempt", failure and ("✖ " .. one_line(failure, 200)) or "no message"),
          detail = lines_of(failure or ""),
        }, data.turn, data.step, time)
      elseif kind == "tool/call" then
        local call_id = data.callId
        local node = {
          kind = "tool",
          seq = seq,
          callId = call_id,
          name = type(data.name) == "string" and data.name or "tool",
          arguments = type(data.arguments) == "string" and data.arguments or nil,
          start = time,
          children = {},
        }
        attach(node, data.turn, data.step, time)
        if call_id ~= nil then
          calls[call_id] = node
        end
        counts.tools = counts.tools + 1
      elseif kind == "tool/result" then
        local message = type(data.message) == "table" and data.message or {}
        local call_id = message.toolCallId or (type(message.source) == "table" and message.source.callId)
        local node = call_id ~= nil and calls[call_id] or nil
        if not node then
          -- A page can cut the call away; the result still names the tool.
          node = {
            kind = "tool",
            seq = seq,
            callId = call_id,
            name = "(call not loaded)",
            children = {},
          }
          attach(node, data.turn, data.step, time)
          if call_id ~= nil then
            calls[call_id] = node
          end
          counts.tools = counts.tools + 1
        end
        node.finish = time
        -- `meta` is the producing tool's presentation payload and lives on the
        -- event, not on the model-facing message.
        node.result = { content = message.content, isError = message.isError, meta = data.meta }
        node.is_error = message.isError == true
        node.error = type(data.error) == "table" and data.error or nil
      elseif kind == "tool/ptc-dispatch-start" or kind == "tool/ptc-dispatch" then
        local sub_call_id = data.subCallId
        local node = sub_call_id ~= nil and calls[sub_call_id] or nil
        if not node then
          node = {
            kind = "tool",
            seq = seq,
            callId = sub_call_id,
            name = type(data.name) == "string" and data.name or "tool",
            arguments = type(data.arguments) == "string" and data.arguments or nil,
            start = time,
            subtool = true,
            children = {},
          }
          -- A dispatch nests under the call that started it; one whose parent
          -- the window cut away belongs to the step that is open.
          local parent = data.parentCallId ~= nil and calls[data.parentCallId] or nil
          if parent then
            add(parent, node)
          else
            attach(node)
          end
          if sub_call_id ~= nil then
            calls[sub_call_id] = node
          end
          counts.tools = counts.tools + 1
        end
        if kind == "tool/ptc-dispatch" then
          node.finish = time
          node.result = { content = data.content, isError = data.isError == true, meta = data.meta }
          node.is_error = data.isError == true
          node.error = type(data.error) == "table" and data.error or nil
        end
      elseif kind == "request/header" then
        local header = type(data.header) == "table" and data.header or {}
        local config = type(header.config) == "table" and header.config or {}
        local tools = type(header.tools) == "table" and header.tools or {}

        local detail = {}
        local keys = vim.tbl_keys(config)
        table.sort(keys)
        for _, key in ipairs(keys) do
          local value = config[key]
          if type(value) == "string" or type(value) == "number" or type(value) == "boolean" then
            detail[#detail + 1] = ("%s: %s"):format(key, tostring(value))
          end
        end
        if #tools > 0 then
          local names = {}
          for _, tool in ipairs(tools) do
            if type(tool) == "table" and type(tool.name) == "string" then
              names[#names + 1] = tool.name
            end
          end
          if #names == 0 then
            detail[#detail + 1] = ("tools: %d (unnamed)"):format(#tools)
          end
          local line = {}
          for _, name in ipairs(names) do
            line[#line + 1] = name
            if #line == 8 then
              detail[#detail + 1] = "tools: " .. table.concat(line, ", ")
              line = {}
            end
          end
          if #line > 0 then
            detail[#detail + 1] = "tools: " .. table.concat(line, ", ")
          end
        end

        attach({
          kind = "request",
          seq = seq,
          text = join(
            "Request",
            join(config.provider, config.model),
            #tools > 0 and ("%d tools"):format(#tools) or nil,
            type(data.reason) == "string" and data.reason or nil
          ),
          detail = detail,
        })
      elseif kind == "compaction/start" then
        local turn = type(data.turn) == "number" and open_turn(data.turn, time) or nil
        local node = add(turn or root, {
          kind = "compaction",
          seq = seq,
          compactionId = data.compactionId,
          start = time,
          children = {},
        })
        if data.compactionId ~= nil then
          compactions[data.compactionId] = node
        end
      elseif kind == "compaction/summary" then
        local node = data.compactionId ~= nil and compactions[data.compactionId] or nil
        if node then
          node.summary = data.summary
          node.shadowed_tokens = data.shadowedTokenCount
          count_usage(data.usage)
        else
          counts.ignored = counts.ignored + 1
        end
      elseif kind == "compaction/end" then
        local node = data.compactionId ~= nil and compactions[data.compactionId] or nil
        if node then
          node.finish = time
          node.failed = type(data.error) == "string" and data.error or nil
        else
          counts.ignored = counts.ignored + 1
        end
      elseif kind == "llm/retry" then
        local failure = type(data.failure) == "table" and data.failure or {}
        attach({
          kind = "retry",
          seq = seq,
          text = join(
            ("↻ retry %s"):format(tokens(data.retry) or "?"),
            ("in %s"):format(duration(data.delayMs) or "?"),
            one_line(failure.message or failure.code, 200)
          ),
          detail = lines_of(json_line(data, 400) or ""),
        }, data.turn, data.step, time)
      elseif kind == "session/end-seed" then
        -- A tagged marker is a fork/seed cut; an untagged one is a process
        -- restart over the same log, which explains a jump in timestamps.
        add(root, {
          kind = "boundary",
          seq = seq,
          text = data.inherited and "── inherited history (fork or seed)" or "── session resumed",
        })
      else
        counts.ignored = counts.ignored + 1
      end
    end
  end

  --- Compose the labels that depend on later events, then flatten.
  local function finalize(node)
    if node.kind == "turn" then
      local elapsed = node.exact_start and node.finish and duration(node.finish - node.exact_start)
      -- `and nil or` would always pick the fallback here, so branch explicitly.
      local status = reason_label(node.reason)
      if not status and not node.finish then
        status = "running"
      end
      node.text = join(("Turn %s"):format(tostring(node.turn or "?")), clock(node.start), elapsed, status)
      node.hl = (type(node.reason) == "table" and node.reason.kind == "error") and HL.error or HL.turn
    elseif node.kind == "step" then
      local elapsed = node.exact_start and node.finish and duration(node.finish - node.exact_start)
      node.text = join(("Step %s"):format(tostring(node.step or "?")), elapsed, not node.finish and "running" or nil)
    elseif node.kind == "compaction" then
      local elapsed = node.start and node.finish and duration(node.finish - node.start)
      local tokens_shadowed = node.shadowed_tokens and (("%s tokens"):format(tokens(node.shadowed_tokens) or "?")) or nil
      node.text = join(
        "◆ Compaction",
        short_id(node.compactionId),
        elapsed,
        not node.finish and "running…" or nil,
        tokens_shadowed,
        node.failed and ("✖ " .. one_line(node.failed, 200)) or nil
      )
      node.hl = node.failed and HL.error or HL.compaction

      local detail = {}
      if type(node.summary) == "table" then
        detail[#detail + 1] = "summary:"
        for _, line in ipairs(lines_of(body_text(node.summary, {}))) do
          detail[#detail + 1] = line
        end
      end
      node.detail = detail
    elseif node.kind == "tool" then
      finalize_tool(node, limits)
    end

    if node.seq ~= nil then
      node.key = "seq:" .. tostring(node.seq)
    end
    for _, child in ipairs(node.children or {}) do
      finalize(child)
    end
  end

  -- A window can end before the container its last records belong to is known:
  -- keep them under the first turn it saw, or at the top level.
  flush_pending(first_turn or root)

  -- Compose the labels that depend on later events, then flatten the tree.
  finalize(root)

  local rows = {}
  local meta = join(
    short_id(opts.session_id) and ("session " .. short_id(opts.session_id)) or nil,
    type(opts.header) == "table" and type(opts.header.cwd) == "string" and opts.header.cwd or nil,
    type(opts.header) == "table" and type(opts.header.agentPreset) == "string" and ("preset " .. opts.header.agentPreset) or nil,
    first_time and clock(first_time) or nil,
    counts.turns > 0 and ("%d turn%s"):format(counts.turns, counts.turns == 1 and "" or "s") or nil,
    counts.steps > 0 and ("%d step%s"):format(counts.steps, counts.steps == 1 and "" or "s") or nil,
    counts.tools > 0 and ("%d tool call%s"):format(counts.tools, counts.tools == 1 and "" or "s") or nil,
    counts.inputTokens > 0 and ("in " .. tokens(counts.inputTokens)) or nil,
    counts.outputTokens > 0 and ("out " .. tokens(counts.outputTokens)) or nil,
    counts.cacheRead > 0 and ("cache read " .. tokens(counts.cacheRead)) or nil,
    counts.ignored > 0 and ("%d other event%s"):format(counts.ignored, counts.ignored == 1 and "" or "s") or nil
  )

  rows[#rows + 1] = {
    kind = "session",
    depth = 0,
    text = "Session  " .. (title or "untitled session"),
    hl = HL.session,
  }
  if meta ~= "" then
    rows[#rows + 1] = { kind = "meta", depth = 1, text = meta, hl = HL.meta }
  end
  if #root.children == 0 then
    -- A new session has no events yet; say so instead of leaving one line that
    -- looks like a failed read.
    rows[#rows + 1] = { kind = "meta", depth = 1, text = "no events yet", hl = HL.meta }
  end

  local detail_lines = math.max(1, tonumber(opts.detail_lines) or 80)

  --- @param node table
  --- @param depth integer
  local function flatten(node, depth)
    local row = {
      kind = node.kind,
      depth = math.min(depth, MAX_DEPTH),
      text = node.text or "",
      hl = node.hl or HL[node.kind] or HL.meta,
      key = node.key,
      seq = node.seq,
    }
    if type(node.detail) == "table" and #node.detail > 0 then
      row.detail = capped(node.detail, detail_lines)
      row.expandable = true
    end
    rows[#rows + 1] = row
    for _, child in ipairs(node.children or {}) do
      flatten(child, depth + 1)
    end
  end

  for _, child in ipairs(root.children) do
    flatten(child, 1)
  end

  return { rows = rows, title = title, counts = counts }
end

--- Buffer lines of built rows, honouring the expanded set.
---
--- A row's detail body is indented one level deeper than the row itself, so
--- `'foldmethod' = "indent"` folds a record together with its detail. `owner`
--- maps every emitted line back to the row that produced it, which is how the
--- buffer finds what <CR> acts on.
--- @param rows table[]
--- @param opts {expanded: table<string, boolean>|nil}|nil
--- @return {lines: string[], hl: string[], owner: integer[], row_line: integer[]}
function M.lines(rows, opts)
  local expanded = type(opts) == "table" and opts.expanded or {}
  local lines, hl, owner, row_line = {}, {}, {}, {}

  for index, row in ipairs(rows or {}) do
    local indent = string.rep("  ", row.depth or 0)
    local line = indent .. (row.text or "")
    lines[#lines + 1] = line
    hl[#hl + 1] = row.hl or ""
    owner[#lines] = index
    row_line[index] = #lines

    if row.detail and expanded[row.key] then
      local detail_indent = indent .. "  "
      for _, text in ipairs(row.detail) do
        lines[#lines + 1] = detail_indent .. text
        hl[#hl + 1] = "DshTrajectoryDetail"
        owner[#lines] = index
      end
    end
  end

  return { lines = lines, hl = hl, owner = owner, row_line = row_line }
end

return M
