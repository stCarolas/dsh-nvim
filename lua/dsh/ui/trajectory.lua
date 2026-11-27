--- Trajectory view: one read-only buffer, in its own tab, per session.
---
--- `:DshTrajectory` shows the `dsh.trajectory` projection — turns, steps,
--- prompts, injected context, tool calls, compactions and usage — kept live by
--- the same `session/follow` stream the chat view uses. It follows the session
--- independently from the chat view, so the trajectory tab can be opened,
--- refreshed and closed without disturbing a conversation.
---
--- The buffer is deliberately a buffer: read-only text in its own tab page, with
--- its tree expressed as indentation. That gives `'foldmethod' = "indent"`
--- (`zi`, `zM`, `za`, …), the usual yank and search, and no plugin-specific
--- rendering to learn. Two keys act on the row under the cursor: <CR> expands
--- its detail body, `R` re-reads history.
local M = {}

local config = require("dsh.config")
local follow = require("dsh.follow")
local render = require("dsh.render")
local server = require("dsh.server")
local session = require("dsh.session")
local trajectory = require("dsh.trajectory")

local namespace = vim.api.nvim_create_namespace("dsh-trajectory")

--- Below the Markdown span priority: every line has exactly one group.
local BASE_PRIORITY = 4096

--- @type table<string, table>
local state = { views = {} }

local function notify(message, level)
  vim.notify("dsh: " .. message, level or vim.log.levels.INFO)
end

--- Name for a trajectory buffer. The scheme keeps the name from being resolved
--- as a file path relative to the working directory.
--- @param session_id string
--- @return string
local function buffer_name(session_id)
  return "dsh-trajectory://" .. session.short_id(session_id)
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

--- The winbar of one trajectory window.
--- @param entry table
local function update_winbar(entry)
  local win = entry.win
  if not (win and vim.api.nvim_win_is_valid(win)) then
    return
  end
  local title = type(entry.title) == "string" and vim.trim(entry.title) ~= "" and vim.trim(entry.title) or "untitled"
  local status = type(entry.status) == "string" and entry.status or ""
  local text = (" dsh · trajectory · %s%s "):format(
    render.literal(title),
    status ~= "" and (" · " .. render.literal(status)) or ""
  )
  -- `'winbar'` is evaluated like `'statusline'`; a rejected assignment must not
  -- abort a stream update.
  pcall(function()
    vim.wo[win].winbar = text
  end)
end

--- Window options that make the tree readable and foldable.
--- @param win integer
local function setup_window(win)
  vim.wo[win].wrap = false
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  -- Indentation is the tree, so it is also the fold structure. Folds start
  -- disabled: `zi` turns them on, then `zM`, `zR` and `za` work as usual.
  vim.wo[win].foldmethod = "indent"
  vim.wo[win].foldlevel = 99
  vim.wo[win].foldenable = false
end

--- Paint the rows the projection produced into the buffer.
--- @param entry table
local function paint(entry)
  local buf = entry.buf
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end

  local rendered = entry.rendered
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, rendered.lines)
  vim.api.nvim_buf_clear_namespace(buf, namespace, 0, -1)

  -- One group per line, coalescing runs so a long detail body is one extmark.
  local hl = rendered.hl
  local index = 1
  while index <= #rendered.lines do
    local group = hl[index]
    if group and group ~= "" then
      local finish = index
      while finish + 1 <= #hl and hl[finish + 1] == group do
        finish = finish + 1
      end
      vim.api.nvim_buf_set_extmark(buf, namespace, index - 1, 0, {
        end_row = finish,
        end_col = 0,
        hl_group = group,
        priority = BASE_PRIORITY,
      })
      index = finish + 1
    else
      index = index + 1
    end
  end

  vim.bo[buf].modifiable = false
end

