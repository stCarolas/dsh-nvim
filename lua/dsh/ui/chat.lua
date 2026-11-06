--- Chat view: one buffer per DSH session, kept live by a `session/follow` stream.
local M = {}

local config = require("dsh.config")
local archive = require("dsh.archive")
local follow = require("dsh.follow")
local interactions = require("dsh.interactions")
local mux = require("dsh.mux")
local render = require("dsh.render")
local server = require("dsh.server")
local session = require("dsh.session")
local surface = require("dsh.surface")
local treesitter = require("dsh.treesitter")
local workspace = require("dsh.workspace")

local prompt_ui = require("dsh.ui.prompt")
local picker = require("dsh.ui.picker")

--- @type table<string, table>
local state = { sessions = {}, focus_seq = 0 }

local attach

local function notify(message, level)
  vim.notify("dsh: " .. message, level or vim.log.levels.INFO)
end

--- A session title made safe to use in a buffer name.
--- @param title string|nil
--- @return string|nil
local function title_name(title)
  if type(title) ~= "string" then
    return nil
  end
  local name = vim.trim((title:gsub("%c", " "):gsub("%s+", " ")))
  return name ~= "" and name or nil
end

--- Whether another buffer already uses `name`.
--- @param name string
--- @param buf integer
--- @return boolean
local function name_taken(name, buf)
  for _, other in ipairs(vim.api.nvim_list_bufs()) do
    if other ~= buf and vim.api.nvim_buf_is_valid(other) and vim.api.nvim_buf_get_name(other) == name then
      return true
    end
  end
  return false
end

--- Name a session buffer after its DSH title.
---
--- The short id is used until DSH derives a title (a new session has none yet)
--- and whenever the title is empty or unusable. The `dsh://` scheme keeps a
--- title from being resolved as a file path relative to the cwd, and duplicate
--- titles get the session id so two buffers never share a name.
--- @param entry table
local function update_name(entry)
  local buf = entry.buf
  local session_id = entry.session_id
  if not (session_id and buf and vim.api.nvim_buf_is_valid(buf)) then
    return
  end

  local title = title_name(entry.title)
  local name
  if title then
    name = "dsh://" .. title
    if name_taken(name, buf) then
      name = ("%s (%s)"):format(name, session.short_id(session_id))
    end
  else
    name = "dsh://" .. session.short_id(session_id)
  end

  if vim.api.nvim_buf_get_name(buf) ~= name then
    -- A user autocmd may reject the rename; the old name stays usable.
    pcall(vim.api.nvim_buf_set_name, buf, name)
  end
end

--- Clip a streaming preview so the whole winbar fits the window.
---
--- `render.winbar` spends 20 cells on the ` dsh · ` prefix and ` · streaming `
--- suffix; the remaining cells belong to the preview.
--- @param text string
--- @param width integer
--- @return string
local function fit_winbar(text, width)
  local budget = width - 20
  if budget < 8 then
    budget = 8
  end
  if vim.fn.strdisplaywidth(text) <= budget then
    return text
  end

  -- Widest character prefix that still leaves room for the ellipsis.
  local low, high = 0, vim.fn.strchars(text)
  while low < high do
    local middle = math.ceil((low + high) / 2)
    if vim.fn.strdisplaywidth(vim.fn.strcharpart(text, 0, middle)) + 1 <= budget then
      low = middle
    else
      high = middle - 1
    end
  end
  return vim.fn.strcharpart(text, 0, low) .. "…"
end

local function update_winbar(entry)
  if entry.win and vim.api.nvim_win_is_valid(entry.win) then
    local preview
    if entry.status == "streaming" then
      preview = render.last_assistant(entry.entries)
      if preview then
        preview = fit_winbar(preview, vim.api.nvim_win_get_width(entry.win))
      end
    end
    -- `'winbar'` is a statusline expression; a rejected assignment must not
    -- abort a stream update, so keep the failure local.
    pcall(function()
      vim.wo[entry.win].winbar = render.winbar(entry.title, entry.status, preview)
    end)
  end
end

--- Remember that a view is the most recently used one.
--- @param entry table
local function mark_focused(entry)
  state.focus_seq = (state.focus_seq or 0) + 1
  entry.focus_seq = state.focus_seq
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
  update_name(entry)
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
--- @param ctx {url: string, cookie: string}
--- @param session_id string
local function load_once(ctx, session_id)
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
  update_name(entry)
  update_winbar(entry)
end

