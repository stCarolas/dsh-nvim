-- Server discovery and lifecycle specs: attached URL, shared registry, and
-- the detached starter. A stub HTTP transport replaces /connect, and a fake
-- `dsh` script stands in for the spawned process.
-- Run with: nvim --headless -l scripts/server_spec.lua
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h:h")
vim.opt.rtp:append(root)

local config = require("dsh.config")

local failures = 0
local checks = 0

local function check(name, condition, detail)
  checks = checks + 1
  if not condition then
    failures = failures + 1
    print(("FAIL %s%s"):format(name, detail and (" — " .. detail) or ""))
  else
    print("PASS " .. name)
  end
end

--------------------------------------------------------------------------------
-- Stub the HTTP transport: server.lua only uses http.connect.
--------------------------------------------------------------------------------
local connect_calls = {}
local connect_handler = function()
  return "cookie"
end

package.loaded["dsh.http"] = {
  connect = function(url, token, timeout, interactions)
    connect_calls[#connect_calls + 1] = {
      url = url,
      token = token,
      timeout = timeout,
      interactions = interactions,
    }
    return connect_handler(url, token, timeout, interactions)
  end,
}

--- Fresh module state for each scenario, as if another Neovim started.
local function fresh_server()
  package.loaded["dsh.server"] = nil
  return require("dsh.server")
end

--- Run server.start and wait for its callback.
local function start(server)
  local result = {}
  server.start(function(ok, err)
    result.ok = ok
    result.err = err
  end)
  vim.wait(15000, function()
    return result.ok ~= nil
  end, 10)
  return result
end

local function write_registry(dir, value)
  vim.fn.mkdir(dir, "p")
  local handle = assert(io.open(dir .. "/server.json", "w"))
  handle:write(vim.json.encode(value) .. "\n")
  handle:close()
end

local function read_registry(dir)
  local handle = io.open(dir .. "/server.json", "r")
  if not handle then
    return nil
  end
  local text = handle:read("*a")
  handle:close()
  local ok, value = pcall(vim.json.decode, text)
  return ok and value or nil
end

local function process_alive(pid)
  if type(pid) ~= "number" then
    return false
  end
  local ok, result = pcall(vim.uv.kill, pid, 0)
  return ok and result == 0
end

local cleanup = {}

local function cleanup_dirs()
  for _, dir in ipairs(cleanup) do
    local entry = read_registry(dir)
    if entry and entry.pid ~= vim.uv.os_getpid() and process_alive(entry.pid) then
      pcall(vim.uv.kill, entry.pid, 15)
    end
    vim.fn.delete(dir, "rf")
  end
  cleanup = {}
end

--------------------------------------------------------------------------------
-- 0. New options normalize instead of silently changing behavior.
--------------------------------------------------------------------------------
config.setup({ notifications = false, shared = "yes", url = "", shared_dir = 42 })
check("shared normalizes to false", config.options.shared == false, tostring(config.options.shared))
check("empty url normalizes to nil", config.options.url == nil, tostring(config.options.url))
check("bad shared_dir normalizes to the default", config.options.shared_dir == nil, tostring(config.options.shared_dir))

--------------------------------------------------------------------------------
-- 1. `url` attaches to an external server and never starts one.
--------------------------------------------------------------------------------
config.setup({
  notifications = false,
  url = "http://127.0.0.1:4321/base/?token=tok_ABC-123",
})
connect_calls = {}
connect_handler = function()
  return "cookie-url"
end
local server = fresh_server()
local result = start(server)
check("attached start succeeds", result.ok == true, tostring(result.err))
check(
  "launch token parsed from url",
  #connect_calls == 1 and connect_calls[1].url == "http://127.0.0.1:4321/base" and connect_calls[1].token == "tok_ABC-123",
  vim.inspect(connect_calls[1])
)
check("attached mode reported", server.describe().attached == true and server.describe().running == true)
server.stop()
check("stopping an attached server only disconnects", server.is_running() == false)