--- Rebuild the projection and repaint the buffer.
--- @param entry table
local function rebuild(entry)
  if entry.closed or not vim.api.nvim_buf_is_valid(entry.buf) then
    return
  end

  local built = trajectory.build(entry.records, {
    session_id = entry.session_id,
    header = entry.header,
    expanded = entry.expanded,
    detail_lines = config.options.trajectory.detail_lines,
    preview_chars = config.options.trajectory.preview_chars,
  })
  entry.built = built
  entry.title = built.title or entry.title
  entry.rendered = trajectory.lines(built.rows, { expanded = entry.expanded })

  -- Keep the cursor where it was; a view that has never been shown opens at the
  -- tail, which is the live end of the trajectory (like the web UI).
  local win = entry.win
  local showing = win and vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == entry.buf
  local row = showing and vim.api.nvim_win_get_cursor(win)[1] or nil

  paint(entry)

  if showing then
    local target = entry.shown and row or #entry.rendered.lines
    target = math.min(math.max(target or 1, 1), math.max(#entry.rendered.lines, 1))
    pcall(vim.api.nvim_win_set_cursor, win, { target, 0 })
  end
  update_winbar(entry)
end

--- One-shot history read, used when live streaming is turned off or when the
--- stream cannot be opened.
--- @param entry table
--- @param ctx {url: string, cookie: string}
--- @return boolean loaded
local function load_once(entry, ctx)
  local item = session.find(ctx, entry.session_id)
  local cursor = item and item.projections and item.projections.asOfSeq or nil
  if not cursor then
    cursor = session.cursor(ctx, entry.session_id)
  end
  if not cursor then
    entry.status = "no history"
    update_winbar(entry)
    return false
  end

  -- A subagent Session is only readable through its parent address, which the
  -- summary carries.
  entry.address = session.address(item) or entry.address or session.address(entry.session_id)
  local page, err = session.page(ctx, entry.address, cursor, config.options.max_messages)
  if not page then
    entry.status = "error"
    update_winbar(entry)
    notify(err or "cannot read history", vim.log.levels.ERROR)
    return false
  end

  entry.records = page.records or {}
  entry.status = item and item.running and "running" or "idle"
  rebuild(entry)
  return true
end

--- What `session/follow` should address for this view.
---
--- A plain session is followed by its id, so the request keeps the shape the
--- chat view uses. A subagent session needs the parent-qualified address.
--- @param entry table
--- @return string|table
local function stream_target(entry)
  local address = entry.address
  if type(address) == "table" and address.kind == "subagent" then
    return address
  end
  return entry.session_id
end

--- Subscribe a view to its session stream.
--- @param entry table
local function attach(entry)
  if entry.attaching then
    return
  end
  entry.attaching = true

  server.context(function(err, ctx)
    entry.attaching = false
    local current = state.views[entry.session_id]
    if not current or current.closed then
      return
    end
    if err then
      current.status = "offline"
      update_winbar(current)
      notify(err, vim.log.levels.ERROR)
      return
    end

    if not config.options.trajectory.follow or not config.options.stream.enabled then
      load_once(current, ctx)
      return
    end

    --- Show the history over HTTP when the stream cannot be used.
    ---
    --- `start` reports a synchronous failure and then also finds the handle
    --- empty, so the read is requested once per attach attempt.
    local function history_only(reason)
      if current.history_requested then
        return
      end
      current.history_requested = true
      if load_once(current, ctx) then
        current.status = "offline"
        update_winbar(current)
      end
      if reason then
        notify(("live updates unavailable: %s"):format(reason), vim.log.levels.WARN)
      end
    end

    local function start()
      if current.follow then
        current.follow.detach()
      end
      current.status = "connecting"
      update_winbar(current)

      current.follow = follow.attach(ctx, stream_target(current), {
        on_update = function(follow_state)
          local view = state.views[entry.session_id]
          if not view or view.closed then
            return
          end
          view.records = follow_state.records
          view.header = follow_state.header or view.header
          view.title = follow_state.title or view.title
          if follow_state.status then
            view.status = follow_state.status
          end
          rebuild(view)
        end,
        on_status = function(status, message)
          local view = state.views[entry.session_id]
          if not view or view.closed then
            return
          end
          view.status = status
          update_winbar(view)

          if status ~= "error" and status ~= "disconnected" then
            return
          end

          -- A subagent Session rejects its own id and asks for the durable
          -- parent address; resolve it once and open the stream again.
          if
            status == "error"
            and not view.address_retried
            and type(message) == "string"
            and message:find("agent%-busy")
          then
            view.address_retried = true
            local item = session.find(ctx, view.session_id)
            local address = session.address(item)
            if type(address) == "table" and address.kind == "subagent" then
              view.address = address
              start()
              return
            end
          end

          if status == "error" then
            history_only(message)
            return
          end

          -- `R` re-attaches; a trajectory view is an inspection surface, so it
          -- says it went stale instead of retrying in the background.
          notify(message or "live updates stopped", vim.log.levels.WARN)
        end,
      })

      if not current.follow then
        history_only("cannot open the session stream")
      end
    end

    start()
  end)
end

--- Buffer-local keys of a trajectory view.
--- @param session_id string
local function attach_keymaps(session_id)
  local entry = state.views[session_id]
  if not entry then
    return
  end
  local keys = config.options.keymaps

  local function map(lhs, callback, description)
    if type(lhs) ~= "string" or lhs == "" then
      return
    end
    vim.keymap.set("n", lhs, callback, {
      buffer = entry.buf,
      nowait = true,
      silent = true,
      desc = description,
    })
  end

  map("<CR>", function()
    M.toggle(session_id)
  end, "DSH: expand or collapse the trajectory row")
  map(keys.refresh, function()
    M.refresh(session_id)
  end, "DSH: refresh the trajectory")
  map(keys.close, function()
    M.close(session_id)
  end, "DSH: close the trajectory view")
end

--- The trajectory view whose buffer is the current buffer, if any.
--- @return table|nil
local function view_at_cursor()
  local buf = vim.api.nvim_get_current_buf()
  for _, entry in pairs(state.views) do
    if not entry.closed and entry.buf == buf then
      return entry
    end
  end
  return nil
end

--- Create the view state and buffer for a session, or reuse the open one.
--- @param session_id string
--- @param title string|nil
--- @param item table|nil SessionSummary, when the caller already has it
--- @return table
local function ensure_buffer(session_id, title, item)
  local entry = state.views[session_id]
  if entry and vim.api.nvim_buf_is_valid(entry.buf) then
    entry.title = entry.title or title
    entry.address = session.address(item) or entry.address
    return entry
  end

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].swapfile = false
  vim.bo[buf].bufhidden = "hide"
  -- An inspection surface, not a document: keep it out of `:ls` and buffer
  -- lists, like a session buffer.
  vim.bo[buf].buflisted = false
  vim.bo[buf].filetype = "dshtrajectory"

  entry = {
    buf = buf,
    session_id = session_id,
    address = session.address(item) or session.address(session_id),
    title = title,
    status = "connecting",
    records = {},
    expanded = {},
  }
  state.views[session_id] = entry

  local name = buffer_name(session_id)
  local suffix = 1
  while name_taken(name, buf) do
    suffix = suffix + 1
    name = ("%s-%d"):format(buffer_name(session_id), suffix)
  end
  pcall(vim.api.nvim_buf_set_name, buf, name)

  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = buf,
    once = true,
    callback = function()
      local current = state.views[session_id]
      if current then
        current.closed = true
        if current.follow then
          current.follow.detach()
          current.follow = nil
        end
        state.views[session_id] = nil
      end
    end,
  })

  return entry
