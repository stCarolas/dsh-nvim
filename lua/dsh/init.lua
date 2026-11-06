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
  if config.options.treesitter then
    require("dsh.treesitter").setup()
  end

  local global = config.options.keymaps.global or {}
  local actions = {
    menu = function()
      M.menu()
    end,
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

--- Open the nested DSH menu: new session, open session, skills and commands.
function M.menu()
  require("dsh.ui.menu").open()
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

--- Ensure the DSH server is ready for later Neovim instances.
---
--- Intended for the shared/attached modes: a private server dies with this
--- Neovim, so warming one up would help nobody and is refused. With `cli` the
--- command exits with status 0 (ready) or 1 (failed), which is what
--- `:DshWarmup!` does for startup scripts; without it the outcome is reported
--- and control returns to the editor.
--- @param cli boolean|nil exit with a status code instead of returning
--- @return boolean ok
--- @return string|nil error
function M.warmup(cli)
  local config = require("dsh.config").options
  local server = require("dsh.server")

  local function finish(ok, err)
    if ok then
      vim.notify("dsh: server ready at " .. tostring(server.describe().url), vim.log.levels.INFO, { title = "dsh.nvim" })
    else
      vim.notify("dsh: warmup failed: " .. tostring(err), vim.log.levels.ERROR, { title = "dsh.nvim" })
    end
    if cli then
      vim.cmd(ok and "cquit 0" or "cquit 1")
    end
    return ok, err
  end

  if not (config.shared or config.url) then
    return finish(false, "warmup needs shared = true or url = ...; a private server stops with this Neovim")
  end

  local done = false
  local started, start_err
  server.start(function(ok, err)
    done, started, start_err = true, ok, err
  end)
  if not done then
    vim.wait((config.startup_timeout or 120000) + 15000, function()
      return done
    end, 50)
  end
  if not done then
    return finish(false, "timed out waiting for the DSH server")
  end
  return finish(started == true, start_err)
end

--- Delete (archive) the current session.
--- @param skip_confirm boolean|nil skip the confirmation prompt
function M.delete(skip_confirm)
  require("dsh.ui.chat").delete(nil, { skip_confirm = skip_confirm })
end

--- Stop the DSH server this plugin started (a shared one included).
function M.stop()
  require("dsh.ui.chat").shutdown()
  server.stop({ force = true })
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
