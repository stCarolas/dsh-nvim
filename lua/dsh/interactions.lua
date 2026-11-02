--- Forwarded human interactions: `ask_user_question` and approval prompts.
---
--- DSH forwards two human decisions to answer-capable Clients over the
--- Gateway-owned `$events` stream:
---
---   * `user-questions/request` — the `ask_user_question` tool: one or more
---     questions, each with selectable options, multi-select, and optional
---     free-text "Other" answers;
---   * `approval/request` — permission for a sensitive tool action.
---
--- The plugin answers both through `vim.ui.select` / `vim.ui.input`, so the
--- user's picker plugin, command line and notification settings apply.
---
--- Wire shape (one item per forwarded event): >
---   {"type":"ready","clientId":"…","host":{…}}
---   {"type":"waterfall","event":"user-questions/request","eventId":"…",
---    "agentId":"…","request":{…}}
---   {"type":"cancel","eventId":"…"}
--- <
--- The answer is an HTTP RPC on `$events/result`:
---   {clientId, eventId, outcome = {kind = "result", value = …}}
--- DSH rejects answers from any peer other than the one owning the event
--- stream, so this module sends the socket's own credential (see
--- `mux.credential`), not the long-lived HTTP cookie.
---
--- Prompts are serialized: DSH may forward several requests while one is
--- already on screen, and the user should answer them one at a time in order.
local M = {}

local config = require("dsh.config")
local http = require("dsh.http")
local mux = require("dsh.mux")

local state = {
  ctx = nil,
  stream_id = nil,
  client_id = nil,
  queue = {},
  inflight = {},
  cancelled = {},
  outbox = {},
  active = false,
  active_event = nil,
  active_frame = nil,
  claim_id = nil,
  stopped = true,
}

local function notify(message, level)
  if config.options.notifications then
    vim.notify("dsh: " .. message, level or vim.log.levels.INFO, { title = "dsh.nvim" })
  end
end

--- Option text shown in the picker: label, then its description when present.
--- @param option table AskUserQuestionOption
--- @return string
local function option_text(option)
  local label = type(option.label) == "string" and option.label or tostring(option.label)
  local description = option.description
  if type(description) == "string" and description ~= "" then
    return ("%s — %s"):format(label, description)
  end
  return label
end

--- Heading used for the picker prompt and notifications.
--- @param question table AskUserQuestionItem
--- @return string
local function question_prompt(question)
  local text = type(question.question) == "string" and question.question or "(question)"
  if type(question.header) == "string" and question.header ~= "" then
    text = ("%s: %s"):format(question.header, text)
  end
  return text
end

--- Make a display label unique; several questions may repeat an option.
--- @param used table<string, boolean>
--- @param text string
--- @return string
local function unique(used, text)
  local candidate = text
  local index = 1
  while used[candidate] do
    index = index + 1
    candidate = ("%s #%d"):format(text, index)
  end
  used[candidate] = true
  return candidate
end

--- One answer item for `AskUserQuestionAnswer.answers`.
--- @param question table
--- @param selected string[]
--- @param custom string|nil
--- @return table
local function answer_item(question, selected, custom)
  local item = { id = question.id, selected = selected or {} }
  if type(custom) == "string" and custom ~= "" then
    item.custom = custom
  end
  return item
end

--- Ask for free text with `vim.ui.input`; an empty or cancelled answer is nil.
--- @param prompt string
--- @param callback fun(text: string|nil)
local function prompt_custom(prompt, callback)
  vim.ui.input({ prompt = prompt .. " (answer): ", kind = "dsh.question" }, function(text)
    if type(text) == "string" then
      text = vim.trim(text)
    end
    if type(text) ~= "string" or text == "" then
      callback(nil)
      return
    end
    callback(text)
  end)
end