end

--- Show the view in its own tab page, or focus the window that already has it.
--- @param entry table
local function show(entry)
  local win = entry.win
  if win and vim.api.nvim_win_is_valid(win) then
    local tabpage = vim.api.nvim_win_get_tabpage(win)
    if vim.api.nvim_get_current_tabpage() ~= tabpage then
      vim.api.nvim_set_current_tabpage(tabpage)
    end
    vim.api.nvim_set_current_win(win)
    if vim.api.nvim_win_get_buf(win) ~= entry.buf then
      -- The window was reused for another buffer while the view was hidden.
      pcall(vim.api.nvim_win_set_buf, win, entry.buf)
    end
    setup_window(win)
    entry.shown = true
    update_winbar(entry)
    return
  end

  -- `:tab sbuffer` shows the buffer in a new tab directly, leaving no empty
  -- buffer behind.
  vim.cmd("tab sbuffer " .. entry.buf)
  entry.win = vim.api.nvim_get_current_win()
  setup_window(entry.win)
  entry.shown = true
  attach_keymaps(entry.session_id)
end

--- Open (or focus) the trajectory of a session.
--- @param opts {session_id: string|nil, title: string|nil, item: table|nil}|nil
--- `item` is the SessionSummary when the caller has one: it carries the durable
--- parent address a subagent session must be read through.
function M.open(opts)
  opts = type(opts) == "table" and opts or {}
  local session_id = opts.session_id

  if not session_id then
    -- The view under the cursor, then the most recently used one, mirroring
    -- how `:DshInterrupt` and the menu resolve their target.
    local chat = require("dsh.ui.chat")
    session_id = chat.current() or chat.recent_view()
  end

  if not session_id then
    M.pick()
    return
  end

  local entry = ensure_buffer(session_id, opts.title, opts.item)
  show(entry)
  -- Paint the empty tree now: an empty buffer would look like a failure while
  -- the stream's opening snapshot is on its way.
  rebuild(entry)
  attach(entry)
  return entry
end

