--- Workspace picker: choose the DSH Workspace that scopes session pickers and
--- new sessions.
---
--- DSH keeps every Workspace and its Session membership in one live
--- `workspace/follow` stream, so the roster comes from `dsh.workspaces`
--- rather than a unary list call. Selection is client-side state in
--- `dsh.workspace`: it changes which directory the plugin's pickers filter by
--- and where `:DshNew` creates Sessions, and it never changes Neovim's cwd.
local M = {}

local choice = require("dsh.ui.choice")
local server = require("dsh.server")
local session = require("dsh.session")
local workspace = require("dsh.workspace")
local workspaces = require("dsh.workspaces")

local function notify(message, level)
  vim.notify("dsh: " .. message, level or vim.log.levels.INFO)
end

--- Abbreviated form of a workspace directory for a picker row.
--- @param path string|nil
--- @return string
local function short_path(path)
  if type(path) ~= "string" or path == "" then
    return "?"
  end
  return vim.fn.fnamemodify(path, ":~")
end

--- Display title for one Workspace row.
--- @param entry table
--- @return string
local function display_title(entry)
  if type(entry.title) == "string" and entry.title ~= "" then
    return entry.title
  end
  local path = type(entry.path) == "string" and entry.path or ""
  local name = vim.fn.fnamemodify(path, ":t")
  if type(name) == "string" and name ~= "" then
    return name
  end
  return path ~= "" and path or "workspace"
end

--- Human-readable Session count for one Workspace row.
--- @param entry table
--- @return string
local function session_count(entry)
  local ids = entry.sessionIds
  local count = type(ids) == "table" and #ids or 0
  if count == 0 then
    return "no sessions"
  elseif count == 1 then
    return "1 session"
  end
  return ("%d sessions"):format(count)
end

--- One picker row.
--- @param entry table workspace row, or `{reset = true}` for the cwd row
--- @param selected_id string|nil
--- @param cwd_key string|nil
--- @return string
local function row_label(entry, selected_id, cwd_key)
  if entry.reset then
    local label = ("Use Neovim's current directory — %s"):format(short_path(vim.fn.getcwd()))
    if selected_id == nil then
      label = label .. "  (current)"
    end
    return label
  end

  local label = ("%s — %s  (%s)"):format(display_title(entry), short_path(entry.path), session_count(entry))
  if entry.workspaceId == selected_id then
    label = label .. "  (selected)"
  elseif selected_id == nil and cwd_key and type(entry.path) == "string" then
    if session.comparison_key(entry.path) == cwd_key then
      label = label .. "  (current)"
    end
  end
  return label
end

--- Pick the Workspace that scopes session pickers and new sessions.
function M.pick()
  server.context(function(err, ctx)
    if err then
      notify(err, vim.log.levels.ERROR)
      return
    end

    local ready, stream_err = workspaces.ensure(ctx)
    if not ready then
      notify(stream_err or "cannot list workspaces", vim.log.levels.ERROR)
      return
    end

    local items = workspaces.list()
    if #items == 0 then
      notify("no workspaces yet; :DshNew registers one for this directory", vim.log.levels.WARN)
      return
    end

    local selected = workspace.selected()
    local selected_id = selected and selected.workspaceId or nil
    local cwd_key = session.comparison_key(vim.fn.getcwd())

    local rows = { { reset = true } }
    for _, item in ipairs(items) do
      rows[#rows + 1] = item
    end

    choice.one(rows, function(entry)
      return row_label(entry, selected_id, cwd_key)
    end, { prompt = "DSH workspace" }, function(entry)
      if entry.reset then
        workspace.clear_selection()
        notify(("workspace: Neovim's current directory (%s)"):format(short_path(vim.fn.getcwd())))
        return
      end

      if entry.workspaceId ~= nil and entry.workspaceId == selected_id then
        notify(("already using %s"):format(display_title(entry)))
        return
      end

      local ok, select_err = workspace.select(entry)
      if not ok then
        notify(select_err or "cannot select the workspace", vim.log.levels.ERROR)
        return
      end
      notify(("workspace: %s (%s)"):format(display_title(entry), short_path(entry.path)))
    end)
  end)
end

--- Return to Neovim's current directory without opening a picker.
function M.reset()
  workspace.clear_selection()
  notify(("workspace: Neovim's current directory (%s)"):format(short_path(vim.fn.getcwd())))
end

return M
