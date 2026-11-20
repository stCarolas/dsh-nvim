-- Workspace roster (workspace/follow) and the workspace picker.
-- Run with: nvim --headless -l scripts/workspace_spec.lua
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h:h")
vim.opt.rtp:append(root)

local config = require("dsh.config")
config.setup({ notifications = false })

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

local function contains(list, needle)
  for _, item in ipairs(list) do
    if type(item) == "string" and item:find(needle, 1, true) then
      return true
    end
  end
  return false
end

--------------------------------------------------------------------------------
-- Stubs: the roster is a stream; the picker is pure UI over the cache.
--------------------------------------------------------------------------------
local mux = {
  connected = false,
  handlers = nil,
  endpoint = nil,
  args = nil,
  on_close_callback = nil,
  acquire_error = nil,
}

function mux.is_connected()
  return mux.connected
end

function mux.acquire(_, callback)
  if mux.acquire_error then
    callback(mux.acquire_error)
    return
  end
  mux.connected = true
  callback(nil)
end

function mux.stream(endpoint, args, handlers)
  mux.endpoint = endpoint
  mux.args = args
  mux.handlers = handlers
  if not mux.connected then
    if handlers.on_error then
      handlers.on_error("websocket is not connected")
    end
    return nil
  end
  return "workspace-stream"
end

function mux.on_close(callback)
  mux.on_close_callback = callback
end

function mux.cancel() end

package.loaded["dsh.mux"] = mux
package.loaded["dsh.http"] = {
  rpc = function()
    return nil, "no rpc in this spec"
  end,
}

local workspaces = require("dsh.workspaces")
local workspace = require("dsh.workspace")
local session = require("dsh.session")

local function feed(frame)
  mux.handlers.on_item(frame)
end

