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
    model = function()
      M.model()
    end,
    mode = function()
      M.mode()
    end,
    workspace = function()
      M.workspace()
    end,
    search = function()
      M.search()
    end,
    new_session = function()
      M.new_session()
    end,
    quick_chat = function()
      M.quick_chat()
    end,
    next_chat = function()
      M.next_chat()
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
    interrupt = function()
      M.interrupt()
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

--- Create a session in the selected workspace (or this directory's) and open it.
--- @param opts {prompt: boolean|table|nil, mode: string|nil, layout: table|nil}|nil
function M.new_session(opts)
  require("dsh.ui.chat").new_session(opts)
end

--- Start a quick chat: new session, session view in one split, prompt in
--- another, prefilled with the Visual selection that was active.
---
--- The Agent mode comes from `quick_chat.mode` (or `opts.mode`), the view from
--- `quick_chat.chat` and the prompt from `quick_chat.prompt`. `:DshQuickChat`
--- is the command; this is the Lua entry point for mappings.
--- @param opts {mode: string|nil}|nil Agent preset id for this call
function M.quick_chat(opts)
  require("dsh.ui.quick_chat").open(opts)
end

--- Switch to the next open session view, or start a new chat.
--- Views are ordered by buffer number (the order they were opened) and the
--- next one is focused, wrapping around. From a buffer that is not a session
--- view this starts a new session in the selected workspace (or this
--- directory's), opens it where `chat.open_in` says and opens its prompt.
function M.next_chat()
  require("dsh.ui.chat").next_chat()
end

--- Pick a session rooted at the current directory and open it.
function M.pick()
  require("dsh.ui.chat").pick()
end

--- Open the nested DSH menu: new session, open session, skills and commands.
function M.menu()
  require("dsh.ui.menu").open()
end

--- Pick the model of the current (or chosen) session.
---
--- Reads `session/modelCatalog` and applies the choice with
--- `session/selectModel`, so the switch is session-local and the server also
--- saves it as the default for later sessions.
function M.model()
  require("dsh.ui.agent").model()
end

--- Pick an Agent mode (preset) with `vim.ui.select`.
---
--- On a blank session the choice applies to that session
--- (`agentPresets/select`). On a session that has already started, or when no
--- session view is open, the choice changes the preset new sessions compose
--- (`settings/update` on the `agent-preset-registry` namespace).
function M.mode()
  require("dsh.ui.agent").mode()
end

--- Pick the Workspace that scopes session pickers and `:DshNew`.
---
--- The selection is client-side: Neovim's own working directory never
--- changes. Session pickers then list the chosen Workspace's Sessions, and
--- `:DshNew` creates its Session there.
function M.workspace()
  require("dsh.ui.workspace").pick()
end

--- Return the plugin's session scope to Neovim's current directory.
function M.clear_workspace()
  require("dsh.ui.workspace").reset()
end

--- Search the session transcript: prompts, replies, tool calls and notices.
---
--- Rows come from the rendered buffer, so the picker matches the text you see
--- and a selection moves the cursor to that message. Telescope renders it when
--- installed, `vim.ui.select` otherwise. `scope` narrows the rows to "prompts",
--- "replies", "tools" or "notes"; the default comes from `search.scope`.
--- @param opts {scope: string|nil}|string|nil scope name, or options
function M.search(opts)
  if type(opts) == "string" then
    opts = { scope = opts }
  end
  require("dsh.ui.search").open(opts)
end

--- Send a prompt to the session of the current buffer.
function M.prompt()
  require("dsh.ui.chat").prompt()
end

--- Re-read the current session's history.
function M.refresh()
  require("dsh.ui.chat").refresh()
end

--- Cancel the running turn in the current (or most recently used) session.
function M.cancel()
  require("dsh.ui.chat").cancel()
end

--- Interrupt the running turn of the session in view.
---
--- Same target resolution as `cancel` — the view under the cursor, then the
--- most recently used open view — and the accepted request is reported, so
--- `:DshInterrupt` from a prompt window or another tab names what it stopped.
function M.interrupt()
  require("dsh.ui.chat").interrupt()
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

--- Connection facts for statuslines, status plugins and health checks.
---
--- Safe to call on every redraw: it reads cached connection state and probes
--- the recorded process id, but never starts a server, sends a request or
--- opens a socket.
---
--- Fields:
---   running       boolean        the plugin holds server credentials
---   connected     boolean        credentials are usable: running, and the
---                                server is not known to be dead
---   server_live   boolean|nil    recorded server process is alive; nil when
---                                it cannot be checked (attached mode)
---   starting      boolean        a server boot/attach is in progress
---   mode          string|nil     "own", "shared" or "attached"
---   url           string|nil     server base URL
---   pid           integer|nil    server process, when known
---   websocket     boolean        multiplexed live-update socket is open
---   stream        boolean        alias of `websocket` (compatibility)
---   interactions  boolean        question/approval stream announced itself
---   views         integer        open session views
---   error         string|nil     last connection error
--- @return table
function M.status()
  local status = server.describe()
  local alive = server.is_alive()
  status.server_live = alive
  status.websocket = require("dsh.mux").is_connected()
  status.stream = status.websocket
  status.interactions = require("dsh.interactions").is_ready()
  status.views = require("dsh.ui.chat").view_count()
  status.connected = status.running and alive ~= false
  return status
end

--- Whether the plugin currently has a usable connection to a DSH server.
---
--- Shorthand for `require("dsh").status().connected`.
--- @return boolean
function M.connected()
  return M.status().connected
end

render.define_highlights()

return M
