--- Configuration for dsh.nvim.
local M = {}

M.defaults = {
  --- Command used to boot the DSH web profile.
  --- `nil` auto-detects: a `dsh` executable, otherwise `npx --yes @deepseek-ai/dsh@latest`.
  cmd = nil,

  --- Port passed to `dsh web`. 0 lets the OS pick a free port.
  port = 0,

  --- Working directory for the spawned server. `nil` uses Neovim's cwd.
  cwd = nil,

  --- Boot `dsh web` on first use instead of requiring a pre-running server.
  auto_start = true,

  --- Attach to an already running `dsh web` instead of starting one. Pass the
  --- URL printed by `dsh web`, including its `?token=...` query. When set, the
  --- plugin never starts or stops a server.
  url = nil,

  --- Share one `dsh web` process across every Neovim instance. The first
  --- instance boots a detached server and records its URL and launch token in
  --- `shared_dir`; later instances attach to it. The shared server outlives
  --- Neovim, and `:DshStop` ends it. Ignored when `url` is set.
  shared = false,

  --- Directory for the shared-server registry and log file. `nil` uses
  --- `stdpath("run")/dsh-nvim`, falling back to `stdpath("cache")`.
  shared_dir = nil,

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
    --- Include sessions spawned by subagents. When false, pickers list only
    --- root sessions.
    include_subagents = true,
    --- Show archived sessions (the sessions `:DshDelete` removes) in pickers.
    --- DSH archives instead of erasing: the transcript stays on disk and the
    --- Web UI can restore it.
    include_archived = false,
  },

  --- Longest tool output shown as a code block, in rows.
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

  --- Wire the bundled Tree-sitter grammar for the `dshchat` filetype.
  --- Registers the parser with nvim-treesitter (when installed), so
  --- `:TSInstall dshchat` builds it from the plugin checkout, and starts
  --- Tree-sitter highlighting in session buffers when a parser is available.
  --- The renderer's extmarks keep doing the inline styling either way.
  treesitter = true,

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
    --- Write the DSH session title as the first line of the session buffer.
    --- The winbar shows the title either way.
    show_title = true,
  },

  --- Where a prompt is typed.
  prompt = {
    --- "float" opens the centered floating popup (default). "split" opens a
    --- scratch buffer in a separate window, which is easier to edit long,
    --- multi-line prompts in.
    open_in = "float",
    --- Orientation when `open_in = "split"`: "horizontal" (bottom) or
    --- "vertical" (right).
    split = "horizontal",
    --- Size of that window: rows for "horizontal", columns for "vertical".
    width = 80,
    height = 10,
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

--- Warn about a value that was normalized, when notifications are enabled.
--- @param message string
local function warn(message)
  if M.options.notifications then
    vim.notify("dsh: " .. message, vim.log.levels.WARN, { title = "dsh.nvim" })
  end
end

--- Keep a size a positive integer, or fall back to the default.
--- @param value any
--- @param fallback integer
--- @param minimum integer
--- @return integer
local function dimension(value, fallback, minimum)
  if type(value) ~= "number" or value ~= value or value < minimum then
    return fallback
  end
  return math.floor(value)
end

--- Normalize values that would otherwise change behavior silently.
---
--- A typo in `sessions.scope` used to hide every session from the picker with
--- no explanation; any value other than "cwd" or "all" now falls back to "cwd"
--- with a warning. `sessions.include_subagents`, `prompt.open_in` and
--- `prompt.split` are normalized the same way, so a typo cannot silently change
--- what the picker lists or where the prompt opens.
--- @return table options
function M.validate()
  if type(M.options.shared) ~= "boolean" then
    local invalid = M.options.shared
    M.options.shared = false
    warn(("shared must be a boolean (got %s); using false"):format(vim.inspect(invalid)))
  end
  if M.options.url ~= nil and (type(M.options.url) ~= "string" or vim.trim(M.options.url) == "") then
    local invalid = M.options.url
    M.options.url = nil
    warn(("url must be a non-empty string (got %s); using nil"):format(vim.inspect(invalid)))
  end
  if
    M.options.shared_dir ~= nil
    and (type(M.options.shared_dir) ~= "string" or vim.trim(M.options.shared_dir) == "")
  then
    local invalid = M.options.shared_dir
    M.options.shared_dir = nil
    warn(("shared_dir must be a non-empty string (got %s); using the default"):format(vim.inspect(invalid)))
  end

  local sessions = M.options.sessions
  if type(sessions) ~= "table" then
    M.options.sessions = vim.deepcopy(M.defaults.sessions)
    warn("sessions config must be a table; using the defaults")
  else
    if sessions.scope ~= "cwd" and sessions.scope ~= "all" then
      local invalid = sessions.scope
      sessions.scope = "cwd"
      warn(("sessions.scope must be \"cwd\" or \"all\" (got %s); using \"cwd\""):format(vim.inspect(invalid)))
    end
    if type(sessions.include_subagents) ~= "boolean" then
      local invalid = sessions.include_subagents
      sessions.include_subagents = true
      warn(("sessions.include_subagents must be a boolean (got %s); using true"):format(vim.inspect(invalid)))
    end
    if type(sessions.include_archived) ~= "boolean" then
      local invalid = sessions.include_archived
      sessions.include_archived = false
      warn(("sessions.include_archived must be a boolean (got %s); using false"):format(vim.inspect(invalid)))
    end
  end

  local prompt = M.options.prompt
  if type(prompt) ~= "table" then
    M.options.prompt = vim.deepcopy(M.defaults.prompt)
    warn("prompt config must be a table; using the defaults")
  else
    if prompt.open_in ~= "float" and prompt.open_in ~= "split" then
      local invalid = prompt.open_in
      prompt.open_in = "float"
      warn(("prompt.open_in must be \"float\" or \"split\" (got %s); using \"float\""):format(vim.inspect(invalid)))
    end
    if prompt.split ~= "horizontal" and prompt.split ~= "vertical" then
      local invalid = prompt.split
      prompt.split = "horizontal"
      warn(("prompt.split must be \"horizontal\" or \"vertical\" (got %s); using \"horizontal\""):format(vim.inspect(invalid)))
    end
    prompt.width = dimension(prompt.width, M.defaults.prompt.width, 10)
    prompt.height = dimension(prompt.height, M.defaults.prompt.height, 3)
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