--- Show a question's long detail (a plan under review, for example).
---
--- `vim.ui.select` prompts are one line, and the detail may be a whole
--- Markdown document, so it goes to a notification. `:messages` keeps it.
--- @param question table
local function show_detail(question)
  local detail = question.detail
  if type(detail) ~= "string" or detail == "" then
    return
  end

  local lines = vim.split(detail, "\n", { plain = true })
  local limit = 12
  if #lines > limit then
    local hidden = #lines - limit
    lines = vim.list_slice(lines, 1, limit)
    lines[#lines + 1] = ("… (%d more lines)"):format(hidden)
  end
  notify(("[%s]\n%s"):format(question_prompt(question), table.concat(lines, "\n")))
end

--- Ask one single-select question.
--- @param question table
--- @param options table[]
--- @param done fun(answer: table)
local function ask_single(question, options, done)
  local prompt = question_prompt(question)
  local used = {}
  local labels = {}
  local actions = {}

  local function add(text, action)
    local label = unique(used, text)
    labels[#labels + 1] = label
    actions[label] = action
  end

  for _, option in ipairs(options) do
    add(option_text(option), { kind = "option", label = option.label })
  end
  add("Other… (type an answer)", { kind = "custom" })
  add("Skip this question", { kind = "skip" })

  local choose

  function choose()
    vim.ui.select(labels, { prompt = prompt, kind = "dsh.question" }, function(choice)
      local action = choice and actions[choice]
      if not action or action.kind == "skip" then
        done(answer_item(question, {}))
      elseif action.kind == "custom" then
        prompt_custom(prompt, function(text)
          if text then
            done(answer_item(question, {}, text))
          else
            -- Cancelled the text field: go back to the option list.
            choose()
          end
        end)
      else
        local label = action.label
        done(answer_item(question, { type(label) == "string" and label or tostring(label) }))
      end
    end)
  end

  choose()
end

--- Ask one multi-select question, one option per prompt round.
--- @param question table
--- @param options table[]
--- @param done fun(answer: table)
local function ask_multi(question, options, done)
  local selected = {}
  local selected_set = {}
  local custom = nil

  local function finish()
    done(answer_item(question, selected, custom))
  end

  local function choose()
    local prompt = question_prompt(question)
    if #selected > 0 then
      prompt = ("%s  [selected: %s]"):format(prompt, table.concat(selected, ", "))
    end

    local used = {}
    local labels = {}
    local actions = {}

    local function add(text, action)
      local label = unique(used, text)
      labels[#labels + 1] = label
      actions[label] = action
    end

    for _, option in ipairs(options) do
      local label = option.label
      local text = option_text(option)
      if type(label) == "string" and selected_set[label] then
        -- A selected option stays on the list so a mis-click can be toggled off.
        add("✓ " .. text, { kind = "option", label = label, selected = true })
      else
        add(text, { kind = "option", label = label })
      end
    end
    if #selected > 0 or custom then
      add("Done selecting", { kind = "done" })
    else
      add("Skip this question", { kind = "skip" })
    end
    add("Other… (type an answer)", { kind = "custom" })

    vim.ui.select(labels, {
      prompt = prompt .. " — select all that apply",
      kind = "dsh.question",
    }, function(choice)
      local action = choice and actions[choice]
      if not action or action.kind == "done" or action.kind == "skip" then
        finish()
      elseif action.kind == "custom" then
        prompt_custom(prompt, function(text)
          if text then
            custom = text
          end
          choose()
        end)
      else
        local label = type(action.label) == "string" and action.label or tostring(action.label)
        if action.selected then
          selected_set[label] = nil
          for index, value in ipairs(selected) do
            if value == label then
              table.remove(selected, index)
              break
            end
          end
        elseif not selected_set[label] then
          selected_set[label] = true
          selected[#selected + 1] = label
        end
        choose()
      end
    end)
  end

  choose()
end

--- Ask every question of one `user-questions/request` in order.
--- @param frame table forwarded waterfall frame
--- @param finish fun(outcome: table) called exactly once
local function ask_questions(frame, finish)
  local request = frame.request or {}
  local questions = type(request.questions) == "table" and request.questions or {}
  if #questions == 0 then
    finish({ kind = "next" })
    return
  end

  local answers = {}
  local index = 0

  local function next_question()
    index = index + 1
    local question = questions[index]
    if not question then
      finish({ kind = "result", value = { answers = answers } })
      return
    end

    show_detail(question)

    local function store(answer)
      answers[#answers + 1] = answer
      next_question()
    end

    local options = type(question.options) == "table" and question.options or {}
    if #options == 0 then
      prompt_custom(question_prompt(question), function(text)
        store(answer_item(question, {}, text))
      end)
    elseif question.multiSelect then
      ask_multi(question, options, store)
    else
      ask_single(question, options, store)
    end
  end

  next_question()
end

--- Localized presentation text for an approval request, when DSH sent one.
--- @param request table
--- @return string|nil
local function approval_reason(request)
  local display = request.displayReason
  if type(display) == "table" then
    if type(display.en) == "string" and display.en ~= "" then
      return display.en
    end
    for _, value in pairs(display) do
      if type(value) == "string" and value ~= "" then
        return value
      end
    end
  end
  if type(request.reason) == "string" and request.reason ~= "" then
    return request.reason
  end
  return nil
end

--- Ask one approval request. DSH's vocabulary is `allowed-once` / `rejected`.
--- Cancelling the picker (Esc) rejects, the same fail-closed choice the Web
--- approval panel makes.
--- @param frame table
--- @param finish fun(outcome: table)
local function ask_approval(frame, finish)
  local request = frame.request or {}
  local tool = type(request.toolName) == "string" and request.toolName or "tool"
  local reason = approval_reason(request)
  if reason then
    notify(("allow %s?\n%s"):format(tool, reason))
  end

  local allow = "Allow once"
  vim.ui.select({ allow, "Reject" }, {
    prompt = ("DSH approval: allow %s?"):format(tool),
    kind = "dsh.approval",
  }, function(choice)
    if choice == allow then
      finish({ kind = "result", value = "allowed-once" })
    else
      finish({ kind = "result", value = "rejected" })
    end
  end)
end

--- Send one outcome for a forwarded event, or keep it until a socket exists.
--- @param event_id string
--- @param outcome table
local function send_result(event_id, outcome)
  local ctx = state.ctx
  local cookie = mux.credential and mux.credential() or nil
  if not ctx or not state.client_id or not cookie then
    -- The socket dropped while the user was deciding. DSH redelivers pending
    -- events to the next `$events` generation, so hold the answer until its
    -- `ready` frame arrives and it can be matched to the new client id.
    state.outbox[#state.outbox + 1] = { event_id = event_id, outcome = outcome }
    return
  end

  local _, err = http.rpc({ url = ctx.url, cookie = cookie }, "$events/result", {
    clientId = state.client_id,
    eventId = event_id,
    outcome = outcome,
  }, config.options.request_timeout)
  if err then
    notify(("could not answer DSH interaction: %s"):format(err), vim.log.levels.WARN)
  end
end

--- Flush decisions made while the socket was reconnecting.
local function flush_outbox()
  if not state.client_id or #state.outbox == 0 then
    return
  end
  local pending = state.outbox
  state.outbox = {}
  for _, entry in ipairs(pending) do
    send_result(entry.event_id, entry.outcome)
  end
end

--- Best-effort answer for a question whose live request DSH cancelled.
---
--- Timed `ask_user_question` calls release the model at their deadline and
--- leave the question answerable as a "continued" question. Answering needs the
--- durable `userQuestions/answer` RPC (a new user turn), not the closed
--- waterfall. The call may also have been aborted outright, in which case DSH
--- reports that the question is no longer answerable.
--- @param frame table
--- @param outcome table
local function answer_continued(frame, outcome)
  local request = frame.request or {}
  local wait = request.wait
  if outcome.kind ~= "result" or type(outcome.value) ~= "table" then
    return
  end
  if type(wait) ~= "table" or type(wait.callId) ~= "string" then
    return
  end
  if type(frame.agentId) ~= "string" or not state.ctx then
    return
  end
  if type(state.ctx.cookie) ~= "string" then
    return
  end

  local _, err = http.rpc({ url = state.ctx.url, cookie = state.ctx.cookie }, "userQuestions/answer", {
    agentId = frame.agentId,
    callId = wait.callId,
    answer = outcome.value,
  }, config.options.request_timeout)
  if err then
    notify(("the question is no longer answerable: %s"):format(err), vim.log.levels.WARN)
  end
end

--- Prompt the next queued request.
local function pump()
  if state.active or state.stopped then
    return
  end

  local item = table.remove(state.queue, 1)
  if not item then
    return
  end

  local event_id = item.frame.eventId
  if state.cancelled[event_id] then
    state.cancelled[event_id] = nil
    state.inflight[event_id] = nil
    pump()
    return
  end

  state.active = true
  state.active_event = event_id
  state.active_frame = item.frame

  -- A timed `ask_user_question` releases the model at its deadline unless a UI
  -- claims the wait. Claiming pauses that countdown while the prompt is open;
  -- the answer below settles the wait and the claim closes with this stream.
  if item.kind == "question" then
    local request = item.frame.request or {}
    local wait = request.wait
    if
      type(wait) == "table"
      and wait.timed == true
      and type(wait.callId) == "string"
      and type(item.frame.agentId) == "string"
    then
      state.claim_id = mux.stream("userQuestions/attachWait", {
        agentId = item.frame.agentId,
        callId = wait.callId,
      }, {
        on_item = function() end,
        on_error = function() end,
        on_end = function() end,
      })
    end
  end

  local finished = false

  local function finish(outcome)
    if finished then
      return
    end
    finished = true
    state.active = false
    state.active_event = nil
    state.active_frame = nil
    state.inflight[event_id] = nil

    local cancelled = state.cancelled[event_id] == true
    state.cancelled[event_id] = nil
    if outcome and not state.stopped then
      if cancelled then
        answer_continued(item.frame, outcome)
      else
        send_result(event_id, outcome)
      end
    end
    -- Release the claim only after the answer travelled: releasing it first can
    -- re-arm the deadline and settle the wait before the result is processed.
    if state.claim_id then
      mux.cancel(state.claim_id)
      state.claim_id = nil
    end
    -- Keep prompts one at a time without recursing inside a UI callback.
    vim.schedule(pump)
  end

  local ok, err = pcall(function()
    if item.kind == "question" then
      ask_questions(item.frame, finish)
    else
      ask_approval(item.frame, finish)
    end
  end)
  if not ok then
    notify(("cannot ask DSH interaction: %s"):format(err), vim.log.levels.ERROR)
    finish({ kind = "next" })
  end
end

--- Queue one forwarded waterfall frame.
--- @param kind "question"|"approval"
--- @param frame table
local function enqueue(kind, frame)
  local event_id = frame.eventId
  if type(event_id) ~= "string" or event_id == "" or state.inflight[event_id] then
    return
  end
  state.inflight[event_id] = true
  state.queue[#state.queue + 1] = { kind = kind, frame = frame }
  pump()
end

--- Handle one item of the `$events` stream.
--- @param value table
local function handle_item(value)
  if type(value) ~= "table" then
    return
  end

  if value.type == "ready" then
    state.client_id = value.clientId
    flush_outbox()
    return
  end

  if value.type == "cancel" then
    local event_id = value.eventId
    local active = state.active_event == event_id
    local queued = false
    for index, item in ipairs(state.queue) do
      if item.frame.eventId == event_id then
        table.remove(state.queue, index)
        state.inflight[event_id] = nil
        queued = true
        break
      end
    end
    if not active and not queued and not state.inflight[event_id] then
      -- A cancel for a request that already settled: nothing left to answer.
      return
    end
    if queued then
      -- Removing it from the queue is enough; it never prompts or answers.
      return
    end
    state.cancelled[event_id] = true
    if active then
      local wait = state.active_frame and state.active_frame.request and state.active_frame.request.wait
      if type(wait) == "table" and type(wait.callId) == "string" then
        notify("DSH released the question at its deadline; the answer will arrive as a follow-up")
      else
        notify("DSH cancelled the pending interaction; nothing will be sent", vim.log.levels.WARN)
      end
    end
    return
  end

  if value.type ~= "waterfall" then
    return
  end

  local options = config.options.interactions
  if value.event == "user-questions/request" and options.questions then
    enqueue("question", value)
  elseif value.event == "approval/request" and options.approvals then
    enqueue("approval", value)
  else
    -- Unknown or disabled: hand the request back to DSH unchanged.
    send_result(value.eventId, { kind = "next" })
  end
end

--- Open the single forwarded-event stream on the current socket.
local function open_stream()
  if state.stopped or not mux.is_connected() then
    return
  end

  state.stream_id = mux.stream("$events", vim.empty_dict(), {
    on_item = handle_item,
    on_end = function()
      state.stream_id = nil
      state.client_id = nil
    end,
    on_error = function(message)
      state.stream_id = nil
      state.client_id = nil
      if not state.stopped then
        notify(("question stream unavailable: %s"):format(message), vim.log.levels.WARN)
      end
    end,
  })
  if not state.stream_id then
    state.client_id = nil
  end
end

--- Ensure the forwarded-event stream is open for `ctx`.
---
--- Safe to call whenever a session view attaches: within one socket generation
--- the stream opens once, and after that socket drops the next call reopens it.
--- @param ctx {url: string, cookie: string}
function M.start(ctx)
  state.ctx = ctx
  if not config.options.interactions.enabled then
    return
  end

  state.stopped = false
  if not mux.is_connected() then
    state.stream_id = nil
    state.client_id = nil
  end
  if state.stream_id then
    return
  end

  mux.acquire(ctx, function(err)
    if state.stopped or err or state.stream_id then
      return
    end
    open_stream()
  end)
end

--- Whether the event stream has announced its client id.
--- @return boolean
function M.is_ready()
  return state.client_id ~= nil and state.stream_id ~= nil
end

--- Drop pending prompts and state (view teardown or plugin shutdown).
function M.stop()
  if state.claim_id and mux.is_connected() then
    mux.cancel(state.claim_id)
  end
  if state.stream_id and mux.is_connected() then
    mux.cancel(state.stream_id)
  end
  state.stopped = true
  state.ctx = nil
  state.stream_id = nil
  state.client_id = nil
  state.queue = {}
  state.inflight = {}
  state.cancelled = {}
  state.outbox = {}
  state.active = false
  state.active_event = nil
  state.active_frame = nil
  state.claim_id = nil
end

return M
