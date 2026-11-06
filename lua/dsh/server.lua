--- Lifecycle manager for the DSH server.
---
--- Three modes:
---
---  * attached — `url` names a running `dsh web` (including its launch-token
---    query). The plugin only connects; it never starts or stops that server.
---  * shared — `shared = true` makes every Neovim instance use one server: the
---    first instance boots a detached `dsh web` and records its URL and launch
---    token in a private runtime file, later instances attach to it, and the
---    server outlives the Neovim that started it. `:DshStop` stops it.
---  * private (default) — every instance boots and owns its own `dsh web`.
---
--- DSH accepts the launch token repeatedly at `GET /connect`, minting one
--- independent peer per call, so a shared server can serve the Web UI and any
--- number of Neovim instances at once. Each instance still mints its own peer
--- cookies (`cookie` for HTTP, `mint()` per WebSocket).
local M = {}

local config = require("dsh.config")
local http = require("dsh.http")

--- Liveness probe timeout: a shared registry entry should answer quickly.
local PROBE_TIMEOUT = 5000
--- How often discovery/startup polls the registry and the server log.
local POLL_INTERVAL = 100

local state = {
  proc = nil,
  url = nil,
  token = nil,
  cookie = nil,
  pid = nil,
  mode = nil, -- "own" | "shared" | "attached"
  starting = false,
  handshaking = false,
  waiters = {},
  stdout = {},
  stderr = {},
  last_error = nil,
}

--- Forward declaration: the registry lives with the shared-server helpers
--- further down, while `describe` needs its path.
local registry_path

--- @return boolean
function M.is_running()
  return state.url ~= nil and state.cookie ~= nil
end

--- Current connection facts, for `:checkhealth` and status messages.
function M.describe()
  return {
    running = M.is_running(),
    url = state.url,
    pid = state.pid or (state.proc and state.proc.pid) or nil,
    mode = state.mode,
    shared = state.mode == "shared",
    attached = state.mode == "attached",
    registry = state.mode == "shared" and registry_path() or nil,
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
  -- Pin the `latest` dist-tag explicitly. A bare package name makes npm resolve
  -- the range `*`, which excludes prereleases -- and while DSH is published only
  -- as alpha/rc builds that fails with `No matching version found for
  -- @deepseek-ai/dsh@*` (ETARGET).
  return { "npx", "--yes", "@deepseek-ai/dsh@latest" }
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

--- Split a `dsh web` announcement into the base URL and launch token.
--- @param printed string
--- @return string|nil base
--- @return string|nil token
local function parse_url(printed)
  printed = vim.trim(printed or "")
  local token = printed:match("[?&]token=([%w%-_]+)")
  if not token then
    return nil, nil
  end
  local base = printed:gsub("/?%?token=.*$", ""):gsub("/+$", "")
  return base, token
end

--- Exchange a launch token for a fresh HTTP peer cookie.
--- @param base string
--- @param token string
--- @param timeout number|nil
--- @return string|nil cookie
--- @return string|nil error
local function connect_with_token(base, token, timeout)
  if type(base) ~= "string" or base == "" or type(token) ~= "string" or token == "" then
    return nil, "missing server URL or launch token"
  end
  return http.connect(base, token, timeout or config.options.request_timeout)
end

--- Exchange the scraped launch token for a cookie (private mode).
local function handshake()
  local text = table.concat(state.stdout, "")
  local printed = text:match("dsh web:%s*(http[^\r\n]+)")
  if not printed then
    return
  end

  local base, token = parse_url(printed)
  if not base then
    return
  end

  local cookie, err = connect_with_token(base, token, config.options.request_timeout)
  if not cookie then
    finish_start(false, "authentication failed: " .. tostring(err))
    M.stop({ force = true })
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

--- Boot a private `dsh web` and wait until its API answers.
local function start_own()
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
      state.token = nil
      state.cookie = nil
      state.pid = nil
      notify("dsh server exited", vim.log.levels.WARN)
    end
  end)

  if not ok then
    finish_start(false, "cannot start dsh: " .. tostring(proc))
    return
  end

  state.proc = proc
  state.pid = proc.pid
  state.mode = "own"

  vim.defer_fn(function()
    if not state.starting then
      return
    end
    local tail = table.concat(state.stderr, "")
    finish_start(false, "timed out waiting for dsh web to start" .. (tail ~= "" and (": " .. vim.trim(tail)) or ""))
    M.stop({ force = true })
  end, config.options.startup_timeout)
