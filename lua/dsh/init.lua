--- Public entry point for dsh.nvim.
local M = {}

local config = require("dsh.config")
local render = require("dsh.render")
local server = require("dsh.server")

--- Configure the plugin. Safe to call more than once.
--- @param opts table|nil
function M.setup(opts)
  config.setup(opts)
  render.define_highlights()

  local global = config.options.keymaps.global or {}
  local actions = {
    new_session = function()
      M.new_session()
    end,
    pick = function()
      M.pick()
    end,
    open = function()
      M.open()
    end,
    prompt = function()
      M.prompt()
    end,
  }
  for action, lhs in pairs(global) do
    local callback = actions[action]
    if callback and lhs and lhs ~= "" then
      vim.keymap.set("n", lhs, callback, { desc = "DSH: " .. action:gsub("_", " "), silent = true })
    end
  end

  return M
end

--- Open a session view, or pick one when `session_id` is omitted.
--- @param session_id string|nil
function M.open(session_id)
  require("dsh.ui.chat").open(session_id)
end

--- Create a session in the current directory's workspace and open it.
--- @param opts {prompt: boolean|nil}|nil
function M.new_session(opts)
  require("dsh.ui.chat").new_session(opts)
end

--- Pick a session rooted at the current directory and open it.
function M.pick()
  require("dsh.ui.chat").pick()
end

--- Send a prompt to the session of the current buffer.
function M.prompt()
  require("dsh.ui.chat").prompt()
end

--- Re-read the current session's history.
function M.refresh()
  require("dsh.ui.chat").refresh()
end

--- Cancel the running turn in the current session.
function M.cancel()
  require("dsh.ui.chat").cancel()
end

--- Close the current session view.
function M.close()
  require("dsh.ui.chat").close()
end

--- Stop the `dsh web` process this plugin started.
function M.stop()
  require("dsh.ui.chat").shutdown()
  server.stop()
end

--- Connection facts, for statuslines and health checks.
function M.status()
  local status = server.describe()
  status.stream = require("dsh.mux").is_connected()
  status.interactions = require("dsh.interactions").is_ready()
  return status
end

render.define_highlights()

return M
