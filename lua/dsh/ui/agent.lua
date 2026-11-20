--- Model and mode pickers.
---
--- `:DshModel` switches the provider/model of a Session; `:DshMode` chooses an
--- Agent preset ("mode" in the Web UI: Standard, Creator, PTC, Minimal, or a
--- preset declared by a bundle). Both are flat `vim.ui.select` lists built
--- from the DSH catalogs, so the user's picker plugin applies. The current
--- choice is marked on its row.
---
--- A Session's composition is fixed once its first turn starts
--- (`agent-preset/locked`), so `:DshMode` acts on a blank Session view. From a
--- started Session or from no Session view at all it changes the preset new
--- Sessions compose instead, and the prompt says so.
local M = {}

local agent = require("dsh.agent")
local chat = require("dsh.ui.chat")
local choice = require("dsh.ui.choice")
local server = require("dsh.server")

local function notify(message, level)
  vim.notify("dsh: " .. message, level or vim.log.levels.INFO)
end

--- One-line text for a `vim.ui.select` row.
--- @param text string|nil
--- @return string
local function one_line(text)
  if type(text) ~= "string" then
    return ""
  end
  return (text:gsub("[\r\n]+", " "))
end

--- Flatten the provider groups of a model catalog into picker rows.
--- @param catalog table
--- @return table[] entries `{provider = group, model = model}`
local function model_entries(catalog)
  local entries = {}
  for _, group in ipairs(type(catalog.groups) == "table" and catalog.groups or {}) do
    for _, model in ipairs(type(group.models) == "table" and group.models or {}) do
      entries[#entries + 1] = { provider = group, model = model }
    end
  end
  return entries
end

--- Whether a provider/model pair appears in the catalog rows.
--- @param entries table[]
--- @param selection table
--- @return boolean
local function model_in_catalog(entries, selection)
  for _, entry in ipairs(entries) do
    if entry.provider.id == selection.provider and entry.model.id == selection.model then
      return true
    end
  end
  return false
end

--- Provider-authored badge text, as a plain string.
--- @param badge table|nil
--- @return string|nil
local function badge_text(badge)
  local text = type(badge) == "table" and badge.text or nil
  if type(text) == "string" then
    return text
  end
  if type(text) == "table" then
    local value = text.en
    if type(value) ~= "string" then
      for _, translation in pairs(text) do
        if type(translation) == "string" then
          value = translation
          break
        end
      end
    end
    if type(value) == "string" and value ~= "" then
      return value
    end
  end
  return nil
end

--- One picker row for a model.
--- @param entry table
--- @param current table|nil
--- @return string
local function model_label(entry, current)
  local provider = entry.provider
  local model = entry.model
  local provider_name = type(provider.name) == "string" and provider.name ~= "" and provider.name or provider.id
  local model_name = type(model.name) == "string" and model.name ~= "" and model.name or model.id

  local label = ("%s · %s"):format(provider_name, model_name)
  local badge = badge_text(model.badge)
  if badge then
    label = label .. " [" .. badge .. "]"
  end
  local description = one_line(model.description)
  if description ~= "" then
    label = label .. " — " .. description
  end
  if agent.same_model(current, { provider = provider.id, model = model.id }) then
    label = label .. "  (current)"
  end
  return label
end

--- Show the model catalog for one Session.
--- @param ctx {url: string, cookie: string}
--- @param session_id string
local function show_models(ctx, session_id)
  local catalog, catalog_err = agent.catalog(ctx)
  if not catalog then
    notify(catalog_err or "cannot read the model catalog", vim.log.levels.ERROR)
    return
  end

  local entries = model_entries(catalog)
  if #entries == 0 then
    local details = {}
    for _, failure in ipairs(type(catalog.failures) == "table" and catalog.failures or {}) do
      details[#details + 1] = ("%s: %s"):format(failure.name or failure.id, one_line(failure.message))
    end
    local suffix = #details > 0 and (": " .. table.concat(details, "; ")) or ""
    notify("no models available" .. suffix, vim.log.levels.WARN)
    return
  end

  -- The current row is a hint, not a requirement: a failed projection read
  -- must not stop the model switch.
  local state = agent.state(ctx, session_id)
  local current = state and state.model or nil
  if state and not current and type(catalog.default) == "table" then
    local default = catalog.default
    local selection = { provider = default.provider, model = default.model }
    if model_in_catalog(entries, selection) then
      current = selection
    end
  end

  choice.one(entries, function(entry)
    return model_label(entry, current)
  end, { prompt = "DSH model" }, function(entry)
    local selection = { provider = entry.provider.id, model = entry.model.id }
    if agent.same_model(current, selection) then
      notify(("already using %s/%s"):format(selection.provider, selection.model))
      return
    end

    -- Mirror the Web UI: choosing a model starts at its advertised default
    -- reasoning effort; the adapter falls back to provider behavior without one.
    local effort = type(entry.model.reasoning) == "table" and entry.model.reasoning.defaultEffort or nil
    local value, select_err = agent.select_model(ctx, session_id, selection.provider, selection.model, effort)
    if not value then
      notify(select_err or "cannot switch model", vim.log.levels.ERROR)
      return
    end

    local selected = type(value.selected) == "table" and value.selected or {}
    local provider = selected.provider or selection.provider
    local model = selected.model or selection.model
    local suffix = type(selected.reasoningEffort) == "string" and (" (" .. selected.reasoningEffort .. ")") or ""
    notify(("model: %s/%s%s"):format(provider, model, suffix))
  end)
end

--- Usable presets in roster order, with broken declarations left out.
--- @param roster table
--- @return table[] presets
--- @return string[] broken diagnostics of declarations that cannot compose
local function preset_entries(roster)
  local presets, broken = {}, {}
  for _, preset in ipairs(type(roster.presets) == "table" and roster.presets or {}) do
    if preset.broken then
      broken[#broken + 1] = ("%s: %s"):format(tostring(preset.id), one_line(preset.broken))
    else
      presets[#presets + 1] = preset
    end
  end
  return presets, broken
end

--- The preset new Sessions compose, when the roster marks one.
--- @param presets table[]
--- @return string|nil
local function default_preset_id(presets)
  for _, preset in ipairs(presets) do
    if preset.isDefault == true then
      return preset.id
    end
  end
  return nil
end

--- One picker row for a preset.
--- @param preset table
--- @param current_id string|nil
--- @return string
local function preset_label(preset, current_id)
  local label = agent.preset_name(preset)
  local description = one_line(preset.description)
  if description ~= "" then
    label = label .. " — " .. description
  end
  if preset.id == current_id then
    label = label .. "  (current)"
  end
  return label
end

--- Name of the preset a Session would use, falling back to the roster default.
--- @param presets table[]
--- @param preset_id string|nil
--- @return string
local function preset_name_by_id(presets, preset_id)
  for _, preset in ipairs(presets) do
    if preset.id == preset_id then
      return agent.preset_name(preset)
    end
  end
  return tostring(preset_id)
end

--- Pick the default preset for Sessions created later.
--- @param ctx {url: string, cookie: string}
--- @param presets table[]
--- @param default_id string|nil
--- @param locked boolean whether a started Session made this the only option
local function choose_new_default(ctx, presets, default_id, locked)
  local prompt = "DSH mode for new sessions"
  if locked then
    prompt = prompt .. " (this session is locked)"
  end

  choice.one(presets, function(preset)
    return preset_label(preset, default_id)
  end, { prompt = prompt }, function(preset)
    if preset.id == default_id then
      notify(("new sessions already use %s"):format(agent.preset_name(preset)))
      return
    end

    local value, set_err = agent.default_preset(ctx, preset.id)
    if not value then
      notify(set_err or "cannot set the default mode", vim.log.levels.ERROR)
      return
    end
    notify(("new sessions use %s"):format(agent.preset_name(preset)))
  end)
end

--- Pick the preset of one blank Session.
--- @param ctx {url: string, cookie: string}
--- @param presets table[]
--- @param session_id string
--- @param state table
--- @param default_id string|nil
local function choose_session_preset(ctx, presets, session_id, state, default_id)
  local current_id = state.preset or default_id

  choice.one(presets, function(preset)
    return preset_label(preset, current_id)
  end, { prompt = "DSH mode" }, function(preset)
    if preset.id == state.preset then
      notify(("already in %s"):format(agent.preset_name(preset)))
      return
    end

    local value, select_err, code = agent.select_preset(ctx, session_id, preset.id)
    if not value then
      if code == "agent-preset/locked" then
        notify("this session has already started; its mode is fixed", vim.log.levels.WARN)
      else
        notify(select_err or "cannot switch mode", vim.log.levels.ERROR)
      end
      return
    end

    local applied = type(value) == "string" and value or preset.id
    notify(("mode: %s"):format(preset_name_by_id(presets, applied)))
  end)
end

--- Switch the model of the current (or chosen) Session.
function M.model()
  chat.resolve_session(function(session_id)
    server.context(function(err, ctx)
      if err then
        notify(err, vim.log.levels.ERROR)
        return
      end
      show_models(ctx, session_id)
    end)
  end)
end

--- Choose an Agent preset for this blank Session, or for new Sessions.
function M.mode()
  server.context(function(err, ctx)
    if err then
      notify(err, vim.log.levels.ERROR)
      return
    end

    local roster, roster_err = agent.presets(ctx)
    if not roster then
      notify(roster_err or "cannot list modes", vim.log.levels.ERROR)
      return
    end

    local presets, broken = preset_entries(roster)
    if #presets == 0 then
      local suffix = #broken > 0 and (": " .. table.concat(broken, "; ")) or ""
      notify("no agent modes available" .. suffix, vim.log.levels.WARN)
      return
    end
    local default_id = default_preset_id(presets)

    local session_id = chat.current() or chat.recent_view()
    if not session_id then
      choose_new_default(ctx, presets, default_id, false)
      return
    end

    local state, state_err = agent.state(ctx, session_id)
    if not state then
      notify(state_err or "cannot read the session state", vim.log.levels.ERROR)
      return
    end

    if state.blank ~= false then
      choose_session_preset(ctx, presets, session_id, state, default_id)
    else
      choose_new_default(ctx, presets, default_id, true)
    end
  end)
end

return M