end

--------------------------------------------------------------------------------
-- Shared-server registry
--
-- The first instance publishes `{url, token, pid}` to a private runtime file;
-- other instances read it and mint their own peers. Creation is serialized
-- with a lock directory so two instances cannot boot two servers.
--------------------------------------------------------------------------------

--- Directory holding the shared registry, lock and log (mode 0700).
--- @return string
local function shared_dir()
  if type(config.options.shared_dir) == "string" and config.options.shared_dir ~= "" then
    return config.options.shared_dir
  end
  local base = vim.fn.stdpath("run")
  if type(base) ~= "string" or base == "" then
    base = vim.fn.stdpath("cache") or vim.fn.stdpath("data")
  end
  return base .. "/dsh-nvim"
end

--- @return string
function registry_path()
  return shared_dir() .. "/server.json"
end
local function lock_path()
  return shared_dir() .. "/server.lock"
end

local function log_path()
  return shared_dir() .. "/server.log"
end

--- @param path string
--- @return string|nil
local function read_text(path)
  local handle = io.open(path, "r")
  if not handle then
    return nil
  end
  local text = handle:read("*a")
  handle:close()
  return text
end

--- @param path string
--- @param text string
--- @return boolean|nil ok
--- @return string|nil error
local function write_private(path, text)
  local fd, open_err = vim.uv.fs_open(path, "w", 384) -- 0600
  if not fd then
    return nil, open_err
  end
  local ok, write_err = pcall(vim.uv.fs_write, fd, text, 0)
  vim.uv.fs_close(fd)
  if not ok then
    return nil, write_err
  end
  pcall(vim.uv.fs_chmod, path, 384)
  return true
end

--- Ensure the shared directory exists with private permissions.
local function ensure_shared_dir()
  local dir = shared_dir()
  vim.fn.mkdir(dir, "p", 448) -- 0700
  pcall(vim.uv.fs_chmod, dir, 448)
end

--- @return table|nil registry entries
local function read_registry()
  local text = read_text(registry_path())
  if not text or text == "" then
    return nil
  end
  local ok, value = pcall(vim.json.decode, text)
  if not ok or type(value) ~= "table" then
    return nil
  end
  if type(value.url) ~= "string" or type(value.token) ~= "string" then
    return nil
  end
  return value
end

--- Write the registry atomically, so readers never see a torn entry.
--- @param value table
--- @return boolean|nil ok
--- @return string|nil error
local function write_registry(value)
  ensure_shared_dir()
  value.version = value.version or 1
  local temporary = registry_path() .. ".tmp"
  local ok, err = write_private(temporary, vim.json.encode(value) .. "\n")
  if not ok then
    return nil, err
  end
  local renamed, rename_err = vim.uv.fs_rename(temporary, registry_path())
  if not renamed then
    return nil, rename_err
  end
  return true
end

local function remove_registry()
  pcall(vim.uv.fs_unlink, registry_path())
end

--- Whether a process id is alive (signal 0 probes without delivering).
--- @param pid any
--- @return boolean
local function process_alive(pid)
  if type(pid) ~= "number" or pid <= 0 then
    return false
  end
  local ok, result = pcall(vim.uv.kill, pid, 0)
  return ok and result == 0
end

--- Whether the shared server this instance adopted is still the live registry
--- entry. A starter observes its own child via `state.proc`; an adopter only
--- has the recorded pid, so it uses that cheap check before trusting its
--- cached credentials. A dead shared server is rediscovered on the next call.
--- @return boolean
local function shared_entry_alive()
  if state.mode ~= "shared" then
    return true
  end
  local entry = read_registry()
  if not entry or entry.url ~= state.url then
    return false
  end
  if type(entry.pid) == "number" and not process_alive(entry.pid) then
    return false
  end
  return true
