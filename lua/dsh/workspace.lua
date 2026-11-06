--- Workspace operations. Thin wrapper over the `workspace/*` Remote methods.
---
--- A DSH Workspace is the project row the web sidebar groups sessions under.
--- Its directory is canonicalized by the Host (`realpath`), and a Session can
--- only join a Workspace whose directory is exactly its own cwd, so callers
--- must resolve the current directory to the same canonical path first.
local M = {}

local config = require("dsh.config")
local http = require("dsh.http")

--- Resolve the Workspace over `path`, registering it when none exists yet.
---
--- `workspace/create` is idempotent, so this is safe to call for every new
--- session. It also returns the Workspace with its current `sessionIds`, which
--- is how a caller can see the session it just created was accounted.
--- @param ctx {url: string, cookie: string}
--- @param path string absolute directory (canonical form preferred)
--- @return table|nil workspace
--- @return string|nil error
--- @return boolean|nil created true when this call registered the Workspace
function M.ensure(ctx, path)
  local value, err = http.rpc(ctx, "workspace/create", {
    request = { path = path },
  }, config.options.request_timeout)
  if not value then
    return nil, err
  end
  -- A schema change or a proxy can turn the value into a scalar; index nothing
  -- before checking that it is a table, or the picker dies instead of warning.
  if type(value) ~= "table" then
    return nil, "workspace/create returned an unexpected value"
  end

  local workspace = value.workspace
  if type(workspace) ~= "table" or type(workspace.workspaceId) ~= "string" then
    return nil, "workspace/create returned no workspace"
  end
  return workspace, nil, value.created == true
end

--- Archive one session: DSH's remove operation.
---
--- The session leaves Workspace and picker surfaces, and with `stop_activity`
--- its running turn, subagents, jobs and schedules are stopped first. The
--- transcript is kept; `workspace/unarchiveSession` (or the Web UI) restores
--- it.
--- @param ctx {url: string, cookie: string}
--- @param session_id string
--- @param stop_activity boolean|nil
--- @return table|nil value
--- @return string|nil error
function M.archive_session(ctx, session_id, stop_activity)
  local value, err = http.rpc(ctx, "workspace/archiveSession", {
    request = { sessionId = session_id, stopActivity = stop_activity == true },
  }, config.options.request_timeout)
  if not value then
    return nil, err
  end
  return value
end

--- Drop one session from the archive set (idempotent).
--- @param ctx {url: string, cookie: string}
--- @param session_id string
--- @return table|nil value
--- @return string|nil error
function M.unarchive_session(ctx, session_id)
  local value, err = http.rpc(ctx, "workspace/unarchiveSession", {
    request = { sessionId = session_id },
  }, config.options.request_timeout)
  if not value then
    return nil, err
  end
  return value
end

return M
