--- DSH menu: nested `vim.ui.select` navigation.
---
--- The top level is opened with `:DshMenu` (or a `keymaps.global.menu` mapping).
--- Each entry leads to the next selection: the workspace session picker, the
--- skill catalog, or the command catalog. Skills are human-invocable through a
--- whitespace-bounded `/name` token in the prompt, so choosing one opens the
--- prompt prefilled with `/name ` and lets the user type the task. Commands run
--- through `commands/execute` and their result text is notified.
---
--- Skills and commands are session-scoped. The menu resolves its session once,
--- when it opens, so a submenu still targets the same session when `:DshMenu`
--- runs from another buffer or tab: the current view first, then the most
--- recently used open view, and only then does it ask with the session picker.
local M = {}

local http = require("dsh.http")
local server = require("dsh.server")
local session = require("dsh.session")
local chat = require("dsh.ui.chat")

local function notify(message, level)
  vim.notify("dsh: " .. message, level or vim.log.levels.INFO)
end

--- Session the menu should act on: the view at the cursor, or an open view
--- left in another tab/window.
--- @return string|nil
local function menu_session()
  return chat.current() or chat.recent_view()
end

--- Run `continue` for a resolved session, or let the user pick one first when
--- no session view is open at all.
--- @param session_id string|nil
--- @param continue fun(session_id: string)
local function with_session(session_id, continue)
  if session_id then
    continue(session_id)
    return
  end

  chat.pick_session(function(item)
    chat.open(item.sessionId, { title = session.title(item) })
    continue(item.sessionId)
  end)
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

--- Build one label per entry, keeping a label-to-entry map.
--- @param entries table[]
--- @param label fun(entry: table): string
--- @return string[] labels, table<string, table> by_label
local function label_map(entries, label)
  local labels, by_label = {}, {}
  for _, entry in ipairs(entries) do
    local text = label(entry)
    labels[#labels + 1] = text
    by_label[text] = entry
  end
  return labels, by_label
end

--- Ask for one skill and prefill the prompt with its `/name` gesture.
--- @param session_id string
local function choose_skill(session_id, skills)
  local labels, by_label = label_map(skills, function(skill)
    local description = one_line(skill.description)
    return ("%s — %s"):format(skill.name, description)
  end)

  vim.ui.select(labels, { prompt = "DSH skills" }, function(choice)
    local skill = choice and by_label[choice]
    if not skill then
      return
    end
    -- DSH injects the skill instructions when a user prompt contains a
    -- whitespace-bounded `/name` token; the prompt is where the task goes.
    chat.prompt(session_id, {
      title = "DSH skill: " .. skill.name,
      initial = "/" .. skill.name .. " ",
    })
  end)
end

--- List the human-invocable skills of one session.
--- @param session_id string|nil defaults to the current view or a picked one
function M.skills(session_id)
  local function show(id)
    server.context(function(err, ctx)
      if err then
        notify(err, vim.log.levels.ERROR)
        return
      end

      local value, list_err = http.rpc(ctx, "skills/list", { request = { sessionId = id } })
      if not value then
        notify(list_err or "cannot list skills", vim.log.levels.ERROR)
        return
      end

      local skills = value.skills or {}
      if #skills == 0 then
        notify("no skills available for this session")
        return
      end

      choose_skill(id, skills)
    end)
  end

  if session_id then
    show(session_id)
  else
    with_session(menu_session(), show)
  end
end

--- Execute one command line and report its text.
--- @param ctx table
--- @param session_id string
--- @param line string full slash line, e.g. "/goal clear"
--- @param name string command name without the slash, for error messages
local function execute_command(ctx, session_id, line, name)
  local value, err = http.rpc(ctx, "commands/execute", {
    agentId = session_id,
    line = line,
    submittedAttachments = {},
  })
  if not value then
    notify(err or ("command not recognized: /" .. name), err and vim.log.levels.ERROR or vim.log.levels.WARN)
    return
  end

  local result = value.result or {}
  if type(result.text) == "string" and result.text ~= "" then
    notify(result.text, result.kind == "error" and vim.log.levels.ERROR or vim.log.levels.INFO)
  end
end

--- Run one command descriptor, asking for its raw input when advertised.
--- @param ctx table
--- @param session_id string
--- @param command table
local function run_command(ctx, session_id, command)
  local name = command.name
  local hint = type(command.input) == "table" and command.input.hint or nil

  if type(hint) == "string" and hint ~= "" then
    vim.ui.input({ prompt = ("/%s %s: "):format(name, hint) }, function(input)
      if input == nil then
        return
      end
      local line = "/" .. name
      if vim.trim(input) ~= "" then
        line = line .. " " .. input
      end
      execute_command(ctx, session_id, line, name)
    end)
    return
  end

  execute_command(ctx, session_id, "/" .. name, name)
end

--- List the commands of one session.
--- @param session_id string|nil defaults to the current view or a picked one
function M.commands(session_id)
  local function show(id)
    server.context(function(err, ctx)
      if err then
        notify(err, vim.log.levels.ERROR)
        return
      end

      local commands, list_err = http.rpc(ctx, "commands/list", { agentId = id })
      if not commands then
        notify(list_err or "cannot list commands", vim.log.levels.ERROR)
        return
      end
      if #commands == 0 then
        notify("no commands available for this session")
        return
      end

      local labels, by_label = label_map(commands, function(command)
        return ("%s — %s"):format(command.name, one_line(command.description))
      end)

      vim.ui.select(labels, { prompt = "DSH commands" }, function(choice)
        local command = choice and by_label[choice]
        if command then
          run_command(ctx, id, command)
        end
      end)
    end)
  end

  if session_id then
    show(session_id)
  else
    with_session(menu_session(), show)
  end
end

--- Top-level menu entries, in the order they are offered.
--- `run` receives the session resolved when the menu opened.
local ITEMS = {
  { label = "0) new session", run = function() chat.new_session() end },
  { label = "1) open session…", run = function() chat.pick() end },
  { label = "2) dsh skills…", run = function(session_id) M.skills(session_id) end },
  { label = "3) dsh commands…", run = function(session_id) M.commands(session_id) end },
}

--- Open the top-level DSH menu.
function M.open()
  -- Resolve the target before the picker runs: its callback can execute after
  -- focus moved, and `:DshMenu` is often invoked from another tab or buffer.
  local session_id = menu_session()
  local labels, by_label = label_map(ITEMS, function(item)
    return item.label
  end)

  vim.ui.select(labels, { prompt = "DSH menu" }, function(choice)
    local item = choice and by_label[choice]
    if item then
      item.run(session_id)
    end
  end)
end

return M