end

--- @return number|nil pid
local function lock_owner()
  return tonumber(read_text(lock_path() .. "/owner") or "")
end

--- Try to become the instance that boots the shared server.
--- @return boolean|nil acquired true, false when another instance holds it
--- @return string|nil error
local function acquire_lock()
  ensure_shared_dir()
  local ok, err = vim.uv.fs_mkdir(lock_path(), 448)
  if ok then
    write_private(lock_path() .. "/owner", tostring(vim.uv.os_getpid()))
    return true
  end
  if err and not tostring(err):find("EEXIST", 1, true) then
    return nil, err
  end
  return false
end

local function release_lock()
  pcall(vim.uv.fs_unlink, lock_path() .. "/owner")
  pcall(vim.uv.fs_rmdir, lock_path())
end

--- Remove a lock left by a dead starter.
--- @return boolean removed
local function clear_stale_lock()
  local stat = vim.uv.fs_stat(lock_path())
  if not stat then
    return false
  end
  local owner = lock_owner()
  if owner then
    if process_alive(owner) then
      return false
    end
  elseif (os.time() - (stat.mtime and stat.mtime.sec or 0)) < 5 then
    -- The owner file is written right after mkdir; do not race that window.
    return false
  end
  release_lock()
  return true
end

--- Adopt a registry entry, minting this instance's own peer cookie.
--- @param entry table
--- @param timeout number|nil
--- @return string|nil cookie
--- @return string|nil error
local function adopt(entry, timeout)
  local cookie, err = connect_with_token(entry.url, entry.token, timeout)
  if not cookie then
    return nil, err
  end
  state.mode = "shared"
  state.url = entry.url
  state.token = entry.token
  state.cookie = cookie
  state.pid = entry.pid
  state.last_error = nil
  notify("attached to shared DSH at " .. entry.url)
  return cookie
end

--- Report a registry entry that is alive but refuses authentication rather than
--- booting a duplicate server.
--- @param entry table
--- @param err string|nil
local function fail_live_entry(entry, err)
  finish_start(
    false,
    ("shared DSH server at %s is running but refused authentication: %s"):format(entry.url, tostring(err))
  )
end

