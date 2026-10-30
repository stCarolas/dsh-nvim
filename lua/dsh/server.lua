--- Lifecycle manager for the plugin's own `dsh web` process.
---
--- The launch token that authenticates the HTTP API is generated per process and
--- only ever printed in the URL `dsh web` announces, so the plugin boots its own
--- server, scrapes that URL, and exchanges the token for a cookie.
local M = {}

local config = require("dsh.config")
local http = require("dsh.http")

local state = {
  proc = nil,
  url = nil,
  token = nil,
  cookie = nil,
  starting = false,
  handshaking = false,
  waiters = {},
  stdout = {},
  stderr = {},
  last_error = nil,
}

--- @return boolean
function M.is_running()
  return state.url ~= nil and state.cookie ~= nil
end

--- Current connection facts, for `:checkhealth` and status messages.
function M.describe()
  return {
    running = M.is_running(),
    url = state.url,
    pid = state.proc and state.proc.pid or nil,
    error = state.last_error,
  }
end

local function notify(message, level)
  if config.options.notifications then
    vim.notify(message, level or vim.log.levels.INFO, { title = "dsh.nvim" })
  end
end

--- Resolve the launch command: explicit config wins, then `dsh`, then npx.
--- @return string[]
local function resolve_cmd()
  if config.options.cmd then
    return vim.deepcopy(config.options.cmd)
  end
  if vim.fn.executable("dsh") == 1 then
    return { "dsh" }
  end
  return { "npx", "--yes", "@deepseek-ai/dsh" }
end

--- Resolve every pending start callback with the same outcome.
local function finish_start(ok, err)
  local waiters = state.waiters
  state.waiters = {}
  state.starting = false
  if not ok then
    state.last_error = err
  end
  for _, callback in ipairs(waiters) do
    vim.schedule(function()
      callback(ok, err)
    end)
  end
end

--- Exchange the scraped launch token for a cookie.
local function handshake()
  local text = table.concat(state.stdout, "")
  local printed = text:match("dsh web:%s*(http[^\r\n]+)")
  if not printed then
    return
  end
  printed = vim.trim(printed)

  local token = printed:match("[?&]token=([%w%-_]+)")
  if not token then
    return
  end

  local base = printed:gsub("/?%?token=.*$", "")
  base = base:gsub("/+$", "")

  local cookie, err = http.connect(base, token, config.options.request_timeout)
  if not cookie then
    finish_start(false, "authentication failed: " .. tostring(err))
    M.stop()
    return
  end

  state.url = base
  state.token = token
  state.cookie = cookie
  state.last_error = nil
  notify("connected to DSH at " .. base)
  finish_start(true)
end

local function on_stdout(_, data)
  if not data or data == "" then
    return
  end
  state.stdout[#state.stdout + 1] = data
  if #state.stdout > 80 then
    table.remove(state.stdout, 1)
  end
  if state.cookie or state.handshaking then
    return
  end
  -- The announced URL can straddle two chunks, so match the accumulated text.
  if table.concat(state.stdout, ""):find("dsh web:", 1, true) then
    state.handshaking = true
    vim.schedule(function()
      state.handshaking = false
      if not state.cookie then
        handshake()
      end
    end)
  end
end

local function on_stderr(_, data)
  if not data or data == "" then
    return
  end
  state.stderr[#state.stderr + 1] = data
  if #state.stderr > 60 then
    table.remove(state.stderr, 1)
  end
end

--- Boot `dsh web` and wait until its API answers.
--- @param callback fun(ok: boolean, err: string|nil)|nil
function M.start(callback)
  if M.is_running() then
    if callback then
      vim.schedule(function()
        callback(true)
      end)
    end
    return
  end

  if state.starting then
    if callback then
      table.insert(state.waiters, callback)
    end
    return
  end

  state.starting = true
  state.stdout = {}
  state.stderr = {}
  if callback then
    table.insert(state.waiters, callback)
  end

  local cmd = resolve_cmd()
  vim.list_extend(cmd, { "web", "--port", tostring(config.options.port or 0), "--no-open" })

  local ok, proc = pcall(vim.system, cmd, {
    cwd = config.options.cwd or vim.fn.getcwd(),
    stdout = on_stdout,
    stderr = on_stderr,
  }, function()
    local was_connected = state.cookie ~= nil
    state.proc = nil
    if not was_connected then
      local tail = table.concat(state.stderr, "")
      if tail == "" then
        tail = table.concat(state.stdout, "")
      end
      finish_start(false, "dsh exited before it was ready: " .. vim.trim(tail))
    else
      state.url = nil
      state.cookie = nil
      notify("dsh server exited", vim.log.levels.WARN)
    end
  end)

  if not ok then
    state.starting = false
    finish_start(false, "cannot start dsh: " .. tostring(proc))
    return
  end

  state.proc = proc

  vim.defer_fn(function()
    if not state.starting then
      return
    end
    local tail = table.concat(state.stderr, "")
    finish_start(false, "timed out waiting for dsh web to start" .. (tail ~= "" and (": " .. vim.trim(tail)) or ""))
    M.stop()
  end, config.options.startup_timeout)
end

--- Terminate the server this plugin started.
function M.stop()
  if state.proc then
    pcall(function()
      state.proc:kill(15)
    end)
  end
  state.proc = nil
  state.url = nil
  state.token = nil
  state.cookie = nil
  state.starting = false
  state.handshaking = false
  state.waiters = {}
end

--- Mint a fresh peer cookie from the stored launch token.
---
--- Each `/connect` creates a new peer, and DSH disposes a peer when the socket
--- that claimed it closes. WebSocket connections therefore mint their own cookie
--- instead of consuming the long-lived HTTP one.
--- @param timeout number|nil
--- @return string|nil cookie
--- @return string|nil error
function M.mint_cookie(timeout)
  if not state.url or not state.token then
    return nil, "dsh is not connected"
  end
  return http.connect(state.url, state.token, timeout or config.options.request_timeout)
end

--- Ensure a connection, then hand its context to `callback`.
---
--- The context carries two credentials: `cookie` is a long-lived peer used for
--- HTTP calls, and `mint` produces a disposable peer for a WebSocket. DSH disposes
--- a peer when its socket closes, so a socket cookie must never be reused.
--- @param callback fun(err: string|nil, ctx: {url: string, cookie: string, mint: fun(): string|nil}|nil)
function M.context(callback)
  if M.is_running() then
    callback(nil, { url = state.url, cookie = state.cookie, mint = M.mint_cookie })
    return
  end
  if not config.options.auto_start then
    callback("dsh server is not running (auto_start is disabled)")
    return
  end
  M.start(function(ok, err)
    if not ok then
      callback(err or "failed to start dsh")
      return
    end
    callback(nil, { url = state.url, cookie = state.cookie, mint = M.mint_cookie })
  end)
end

return M
