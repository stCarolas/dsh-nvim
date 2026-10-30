--- Chat view: one buffer per DSH session, kept live by a `session/follow` stream.
local M = {}

local config = require("dsh.config")
local follow = require("dsh.follow")
local mux = require("dsh.mux")
local render = require("dsh.render")
local server = require("dsh.server")
local session = require("dsh.session")
local surface = require("dsh.surface")

local prompt_ui = require("dsh.ui.prompt")
local picker = require("dsh.ui.picker")

--- @type table<string, table>
local state = { sessions = {} }

local attach

local function notify(message, level)
  vim.notify("dsh: " .. message, level or vim.log.levels.INFO)
end

local function update_winbar(entry)
  if entry.win and vim.api.nvim_win_is_valid(entry.win) then
    vim.wo[entry.win].winbar = render.winbar(entry.title, entry.status)
  end
end

--- Publish one follow state to a view.
local function apply(entry, follow_state)
  if entry.closed then
    return
  end
  entry.entries = follow_state.entries
  entry.title = follow_state.title or entry.title
  if follow_state.status then
    entry.status = follow_state.status
  end
  render.render(entry.buf, entry.entries, entry.win)
  update_winbar(entry)
end

--- Retry the stream after an unexpected drop.
local function schedule_reconnect(session_id, reason)
  local entry = state.sessions[session_id]
  if not entry or entry.closed then
    return
  end

  local attempts = (entry.reconnect_attempts or 0) + 1
  entry.reconnect_attempts = attempts

  if attempts > config.options.stream.reconnect_attempts then
    entry.status = "offline"
    update_winbar(entry)
    notify(("live updates stopped: %s"):format(reason or "stream lost"), vim.log.levels.WARN)
    return
  end

  entry.status = "reconnecting"
  update_winbar(entry)
  vim.defer_fn(function()
    local current = state.sessions[session_id]
    if current and not current.closed then
      attach(session_id)
    end
  end, config.options.stream.reconnect_delay)
end

--- One-shot history read used when live streaming is disabled.
local function load_once(session_id)
  server.context(function(err, ctx)
    if err then
      notify(err, vim.log.levels.ERROR)
      return
    end
    local entry = state.sessions[session_id]
    if not entry or entry.closed then
      return
    end

    local item = session.find(ctx, session_id)
    local cursor = item and item.projections and item.projections.asOfSeq
    if not cursor then
      cursor = session.cursor(ctx, session_id)
    end
    if not cursor then
      entry.status = "no history"
      update_winbar(entry)
      return
    end

    local page, page_err = session.page(ctx, session_id, cursor, config.options.max_messages)
    if not page then
      entry.status = "error"
      update_winbar(entry)
      notify(page_err or "cannot read history", vim.log.levels.ERROR)
      return
    end

    local built = surface.build(page.records)
    entry.entries = built.entries
    entry.title = built.title or entry.title
    entry.status = item and item.running and "running" or "idle"
    render.render(entry.buf, entry.entries, entry.win)
    update_winbar(entry)
  end)
end

--- Subscribe a view to its session stream.
--- @param session_id string
function attach(session_id)
  local entry = state.sessions[session_id]
  if not entry or entry.closed or entry.attaching then
    return
  end

  if not config.options.stream.enabled then
    load_once(session_id)
    return
  end

  entry.attaching = true

  server.context(function(err, ctx)
    entry.attaching = false
    local current = state.sessions[session_id]
    if not current or current.closed then
      return
    end
    if err then
      current.status = "offline"
      update_winbar(current)
      notify(err, vim.log.levels.ERROR)
      return
    end

    if current.follow then
      current.follow.detach()
    end

    current.status = "connecting"
    update_winbar(current)

    current.follow = follow.attach(ctx, session_id, {
      on_update = function(follow_state)
        local view = state.sessions[session_id]
        if view then
          apply(view, follow_state)
        end
      end,
      on_status = function(status, message)
        local view = state.sessions[session_id]
        if not view or view.closed then
          return
        end
        view.status = status
        update_winbar(view)
        if status == "streaming" then
          view.reconnect_attempts = 0
        elseif status == "error" or status == "disconnected" then
          schedule_reconnect(session_id, message or status)
        end
      end,
    })
  end)
end