--- Boot the shared server detached, redirecting its output to the log file.
local function spawn_shared()
  if vim.fn.has("win32") == 1 then
    release_lock()
    finish_start(false, "shared mode needs a POSIX shell; configure `url` instead")
    return
  end

  ensure_shared_dir()
  local log = log_path()
  pcall(vim.uv.fs_unlink, log)
  write_private(log, "")

  local cmd = resolve_cmd()
  vim.list_extend(cmd, { "web", "--port", tostring(config.options.port or 0), "--no-open" })
  local quoted = {}
  for _, arg in ipairs(cmd) do
    quoted[#quoted + 1] = vim.fn.shellescape(arg)
  end
  -- `detach` lets the server outlive this Neovim; the redirection keeps the
  -- child from writing into a pipe that disappears when Neovim exits.
  local line = "exec " .. table.concat(quoted, " ") .. " >> " .. vim.fn.shellescape(log) .. " 2>&1"

  local ok, proc = pcall(vim.system, { "sh", "-c", line }, {
    cwd = config.options.cwd or vim.fn.getcwd(),
    detach = true,
    stdout = false,
    stderr = false,
  }, function()
    local was_starting = state.starting
    local was_connected = state.cookie ~= nil
    state.proc = nil
    if was_starting then
      state.pid = nil
      release_lock()
      finish_start(false, "dsh exited before it was ready: " .. vim.trim(read_text(log) or ""))
      return
    end
    if was_connected and state.mode == "shared" then
      local entry = read_registry()
      if entry and entry.url == state.url then
        remove_registry()
      end
      state.url = nil
      state.token = nil
      state.cookie = nil
      state.pid = nil
      notify("shared dsh server exited", vim.log.levels.WARN)
    end
  end)

  if not ok then
    release_lock()
    finish_start(false, "cannot start dsh: " .. tostring(proc))
    return
  end

  state.proc = proc
  state.pid = proc.pid
  state.mode = "shared"

  local deadline = vim.uv.now() + (config.options.startup_timeout or 120000)
  local function poll()
    if not state.starting then
      return
    end

    local text = read_text(log) or ""
    local printed = text:match("dsh web:%s*(http[^\r\n]+)")
    if printed then
      local base, token = parse_url(printed)
      if base then
        local cookie, err = connect_with_token(base, token, config.options.request_timeout)
        if cookie then
          state.url = base
          state.token = token
          state.cookie = cookie
          local recorded, write_err = write_registry({
            url = base,
            token = token,
            pid = proc.pid,
            started_at = os.time(),
            cwd = config.options.cwd or vim.fn.getcwd(),
          })
          release_lock()
          if not recorded then
            finish_start(false, "cannot record the shared DSH server: " .. tostring(write_err))
            M.stop({ force = true })
            return
          end
          notify("started shared DSH at " .. base)
          finish_start(true)
          return
        end
        release_lock()
        finish_start(false, "authentication failed: " .. tostring(err))
        M.stop({ force = true })
        return
      end
    end

    if vim.uv.now() >= deadline then
      local tail = vim.trim((read_text(log) or ""):sub(-2000))
      release_lock()
      finish_start(false, "timed out waiting for dsh web to start" .. (tail ~= "" and (": " .. tail) or ""))
      M.stop({ force = true })
      return
    end
    vim.defer_fn(poll, POLL_INTERVAL)
  end
  poll()
end

--- Shared mode: adopt a healthy server, wait for another instance that is
--- starting one, or become the starter.
local function start_shared()
  local function attempt()
    if not state.starting then
      return
    end

    local entry = read_registry()
    if entry then
      local cookie, err = adopt(entry, PROBE_TIMEOUT)
      if cookie then
        finish_start(true)
        return
      end
      if process_alive(entry.pid) then
        fail_live_entry(entry, err)
        return
      end
      remove_registry()
    end

    local acquired, lock_err = acquire_lock()
    if acquired == nil then
      finish_start(false, "cannot create the shared DSH lock: " .. tostring(lock_err))
      return
    end
    if acquired then
      spawn_shared()
      return
    end

    -- Another instance holds the lock: wait for the registry it publishes.
    local deadline = vim.uv.now() + (config.options.startup_timeout or 120000)
    local function poll()
      if not state.starting then
        return
      end

      local waiting = read_registry()
      if waiting then
        local cookie, err = adopt(waiting, PROBE_TIMEOUT)
        if cookie then
          finish_start(true)
          return
        end
        if process_alive(waiting.pid) then
          fail_live_entry(waiting, err)
          return
        end
        remove_registry()
      end

      if clear_stale_lock() or vim.uv.fs_stat(lock_path()) == nil then
        -- The starter failed or finished without publishing; try to take over
        -- instead of waiting out the whole startup timeout.
        attempt()
        return
      end

      if vim.uv.now() >= deadline then
        finish_start(false, "timed out waiting for the shared DSH server")
        return
      end
      vim.defer_fn(poll, POLL_INTERVAL)
    end
    poll()
  end

  attempt()
end

--- Attached mode: use the server named by `url`, which includes its token.
local function start_attached()
  local base, token = parse_url(config.options.url)
  if not base then
    finish_start(false, "url must be the `dsh web` URL including its ?token=... query")
    return
  end

  local cookie, err = connect_with_token(base, token, config.options.request_timeout)
  if not cookie then
    finish_start(false, ("cannot connect to %s: %s"):format(base, tostring(err)))
    return
  end

  state.mode = "attached"
  state.url = base
  state.token = token
  state.cookie = cookie
  state.pid = nil
  state.last_error = nil
  notify("connected to DSH at " .. base)
  finish_start(true)
end

--- Boot `dsh web` (or attach to the shared/configured one) and wait until its
--- API answers.
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

  if config.options.url then
    start_attached()
  elseif config.options.shared then
    start_shared()
  else
    start_own()
  end
end

--- Terminate the server this plugin started, or detach from it.
---
--- `force` (from `:DshStop`) stops a shared server even when it outlived its
--- starter. Without it — notably from `VimLeavePre` — a shared or attached
--- server is left running for the other Neovim instances.
--- @param opts {force: boolean|nil}|nil
function M.stop(opts)
  local force = type(opts) == "table" and opts.force == true
  local proc = state.proc
  local mode = state.mode
  local pid = state.pid
  local url = state.url
  local starting = state.starting

  if mode == "attached" then
    -- Never stop a server the plugin did not start.
  elseif mode == "shared" then
    if force or starting then
      if proc then
        pcall(function()
          proc:kill(15)
        end)
      elseif force and pid then
        pcall(vim.uv.kill, pid, 15)
      end
      release_lock()
      if force then
        local entry = read_registry()
        if entry and (not url or entry.url == url) then
          remove_registry()
        end
      end
    end
  elseif proc then
    pcall(function()
      proc:kill(15)
    end)
  end

  state.proc = nil
  state.url = nil
  state.token = nil
  state.cookie = nil
  state.pid = nil
  state.mode = nil
  state.starting = false
  state.handshaking = false
  state.waiters = {}
end

--- Mint a fresh peer cookie from the stored launch token.
---
--- Each `/connect` creates a new peer, and DSH disposes a peer when the socket
--- that claimed it closes. WebSocket connections therefore mint their own cookie
--- instead of consuming the long-lived HTTP one.
---
--- Socket peers are minted with `interactions=answer`: forwarded human
--- interactions (questions and approvals) ride the socket that owns them, and
--- only an answer-capable peer may open that stream or send its answers. The
--- long-lived HTTP peer keeps `interactions=none`, because answering through a
--- different peer is rejected by DSH.
--- @param timeout number|nil
--- @return string|nil cookie
--- @return string|nil error
function M.mint_cookie(timeout)
  if not state.url or not state.token then
    return nil, "dsh is not connected"
  end
  return http.connect(state.url, state.token, timeout or config.options.request_timeout, "answer")
end

--- Ensure a connection, then hand its context to `callback`.
---
--- The context carries two credentials: `cookie` is a long-lived peer used for
--- HTTP calls, and `mint` produces a disposable peer for a WebSocket. DSH disposes
--- a peer when its socket closes, so a socket cookie must never be reused.
--- @param callback fun(err: string|nil, ctx: {url: string, cookie: string, mint: fun(): string|nil}|nil)
function M.context(callback)
  if M.is_running() then
    if shared_entry_alive() then
      callback(nil, { url = state.url, cookie = state.cookie, mint = M.mint_cookie })
      return
    end
    -- The shared server behind our cached credentials is gone (or replaced);
    -- forget them and rediscover. A live server we merely lost track of is
    -- left alone by the non-force stop.
    M.stop()
  end
  if not config.options.auto_start then
    -- Discovery is still allowed: attaching to an existing server starts
    -- nothing. Only booting one is disabled.
    if config.options.url then
      M.start(function(ok, err)
        if not ok then
          callback(err or "failed to attach to dsh")
          return
        end
        callback(nil, { url = state.url, cookie = state.cookie, mint = M.mint_cookie })
      end)
      return
    end
    if config.options.shared then
      local entry = read_registry()
      local cookie, err = entry and adopt(entry, PROBE_TIMEOUT)
      if not cookie then
        callback(("dsh server is not running (auto_start is disabled): %s"):format(tostring(err or "no shared server")))
        return
      end
      callback(nil, { url = state.url, cookie = state.cookie, mint = M.mint_cookie })
      return
    end
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
