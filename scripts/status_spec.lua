-- Connection status specs: `require("dsh").status()` fields for status plugins.
-- Run with: nvim --headless -l scripts/status_spec.lua
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h:h")
vim.opt.rtp:append(root)

local config = require("dsh.config")
config.setup({ notifications = false, treesitter = false })

local checks = 0
local failures = 0

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
-- Stubs: status must read the cached transport state, never call the network.
--------------------------------------------------------------------------------
local described = {
  running = true,
  starting = false,
  url = "http://127.0.0.1:9999",
  pid = 4242,
  mode = "own",
  shared = false,
  attached = false,
  registry = nil,
  error = nil,
}
local alive = true
local websocket = true
local interactions = true
local views = 2

package.loaded["dsh.server"] = {
  describe = function()
    return vim.deepcopy(described)
  end,
  is_alive = function()
    return alive
  end,
  is_starting = function()
    return described.starting
  end,
  is_running = function()
    return described.running
  end,
  stop = function() end,
}
package.loaded["dsh.mux"] = {
  is_connected = function()
    return websocket
  end,
}
package.loaded["dsh.interactions"] = {
  is_ready = function()
    return interactions
  end,
}
package.loaded["dsh.ui.chat"] = {
  view_count = function()
    return views
  end,
  shutdown = function() end,
}

local dsh = require("dsh")

--------------------------------------------------------------------------------
-- 1. A live own server with every transport up.
--------------------------------------------------------------------------------
local status = dsh.status()
check("running is reported", status.running == true)
check("server liveness is reported", status.server_live == true, tostring(status.server_live))
check("connected is true for a live server", status.connected == true, tostring(status.connected))
check("dsh.connected() matches", dsh.connected() == true)
check("startup state is reported", status.starting == false, tostring(status.starting))
check("mode is reported", status.mode == "own", tostring(status.mode))
check("endpoint is reported", status.url == "http://127.0.0.1:9999", tostring(status.url))
check("pid is reported", status.pid == 4242, tostring(status.pid))
check("websocket is reported", status.websocket == true)
check("stream aliases websocket", status.stream == status.websocket)
check("interactions are reported", status.interactions == true)
check("open view count is reported", status.views == 2, tostring(status.views))

--------------------------------------------------------------------------------
-- 2. A dead server process clears connected, and unknown liveness does not
--    (attached mode cannot probe a process the plugin does not own).
--------------------------------------------------------------------------------
alive = false
status = dsh.status()
check("a dead server clears server_live", status.server_live == false, tostring(status.server_live))
check("a dead server clears connected", status.connected == false, tostring(status.connected))
check("dsh.connected() follows a dead server", dsh.connected() == false)

alive = nil
described.mode = "attached"
described.attached = true
described.pid = nil
status = dsh.status()
check("attached mode reports unknown liveness", status.server_live == nil, tostring(status.server_live))
check("attached mode stays connected while its credentials are cached", status.connected == true, tostring(status.connected))

--------------------------------------------------------------------------------
-- 3. Transports and views are reported independently of the server state.
--------------------------------------------------------------------------------
websocket = false
interactions = false
views = 0
status = dsh.status()
check("a closed websocket is reported", status.websocket == false and status.stream == false)
check("an unavailable interaction stream is reported", status.interactions == false)
check("no open views is reported", status.views == 0, tostring(status.views))

--------------------------------------------------------------------------------
-- 4. Starting and not-yet-connected states, including the last error.
--------------------------------------------------------------------------------
described = {
  running = false,
  starting = true,
  url = nil,
  pid = nil,
  mode = nil,
  shared = false,
  attached = false,
  registry = nil,
  error = "last failure",
}
alive = false
status = dsh.status()
check("a starting server is reported", status.starting == true, tostring(status.starting))
check("an unconnected plugin is reported", status.running == false and status.connected == false)
check("the last connection error is reported", status.error == "last failure", tostring(status.error))

--------------------------------------------------------------------------------
-- 5. :DshStatus renders the same facts.
--------------------------------------------------------------------------------
vim.cmd("runtime plugin/dsh.lua")
check("DshStatus command is registered", vim.fn.exists(":DshStatus") == 2)

local noticed = {}
local original_notify = vim.notify
vim.notify = function(message)
  noticed[#noticed + 1] = tostring(message)
end

described = {
  running = true,
  starting = false,
  url = "http://127.0.0.1:9999",
  pid = 4242,
  mode = "own",
  shared = false,
  attached = false,
  registry = nil,
  error = nil,
}
alive = true
websocket = true
interactions = true
views = 2
vim.cmd("DshStatus")
local message = noticed[#noticed] or ""
check("DshStatus reports server liveness", message:find("server live", 1, true) ~= nil, message)
check("DshStatus reports the websocket", message:find("websocket connected", 1, true) ~= nil, message)
check("DshStatus reports interactions", message:find("questions ready", 1, true) ~= nil, message)
check("DshStatus reports open views", message:find("2 views", 1, true) ~= nil, message)

described.running = false
described.starting = true
vim.cmd("DshStatus")
message = noticed[#noticed] or ""
check("DshStatus reports startup", message:find("not connected: starting", 1, true) ~= nil, message)

vim.notify = original_notify

print(("\n=== %d checks, %d failed ==="):format(checks, failures))
vim.cmd("cquit " .. (failures > 0 and 1 or 0))