--- Open the trajectory of the session named by `prefix`.
---
--- A full id opens straight away. Anything else is matched against the ids and
--- the short ids the view shows (the first 8 characters after `session-`) of the
--- sessions the server knows, and must match exactly one — a prefix never
--- silently shows the wrong trajectory.
--- @param prefix string|nil
function M.open_session(prefix)
  if type(prefix) ~= "string" or prefix == "" then
    M.open()
    return
  end

  if state.views[prefix] or prefix:match("^session%-[0-9a-f%-]+$") then
    M.open({ session_id = prefix })
    return
  end

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

    local matches = {}
    for _, item in ipairs(items) do
      local id = type(item) == "table" and item.sessionId or nil
      if type(id) == "string" then
        local short = session.short_id(id)
        if id:sub(1, #prefix) == prefix or (short and short:sub(1, #prefix) == prefix) then
          matches[#matches + 1] = item
        end
      end
    end

    if #matches == 0 then
      notify(("no session matches %q"):format(prefix), vim.log.levels.WARN)
      return
    end
    if #matches > 1 then
      local ids = {}
      for _, item in ipairs(matches) do
        ids[#ids + 1] = item.sessionId
      end
      table.sort(ids)
      notify(("session %q matches %d sessions: %s"):format(prefix, #matches, table.concat(ids, ", ")), vim.log.levels.WARN)
      return
    end
    M.open({ session_id = matches[1].sessionId, title = session.title(matches[1]), item = matches[1] })
  end)
end

--- Pick a session, then open its trajectory.
function M.pick()
  require("dsh.ui.chat").pick_session(function(item)
    M.open({ session_id = item.sessionId, title = session.title(item), item = item })
  end, {
    on_created = function(session_id)
      M.open({ session_id = session_id })
    end,
  })
end

--- Expand or collapse the detail of the row under the cursor.
--- @param session_id string|nil defaults to the view in this buffer
function M.toggle(session_id)
  local entry = (session_id and state.views[session_id]) or view_at_cursor()
  if not entry then
    notify("no trajectory view in this buffer", vim.log.levels.WARN)
    return
  end
  if not (entry.built and entry.rendered) then
    return
  end

  local win = vim.api.nvim_get_current_win()
  if vim.api.nvim_win_get_buf(win) ~= entry.buf then
    return
  end

  local line = vim.api.nvim_win_get_cursor(win)[1]
  local index = entry.rendered.owner[line]
  local row = index and entry.built.rows[index]
  if not (row and row.expandable and row.key) then
    return
  end

  entry.expanded[row.key] = not entry.expanded[row.key] or nil
  rebuild(entry)

  local target = entry.rendered.row_line[index]
  if target and vim.api.nvim_win_is_valid(win) then
    pcall(vim.api.nvim_win_set_cursor, win, { target, 0 })
  end
end

--- Re-read history: re-open the stream, or the page when streaming is off.
--- @param session_id string|nil defaults to the view in this buffer
function M.refresh(session_id)
  local entry = (session_id and state.views[session_id]) or view_at_cursor()
  if not entry then
    notify("no trajectory view in this buffer", vim.log.levels.WARN)
    return
  end

  if entry.follow then
    entry.follow.detach()
    entry.follow = nil
  end
  entry.history_requested = nil
  entry.status = "connecting"
  update_winbar(entry)
  attach(entry)
end

--- Close a trajectory view and its tab page.
--- @param session_id string|nil defaults to the view in this buffer
function M.close(session_id)
  local entry = (session_id and state.views[session_id]) or view_at_cursor()
  if not entry then
    notify("no trajectory view to close", vim.log.levels.WARN)
    return
  end

  local win, buf = entry.win, entry.buf
  entry.closed = true
  if entry.follow then
    entry.follow.detach()
    entry.follow = nil
  end
  state.views[entry.session_id] = nil

  if win and vim.api.nvim_win_is_valid(win) and #vim.api.nvim_list_wins() > 1 then
    pcall(vim.api.nvim_win_close, win, true)
  end
  if buf and vim.api.nvim_buf_is_valid(buf) then
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
  end
end

--- Number of open trajectory views.
--- @return integer
function M.view_count()
  local count = 0
  for _, entry in pairs(state.views) do
    if not entry.closed and entry.buf and vim.api.nvim_buf_is_valid(entry.buf) then
      count = count + 1
    end
  end
  return count
end

--- Detach every trajectory view; used when Neovim exits.
function M.shutdown()
  for session_id, entry in pairs(state.views) do
    entry.closed = true
    if entry.follow then
      entry.follow.detach()
      entry.follow = nil
    end
    state.views[session_id] = nil
  end
end

return M
