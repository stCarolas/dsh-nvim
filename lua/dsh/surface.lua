--- Projection of the DSH event log into displayable entries.
---
--- DSH stores far more events than a chat view wants: system prompts, runtime
--- context, inbox bookkeeping, request headers, step boundaries. This module keeps
--- the model-visible surface only and honours `surfaceOp = replace`, which
--- compaction uses to swap earlier messages for a summary.
local M = {}

local config = require("dsh.config")

--- Extract model text from an array of content blocks.
--- @param blocks table[]|nil
--- @return string
local function blocks_text(blocks)
  local parts = {}
  for _, block in ipairs(blocks or {}) do
    if block.type == "text" then
      parts[#parts + 1] = block.text
    elseif block.type == "reasoning" then
      if config.options.show_reasoning then
        parts[#parts + 1] = "[reasoning] " .. block.text
      end
    elseif block.type == "image" then
      parts[#parts + 1] = "[image]"
    elseif block.type == "file" then
      parts[#parts + 1] = "[file]"
    end
  end
  return table.concat(parts, "\n"):gsub("%s+$", "")
end
M.blocks_text = blocks_text

--- First error reported by an attempt's stream, if the attempt failed.
--- @param stream table[]|nil
--- @return string|nil
local function attempt_error(stream)
  for _, record in ipairs(stream or {}) do
    local chunk = record.chunk
    if type(chunk) == "table" and chunk.type == "finish" then
      local reason = chunk.reason
      if type(reason) == "table" and reason.kind == "error" then
        local failure = reason.failure or {}
        return failure.message or failure.code or "model call failed"
      end
    end
  end
  return nil
end

--- Drop entries whose seq falls inside a replaced surface range.
--- @param entries table[]
local function drop_range(entries, from, to)
  local kept = {}
  for _, entry in ipairs(entries) do
    local seq = entry.seq
    if not (seq and seq >= from and seq <= to) then
      kept[#kept + 1] = entry
    end
  end
  return kept
end

--- Build the display model from `session/page` records.
--- @param records table[]|nil
--- @return {entries: table[], title: string|nil, last_seq: number|nil, pending_error: string|nil}
function M.build(records)
  local entries = {}
  local title = nil
  local last_seq = nil
  local pending_error = nil

  for _, record in ipairs(records or {}) do
    local event = record.event
    if type(event) == "table" then
      local seq = event.seq
      if type(seq) == "number" then
        last_seq = seq
        local surface_op = event.surfaceOp
        if type(surface_op) == "table" and surface_op.op == "replace"
          and type(surface_op.startSeq) == "number" and type(surface_op.endSeq) == "number" then
          entries = drop_range(entries, surface_op.startSeq, surface_op.endSeq)
        end
      end

      local data = event.data or {}
      local kind = event.type

      if kind == "user/message" then
        -- Only messages the human typed; runtime/time context is model plumbing.
        local source = data.source
        if type(source) == "table" and source.kind == "user" then
          local text = blocks_text(data.content)
          if text ~= "" then
            entries[#entries + 1] = { role = "user", seq = seq, text = text }
          end
        end
      elseif kind == "assistant/message" then
        local message = data.message or {}
        local text = blocks_text(message.content)
        if text ~= "" or data.interrupted then
          entries[#entries + 1] = {
            role = "assistant",
            seq = seq,
            text = text,
            interrupted = data.interrupted == true,
          }
        end
      elseif kind == "assistant/attempt" then
        local message = attempt_error(data.stream)
        if message then
          pending_error = message
        end
      elseif kind == "tool/call" then
        entries[#entries + 1] = {
          role = "tool",
          seq = seq,
          name = data.name or "tool",
          arguments = data.arguments,
          text = require("dsh.session").summarize_arguments(data.arguments),
        }
      elseif kind == "tool/result" then
        local message = data.message or {}
        local text = blocks_text(message.content)
        entries[#entries + 1] = {
          role = "tool_result",
          seq = seq,
          text = text,
          is_error = message.isError == true,
        }
        if message.isError then
          pending_error = nil
        end
      elseif kind == "session/title" then
        if type(data.title) == "string" and data.title ~= "" then
          title = data.title
        end
      elseif kind == "turn/end" then
        local reason = data.reason or {}
        if reason.kind == "error" then
          local error_info = reason.error or {}
          entries[#entries + 1] = {
            role = "error",
            seq = seq,
            text = error_info.message or "turn failed",
          }
          pending_error = nil
        end
      end
    end
  end

  -- An attempt-level failure with no terminal turn/end error still deserves surfacing.
  if pending_error and entries[#entries] and entries[#entries].role ~= "error" then
    entries[#entries + 1] = { role = "error", text = pending_error }
  end

  -- Lead with the session title when DSH derived one.
  if title then
    table.insert(entries, 1, { role = "title", text = title })
  end

  return { entries = entries, title = title, last_seq = last_seq }
end

return M
