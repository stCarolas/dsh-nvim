-- Model and mode pickers over stubbed DSH RPCs. No server and no buffers.
-- Run with: nvim --headless -l scripts/agent_spec.lua
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h:h")
vim.opt.rtp:append(root)

local config = require("dsh.config")
config.setup({ notifications = false })

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

local function contains(list, needle)
  for _, item in ipairs(list) do
    if item == needle or (type(item) == "string" and item:find(needle, 1, true)) then
      return true
    end
  end
  return false
end

--------------------------------------------------------------------------------
-- Stubs: the pickers are pure UI orchestration over chat/session/rpc.
--------------------------------------------------------------------------------
local chat_state = { current = nil, recent = nil }
local chat_calls = {}
local chat = {
  current = function()
    return chat_state.current
  end,
  recent_view = function()
    return chat_state.recent
  end,
  open = function(session_id, opts)
    chat_calls.open = { id = session_id, opts = opts }
  end,
  resolve_session = function(continue)
    local session_id = chat_state.current or chat_state.recent
    if session_id then
      continue(session_id)
      return
    end
    chat_calls.resolve_pending = continue
  end,
}
package.loaded["dsh.ui.chat"] = chat
package.loaded["dsh.server"] = {
  context = function(callback)
    callback(nil, { url = "http://test", cookie = "cookie" })
  end,
}