local function ids(items)
  local out = {}
  for _, item in ipairs(items) do
    out[#out + 1] = item.workspaceId
  end
  return table.concat(out, ",")
end

--------------------------------------------------------------------------------
-- 1. Baseline, upsert, order, remove and replace frames.
--------------------------------------------------------------------------------
workspaces.begin({ url = "http://test", cookie = "cookie" })

check("workspace stream opened", mux.endpoint == "workspace/follow", tostring(mux.endpoint))
check("workspace stream sends empty args", type(mux.args) == "table", type(mux.args))
check("workspace roster waits for its baseline", workspaces.is_ready() == false)

feed({
  type = "baseline",
  value = {
    items = {
      { workspaceId = "w1", path = "/repo/a", title = "A", sessionIds = { "s1" } },
      { workspaceId = "w2", path = "/repo/b", title = "B", sessionIds = {} },
    },
    archivedSessionIds = {},
    pinnedSessionIds = {},
  },
})
check("baseline makes the roster ready", workspaces.is_ready() == true)
check("baseline keeps host order", ids(workspaces.list()) == "w1,w2", ids(workspaces.list()))

feed({
  type = "upsert",
  workspace = { workspaceId = "w3", path = "/repo/c", title = "C", sessionIds = {} },
})
check("upsert appends a new workspace", ids(workspaces.list()) == "w1,w2,w3", ids(workspaces.list()))

feed({
  type = "upsert",
  workspace = { workspaceId = "w1", path = "/repo/a", title = "A renamed", sessionIds = { "s1", "s2" } },
})
local updated = workspaces.list()[1]
check("upsert updates the existing row", updated.title == "A renamed" and #updated.sessionIds == 2, vim.inspect(updated))
check("upsert keeps the position", ids(workspaces.list()) == "w1,w2,w3", ids(workspaces.list()))

feed({ type = "order", workspaceIds = { "w3", "w1", "w2" } })
check("order frame reorders rows", ids(workspaces.list()) == "w3,w1,w2", ids(workspaces.list()))

feed({ type = "remove", workspaceId = "w2" })
check("remove drops a row", ids(workspaces.list()) == "w3,w1", ids(workspaces.list()))

-- Archive and pin frames ride the same stream but say nothing about workspaces.
feed({ type = "archived", archivedSessionIds = { "s1" } })
feed({ type = "pinned", pinnedSessionIds = { "s2" } })
check("unrelated frames leave the roster alone", ids(workspaces.list()) == "w3,w1", ids(workspaces.list()))

feed({
  type = "replace",
  value = { items = { { workspaceId = "w4", path = "/repo/d", title = "D", sessionIds = {} } } },
})
check("replace swaps the whole roster", ids(workspaces.list()) == "w4", ids(workspaces.list()))

-- 2. `ensure` is immediate once a baseline arrived.
local ready, ready_err = workspaces.ensure({ url = "http://test", cookie = "cookie" })
check("ensure returns the ready roster", ready == true, ready_err)

-- 3. A dropped socket clears the cache and a failed reacquire is reported.
mux.connected = false
mux.acquire_error = "cannot open websocket: refused"
mux.on_close_callback()
check("socket close clears the roster", workspaces.is_ready() == false and #workspaces.list() == 0)
local failed, failed_err = workspaces.ensure({ url = "http://test", cookie = "cookie" }, 100)
check("failed reacquire is reported", failed == nil and failed_err ~= nil, tostring(failed_err))
check("failed reacquire exposes the stream error", workspaces.error() ~= nil and workspaces.error():find("refused", 1, true) ~= nil, tostring(workspaces.error()))

--------------------------------------------------------------------------------
-- 4. The selected workspace overrides the scoping path only.
--------------------------------------------------------------------------------
local cwd = vim.fn.getcwd()
local ok_select, select_err = workspace.select({ workspaceId = "w1", path = "/repo/a", title = "A" })
check("workspace selection accepted", ok_select == true, tostring(select_err))
check("selected workspace is exposed", workspace.selected() and workspace.selected().workspaceId == "w1")
check("scope path follows the selection", workspace.scope_path() == "/repo/a", workspace.scope_path())

workspace.clear_selection()
check("clearing restores the cwd scope", workspace.scope_path() == cwd, workspace.scope_path())
local bad, bad_err = workspace.select({ workspaceId = "broken" })
check("workspaceless selection is rejected", bad == nil and bad_err ~= nil, tostring(bad_err))
check("rejected selection keeps the cwd scope", workspace.scope_path() == cwd and workspace.selected() == nil)

--------------------------------------------------------------------------------
-- 5. Workspace picker rows, selection and reset.
--------------------------------------------------------------------------------
local workspaces_stub = {
  ready = true,
  error = nil,
  items = {},
}
function workspaces_stub.ensure()
  if workspaces_stub.ready then
    return true
  end
  return nil, workspaces_stub.error or "workspace list unavailable"
end
function workspaces_stub.list()
  return workspaces_stub.items
end
package.loaded["dsh.workspaces"] = workspaces_stub
package.loaded["dsh.server"] = {
  context = function(callback)
    callback(nil, { url = "http://test", cookie = "cookie" })
  end,
}
package.loaded["dsh.ui.workspace"] = nil
local workspace_ui = require("dsh.ui.workspace")

local notified = {}
local original_notify = vim.notify
vim.notify = function(message)
  notified[#notified + 1] = message
end

local selections = {}
local select_calls = {}
vim.ui.select = function(labels, opts, callback)
  select_calls[#select_calls + 1] = { prompt = opts and opts.prompt, labels = labels }
  local wanted = table.remove(selections, 1)
  if wanted == nil then
    callback(nil)
    return
  end
  for index, label in ipairs(labels) do
    if label == wanted or label:find(wanted, 1, true) then
      callback(label, index)
      return
    end
  end
  error(("no label matching %q in %s"):format(wanted, vim.inspect(labels)))
end

local function reset_ui()
  workspace.clear_selection()
  notified = {}
  selections = {}
  select_calls = {}
  workspaces_stub.ready = true
  workspaces_stub.error = nil
  workspaces_stub.items = {
    { workspaceId = "w-cwd", path = cwd, title = "Current project", sessionIds = { "s1", "s2" } },
    { workspaceId = "w-other", path = cwd .. "/other", title = "Other project", sessionIds = {} },
  }
end

reset_ui()
workspace_ui.pick()
check("workspace picker uses vim.ui", #select_calls == 1, tostring(#select_calls))
check("workspace picker prompt", select_calls[1] and select_calls[1].prompt == "DSH workspace", select_calls[1] and select_calls[1].prompt)
check(
  "cwd row is offered first",
  select_calls[1] and select_calls[1].labels[1]:find("Use Neovim's current directory", 1, true) ~= nil,
  select_calls[1] and vim.inspect(select_calls[1].labels)
)
check(
  "cwd row is marked current without a selection",
  select_calls[1] and select_calls[1].labels[1]:find("(current)", 1, true) ~= nil,
  select_calls[1] and select_calls[1].labels[1]
)
check(
  "workspace rows carry title, path and count",
  select_calls[1] and contains(select_calls[1].labels, "Current project — ")
    and contains(select_calls[1].labels, "(2 sessions)")
    and contains(select_calls[1].labels, "Other project — ")
    and contains(select_calls[1].labels, "(no sessions)"),
  select_calls[1] and vim.inspect(select_calls[1].labels)
)
check(
  "the cwd workspace is marked",
  select_calls[1] and contains(select_calls[1].labels, "Current project — ") and select_calls[1].labels[2]:find("(current)", 1, true) ~= nil,
  select_calls[1] and select_calls[1].labels[2]
)

-- Choosing a workspace stores it as the session scope.
reset_ui()
selections = { "Other project" }
workspace_ui.pick()
check("chosen workspace becomes the scope", workspace.selected() and workspace.selected().workspaceId == "w-other")
check("workspace choice is reported", notified[#notified] and notified[#notified]:find("workspace: Other project", 1, true) ~= nil, tostring(notified[#notified]))

-- The selected row is marked, and the cwd row no longer claims "current".
reset_ui()
workspace.select({ workspaceId = "w-other", path = cwd .. "/other", title = "Other project" })
workspace_ui.pick()
check("selected workspace is marked", select_calls[1] and contains(select_calls[1].labels, "(selected)"))
check("cwd row is not marked current", select_calls[1] and select_calls[1].labels[1]:find("(current)", 1, true) == nil, select_calls[1] and select_calls[1].labels[1])

-- Choosing the selected workspace again is a no-op.
reset_ui()
workspace.select({ workspaceId = "w-other", path = cwd .. "/other", title = "Other project" })
selections = { "Other project" }
workspace_ui.pick()
check("already-selected workspace is reported", notified[#notified] and notified[#notified]:find("already using Other project", 1, true) ~= nil, tostring(notified[#notified]))

-- The cwd row clears the selection.
reset_ui()
workspace.select({ workspaceId = "w-other", path = cwd .. "/other", title = "Other project" })
selections = { "Use Neovim's current directory" }
workspace_ui.pick()
check("cwd row clears the selection", workspace.selected() == nil)
check("cwd reset is reported", notified[#notified] and notified[#notified]:find("current directory", 1, true) ~= nil, tostring(notified[#notified]))

-- Cancelling leaves both the selection and the scope untouched.
reset_ui()
workspace.select({ workspaceId = "w-other", path = cwd .. "/other", title = "Other project" })
selections = {}
workspace_ui.pick()
check("cancelled picker keeps the selection", workspace.selected() and workspace.selected().workspaceId == "w-other")
check("cancelled picker says nothing", #notified == 0, vim.inspect(notified))

-- An empty roster and a failed stream are reported instead of opening a picker.
reset_ui()
workspaces_stub.items = {}
workspace_ui.pick()
check("empty roster opens no picker", #select_calls == 0)
check("empty roster is reported", notified[#notified] and notified[#notified]:find("no workspaces", 1, true) ~= nil, tostring(notified[#notified]))

reset_ui()
workspaces_stub.ready = false
workspaces_stub.error = "workspace stream unavailable"
workspace_ui.pick()
check("failed roster opens no picker", #select_calls == 0)
check("failed roster is reported", notified[#notified] and notified[#notified]:find("workspace stream unavailable", 1, true) ~= nil, tostring(notified[#notified]))

-- `reset` returns to cwd without a picker.
reset_ui()
workspace.select({ workspaceId = "w-other", path = cwd .. "/other", title = "Other project" })
workspace_ui.reset()
check("reset clears the scope", workspace.selected() == nil)
check("reset is reported", notified[#notified] and notified[#notified]:find("current directory", 1, true) ~= nil, tostring(notified[#notified]))
check("reset opens no picker", #select_calls == 0)

vim.notify = original_notify

print(("\n=== %d checks, %d failed ==="):format(checks, failures))
vim.cmd("cquit " .. (failures > 0 and 1 or 0))