--- Create the buffer for a session if it does not exist yet.
local function ensure_buffer(session_id)
  local entry = state.sessions[session_id]
  if entry and vim.api.nvim_buf_is_valid(entry.buf) then
    return entry
  end

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].swapfile = false
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].filetype = "dshchat"
  pcall(vim.api.nvim_buf_set_name, buf, "dsh://" .. session.short_id(session_id))

  entry = entry or {}
  entry.buf = buf
  entry.entries = entry.entries or {}
  entry.status = entry.status or "connecting"
  state.sessions[session_id] = entry

  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = buf,
    once = true,
    callback = function()
      local current = state.sessions[session_id]
      if current then
        current.closed = true
        if current.follow then
          current.follow.detach()
        end
        state.sessions[session_id] = nil
      end
      if next(state.sessions) == nil then
        mux.close()
      end
    end,
  })

  return entry
end

--- Resolve where a session view opens.
--- @return "tab"|"current"|"vertical"|"horizontal"
local function location()
  local cfg = config.options.chat
  if cfg.open_in == "tab" or cfg.split == "tab" then
    return "tab"
  end
  if cfg.open_in == "current" or cfg.split == "current" then
    return "current"
  end
  if cfg.split == "horizontal" then
    return "horizontal"
  end
  return "vertical"
end

--- Focus an existing view, switching tab pages when needed.
--- @param entry table
--- @return boolean focused
local function focus(entry)
  local win = entry.win
  if not (win and vim.api.nvim_win_is_valid(win)) then
    return false
  end
  local tabpage = vim.api.nvim_win_get_tabpage(win)
  if vim.api.nvim_get_current_tabpage() ~= tabpage then
    vim.api.nvim_set_current_tabpage(tabpage)
  end
  vim.api.nvim_set_current_win(win)
  return true
end

--- Show the session buffer in a window.
local function show(entry)
  if focus(entry) then
    return
  end

  local cfg = config.options.chat
  local target = location()

  if target == "tab" then
    -- `:tab sbuffer` opens the buffer directly, so no empty buffer is left behind.
    vim.cmd("tab sbuffer " .. entry.buf)
  elseif target == "current" then
    vim.api.nvim_win_set_buf(0, entry.buf)
  elseif target == "horizontal" then
    vim.cmd(("botright %dsplit"):format(cfg.height))
    vim.api.nvim_win_set_buf(0, entry.buf)
  else
    vim.cmd(("botright %dvsplit"):format(cfg.width))
    vim.api.nvim_win_set_buf(0, entry.buf)
  end

  entry.win = vim.api.nvim_get_current_win()
  vim.wo[entry.win].wrap = true
  vim.wo[entry.win].number = false
  vim.wo[entry.win].relativenumber = false
  update_winbar(entry)
  render.render(entry.buf, entry.entries, entry.win)
end

local function attach_keymaps(session_id)
  local entry = state.sessions[session_id]
  local keys = config.options.keymaps

  local function map(lhs, callback, description)
    if not lhs or lhs == "" then
      return
    end
    vim.keymap.set("n", lhs, callback, {
      buffer = entry.buf,
      nowait = true,
      silent = true,
      desc = description,
    })
  end

  map(keys.prompt, function()
    M.prompt(session_id)
  end, "DSH: send prompt")
  map(keys.refresh, function()
    M.refresh(session_id)
  end, "DSH: refresh history")
  map(keys.sessions, function()
    M.pick()
  end, "DSH: pick session")
  map(keys.close, function()
    M.close(session_id)
  end, "DSH: close session view")
  map(keys.cancel, function()
    M.cancel(session_id)
  end, "DSH: cancel running turn")
end

--- Open (or focus) a session view.
--- @param session_id string|nil omit to pick from the list
function M.open(session_id)
  if not session_id then
    M.pick()
    return
  end

  local entry = ensure_buffer(session_id)
  attach_keymaps(session_id)
  show(entry)
  attach(session_id)
end

--- Create a session in the current directory and open it.
--- @param opts {prompt: boolean|nil}|nil
function M.new_session(opts)
  server.context(function(err, ctx)
    if err then
      notify(err, vim.log.levels.ERROR)
      return
    end

    local value, create_err = session.create(ctx, vim.fn.getcwd())
    if not value then
      notify(create_err or "cannot create session", vim.log.levels.ERROR)
      return
    end

    M.open(value.sessionId)
    if opts and opts.prompt then
      vim.schedule(function()
        M.prompt(value.sessionId)
      end)
    end
  end)
end