local rpc_handlers = {}
local rpc_calls = {}
package.loaded["dsh.http"] = {
  rpc = function(_, endpoint, args)
    rpc_calls[#rpc_calls + 1] = { endpoint = endpoint, args = args }
    local handler = rpc_handlers[endpoint]
    if handler then
      return handler(args)
    end
    return nil, "unexpected rpc " .. endpoint
  end,
}

local notified = {}
local original_notify = vim.notify
vim.notify = function(message, level)
  notified[#notified + 1] = { message = message, level = level }
end

local selections = {}
local select_calls = {}
vim.ui.select = function(labels, opts, callback)
  select_calls[#select_calls + 1] = { prompt = opts and opts.prompt, labels = labels }
  local wanted = table.remove(selections, 1)
  if wanted == nil then
    callback(nil)
    return
  end
  for index, label in ipairs(labels) do
    if label == wanted or label:find(wanted, 1, true) then
      callback(label, index)
      return
    end
  end
  error(("no label matching %q in %s"):format(wanted, vim.inspect(labels)))
end

local agent_ui = require("dsh.ui.agent")

local CATALOG = {
  default = { provider = "deepseek-official", model = "deepseek-flash" },
  routableProviders = { "deepseek-official", "acme" },
  groups = {
    {
      id = "deepseek-official",
      name = "DeepSeek",
      models = {
        { id = "deepseek-flash", name = "DeepSeek Flash", description = "Fast everyday model" },
        {
          id = "deepseek-reasoner",
          name = "DeepSeek Reasoner",
          reasoning = { defaultEffort = "high", efforts = { { id = "high", name = "High" } } },
        },
      },
    },
    {
      id = "acme",
      name = "Acme",
      models = { { id = "acme-one", name = "Acme One", badge = { text = "new" } } },
    },
  },
  failures = {},
}

local ROSTER = {
  presets = {
    { id = "standard", order = 1, isDefault = true },
    { id = "ptc", order = 2, isDefault = false },
    { id = "minimal", order = 3, isDefault = false },
    { id = "cordis", order = 4, isDefault = false },
    { id = "oda", name = "ODA feature", description = "Bundle presets", isDefault = false },
    { id = "broken", isDefault = false, broken = "missing service" },
  },
}

local state_value = {
  blank = true,
  preset = "standard",
  model = { provider = "deepseek-official", model = "deepseek-flash" },
}

local function reset()
  chat_state.current = nil
  chat_state.recent = nil
  chat_calls = {}
  rpc_handlers = {}
  rpc_calls = {}
  notified = {}
  selections = {}
  select_calls = {}
  state_value = {
    blank = true,
    preset = "standard",
    model = { provider = "deepseek-official", model = "deepseek-flash" },
  }

  rpc_handlers["session/modelCatalog"] = function()
    return CATALOG
  end
  rpc_handlers["session/projections"] = function()
    return { values = {
      agentPreset = state_value.preset,
      modelSelection = { next = state_value.model },
      sessionListMetadata = { blank = state_value.blank },
    } }
  end
  rpc_handlers["session/selectModel"] = function(args)
    return {
      selected = {
        provider = args.request.provider,
        model = args.request.model,
        reasoningEffort = args.request.reasoningEffort,
      },
    }
  end
  rpc_handlers["agentPresets/list"] = function()
    return ROSTER
  end
  rpc_handlers["agentPresets/select"] = function(args)
    return args.agentPreset
  end
  rpc_handlers["settings/update"] = function(args)
    return { ns = args.ns }
  end
end

local function calls_to(endpoint)
  local found = {}
  for _, call in ipairs(rpc_calls) do
    if call.endpoint == endpoint then
      found[#found + 1] = call
    end
  end
  return found
end

local function last_notice()
  return notified[#notified] and notified[#notified].message or ""
end

--------------------------------------------------------------------------------
-- 1. Model picker: current marker, provider grouping and effort.
--------------------------------------------------------------------------------
reset()
chat_state.current = "session-one"
selections = { "DeepSeek Reasoner" }
agent_ui.model()

check("model picker uses vim.ui", #select_calls == 1, tostring(#select_calls))
check("model picker prompt", select_calls[1] and select_calls[1].prompt == "DSH model", select_calls[1] and select_calls[1].prompt)
check(
  "model rows carry the provider and description",
  select_calls[1] and contains(select_calls[1].labels, "DeepSeek · DeepSeek Flash — Fast everyday model"),
  select_calls[1] and vim.inspect(select_calls[1].labels)
)
check(
  "current model is marked",
  select_calls[1] and contains(select_calls[1].labels, "DeepSeek Flash — Fast everyday model  (current)"),
  select_calls[1] and vim.inspect(select_calls[1].labels)
)
check(
  "provider badge is shown",
  select_calls[1] and contains(select_calls[1].labels, "Acme · Acme One [new]"),
  select_calls[1] and vim.inspect(select_calls[1].labels)
)
local select_model = calls_to("session/selectModel")
check("model switch sent once", #select_model == 1, tostring(#select_model))
check(
  "model switch names the session and provider",
  select_model[1]
    and select_model[1].args.request.sessionId == "session-one"
    and select_model[1].args.request.provider == "deepseek-official"
    and select_model[1].args.request.model == "deepseek-reasoner",
  select_model[1] and vim.inspect(select_model[1].args)
)
check(
  "model switch starts at the advertised default effort",
  select_model[1] and select_model[1].args.request.reasoningEffort == "high",
  select_model[1] and vim.inspect(select_model[1].args.request)
)
check("model switch is reported", contains({ last_notice() }, "model: deepseek-official/deepseek-reasoner (high)"), last_notice())

-- 2. Choosing the current model sends no switch.
reset()
chat_state.current = "session-one"
selections = { "DeepSeek Flash" }
agent_ui.model()
check("current model is a no-op", #calls_to("session/selectModel") == 0)
check("current model no-op is reported", last_notice():find("already using deepseek-official/deepseek-flash", 1, true) ~= nil, last_notice())

-- 3. A model without advertised reasoning omits the effort.
reset()
chat_state.current = "session-one"
selections = { "Acme One" }
agent_ui.model()
local acme_switch = calls_to("session/selectModel")[1]
check("model without reasoning omits the effort", acme_switch and acme_switch.args.request.reasoningEffort == nil, acme_switch and vim.inspect(acme_switch.args.request))

-- 3b. A refused model switch is reported at error level.
reset()
chat_state.current = "session-one"
rpc_handlers["session/selectModel"] = function()
  return nil, "session/model-unavailable: Select an available model before sending a message.", "session/model-unavailable"
end
selections = { "DeepSeek Reasoner" }
agent_ui.model()
check("model refusal is reported", last_notice():find("session/model-unavailable", 1, true) ~= nil, last_notice())
check(
  "model refusal uses the error level",
  notified[#notified] and notified[#notified].level == vim.log.levels.ERROR,
  notified[#notified] and tostring(notified[#notified].level)
)

-- 4. A failed projection read does not block the switch.
reset()
chat_state.current = "session-one"
rpc_handlers["session/projections"] = function()
  return nil, "projection unavailable"
end
selections = { "DeepSeek Reasoner" }
agent_ui.model()
local unmarked = select_calls[1] and select_calls[1].labels or {}
check("model picker still opens without state", #select_calls == 1)
check("no current marker without state", not contains(unmarked, "(current)"))
check("model switch still sent without state", #calls_to("session/selectModel") == 1)

-- 5. Empty and failing catalogs are reported.
reset()
chat_state.current = "session-one"
rpc_handlers["session/modelCatalog"] = function()
  return { default = nil, groups = {}, failures = { { id = "acme", name = "Acme", message = "no API key" } } }
end
agent_ui.model()
check("empty model catalog opens no picker", #select_calls == 0)
check("empty model catalog names the failure", last_notice():find("no models available", 1, true) ~= nil and last_notice():find("no API key", 1, true) ~= nil, last_notice())

reset()
chat_state.current = "session-one"
rpc_handlers["session/modelCatalog"] = function()
  return nil, "catalog unavailable"
end
agent_ui.model()
check("model catalog error is reported", #select_calls == 0 and last_notice():find("catalog unavailable", 1, true) ~= nil, last_notice())

-- 6. No open view asks for a session, then switches its model.
reset()
selections = { "DeepSeek Reasoner" }
agent_ui.model()
check("model picker waits for a session", #select_calls == 0 and type(chat_calls.resolve_pending) == "function")
chat_calls.resolve_pending("session-two")
check("model picker opens after the session is resolved", select_calls[1] and select_calls[1].prompt == "DSH model", select_calls[1] and select_calls[1].prompt)
local resolved_switch = calls_to("session/selectModel")[1]
check(
  "resolved session is used for the switch",
  resolved_switch and resolved_switch.args.request.sessionId == "session-two",
  resolved_switch and vim.inspect(resolved_switch.args)
)

--------------------------------------------------------------------------------
-- 7. Mode picker: built-in names, current marker and blank-session switch.
--------------------------------------------------------------------------------
reset()
chat_state.current = "session-one"
selections = { "Creator mode" }
agent_ui.mode()

check("mode picker uses vim.ui", #select_calls == 1, tostring(#select_calls))
check("blank-session mode prompt", select_calls[1] and select_calls[1].prompt == "DSH mode", select_calls[1] and select_calls[1].prompt)
check(
  "built-in preset names are translated",
  select_calls[1] and contains(select_calls[1].labels, "Standard mode  (current)") and contains(select_calls[1].labels, "Creator mode"),
  select_calls[1] and vim.inspect(select_calls[1].labels)
)
check(
  "declared preset names and descriptions are kept",
  select_calls[1] and contains(select_calls[1].labels, "ODA feature — Bundle presets"),
  select_calls[1] and vim.inspect(select_calls[1].labels)
)
check("broken presets are omitted", select_calls[1] and not contains(select_calls[1].labels, "broken"))
local preset_select = calls_to("agentPresets/select")
check("blank session preset switch sent", #preset_select == 1, tostring(#preset_select))
check(
  "preset switch names the session and preset",
  preset_select[1] and preset_select[1].args.agentId == "session-one" and preset_select[1].args.agentPreset == "cordis",
  preset_select[1] and vim.inspect(preset_select[1].args)
)
check("preset switch is reported", last_notice():find("mode: Creator mode", 1, true) ~= nil, last_notice())
check("blank-session switch does not write the default", #calls_to("settings/update") == 0)

-- 8. Choosing the preset a blank session already runs is a no-op.
reset()
chat_state.current = "session-one"
selections = { "Standard mode" }
agent_ui.mode()
check("current preset is a no-op", #calls_to("agentPresets/select") == 0)
check("current preset no-op is reported", last_notice():find("already in Standard mode", 1, true) ~= nil, last_notice())

-- 9. A started session switches the new-session default instead.
reset()
chat_state.current = "session-one"
rpc_handlers["session/projections"] = function()
  return { values = {
    agentPreset = "standard",
    modelSelection = { next = nil },
    sessionListMetadata = { blank = false },
  } }
end
selections = { "Creator mode" }
agent_ui.mode()

check(
  "locked-session prompt names new sessions",
  select_calls[1] and select_calls[1].prompt == "DSH mode for new sessions (this session is locked)",
  select_calls[1] and select_calls[1].prompt
)
check("locked session sends no preset switch", #calls_to("agentPresets/select") == 0)
local settings_update = calls_to("settings/update")
check("locked session writes the default", #settings_update == 1, tostring(#settings_update))
check(
  "default write names the namespace and field",
  settings_update[1]
    and settings_update[1].args.ns == "agent-preset-registry"
    and settings_update[1].args.patch.selectedDefault == "cordis",
  settings_update[1] and vim.inspect(settings_update[1].args)
)
check("default write is reported", last_notice():find("new sessions use Creator mode", 1, true) ~= nil, last_notice())

-- 10. With no session view the picker changes the new-session default.
reset()
selections = { "PTC mode" }
agent_ui.mode()
check("no-session mode prompt", select_calls[1] and select_calls[1].prompt == "DSH mode for new sessions", select_calls[1] and select_calls[1].prompt)
check("no session projections read", #calls_to("session/projections") == 0)
check("no-session default written", #calls_to("settings/update") == 1)
check("no-session preset switch avoided", #calls_to("agentPresets/select") == 0)

-- 11. The current default is a no-op for new sessions.
reset()
selections = { "Standard mode" }
agent_ui.mode()
check("current default is a no-op", #calls_to("settings/update") == 0)
check("current default no-op is reported", last_notice():find("already use Standard mode", 1, true) ~= nil, last_notice())

-- 12. A started-session race is explained.
reset()
chat_state.current = "session-one"
rpc_handlers["agentPresets/select"] = function()
  return nil, "agent-preset/locked: This session has already started", "agent-preset/locked"
end
selections = { "Creator mode" }
agent_ui.mode()
check("locked race is explained", last_notice():find("already started", 1, true) ~= nil, last_notice())
check("locked race keeps the error level", notified[#notified] and notified[#notified].level == vim.log.levels.WARN, notified[#notified] and tostring(notified[#notified].level))

-- 13. Cancelling a picker sends nothing further.
reset()
chat_state.current = "session-one"
selections = {}
agent_ui.mode()
check("cancelled mode picker keeps only the roster read", #rpc_calls == 2, vim.inspect(rpc_calls))
check("cancelled mode picker switches nothing", #calls_to("agentPresets/select") == 0 and #calls_to("settings/update") == 0)

-- 14. Empty rosters are reported.
reset()
rpc_handlers["agentPresets/list"] = function()
  return { presets = {} }
end
agent_ui.mode()
check("empty roster opens no picker", #select_calls == 0)
check("empty roster is reported", last_notice():find("no agent modes available", 1, true) ~= nil, last_notice())

-- 15. A roster where every declaration is broken reports the diagnostics.
reset()
rpc_handlers["agentPresets/list"] = function()
  return { presets = { { id = "broken", broken = "missing service: worker" } } }
end
agent_ui.mode()
check("broken roster opens no picker", #select_calls == 0)
check("broken roster names the diagnostic", last_notice():find("missing service: worker", 1, true) ~= nil, last_notice())

vim.notify = original_notify

print(("\n=== %d checks, %d failed ==="):format(checks, failures))
vim.cmd("cquit " .. (failures > 0 and 1 or 0))
