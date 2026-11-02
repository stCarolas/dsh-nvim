--- Session picker built on `vim.ui.select`, so it follows the user's picker plugin.
local M = {}

local session = require("dsh.session")

--- Human-readable relative age for an epoch-milliseconds timestamp.
--- @param timestamp number|nil
--- @return string
local function ago(timestamp)
  if type(timestamp) ~= "number" then
    return "?"
  end
  local seconds = math.max(0, os.time() - math.floor(timestamp / 1000))
  if seconds < 60 then
    return "just now"
  elseif seconds < 3600 then
    return ("%dm ago"):format(math.floor(seconds / 60))
  elseif seconds < 86400 then
    return ("%dh ago"):format(math.floor(seconds / 3600))
  end
  return ("%dd ago"):format(math.floor(seconds / 86400))
end

--- One picker row: title, id, age, cwd, state.
--- @param item table SessionSummary
--- @return string
function M.format(item)
  local title = session.title(item) or "(untitled)"
  local parts = {
    title,
    session.short_id(item.sessionId),
    ago(item.updatedAt),
  }
  if item.cwd then
    parts[#parts + 1] = vim.fn.fnamemodify(item.cwd, ":~")
  end
  if item.running then
    parts[#parts + 1] = "● running"
  elseif item.blank then
    parts[#parts + 1] = "blank"
  end
  return table.concat(parts, "  ")
end

--- Prompt the user to choose a session.
--- @param items table[]
--- @param on_choice fun(item: table)
--- @param opts {prompt: string|nil}|nil
function M.select(items, on_choice, opts)
  local labels = {}
  local index_by_label = {}

  for index, item in ipairs(items) do
    local label = M.format(item)
    if index_by_label[label] then
      label = label .. "  #" .. index
    end
    index_by_label[label] = index
    labels[#labels + 1] = label
  end

  vim.ui.select(labels, { prompt = (opts and opts.prompt) or "DSH sessions" }, function(choice)
    if not choice then
      return
    end
    local index = index_by_label[choice]
    if index then
      on_choice(items[index])
    end
  end)
end

return M
