--- Agent configuration: the model catalog and the Agent preset roster.
---
--- A Session runs under one Agent preset ("mode" in the Web UI) and picks one
--- provider model per turn. Both are DSH Remote methods:
---
---   * `session/modelCatalog` lists every currently routable model, grouped by
---     provider, with the deployment default and the reasoning metadata.
---   * `session/selectModel` installs one provider/model selection on a
---     Session (and saves it as the default for later Sessions in the
---     background).
---   * `agentPresets/list` lists the presets the deployment composes.
---   * `agentPresets/select` records one preset on a Session that has not
---     started its first turn; a started Session keeps its composition and the
---     call fails with `agent-preset/locked`.
---   * `settings/update` writes `selectedDefault` into the
---     `agent-preset-registry` namespace, the preset new Sessions compose.
---
--- "Mode" here is the Web UI's name for an Agent preset: built-in ids are
--- `standard`, `ptc`, `minimal` and `cordis` (Creator mode), plus user-defined
--- presets declared by bundles.
local M = {}

local config = require("dsh.config")
local http = require("dsh.http")

--- English names of the shipped presets, matching the Web UI's copy.
local PRESET_NAMES = {
  standard = "Standard mode",
  ptc = "PTC mode",
  minimal = "Minimal mode",
  cordis = "Creator mode",
}

--- Request timeout for these small catalog and selection calls.
local function timeout()
  return config.options.request_timeout
end

--- Read the routable model catalog.
--- @param ctx {url: string, cookie: string}
--- @return table|nil catalog `{default, routableProviders, groups, failures}`
--- @return string|nil error
function M.catalog(ctx)
  return http.rpc(ctx, "session/modelCatalog", vim.empty_dict(), timeout())
end

--- Switch one Session's model.
--- @param ctx {url: string, cookie: string}
--- @param session_id string
--- @param provider string provider route id
--- @param model string provider-owned model id
--- @param reasoning_effort string|nil adapter-owned effort; nil uses the model default
--- @return table|nil value `{selected = {provider, model, reasoningEffort?}}`
--- @return string|nil error
function M.select_model(ctx, session_id, provider, model, reasoning_effort)
  local request = {
    sessionId = session_id,
    provider = provider,
    model = model,
  }
  if type(reasoning_effort) == "string" and reasoning_effort ~= "" then
    request.reasoningEffort = reasoning_effort
  end
  return http.rpc(ctx, "session/selectModel", { request = request }, timeout())
end

--- Read the Agent preset roster.
--- @param ctx {url: string, cookie: string}
--- @return table|nil value `{presets = {{id, name?, description?, isDefault, broken?}}}`
--- @return string|nil error
function M.presets(ctx)
  return http.rpc(ctx, "agentPresets/list", vim.empty_dict(), timeout())
end

--- Select one preset for a Session that has not started its first turn.
--- @param ctx {url: string, cookie: string}
--- @param session_id string
--- @param preset_id string
--- @return string|nil preset the committed preset id
--- @return string|nil error
--- @return string|nil code DSH error code, e.g. "agent-preset/locked"
function M.select_preset(ctx, session_id, preset_id)
  return http.rpc(ctx, "agentPresets/select", {
    agentId = session_id,
    agentPreset = preset_id,
  }, timeout())
end

--- Persist the preset new Sessions compose.
--- @param ctx {url: string, cookie: string}
--- @param preset_id string
--- @return table|nil value settings namespace view after the write
--- @return string|nil error
function M.default_preset(ctx, preset_id)
  return http.rpc(ctx, "settings/update", {
    ns = "agent-preset-registry",
    patch = { selectedDefault = preset_id },
  }, timeout())
end

--- Read one Session's current Agent facts.
---
--- `session/projections` carries what the model and mode pickers need without
--- listing every Session: the recorded preset, the model selection the next
--- step will use, and whether the Session has already started a turn.
--- @param ctx {url: string, cookie: string}
--- @param session_id string
--- @return table|nil state `{blank, preset, model}`; fields are nil when absent
--- @return string|nil error
function M.state(ctx, session_id)
  local value, err = http.rpc(ctx, "session/projections", {
    request = { sessionId = session_id },
  }, timeout())
  if not value then
    return nil, err
  end

  local values = type(value.values) == "table" and value.values or {}
  local metadata = type(values.sessionListMetadata) == "table" and values.sessionListMetadata or {}
  local selection = type(values.modelSelection) == "table" and values.modelSelection or {}

  -- JSON `null` decodes to vim.NIL, so check the decoded type instead of
  -- relying on truthiness for every field.
  local model = selection.next
  if type(model) ~= "table" then
    model = selection.lastUsed
  end
  if type(model) ~= "table" then
    model = nil
  end

  -- `blank and blank or nil` would turn `false` into nil; keep the boolean.
  local blank = metadata.blank
  if type(blank) ~= "boolean" then
    blank = nil
  end

  return {
    blank = blank,
    preset = type(values.agentPreset) == "string" and values.agentPreset or nil,
    model = model,
  }
end

--- Whether a model selection names the same provider/model pair.
--- @param left table|nil
--- @param right table|nil
--- @return boolean
function M.same_model(left, right)
  return type(left) == "table"
    and type(right) == "table"
    and left.provider == right.provider
    and left.model == right.model
end

--- Display name of one preset.
---
--- Shipped presets publish no name; the Web UI translates their ids. The
--- plugin's messages are English, so it uses the same English copy.
--- @param preset table roster entry
--- @return string
function M.preset_name(preset)
  if type(preset.name) == "string" and preset.name ~= "" then
    return preset.name
  end
  local id = type(preset.id) == "string" and preset.id or nil
  if not id then
    return "mode"
  end
  return PRESET_NAMES[id] or id
end

return M
