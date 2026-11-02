-- Forwarded human interactions: ask_user_question and approval prompts through
-- vim.ui. No server and no socket: the mux and HTTP transports are stubbed.
-- Run with: nvim --headless -l scripts/interactions_spec.lua
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h:h")
vim.opt.rtp:append(root)

local checks = 0
local failures = 0

local function check(name, condition, detail)
  checks = checks + 1
  if not condition then
    failures = failures + 1
    print(("FAIL %s%s"):format(name, detail and (" — " .. detail) or ""))
  else
    print("PASS " .. name)
  end
end

local function contains(list, needle)
  for _, value in ipairs(list or {}) do
    if type(value) == "string" and value:find(needle, 1, true) then
      return true
    end
  end
  return false
end

--------------------------------------------------------------------------------
-- Scripted transports.
--------------------------------------------------------------------------------
local rpc_calls = {}
local http = {
  rpc = function(ctx, endpoint, args)
    rpc_calls[#rpc_calls + 1] = { ctx = ctx, endpoint = endpoint, args = args }
    return { ok = true }
  end,
}
package.loaded["dsh.http"] = http

local stream_handlers = nil
local stream_endpoint = nil
local stream_args = nil
local stream_count = 0
local stream_claims = {}
local cancelled_streams = {}
local credential = "socket-cookie"
local connected = true

package.loaded["dsh.mux"] = {
  is_connected = function()
    return connected
  end,
  acquire = function(_, callback)
    callback(nil)
  end,
  stream = function(endpoint, args, handlers)
    stream_count = stream_count + 1
    stream_endpoint = endpoint
    stream_args = args
    if endpoint ~= "$events" then
      local id = ("claim-%d"):format(#stream_claims + 1)
      stream_claims[#stream_claims + 1] = { id = id, endpoint = endpoint, args = args, handlers = handlers }
      return id
    end
    stream_handlers = handlers
    return "events-stream"
  end,
  cancel = function(id)
    cancelled_streams[#cancelled_streams + 1] = id
  end,
  credential = function()
    return credential
  end,
}

local config = require("dsh.config")
config.setup({ notifications = false })

local interactions = require("dsh.interactions")
local ctx = { url = "http://127.0.0.1:1", cookie = "http-cookie" }

--------------------------------------------------------------------------------
-- Scripted vim.ui.
--------------------------------------------------------------------------------
local selects = {}
local select_scripts = {}
local pending_select = nil
local inputs = {}
local input_scripts = {}

--- Pick the first displayed item containing `needle`.
local function pick(needle)
  return function(items)
    for _, item in ipairs(items) do
      if item:find(needle, 1, true) then
        return item
      end
    end
    return nil
  end
end

vim.ui.select = function(items, opts, on_choice)
  selects[#selects + 1] = { items = vim.deepcopy(items), opts = vim.deepcopy(opts or {}) }
  local script = table.remove(select_scripts, 1)
  if script == nil then
    pending_select = { items = items, on_choice = on_choice }
    return
  end
  local choice = type(script) == "function" and script(items) or script
  on_choice(choice)
end

vim.ui.input = function(opts, on_input)
  inputs[#inputs + 1] = { prompt = opts and opts.prompt }
  local script = table.remove(input_scripts, 1)
  on_input(script)
end

local function resolve_pending(needle)
  local pending = pending_select
  pending_select = nil
  local choice = needle and pick(needle)(pending.items) or nil
  pending.on_choice(choice)
  vim.wait(50, function()
    return true
  end, 10)
end

local function reset_ui()
  selects = {}
  select_scripts = {}
  pending_select = nil
  inputs = {}
  input_scripts = {}
  rpc_calls = {}
  stream_claims = {}
  cancelled_streams = {}
end

local function feed(value)
  assert(stream_handlers, "the event stream is not open")
  stream_handlers.on_item(value)
  vim.wait(20, function()
    return true
  end, 10)
end

local function ready(client_id)
  feed({ type = "ready", clientId = client_id or "client-1", host = { home = "/home/user" } })
end

local function question(event_id, questions, extra)
  local request = { questions = questions }
  for key, value in pairs(extra or {}) do
    request[key] = value
  end
  feed({
    type = "waterfall",
    event = "user-questions/request",
    eventId = event_id,
    agentId = "session-1",
    request = request,
  })
end

local function approval(event_id, request)
  feed({
    type = "waterfall",
    event = "approval/request",
    eventId = event_id,
    agentId = "session-1",
    request = request,
  })
end

--------------------------------------------------------------------------------
-- 1. The stream opens once per socket generation.
--------------------------------------------------------------------------------
interactions.start(ctx)
check("event stream endpoint is $events", stream_endpoint == "$events", tostring(stream_endpoint))
check("event stream args are empty", type(stream_args) == "table" and next(stream_args) == nil, vim.inspect(stream_args))
check("event stream opened once", stream_count == 1, tostring(stream_count))

interactions.start(ctx)
check("start is idempotent within a socket", stream_count == 1, tostring(stream_count))
check("not ready before the ready frame", interactions.is_ready() == false)

ready()
check("ready frame makes questions available", interactions.is_ready() == true)

--------------------------------------------------------------------------------
-- 2. Single-select question: option label becomes `selected`.
--------------------------------------------------------------------------------
reset_ui()
select_scripts = { pick("Yes, delete") }
question("event-1", {
  {
    id = "cleanup",
    header = "Confirm",
    question = "Proceed with the destructive cleanup?",
    options = {
      { label = "Yes, delete them (Recommended)", description = "Removes the three stale files." },
      { label = "No, keep them", description = "Aborts the cleanup." },
    },
  },
})

check("single-select sends one result", #rpc_calls == 1, tostring(#rpc_calls))
local call = rpc_calls[1] or {}
check("result uses the socket credential", call.ctx and call.ctx.cookie == "socket-cookie", vim.inspect(call.ctx))
check("result endpoint", call.endpoint == "$events/result", tostring(call.endpoint))
check("result carries client and event ids", call.args.clientId == "client-1" and call.args.eventId == "event-1", vim.inspect(call.args))

local outcome = call.args and call.args.outcome or {}
check("outcome is a result", outcome.kind == "result", tostring(outcome.kind))
local answer_batch = outcome.value and outcome.value.answers or {}
check("one answer item", #answer_batch == 1, tostring(#answer_batch))
check("answer echoes the question id", answer_batch[1] and answer_batch[1].id == "cleanup", vim.inspect(answer_batch[1]))
check(
  "selected is the option label, not the decorated row",
  answer_batch[1] and answer_batch[1].selected[1] == "Yes, delete them (Recommended)",
  vim.inspect(answer_batch[1] and answer_batch[1].selected)
)
check("no free text on a plain option", answer_batch[1] and answer_batch[1].custom == nil)

local first = selects[1] or {}
check("prompt names the header and question", first.opts.prompt == "Confirm: Proceed with the destructive cleanup?", tostring(first.opts.prompt))
check("option description is shown in the picker", contains(first.items, "Removes the three stale files."))
check("picker offers a free-text answer", contains(first.items, "Other…"))
check("picker offers a skip action", contains(first.items, "Skip this question"))

--------------------------------------------------------------------------------
-- 3. Custom ("Other") answer replaces a single-select choice.
--------------------------------------------------------------------------------
reset_ui()
select_scripts = { pick("Other…") }
input_scripts = { "  use the staging directory  " }
question("event-2", {
  { id = "where", question = "Where?", options = { { label = "here" }, { label = "there" } } },
})

check("custom answer sends a result", #rpc_calls == 1)
local custom_answer = rpc_calls[1] and rpc_calls[1].args.outcome.value.answers[1] or {}
check("custom answer trims the text", custom_answer.custom == "use the staging directory", tostring(custom_answer.custom))
check("single-select custom answer is exclusive", custom_answer.selected and #custom_answer.selected == 0, vim.inspect(custom_answer.selected))

--------------------------------------------------------------------------------
-- 4. A question without options asks for free text directly.
--------------------------------------------------------------------------------
reset_ui()
input_scripts = { "42" }
question("event-3", { { id = "count", question = "How many?" } })

check("optionless question uses vim.ui.input", #inputs == 1, tostring(#inputs))
check("optionless prompt names the question", inputs[1] and inputs[1].prompt:find("How many?", 1, true) ~= nil, vim.inspect(inputs[1]))
local free = rpc_calls[1] and rpc_calls[1].args.outcome.value.answers[1] or {}
check("free-text answer is custom", free.custom == "42" and #free.selected == 0, vim.inspect(free))

--------------------------------------------------------------------------------
-- 5. Skipping a question sends the blank answer shape DSH expects.
--------------------------------------------------------------------------------
reset_ui()
select_scripts = { pick("Skip this question") }
question("event-4", { { id = "skipme", question = "Choose", options = { { label = "a" } } } })

local skipped = rpc_calls[1] and rpc_calls[1].args.outcome.value.answers[1] or {}
check("skip sends an empty selection", skipped.selected and #skipped.selected == 0, vim.inspect(skipped))
check("skip carries no custom text", skipped.custom == nil)

--------------------------------------------------------------------------------
-- 6. Multi-select accumulates rounds until "Done selecting".
--------------------------------------------------------------------------------
reset_ui()
select_scripts = {
  pick("Alpha"),
  pick("Beta"),
  pick("Done selecting"),
}
question("event-5", {
  { id = "pick", question = "Pick letters", multiSelect = true, options = { { label = "Alpha" }, { label = "Beta" } } },
})

check("multi-select prompts once per round", #selects == 3, tostring(#selects))
check("multi-select explains the mode", selects[1] and selects[1].opts.prompt:find("select all that apply", 1, true) ~= nil, vim.inspect(selects[1] and selects[1].opts.prompt))
check("multi-select shows the selection so far", selects[2] and selects[2].opts.prompt:find("selected: Alpha", 1, true) ~= nil, vim.inspect(selects[2] and selects[2].opts.prompt))
local multi = rpc_calls[1] and rpc_calls[1].args.outcome.value.answers[1] or {}
check("multi-select keeps every choice", table.concat(multi.selected or {}, ",") == "Alpha,Beta", vim.inspect(multi.selected))

--------------------------------------------------------------------------------
-- 6b. Selected multi-select options can be toggled off again.
--------------------------------------------------------------------------------
reset_ui()
select_scripts = {
  pick("Alpha"),
  pick("Beta"),
  pick("✓ Alpha"),
  pick("Done selecting"),
}
question("event-5b", {
  { id = "toggle", question = "Toggle", multiSelect = true, options = { { label = "Alpha" }, { label = "Beta" } } },
})

check("selected option is marked in the list", contains(selects[2] and selects[2].items, "✓ Alpha"))
check("toggling removes the option", selects[3] and contains(selects[3].items, "✓ Beta"), vim.inspect(selects[3] and selects[3].items))
local toggled = rpc_calls[1] and rpc_calls[1].args.outcome.value.answers[1] or {}
check("toggled-off label is not answered", table.concat(toggled.selected or {}, ",") == "Beta", vim.inspect(toggled.selected))

--------------------------------------------------------------------------------
-- 7. A multi-select custom answer supplements the labels.
--------------------------------------------------------------------------------
reset_ui()
select_scripts = {
  pick("Alpha"),
  pick("Other…"),
  pick("Done selecting"),
}
input_scripts = { "maybe" }
question("event-6", {
  { id = "pick2", question = "Pick", multiSelect = true, options = { { label = "Alpha" } } },
})

local supplemented = rpc_calls[1] and rpc_calls[1].args.outcome.value.answers[1] or {}
check("multi-select keeps selected labels with custom text", table.concat(supplemented.selected or {}, ",") == "Alpha", vim.inspect(supplemented.selected))
check("multi-select keeps custom text", supplemented.custom == "maybe", tostring(supplemented.custom))

--------------------------------------------------------------------------------
-- 8. Several questions in one call produce one answer batch.
--------------------------------------------------------------------------------
reset_ui()
select_scripts = { pick("Yes"), pick("No") }
question("event-7", {
  { id = "one", question = "First?", options = { { label = "Yes" }, { label = "No" } } },
  { id = "two", question = "Second?", options = { { label = "Yes" }, { label = "No" } } },
})

check("two questions ask twice", #selects == 2, tostring(#selects))
local batch = rpc_calls[1] and rpc_calls[1].args.outcome.value.answers or {}
check("one batch carries both answers", #batch == 2 and batch[1].id == "one" and batch[2].id == "two", vim.inspect(batch))

--------------------------------------------------------------------------------
-- 9. Second question asks only after the first is answered.
--------------------------------------------------------------------------------
reset_ui()
question("event-8", {
  { id = "a", question = "A?", options = { { label = "a1" } } },
  { id = "b", question = "B?", options = { { label = "b1" } } },
})
check("queued prompt waits for the answer", #selects == 1 and #rpc_calls == 0, ("selects=%d rpc=%d"):format(#selects, #rpc_calls))
resolve_pending("a1")
vim.wait(100, function()
  return #selects == 2
end, 10)
check("next question follows the first answer", #selects == 2, tostring(#selects))
resolve_pending("b1")
vim.wait(100, function()
  return #rpc_calls == 1
end, 10)
check("both answers send one batch after the queue drains", #rpc_calls == 1, tostring(#rpc_calls))

--------------------------------------------------------------------------------
-- 10. Requests arriving while a prompt is open are queued, not stacked.
--------------------------------------------------------------------------------
reset_ui()
question("event-9", { { id = "q9", question = "Open?", options = { { label = "yes" } } } })
question("event-10", { { id = "q10", question = "Also open?", options = { { label = "yes" } } } })
check("only one prompt is on screen", #selects == 1, tostring(#selects))
check("the second request waits", #rpc_calls == 0)

resolve_pending("yes")
vim.wait(100, function()
  return #selects == 2
end, 10)
check("the queued request prompts next", #selects == 2, tostring(#selects))
resolve_pending("yes")
vim.wait(100, function()
  return #rpc_calls == 2
end, 10)
check("each request gets its own result", #rpc_calls == 2, tostring(#rpc_calls))

--------------------------------------------------------------------------------
-- 11. DSH cancelling an event while its prompt is open: a timed-out question
-- stays answerable through the durable `userQuestions/answer` RPC.
--------------------------------------------------------------------------------
reset_ui()
question("event-11", { { id = "q11", question = "Cancelled?", options = { { label = "yes" } } } }, {
  wait = { callId = "call-11", timed = true },
})
check("cancelled question prompts", #selects == 1)
check("timed question claims the foreground wait", #stream_claims == 1 and stream_claims[1].endpoint == "userQuestions/attachWait", vim.inspect(stream_claims))
check(
  "claim names the live agent and call",
  stream_claims[1] and stream_claims[1].args.agentId == "session-1" and stream_claims[1].args.callId == "call-11",
  vim.inspect(stream_claims[1] and stream_claims[1].args)
)
feed({ type = "cancel", eventId = "event-11" })
resolve_pending("yes")
vim.wait(100, function()
  return #rpc_calls == 1
end, 10)

check("cancelled question uses the durable answer path", rpc_calls[1] and rpc_calls[1].endpoint == "userQuestions/answer", vim.inspect(rpc_calls[1] and rpc_calls[1].endpoint))
check("durable answer uses the HTTP credential", rpc_calls[1] and rpc_calls[1].ctx.cookie == "http-cookie", vim.inspect(rpc_calls[1] and rpc_calls[1].ctx))
check("durable answer names the live agent", rpc_calls[1] and rpc_calls[1].args.agentId == "session-1", vim.inspect(rpc_calls[1] and rpc_calls[1].args))
check("durable answer names the continued call", rpc_calls[1] and rpc_calls[1].args.callId == "call-11", vim.inspect(rpc_calls[1] and rpc_calls[1].args))
check(
  "durable answer carries the chosen batch",
  rpc_calls[1] and rpc_calls[1].args.answer.answers[1].id == "q11" and rpc_calls[1].args.answer.answers[1].selected[1] == "yes",
  vim.inspect(rpc_calls[1] and rpc_calls[1].args.answer)
)
check("claim released after the answer", stream_claims[1] and cancelled_streams[#cancelled_streams] == stream_claims[1].id, vim.inspect(cancelled_streams))

--------------------------------------------------------------------------------
-- 11b. Cancelling an approval has no durable continuation: send nothing.
--------------------------------------------------------------------------------
reset_ui()
approval("event-11b", { toolName = "bash" })
check("cancelled approval prompts", #selects == 1)
feed({ type = "cancel", eventId = "event-11b" })
resolve_pending("Allow once")
vim.wait(100, function()
  return true
end, 10)
check("cancelled approval sends nothing", #rpc_calls == 0, tostring(#rpc_calls))

--------------------------------------------------------------------------------
-- 12. Approvals map to DSH's allow/reject vocabulary.
--------------------------------------------------------------------------------
reset_ui()
select_scripts = { "Allow once" }
approval("event-12", {
  toolName = "bash",
  reason = "run a command touching the repository root",
  displayReason = { en = "wants to run a destructive command" },
})

check("approval sends one result", #rpc_calls == 1, tostring(#rpc_calls))
local allowed = rpc_calls[1] and rpc_calls[1].args.outcome or {}
check("allow outcome", allowed.kind == "result" and allowed.value == "allowed-once", vim.inspect(allowed))
check("approval prompt names the tool", selects[1] and selects[1].opts.prompt:find("bash", 1, true) ~= nil, vim.inspect(selects[1] and selects[1].opts.prompt))

reset_ui()
select_scripts = { function()
  return nil
end }
approval("event-13", { toolName = "bash" })
local rejected = rpc_calls[1] and rpc_calls[1].args.outcome or {}
check("dismissed approval rejects, failing closed", rejected.kind == "result" and rejected.value == "rejected", vim.inspect(rejected))

--------------------------------------------------------------------------------
-- 13. Unknown or disabled events are handed back with `next`.
--------------------------------------------------------------------------------
reset_ui()
feed({
  type = "waterfall",
  event = "some-future/request",
  eventId = "event-14",
  agentId = "session-1",
  request = {},
})
local handed_back = rpc_calls[1] and rpc_calls[1].args.outcome or {}
check("unknown event outcome is next", handed_back.kind == "next", vim.inspect(handed_back))
check("unknown event does not prompt", #selects == 0)

config.setup({ notifications = false, interactions = { questions = false } })
reset_ui()
question("event-15", { { id = "disabled", question = "Disabled?", options = { { label = "a" } } } })
local disabled = rpc_calls[1] and rpc_calls[1].args.outcome or {}
check("disabled questions outcome is next", disabled.kind == "next", vim.inspect(disabled))
check("disabled questions do not prompt", #selects == 0)
config.setup({ notifications = false })

--------------------------------------------------------------------------------
-- 14. Answers decided while the socket is down are sent after `ready`.
--------------------------------------------------------------------------------
reset_ui()
credential = nil
select_scripts = { pick("yes") }
question("event-16", { { id = "q16", question = "Offline?", options = { { label = "yes" } } } })
check("answer waits for a socket", #rpc_calls == 0, tostring(#rpc_calls))

credential = "socket-cookie"
ready("client-2")
check("queued answer flushes on ready", #rpc_calls == 1, tostring(#rpc_calls))
check("flushed answer uses the reconnected client id", rpc_calls[1] and rpc_calls[1].args.clientId == "client-2", vim.inspect(rpc_calls[1] and rpc_calls[1].args))
check("flushed answer keeps its event id", rpc_calls[1] and rpc_calls[1].args.eventId == "event-16", vim.inspect(rpc_calls[1] and rpc_calls[1].args))

--------------------------------------------------------------------------------
-- 15. Long question detail is surfaced without entering option labels.
--------------------------------------------------------------------------------
local notified = {}
vim.notify = function(message)
  notified[#notified + 1] = message
end
config.setup({ notifications = true })
reset_ui()
select_scripts = { pick("Approve") }
question("event-17", {
  {
    id = "plan",
    header = "Plan review",
    question = "Approve this plan?",
    detail = "1. Add the flag\n2. Update the docs",
    intent = { kind = "plan-review", approve = "Approve" },
    options = { { label = "Approve" }, { label = "Request changes" } },
  },
})
check("detail is notified", #notified == 1 and notified[1]:find("Add the flag", 1, true) ~= nil, vim.inspect(notified))
check("detail stays out of the option rows", not contains(selects[1].items, "Add the flag"))
check("plan review answer is the approve label", rpc_calls[1] and rpc_calls[1].args.outcome.value.answers[1].selected[1] == "Approve")
config.setup({ notifications = false })

--------------------------------------------------------------------------------
-- 16. Stopping the view side drops pending work and the stream.
--------------------------------------------------------------------------------
reset_ui()
question("event-18", { { id = "q18", question = "Queued?", options = { { label = "a" } } } })
check("prompt open before stop", #selects == 1)
interactions.stop()
check("stop cancels the event stream", cancelled_streams[#cancelled_streams] == "events-stream", vim.inspect(cancelled_streams))
resolve_pending("a")
vim.wait(100, function()
  return #rpc_calls == 0
end, 10)
check("stopped plugin sends nothing", #rpc_calls == 0, tostring(#rpc_calls))

print(("\n=== %d checks, %d failed ==="):format(checks, failures))
vim.cmd("cquit " .. (failures > 0 and 1 or 0))
