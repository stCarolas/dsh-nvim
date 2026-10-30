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

  notifications = true,
}

M.options = vim.deepcopy(M.defaults)

--- Merge user options over the defaults.
--- @param opts table|nil
function M.setup(opts)
  M.options = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts or {})
  return M.options
end

return M