--- Choose a session with `vim.ui.select` and open it.
function M.pick()
  server.context(function(err, ctx)
    if err then
      notify(err, vim.log.levels.ERROR)
      return
    end

    local items, list_err = session.list(ctx)
    if not items then
      notify(list_err or "cannot list sessions", vim.log.levels.ERROR)
      return
    end

    if #items == 0 then
      notify("no sessions yet; creating one")
      M.new_session()
      return
    end

    picker.select(items, function(item)
      M.open(item.sessionId)
    end)
  end)
end

--- Send a user message to a session.
--- @param session_id string|nil defaults to the session of the current buffer
function M.prompt(session_id)
  session_id = session_id or M.current()
  if not session_id then
    notify("no session in this buffer; run :DshNew or :DshSessions", vim.log.levels.WARN)
    return
  end

  local entry = state.sessions[session_id]
  if not entry then
    return
  end

  prompt_ui.open({ title = "DSH prompt" }, function(text)
    server.context(function(err, ctx)
      if err then
        notify(err, vim.log.levels.ERROR)
        return
      end

      local value, prompt_err = session.prompt(ctx, session_id, text)
      if not value then
        notify(prompt_err or "prompt rejected", vim.log.levels.ERROR)
        return
      end

      entry.status = "sent"
      update_winbar(entry)
    end)
  end)
end

--- Re-open the stream so history is re-read from a fresh snapshot.
--- @param session_id string|nil defaults to the session of the current buffer
function M.refresh(session_id)
  session_id = session_id or M.current()
  if not session_id then
    notify("no DSH session in this buffer", vim.log.levels.WARN)
    return
  end

  local entry = state.sessions[session_id]
  if not entry then
    return
  end

  if entry.follow then
    entry.follow.detach()
    entry.follow = nil
  end
  entry.reconnect_attempts = 0
  attach(session_id)
end

--- Cancel the running turn.
--- @param session_id string|nil defaults to the session of the current buffer
function M.cancel(session_id)
  session_id = session_id or M.current()
  if not session_id then
    return
  end
  server.context(function(err, ctx)
    if err then
      notify(err, vim.log.levels.ERROR)
      return
    end
    local value, cancel_err = session.cancel(ctx, session_id)
    if not value then
      notify(cancel_err or "cannot cancel", vim.log.levels.WARN)
      return
    end
  end)
end

--- Close a view's window, or its tab when the view owns that tab.
--- @param win number|nil
local function close_view_window(win)
  if not (win and vim.api.nvim_win_is_valid(win)) then
    return
  end

  local tabpage = vim.api.nvim_win_get_tabpage(win)
  local tab_windows = vim.api.nvim_tabpage_list_wins(tabpage)

  if #tab_windows > 1 then
    vim.api.nvim_win_close(win, true)
  elseif #vim.api.nvim_list_tabpages() > 1 then
    -- A tab created for this view belongs to the view; close the whole tab.
    vim.cmd("tabclose " .. vim.api.nvim_tabpage_get_number(tabpage))
  elseif #vim.api.nvim_list_wins() > 1 then
    vim.api.nvim_win_close(win, true)
  end
end

--- Close the session view for one buffer.
--- @param session_id string|nil defaults to the session of the current buffer
function M.close(session_id)
  session_id = session_id or M.current()
  if not session_id then
    return
  end

  local entry = state.sessions[session_id]
  if not entry then
    return
  end

  entry.closed = true
  if entry.follow then
    entry.follow.detach()
    entry.follow = nil
  end

  if entry.win and vim.api.nvim_win_is_valid(entry.win) then
    close_view_window(entry.win)
  end
  if vim.api.nvim_buf_is_valid(entry.buf) then
    vim.api.nvim_buf_delete(entry.buf, { force = true })
  end
  state.sessions[session_id] = nil

  if next(state.sessions) == nil then
    mux.close()
  end
end

--- Session id owning the current buffer, if any.
--- @return string|nil
function M.current()
  local buf = vim.api.nvim_get_current_buf()
  for session_id, entry in pairs(state.sessions) do
    if entry.buf == buf then
      return session_id
    end
  end
  return nil
end

--- Detach every view and close the socket; used when Neovim exits.
function M.shutdown()
  for session_id, entry in pairs(state.sessions) do
    entry.closed = true
    if entry.follow then
      entry.follow.detach()
      entry.follow = nil
    end
    state.sessions[session_id] = nil
  end
  mux.close()
end

return M