-- 2. A url without its token is rejected before any request.
config.setup({ notifications = false, url = "http://127.0.0.1:1" })
connect_calls = {}
server = fresh_server()
result = start(server)
check(
  "url without a token fails",
  result.ok == false and tostring(result.err):find("token", 1, true) ~= nil,
  tostring(result.err)
)
check("url without a token sends no request", #connect_calls == 0)

--------------------------------------------------------------------------------
-- 3. Shared mode adopts a healthy registry entry and leaves it on exit.
--------------------------------------------------------------------------------
local adopt_dir = vim.fn.tempname()
cleanup[#cleanup + 1] = adopt_dir
write_registry(adopt_dir, {
  url = "http://127.0.0.1:5001",
  token = "sharedtok",
  pid = vim.uv.os_getpid(),
  version = 1,
})
config.setup({ notifications = false, shared = true, shared_dir = adopt_dir, startup_timeout = 2000 })
connect_calls = {}
connect_handler = function()
  return "cookie-shared"
end
server = fresh_server()
result = start(server)
local described = server.describe()
check("shared start adopts the registry", result.ok == true, tostring(result.err))
check(
  "shared registry values used",
  #connect_calls == 1 and connect_calls[1].url == "http://127.0.0.1:5001" and connect_calls[1].token == "sharedtok",
  vim.inspect(connect_calls[1])
)
check(
  "shared mode reported",
  described.shared == true and described.mode == "shared" and described.registry == adopt_dir .. "/server.json",
  vim.inspect(described)
)

-- 3b. `:DshWarmup` (non-CLI) reports readiness for the adopted server.
local warmup_notices = {}
local original_notify = vim.notify
vim.notify = function(message)
  warmup_notices[#warmup_notices + 1] = message
end
local warm_ok, warm_err = require("dsh").warmup(false)
vim.notify = original_notify
check("warmup succeeds for a shared server", warm_ok == true, tostring(warm_err))
check(
  "warmup reports the server URL",
  warmup_notices[1] ~= nil and warmup_notices[1]:find("http://127.0.0.1:5001", 1, true) ~= nil,
  vim.inspect(warmup_notices)
)

-- The recorded server dies between calls: the cached credentials must not be
-- reused blindly, and the next context rediscovers through the registry.
write_registry(adopt_dir, {
  url = "http://127.0.0.1:5001",
  token = "sharedtok",
  pid = 999999,
  version = 1,
})
local before_reconnect = #connect_calls
local recovered = {}
server.context(function(err, ctx)
  recovered.err = err
  recovered.ctx = ctx
end)
vim.wait(3000, function()
  return recovered.err ~= nil or recovered.ctx ~= nil
end, 10)
check(
  "dead shared server is rediscovered",
  recovered.ctx ~= nil and recovered.ctx.url == "http://127.0.0.1:5001",
  tostring(recovered.err)
)
check("rediscovery mints a new peer", #connect_calls == before_reconnect + 1, tostring(#connect_calls))

server.stop()
check("non-force stop leaves the shared server", read_registry(adopt_dir) ~= nil)
check("non-force stop disconnects locally", server.is_running() == false)

--------------------------------------------------------------------------------
-- 4. A live registry entry that refuses auth must not spawn a duplicate.
--------------------------------------------------------------------------------
local live_dir = vim.fn.tempname()
cleanup[#cleanup + 1] = live_dir
write_registry(live_dir, {
  url = "http://127.0.0.1:5002",
  token = "stale-token",
  pid = vim.uv.os_getpid(),
  version = 1,
})
local marker = live_dir .. "/spawned"
config.setup({
  notifications = false,
  shared = true,
  shared_dir = live_dir,
  startup_timeout = 1500,
  cmd = { "sh", "-c", "touch " .. vim.fn.shellescape(marker) },
})
connect_calls = {}
connect_handler = function()
  return nil, "gateway rejected the token"
end
server = fresh_server()
result = start(server)
check(
  "live entry with bad auth fails",
  result.ok == false and tostring(result.err):find("refused authentication", 1, true) ~= nil,
  tostring(result.err)
)
check("live entry does not spawn a duplicate", vim.uv.fs_stat(marker) == nil)
check("bad live entry keeps its registry", read_registry(live_dir) ~= nil)

--------------------------------------------------------------------------------
-- 5. Shared mode boots a detached server, publishes the registry, and stops it
--    with `force` (as `:DshStop` does).
--------------------------------------------------------------------------------
if vim.fn.executable("python3") == 1 then
  local spawn_dir = vim.fn.tempname()
  cleanup[#cleanup + 1] = spawn_dir
  vim.fn.mkdir(spawn_dir, "p")
  local script = spawn_dir .. "/fake-dsh.py"
  vim.fn.writefile({
    "import sys, time",
    'print("dsh web: http://127.0.0.1:5999/?token=spawntok", flush=True)',
    "time.sleep(120)",
  }, script)

  config.setup({
    notifications = false,
    shared = true,
    shared_dir = spawn_dir,
    cmd = { "python3", script },
    startup_timeout = 8000,
    request_timeout = 5000,
  })
  connect_calls = {}
  connect_handler = function()
    return "cookie-spawn"
  end
  server = fresh_server()
  result = start(server)
  local entry = read_registry(spawn_dir)
  described = server.describe()
  check("detached shared server starts", result.ok == true, tostring(result.err))
  check(
    "registry records the shared server",
    entry ~= nil and entry.url == "http://127.0.0.1:5999" and entry.token == "spawntok" and type(entry.pid) == "number",
    vim.inspect(entry)
  )
  check(
    "spawned mode and pid reported",
    described.shared == true and described.pid == (entry and entry.pid),
    vim.inspect(described)
  )
  local pid = entry and entry.pid
  server.stop({ force = true })
  vim.wait(3000, function()
    return not process_alive(pid)
  end, 20)
  check("force stop ends the shared server", not process_alive(pid), tostring(pid))
  check("force stop clears the registry", read_registry(spawn_dir) == nil)
else
  print("SKIP detached shared server (python3 unavailable)")
end

--------------------------------------------------------------------------------
-- 6. Warmup refuses private mode: that server would die with this Neovim.
--------------------------------------------------------------------------------
config.setup({ notifications = false })
local refusal_notices = {}
vim.notify = function(message)
  refusal_notices[#refusal_notices + 1] = message
end
local refused, refusal = require("dsh").warmup(false)
vim.notify = original_notify
check(
  "warmup refuses private mode",
  refused == false and tostring(refusal):find("shared", 1, true) ~= nil,
  tostring(refusal)
)
check("private warmup starts nothing", require("dsh.server").is_running() == false)
check("private warmup explains itself", refusal_notices[1] ~= nil and refusal_notices[1]:find("warmup failed", 1, true) ~= nil)

cleanup_dirs()

print(("\n=== %d checks, %d failed ==="):format(checks, failures))
vim.cmd("cquit " .. (failures > 0 and 1 or 0))
