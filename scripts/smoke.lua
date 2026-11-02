-- Headless end-to-end smoke test over the WebSocket stream.
-- Run with: nvim --headless -l scripts/smoke.lua
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h:h")
vim.opt.rtp:append(root)

-- DSH keeps projects, sessions, profiles and the workspace registry under
-- $DSH_HOME. This run creates all of them, so point it at a throwaway directory
-- instead of the user's real profile; the directory is removed in `finish`.
local smoke_home = vim.fn.tempname()
vim.fn.mkdir(smoke_home, "p")
vim.env.DSH_HOME = smoke_home

local dsh = require("dsh")
dsh.setup({
  notifications = false,
  startup_timeout = 180000,
  request_timeout = 60000,
})

local server = require("dsh.server")
local session = require("dsh.session")
local workspace = require("dsh.workspace")
local http = require("dsh.http")
local mux = require("dsh.mux")
local interactions = require("dsh.interactions")
local chat = require("dsh.ui.chat")

local steps = {}
local failed = 0

local function step(name, ok, detail)
  steps[#steps + 1] = { name = name, ok = ok, detail = detail or "" }
  if not ok then
    failed = failed + 1
  end
end

local function buffer_text(buf)
  return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
end

local function finish()
  print("\n=== smoke results ===")
  for _, entry in ipairs(steps) do
    print(("%s %-34s %s"):format(entry.ok and "PASS" or "FAIL", entry.name, entry.detail))
  end
  print(("=== %d failed ==="):format(failed))
  if smoke_home then
    pcall(vim.fn.delete, smoke_home, "rf")
  end
  vim.cmd("cquit " .. (failed > 0 and 1 or 0))
end

local done = false

server.start(function(ok, err)
  step("server start", ok, err or server.describe().url)
  if not ok then
    done = true
    return
  end

  server.context(function(ctx_err, ctx)
    step("connection context", ctx_err == nil, ctx_err or (ctx and ctx.url))
    if ctx_err then
      done = true
      return
    end

    local items, list_err = session.list(ctx)
    step("session/list", items ~= nil, list_err or ("%d sessions"):format(items and #items or 0))

    if items then
      local ascending = true
      for index = 2, #items do
        if (items[index].updatedAt or 0) < (items[index - 1].updatedAt or 0) then
          ascending = false
          break
        end
      end
      step("session/list is least-recent-first", ascending, ("%d sessions"):format(#items))
    end

    -- The cwd must resolve to a Workspace before a session can join it.
    local project, project_err, project_created = workspace.ensure(ctx, vim.fn.getcwd())
    step("workspace resolved for cwd", project ~= nil, project_err or (project and project.workspaceId))

    local value, create_err, create_warning = session.create_in_workspace(ctx, vim.fn.getcwd())
    step("session/create in workspace", value ~= nil, create_err or (value and value.sessionId))
    if create_warning then
      step("session/create had no fallback", false, create_warning)
    end
    if not value then
      done = true
      return
    end
    local session_id = value.sessionId

    -- Creating in the Workspace attaches the session, and the picker filter
    -- shows exactly the sessions rooted at this directory.
    local attached, attached_err = workspace.ensure(ctx, vim.fn.getcwd())
    local accounted = false
    for _, member in ipairs(attached and attached.sessionIds or {}) do
      if member == session_id then
        accounted = true
      end
    end
    step("session is accounted to the workspace", accounted, attached_err or tostring(attached and attached.workspaceId))

    local scoped, scoped_err = session.list(ctx)
    local visible = scoped and session.filter_directory(scoped, vim.fn.getcwd()) or {}
    local found = false
    for _, item in ipairs(visible) do
      if item.sessionId == session_id then
        found = true
      end
    end
    step("scoped session/list contains the new session", found, scoped_err or ("%d sessions in cwd"):format(#visible))

    -- Full UI path: open the view, which subscribes over the shared WebSocket.
    chat.open(session_id)
    local buf = vim.api.nvim_get_current_buf()

    local rendered = vim.wait(30000, function()
      return mux.is_connected() and buffer_text(buf):find("No messages yet", 1, true) ~= nil
    end, 100)
    step("view rendered from stream snapshot", rendered, ("%d lines"):format(vim.api.nvim_buf_line_count(buf)))
    step("websocket connected", mux.is_connected())

    -- The same socket carries the forwarded $events stream: questions and
    -- approvals are answerable once DSH has announced its client id.
    local question_ready = vim.wait(15000, function()
      return interactions.is_ready()
    end, 100)
    step("question stream ready", question_ready)

    -- Prompt through the real popup, then let the stream drive the update.
    chat.prompt(session_id)
    local popup = vim.api.nvim_get_current_buf()
    vim.api.nvim_buf_set_lines(popup, 0, -1, false, { "smoke test: answer with a two-item markdown bullet list and a fenced lua snippet" })
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<C-s>", true, false, true), "x", false)

    local saw_user = vim.wait(60000, function()
      return buffer_text(buf):find("smoke test:", 1, true) ~= nil
    end, 100)
    step("user message streamed into view", saw_user)

    local settled = vim.wait(90000, function()
      local text = buffer_text(buf)
      -- A live block carries the "▍" cursor; its disappearance means the durable
      -- assistant message (or a terminal error) has been rendered.
      return text:find("▌ Assistant", 1, true) ~= nil and text:find("▍", 1, true) == nil
    end, 100)
    step("turn settled in view", settled)

    print("\n--- rendered conversation ---")
    local view = buffer_text(buf)
    for index, line in ipairs(vim.split(view, "\n", { plain = true })) do
      if index > 40 then
        print("…")
        break
      end
      print(("%2d |%s"):format(index, line))
    end
    print("--- end conversation ---\n")

    chat.close(session_id)
    vim.wait(2000, function()
      return not mux.is_connected()
    end, 50)
    step("closing the last view closes the socket", not mux.is_connected())

    -- The run used a throwaway $DSH_HOME, so nothing here can reach the user's
    -- real profile. Deleting the workspace is still best-effort: a cleanup
    -- failure must not turn a feature run into a failure.
    if project_created and project then
      local deleted, delete_err = http.rpc(ctx, "workspace/delete", {
        request = { workspaceId = project.workspaceId },
      }, 60000)
      if deleted then
        step("cleanup: test workspace removed", true, project.workspaceId)
      else
        print(("WARN cleanup: test workspace not removed: %s"):format(tostring(delete_err)))
      end
    end
    done = true
  end)
end)

if not vim.wait(300000, function()
  return done
end, 200) then
  step("overall", false, "timed out")
end

chat.shutdown()
server.stop()
finish()