--- Subscribe a view to its session stream.
--- @param session_id string
function attach(session_id)
  local entry = state.sessions[session_id]
  if not entry or entry.closed or entry.attaching then
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

    -- Forwarded questions and approvals ride the same multiplexed socket. They
    -- open independently of `stream.enabled`, so a history-only view can still
    -- answer a blocking `ask_user_question` call.
    interactions.start(ctx)
    -- Keep the archived-session set fresh for pickers.
    archive.begin(ctx)

    if not config.options.stream.enabled then
      load_once(ctx, session_id)
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
        if status == "streaming" or status == "idle" then
          view.reconnect_attempts = 0
        elseif status == "error" or status == "disconnected" then
          schedule_reconnect(session_id, message or status)
        end
      end,
    })
  end)
end

--- Create the buffer for a session if it does not exist yet.
--- @param session_id string
--- @param title string|nil title hint from the session list, when available
local function ensure_buffer(session_id, title)
  local entry = state.sessions[session_id]
  if entry and vim.api.nvim_buf_is_valid(entry.buf) then
    entry.session_id = session_id
    entry.title = entry.title or title
    update_name(entry)
    update_winbar(entry)
    if config.options.treesitter then
      treesitter.start(entry.buf)
    end
    return entry
  end

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].swapfile = false
  vim.bo[buf].bufhidden = "hide"
  -- Session views are plugin-owned: keep them out of `:ls` and every buffer
  -- list (bufferline, `:bnext`, ...). The buffer is still fully usable.
  vim.bo[buf].buflisted = false
  vim.bo[buf].filetype = "dshchat"
  if config.options.treesitter then
    treesitter.start(buf)
  end

  entry = entry or {}
  entry.buf = buf
  entry.session_id = session_id
  entry.entries = entry.entries or {}
  entry.status = entry.status or "connecting"
  entry.title = entry.title or title
  state.sessions[session_id] = entry
  update_name(entry)

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
        interactions.stop()
        mux.close()
      end
    end,
  })

  -- The menu can run from another buffer or tab; remembering which view the
  -- user last visited lets it act on that session instead of asking again.
  vim.api.nvim_create_autocmd("BufEnter", {
    buffer = buf,
    callback = function()
      local current = state.sessions[session_id]
      if current and not current.closed then
        mark_focused(current)
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

--- Put the cursor back on the newest line of a view.
---
--- A prompt closes from insert mode and hands focus back to this window with
--- the cursor wherever it was. `render.render` treats a view as scrolled up
--- unless the cursor sits on the last line, so without this the stream appends
--- output below the fold instead of scrolling.
--- @param entry table
local function focus_tail(entry)
  local win, buf = entry.win, entry.buf
  if not (win and vim.api.nvim_win_is_valid(win) and buf and vim.api.nvim_buf_is_valid(buf)) then
    return
  end
  vim.api.nvim_win_set_cursor(win, { vim.api.nvim_buf_line_count(buf), 0 })
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
--- @param opts {title: string|nil}|nil title hint, used until the stream sends one
function M.open(session_id, opts)
  if not session_id then
    M.pick()
    return
  end

  local title = type(opts) == "table" and opts.title or nil
  local entry = ensure_buffer(session_id, title)
  attach_keymaps(session_id)
  show(entry)
  mark_focused(entry)
  attach(session_id)
end

--- Create a session in the current directory's workspace and open it.
--- @param opts {prompt: boolean|nil}|nil
function M.new_session(opts)
  server.context(function(err, ctx)
    if err then
      notify(err, vim.log.levels.ERROR)
      return
    end

    local value, create_err, warning = session.create_in_workspace(ctx, vim.fn.getcwd())
    if not value then
      notify(create_err or "cannot create session", vim.log.levels.ERROR)
      return
    end
    if warning then
      notify(warning, vim.log.levels.WARN)
    end

    M.open(value.sessionId)
    if opts and opts.prompt then
      vim.schedule(function()
        M.prompt(value.sessionId)
      end)
    end
  end)
end

--- Sessions currently offered by the picker, after applying `sessions.scope`
--- and `sessions.include_subagents`.
--- @param items table[]
--- @return table[]
local function scoped(items)
  local choices = config.options.sessions.scope == "all" and items or session.filter_directory(items)
  if config.options.sessions.include_subagents == false then
    choices = session.filter_roots(choices)
  end
  return archive.filter(choices, config.options.sessions.include_archived == true)
end

--- Where this directory is shown to the user, abbreviated.
--- @return string
local function here()
  return vim.fn.fnamemodify(vim.fn.getcwd(), ":~")
end

--- Prompt for the session picker, matching what the list actually contains.
--- @return string
local function picker_prompt()
  if config.options.sessions.scope == "all" then
    -- The rows come from every directory; naming this one would be a lie.
    return "DSH sessions"
  end
  return ("DSH sessions in %s"):format(here())
end

--- Choose a session in this workspace with `vim.ui.select`.
---
--- `on_choice` receives the selected SessionSummary. It is not called when the
--- user cancels, when nothing is listed, or when an empty workspace makes the
--- view create a brand-new session instead.
--- @param on_choice fun(item: table)
function M.pick_session(on_choice)
  server.context(function(err, ctx)
    if err then
      notify(err, vim.log.levels.ERROR)
      return
    end

    -- Deleted sessions are archived, not erased; load the archive set so the
    -- picker matches the Web UI. Fail-open when the stream is unavailable.
    archive.ensure(ctx)

    local items, list_err = session.list(ctx)
    if not items then
      notify(list_err or "cannot list sessions", vim.log.levels.ERROR)
      return
    end

    local choices = scoped(items)
    if #choices == 0 then
      if #items == 0 then
        notify("no sessions yet; creating one")
        M.new_session()
        return
      end
      notify(("no sessions in %s"):format(here()))
      return
    end

    picker.select(choices, on_choice, { prompt = picker_prompt() })
  end)
end

--- Choose a session with `vim.ui.select` and open it.
function M.pick()
  M.pick_session(function(item)
    M.open(item.sessionId, { title = session.title(item) })
  end)
end

--- Send a user message to a session.
--- @param session_id string|nil defaults to the session of the current buffer
--- @param opts {title: string|nil, initial: string|nil}|nil prompt surface options
function M.prompt(session_id, opts)
  session_id = session_id or M.current()
  if not session_id then
    notify("no session in this buffer; run :DshNew or :DshSessions", vim.log.levels.WARN)
    return
  end

  local entry = state.sessions[session_id]
  if not entry then
    return
  end

  opts = opts or {}
  prompt_ui.open({ title = opts.title or "DSH prompt", initial = opts.initial }, function(text)
    -- The prompt window is gone and focus is back here: pin the view to its
    -- newest line so the streamed reply keeps scrolling into view.
    focus_tail(entry)

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
    interactions.stop()
    mux.close()
  end
end

--- Delete (archive) the current session view.
---
--- DSH has no hard delete: `workspace/archiveSession` stops running work,
--- hides the session from Workspace/picker surfaces and keeps its transcript
--- on disk (the Web UI can unarchive it). The view is closed and the session
--- is hidden from this Neovim's pickers immediately.
--- @param session_id string|nil defaults to the session of the current buffer
--- @param opts {skip_confirm: boolean|nil}|nil
function M.delete(session_id, opts)
  session_id = session_id or M.current()
  if not session_id then
    notify("no session in this buffer; run :DshNew or :DshSessions", vim.log.levels.WARN)
    return
  end

  local entry = state.sessions[session_id]
  local title = (entry and entry.title) or session.short_id(session_id)

  local function remove()
    server.context(function(err, ctx)
      if err then
        notify(err, vim.log.levels.ERROR)
        return
      end

      local value, delete_err = workspace.archive_session(ctx, session_id, true)
      if not value then
        notify(delete_err or "cannot delete session", vim.log.levels.ERROR)
        return
      end

      archive.hide(session_id)
      M.close(session_id)
      notify(("deleted session %s (archived)"):format(title))
    end)
  end

  if opts and opts.skip_confirm then
    remove()
    return
  end

  vim.ui.select({ "Cancel", "Delete session" }, {
    prompt = ("Delete session %q? Running work stops and the transcript is archived."):format(title),
  }, function(choice)
    if choice == "Delete session" then
      remove()
    end
  end)
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

--- Session id of the most recently used view that is still open.
---
--- `:DshMenu` can run from a buffer that is not a session view (another tab,
--- a code buffer, the prompt window). The menu falls back to this so skills
--- and commands act on the session the user was just looking at instead of
--- asking them to pick it again.
--- @return string|nil
function M.recent_view()
  local best_id, best_seq
  for session_id, entry in pairs(state.sessions) do
    if not entry.closed and entry.buf and vim.api.nvim_buf_is_valid(entry.buf) then
      local seq = entry.focus_seq or 0
      if not best_seq or seq > best_seq then
        best_id, best_seq = session_id, seq
      end
    end
  end
  return best_id
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
  interactions.stop()
  mux.close()
end

return M
