-- Workspace scoping specs: cwd canonicalization, filtered session lists, and
-- creating sessions inside the Workspace of the current directory.
-- Run with: nvim --headless -l scripts/scope_spec.lua
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h:h")
vim.opt.rtp:append(root)

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
-- A scripted transport: record every call and answer per endpoint.
--------------------------------------------------------------------------------
local calls = {}
local handlers = {}

local http_stub = {
  rpc = function(_, endpoint, args)
    calls[#calls + 1] = { endpoint = endpoint, args = args }
    local handler = handlers[endpoint]
    if type(handler) == "function" then
      return handler(args)
    end
    return nil, "no stub for " .. endpoint
  end,
}
package.loaded["dsh.http"] = http_stub

local function reset_calls()
  for index = #calls, 1, -1 do
    calls[index] = nil
  end
end

local function calls_to(endpoint)
  local found = {}
  for _, call in ipairs(calls) do
    if call.endpoint == endpoint then
      found[#found + 1] = call
    end
  end
  return found
end

--------------------------------------------------------------------------------
-- Fixture directories: `project` is the real path, `link` a symlink to it.
--------------------------------------------------------------------------------
local tmp = vim.fn.tempname()
local project = tmp .. "/project"
vim.fn.mkdir(project, "p")
local link = tmp .. "/link"
local linked = vim.uv.fs_symlink(project, link)
check("fixture symlink created", linked and vim.uv.fs_realpath(link) == vim.uv.fs_realpath(project), tostring(linked))

local session = require("dsh.session")
local workspace = require("dsh.workspace")
local config = require("dsh.config")
config.setup({ notifications = false })

--------------------------------------------------------------------------------
-- 1. cwd canonicalization.
--------------------------------------------------------------------------------
local canonical_project = session.canonical_path(project)
local canonical_link = session.canonical_path(link)
check("canonical path resolves symlinks", canonical_link == canonical_project, tostring(canonical_link))
check("canonical path is the realpath", canonical_project == vim.uv.fs_realpath(project), tostring(canonical_project))
check("canonical path drops trailing separators", session.canonical_path(project .. "/") == canonical_project)
check("canonical path keeps the filesystem root", session.canonical_path("/") == "/", tostring(session.canonical_path("/")))
check("canonical path rejects empty input", session.canonical_path("") == nil)

--------------------------------------------------------------------------------
-- 2. Directory filtering keeps order and accepts symlinked cwds.
--------------------------------------------------------------------------------
local items = {
  { sessionId = "a", cwd = project },
  { sessionId = "b", cwd = link },
  { sessionId = "c", cwd = tmp },
  { sessionId = "d" },
  { sessionId = "e", cwd = "" },
  { sessionId = "f", cwd = project .. "/" },
}

local function ids(list)
  local out = {}
  for _, item in ipairs(list) do
    out[#out + 1] = item.sessionId
  end
  return table.concat(out, ",")
end

local kept = session.filter_directory(items, project)
check("filter keeps only the current directory", ids(kept) == "a,b,f", ids(kept))
check("filter resolves a symlinked query cwd", ids(session.filter_directory(items, link)) == "a,b,f", ids(session.filter_directory(items, link)))
check("filter rejects sessions without a cwd", not session.in_directory({ sessionId = "x" }, project))
check("filter is empty without a usable target", ids(session.filter_directory(items, "")) == "")

--------------------------------------------------------------------------------
-- 3. New sessions go into the Workspace for the cwd.
--------------------------------------------------------------------------------
local ctx = { url = "http://127.0.0.1:1", cookie = "cookie" }

handlers["workspace/create"] = function(args)
  check("workspace/create names the canonical directory", args.request.path == canonical_project, tostring(args.request.path))
  return {
    workspace = { workspaceId = "ws-project", path = canonical_project, sessionIds = {} },
    created = true,
  }
end
handlers["session/create"] = function(args)
  check("session/create names the workspace", args.request.workspaceId == "ws-project", vim.inspect(args.request))
  check("session/create does not pass a raw cwd", args.request.cwd == nil)
  return { sessionId = "session-created" }
end

reset_calls()
local value, create_err, warning = session.create_in_workspace(ctx, link)
check("session created in the workspace", value and value.sessionId == "session-created", tostring(create_err))
check("workspace creation is not reported as a fallback", warning == nil, tostring(warning))
check("workspace resolved before session creation", #calls_to("workspace/create") == 1 and #calls_to("session/create") == 1)

--------------------------------------------------------------------------------
-- 4. A deployment without the Workspace registry still creates sessions.
--------------------------------------------------------------------------------
handlers["workspace/create"] = function()
  -- The real code for "nothing exports this endpoint" (there is no
  -- "gateway/method-not-found" in the gateway vocabulary).
  return nil, "gateway/method-unavailable: workspace/create", "gateway/method-unavailable", {}
end
handlers["session/create"] = function(args)
  return { sessionId = "session-plain", cwd = args.request.cwd }
end

reset_calls()
local plain, plain_err, plain_warning = session.create_in_workspace(ctx, project)
check("fallback creates a plain cwd session", plain and plain.sessionId == "session-plain", tostring(plain_err))
check("fallback session is rooted at the canonical cwd", plain and plain.cwd == canonical_project, plain and tostring(plain.cwd))
check("fallback reports why it fell back", plain_warning and plain_warning:find("method%-unavailable") ~= nil, tostring(plain_warning))

--------------------------------------------------------------------------------
-- 5. A refused workspace attach keeps the session the host already created.
--
-- DSH creates the session and only then attaches it, so retrying on
-- `session/workspace-attach-failed` used to leave an orphan behind.
--------------------------------------------------------------------------------
handlers["workspace/create"] = function()
  return { workspace = { workspaceId = "ws-project", path = canonical_project, sessionIds = {} }, created = false }
end
handlers["session/create"] = function(args)
  if args.request.workspaceId then
    return nil,
      "session/workspace-attach-failed: attach refused",
      "session/workspace-attach-failed",
      { sessionId = "session-attached-late", workspaceId = "ws-project" }
  end
  return { sessionId = "session-fallback", cwd = args.request.cwd }
end

reset_calls()
local late, late_err, late_warning = session.create_in_workspace(ctx, project)
check("attach failure keeps the created session", late and late.sessionId == "session-attached-late", tostring(late_err))
check("attach failure is reported", late_warning and late_warning:find("not attached") ~= nil, tostring(late_warning))
check("attach failure does not create a second session", #calls_to("session/create") == 1, tostring(#calls_to("session/create")))

-- An error with no code may have happened after creation: do not retry.
handlers["session/create"] = function(args)
  if args.request.workspaceId then
    return nil, "curl: (28) timed out"
  end
  return { sessionId = "session-fallback" }
end
reset_calls()
local ambiguous, ambiguous_err = session.create_in_workspace(ctx, project)
check("ambiguous failure returns an error", ambiguous == nil and ambiguous_err ~= nil, tostring(ambiguous_err))
check("ambiguous failure does not retry", #calls_to("session/create") == 1, tostring(#calls_to("session/create")))

-- A capability error happened before creation, so the fallback is safe.
handlers["session/create"] = function(args)
  if args.request.workspaceId then
    return nil, "workspace/not-found: gone", "workspace/not-found", {}
  end
  return { sessionId = "session-fallback", cwd = args.request.cwd }
end
reset_calls()
local recovered, recovered_err, recovered_warning = session.create_in_workspace(ctx, project)
check("pre-creation error falls back", recovered and recovered.sessionId == "session-fallback", tostring(recovered_err))
check("pre-creation fallback is reported", recovered_warning and recovered_warning:find("workspace attach failed") ~= nil, tostring(recovered_warning))

--------------------------------------------------------------------------------
-- 6. The picker applies `sessions.scope`.
--------------------------------------------------------------------------------
local notified = {}
vim.notify = function(message)
  notified[#notified + 1] = message
end

package.loaded["dsh.server"] = {
  context = function(callback)
    callback(nil, ctx)
  end,
}
package.loaded["dsh.follow"] = { attach = function() return { detach = function() end } end }
package.loaded["dsh.mux"] = {
  close = function() end,
  is_connected = function()
    return false
  end,
  -- chat.attach starts the interaction stream on every view.
  acquire = function(_, callback)
    callback(nil)
  end,
  stream = function()
    return nil
  end,
  cancel = function() end,
  credential = function()
    return nil
  end,
}

local chat = require("dsh.ui.chat")

local picker_prompts = {}
local picker_choices = {}
vim.ui.select = function(labels, opts, callback)
  picker_prompts[#picker_prompts + 1] = opts and opts.prompt
  picker_choices[#picker_choices + 1] = labels
  callback(nil)
end

local list_items = {
  { sessionId = "session-aaaaaaaa", updatedAt = 1, cwd = project },
  { sessionId = "session-bbbbbbbb", updatedAt = 2, cwd = link },
  { sessionId = "session-cccccccc", updatedAt = 3, cwd = tmp },
}

handlers["session/list"] = function()
  return { items = vim.deepcopy(list_items) }
end

vim.cmd("cd " .. vim.fn.fnameescape(project))

reset_calls()
config.setup({ notifications = false, sessions = { scope = "cwd", order = "oldest" } })
chat.pick()
check("picker lists only the current directory", picker_choices[1] and #picker_choices[1] == 2, tostring(picker_choices[1] and #picker_choices[1]))
check("picker prompt names the directory", picker_prompts[1] and picker_prompts[1]:find(project, 1, true) ~= nil, tostring(picker_prompts[1]))

config.setup({ notifications = false, sessions = { scope = "all", order = "oldest" } })
chat.pick()
check("scope=all lists every session", picker_choices[2] and #picker_choices[2] == 3, tostring(picker_choices[2] and #picker_choices[2]))
check(
  "scope=all prompt does not claim the directory",
  picker_prompts[2] and picker_prompts[2]:find(project, 1, true) == nil,
  tostring(picker_prompts[2])
)

-- Sessions exist, but none here: say so instead of silently creating one.
handlers["session/list"] = function()
  return { items = { { sessionId = "session-cccccccc", updatedAt = 3, cwd = tmp } } }
end
config.setup({ notifications = false, sessions = { scope = "cwd", order = "oldest" } })
reset_calls()
notified = {}
chat.pick()
check("empty scope notifies instead of picking", #picker_choices == 2, tostring(#picker_choices))
check("empty scope message names the directory", notified[1] and notified[1]:find(project, 1, true) ~= nil, tostring(notified[1]))
check("empty scope does not create a session", #calls_to("session/create") == 0)

--------------------------------------------------------------------------------
-- 6b. A selected Workspace overrides scoping and new-session creation, without
-- changing Neovim's own cwd.
--------------------------------------------------------------------------------
local other = tmp .. "/other"
vim.fn.mkdir(other, "p")
local canonical_other = session.canonical_path(other)
table.insert(list_items, { sessionId = "session-dddddddd", updatedAt = 4, cwd = other })

handlers["session/list"] = function()
  return { items = vim.deepcopy(list_items) }
end
workspace.select({ workspaceId = "ws-other", path = other, title = "Other project" })
config.setup({ notifications = false, sessions = { scope = "all", order = "oldest" } })

local choices_before = #picker_choices
local prompts_before = #picker_prompts
chat.pick()
check(
  "selected workspace overrides scope=all",
  picker_choices[choices_before + 1] and #picker_choices[choices_before + 1] == 1,
  tostring(picker_choices[choices_before + 1] and #picker_choices[choices_before + 1])
)
check(
  "selected workspace prompt names the workspace",
  picker_prompts[prompts_before + 1] and picker_prompts[prompts_before + 1]:find("Other project", 1, true) ~= nil,
  tostring(picker_prompts[prompts_before + 1])
)

handlers["workspace/create"] = function(args)
  check("new session resolves the selected workspace", args.request.path == canonical_other, tostring(args.request.path))
  return {
    workspace = { workspaceId = "ws-other", path = canonical_other, sessionIds = {} },
    created = false,
  }
end
handlers["session/create"] = function(args)
  check("new session joins the selected workspace", args.request.workspaceId == "ws-other", vim.inspect(args.request))
  return { sessionId = "session-other" }
end

reset_calls()
chat.new_session()
check("new session uses the selected workspace", #calls_to("session/create") == 1, tostring(#calls_to("session/create")))
check("new session opens a view", chat.is_open("session-other"))
chat.close("session-other")
handlers["session/create"] = function()
  return { sessionId = "session-after-workspace" }
end

workspace.clear_selection()
config.setup({ notifications = false, sessions = { scope = "cwd", order = "oldest" } })
local restored_before = #picker_choices
chat.pick()
check(
  "clearing the workspace restores cwd scoping",
  picker_choices[restored_before + 1] and #picker_choices[restored_before + 1] == 2,
  tostring(picker_choices[restored_before + 1] and #picker_choices[restored_before + 1])
)

--------------------------------------------------------------------------------
-- 7. Malformed server data is rejected instead of raising.
--------------------------------------------------------------------------------
handlers["workspace/create"] = function()
  return 42
end
reset_calls()
local drifted, drift_err = workspace.ensure(ctx, project)
check("scalar workspace value is rejected", drifted == nil and drift_err ~= nil, tostring(drift_err))
local ok_scalar, scalar_result = pcall(session.create_in_workspace, ctx, project)
check("scalar workspace value does not raise", ok_scalar, tostring(scalar_result))

check("canonical path rejects NUL", session.canonical_path("/tmp/a\0b") == nil)
local ok_nul, kept_nul = pcall(session.filter_directory, {
  { sessionId = "nul", cwd = project .. "/\0evil" },
  { sessionId = "real", cwd = project },
}, project)
check("NUL cwd does not raise", ok_nul, tostring(kept_nul))
check("NUL cwd row is dropped", ok_nul and ids(kept_nul) == "real", ok_nul and ids(kept_nul) or tostring(kept_nul))

local ok_rows, kept_rows = pcall(session.filter_directory, {
  "not a table",
  42,
  { sessionId = "real", cwd = project },
}, project)
check("malformed rows do not raise", ok_rows, tostring(kept_rows))
check("malformed rows are dropped", ok_rows and ids(kept_rows) == "real", ok_rows and ids(kept_rows) or tostring(kept_rows))
check("malformed item list yields no rows", ids(session.filter_directory(nil, project)) == "")

--------------------------------------------------------------------------------
-- 8. Comparison folding is platform-specific; wire values keep their case.
--------------------------------------------------------------------------------
local win_key = session.comparison_key(project, { win32 = true })
local win_expected = canonical_project:lower():gsub("/", "\\")
check("win32 key folds separators and case", win_key == win_expected, tostring(win_key))
check(
  "macOS key folds case",
  session.comparison_key(project, { macos = true }) == session.comparison_key(project:upper(), { macos = true })
)
check("linux key keeps case", session.comparison_key(project, {}) == canonical_project, tostring(session.comparison_key(project, {})))
check(
  "win32 filter matches a differently-cased cwd",
  ids(session.filter_directory({ { sessionId = "x", cwd = project:upper() } }, project, { win32 = true })) == "x"
)
check("canonical path is not case-folded", session.canonical_path(project) == canonical_project, tostring(session.canonical_path(project)))

--------------------------------------------------------------------------------
-- 9. An unknown `sessions.scope` is normalized with a warning.
--------------------------------------------------------------------------------
notified = {}
config.setup({ sessions = { scope = "ALL" } })
check("invalid scope falls back to cwd", config.options.sessions.scope == "cwd", tostring(config.options.sessions.scope))
check("invalid scope is reported", notified[1] ~= nil and notified[1]:find("sessions%.scope") ~= nil, tostring(notified[1]))
config.setup({ sessions = { scope = "all" } })
check("valid scope is kept", config.options.sessions.scope == "all", tostring(config.options.sessions.scope))

notified = {}
config.setup({ sessions = { include_subagents = "no" } })
check(
  "invalid include_subagents falls back to true",
  config.options.sessions.include_subagents == true,
  tostring(config.options.sessions.include_subagents)
)
check(
  "invalid include_subagents is reported",
  notified[1] ~= nil and notified[1]:find("include_subagents") ~= nil,
  tostring(notified[1])
)

check("plain summaries are root sessions", session.is_root({ sessionId = "x" }))
check("parented summaries are not root sessions", not session.is_root({ parentSessionId = "session-parent" }))
check("subagent origins are not root sessions", not session.is_root({ origin = "subagent" }))
check(
  "filter_roots keeps only root sessions",
  #session.filter_roots({
    { sessionId = "root" },
    { sessionId = "child", parentSessionId = "root" },
    { sessionId = "child2", origin = "subagent" },
  }) == 1
)

--------------------------------------------------------------------------------
-- 10. A failed list reports; an empty list creates and opens a session.
--------------------------------------------------------------------------------
handlers["session/list"] = function()
  return nil, "gateway/service-unavailable: no session source", "gateway/service-unavailable", {}
end
config.setup({ notifications = false, sessions = { scope = "cwd" } })
local picks_before = #picker_choices
notified = {}
reset_calls()
chat.pick()
check("list failure notifies", notified[1] and notified[1]:find("service%-unavailable") ~= nil, tostring(notified[1]))
check("list failure does not pick", #picker_choices == picks_before)
check("list failure does not create", #calls_to("session/create") == 0)

handlers["session/list"] = function()
  return { items = {} }
end
handlers["workspace/create"] = function()
  return { workspace = { workspaceId = "ws-empty", path = canonical_project, sessionIds = {} }, created = false }
end
handlers["session/create"] = function()
  return { sessionId = "session-auto" }
end
local opened = {}
local real_open = chat.open
chat.open = function(session_id)
  opened[#opened + 1] = session_id
end
notified = {}
reset_calls()
chat.pick()
check("empty list notifies", notified[1] ~= nil and notified[1]:find("no sessions yet") ~= nil, tostring(notified[1]))
check("empty list creates a session", #calls_to("session/create") == 1, tostring(#calls_to("session/create")))
check("empty list opens the new session", opened[1] == "session-auto", tostring(opened[1]))

--------------------------------------------------------------------------------
-- 11. Choosing a row opens that session.
--------------------------------------------------------------------------------
handlers["session/list"] = function()
  return { items = vim.deepcopy(list_items) }
end
config.setup({ notifications = false, sessions = { scope = "cwd" } })
opened = {}
vim.ui.select = function(labels, opts, callback)
  picker_prompts[#picker_prompts + 1] = opts and opts.prompt
  picker_choices[#picker_choices + 1] = labels
  callback(labels[1])
end
reset_calls()
chat.pick()
check("picker selection opens the chosen session", opened[1] == "session-aaaaaaaa", tostring(opened[1]))
check("picker selection creates nothing", #calls_to("session/create") == 0)

--------------------------------------------------------------------------------
-- 12. Subagent sessions can be hidden from the picker.
--------------------------------------------------------------------------------
local mixed_sessions = {
  { sessionId = "session-rootaaaa", updatedAt = 1, cwd = project },
  { sessionId = "session-rootbbbb", updatedAt = 2, cwd = tmp },
  { sessionId = "session-childccc", updatedAt = 3, cwd = project, parentSessionId = "session-rootaaaa" },
  { sessionId = "session-childddd", updatedAt = 4, cwd = project, origin = "subagent" },
}
handlers["session/list"] = function()
  return { items = vim.deepcopy(mixed_sessions) }
end
local root_choices = {}
vim.ui.select = function(labels, _, callback)
  root_choices[#root_choices + 1] = labels
  callback(nil)
end

config.setup({ notifications = false, sessions = { scope = "cwd", include_subagents = true } })
chat.pick()
check("subagent sessions are listed by default", #root_choices[1] == 3, tostring(#root_choices[1]))

config.setup({ notifications = false, sessions = { scope = "cwd", include_subagents = false } })
chat.pick()
check("include_subagents=false lists only root sessions", #root_choices[2] == 1, tostring(#root_choices[2]))

config.setup({ notifications = false, sessions = { scope = "all", include_subagents = false } })
chat.pick()
check("root filter also applies to scope=all", #root_choices[3] == 2, tostring(#root_choices[3]))

chat.open = real_open

chat.shutdown()
vim.cmd("cd " .. vim.fn.fnameescape(root))
vim.fn.delete(tmp, "rf")

print(("\n=== %d checks, %d failed ==="):format(checks, failures))
vim.cmd("cquit " .. (failures > 0 and 1 or 0))
