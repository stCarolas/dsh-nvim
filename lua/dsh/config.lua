--- Configuration for dsh.nvim.
local M = {}

M.defaults = {
  --- Command used to boot the DSH web profile.
  --- `nil` auto-detects: a `dsh` executable, otherwise `npx --yes @deepseek-ai/dsh`.
  cmd = nil,

  --- Port passed to `dsh web`. 0 lets the OS pick a free port.
  port = 0,

  --- Working directory for the spawned server. `nil` uses Neovim's cwd.
  cwd = nil,

  --- Boot `dsh web` on first use instead of requiring a pre-running server.
  auto_start = true,

  --- How long to wait for the server to print its token URL.
  startup_timeout = 120000,

  --- Timeout for a single HTTP request (session pages on big sessions are slow).
  request_timeout = 60000,

  --- Messages fetched per history page and per follow snapshot.
  max_messages = 200,

  --- Session listing behaviour.
  sessions = {
    --- Listing order: "oldest" (least recently used first), "newest", or "none".
    order = "oldest",
    --- Which sessions a picker offers: "cwd" lists only sessions rooted at
    --- Neovim's current directory (the workspace being worked in), "all"
    --- lists every session the server knows.
    scope = "cwd",
  },

  --- Longest tool output rendered, in lines.
  tool_output_lines = 8,

  --- Live updates over the DSH WebSocket stream.
  stream = {
    --- Use `session/follow` for live history and token streaming.
    --- When false, history is read once per open/refresh over HTTP.
    enabled = true,
    --- Coalesce stream chunks into at most one render per interval (ms).
    render_interval = 60,
    --- Reconnect attempts after the socket drops.
    reconnect_attempts = 5,
    reconnect_delay = 1500,
  },

  --- Render model reasoning blocks (dimmed). Usually noise.
  show_reasoning = false,

  --- Markdown rendering of agent output.
  markdown = {
    enabled = true,
    --- Highlight fenced code with treesitter when the language parser exists.
    code_highlight = true,
    --- Show the fence language as virtual text at the end of the first code line.
    show_language = true,
    --- Skip syntax highlighting above this many lines per block.
    max_highlight_lines = 300,
  },

  chat = {
    --- Where a session view opens: "split", "tab", or "current".
    open_in = "split",
    --- Orientation when `open_in = "split"`: "vertical" or "horizontal".
    --- The legacy values "tab" and "current" are still honoured here.
    split = "vertical",
    width = 100,
    height = 20,
  },

  keymaps = {
    --- Buffer-local mappings inside a DSH chat buffer.
    prompt = "<CR>",
    refresh = "R",
    cancel = "<C-c>",
    sessions = "<localleader>s",
    close = "q",

    --- Optional global mappings, e.g. { new_session = "<leader>dn", pick = "<leader>ds" }.
    global = {},
  },

  --- Human decisions DSH forwards while a session view is open. Both use
  --- `vim.ui.select` / `vim.ui.input`, so the user's picker plugin applies.
  interactions = {
    --- Answer forwarded interactions at all. Disabling this leaves
    --- `ask_user_question` calls waiting for another client.
    enabled = true,
    --- `ask_user_question` calls: options, multi-select and free-text answers.
    questions = true,
    --- Permission prompts for sensitive tool actions (allow once / reject).
    approvals = true,
  },

  notifications = true,
}

M.options = vim.deepcopy(M.defaults)

--- Normalize values that would otherwise change behavior silently.
---
--- A typo in `sessions.scope` used to hide every session from the picker with
--- no explanation; any value other than "cwd" or "all" now falls back to "cwd"
--- with a warning.
--- @return table options
function M.validate()
  local sessions = M.options.sessions
  if type(sessions) ~= "table" then
    M.options.sessions = vim.deepcopy(M.defaults.sessions)
    if M.options.notifications then
      vim.notify("dsh: sessions config must be a table; using the defaults", vim.log.levels.WARN, { title = "dsh.nvim" })
    end
    return M.options
  end

  if sessions.scope ~= "cwd" and sessions.scope ~= "all" then
    local invalid = sessions.scope
    sessions.scope = "cwd"
    if M.options.notifications then
      vim.notify(
        ("dsh: sessions.scope must be \"cwd\" or \"all\" (got %s); using \"cwd\""):format(vim.inspect(invalid)),
        vim.log.levels.WARN,
        { title = "dsh.nvim" }
      )
    end
  end
  return M.options
end

--- Merge user options over the defaults.
--- @param opts table|nil
function M.setup(opts)
  M.options = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), type(opts) == "table" and opts or {})
  return M.validate()
end

return M
