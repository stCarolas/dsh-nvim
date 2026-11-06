# dsh.nvim

A Neovim front-end for [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness) (`dsh`):
browse the sessions of the directory you are working in, read their history in a buffer,
send prompts — with the agent's reply streaming into the buffer token by token over DSH's
WebSocket, rendered as Markdown — and answer the agent when it asks you to choose.

```
# Fix the flaky retry test
▌ You
fix the flaky retry test
▌ Assistant
The retry loop copies the backoff value before the jitter is applied.

- jitter is applied per attempt
- the timer is not cleared on abort

  function retry(fn, opts)
    return attempt(fn, { ...opts, jitter: true })
  end

  ⚙ read(path=src/retry.ts)
    1  export function retry(fn, opts) {
    … 42 more lines
```

Assistant output is rendered as Markdown: headings, bullet and numbered lists, task
checkboxes, blockquotes, rules and inline emphasis are styled, fenced code is indented and
syntax-highlighted with treesitter when that language's parser is installed, and fence
languages appear as virtual text (never in the buffer contents). Tool results are kept
verbatim as a code block tabulated one level under the call (`DshCodeBlock`), truncated to
`tool_output_lines` rows with the remainder counted — failed output keeps its error highlight.
Prompts you type are echoed verbatim, so Markdown in your own text is left alone. When the
agent needs a decision, the plugin asks through `vim.ui.select` / `vim.ui.input`, so your
picker plugin handles it.

## Requirements

| | |
|---|---|
| Neovim | 0.10+ (`vim.uv`, `vim.system`, `vim.json`) |
| `curl` | HTTP transport for unary calls |
| `dsh` | on `PATH`, or `npx` for the `@deepseek-ai/dsh@latest` fallback |

The plugin **boots and owns its own `dsh web` process** (`--port 0`, so it never collides with a
server you already run) and stops it when Neovim exits. Set `shared = true` to use one detached
server for every Neovim instance instead, or `url` to attach to a server you manage — see
[Shared server](#shared-server).

## Shared server

DSH serves many clients from one process, so the plugin can share a single `dsh web` across
Neovim instances:

```lua
require("dsh").setup({ shared = true })
```

The first instance boots the server detached and records its URL and launch token in
`stdpath("run")/dsh-nvim/server.json` (directory `0700`, file `0600`); later instances attach
to it and mint their own peer cookie. The server outlives the Neovim that started it, and
`:DshStop` in any instance stops it for everyone. `shared_dir` moves the registry and log file.

To use a server you manage yourself (systemd, tmux, the web UI), pass its printed URL including
the token:

```lua
require("dsh").setup({ url = "http://127.0.0.1:3080/?token=…" })
```

The plugin then only connects: it never starts or stops that server, and `auto_start = false`
still allows the attach.

Warm the server up from a startup script so the first session opens instantly:

```sh
# Exits 0 once the server is ready, 1 if it failed; needs shared = true or url.
nvim --headless -c 'DshWarmup!' >/dev/null 2>&1
```

Without `!`, `:DshWarmup` waits for readiness, reports the URL, and leaves Neovim running (a
private server cannot be warmed up, because it stops with the Neovim that started it).

Every instance sees the same DSH sessions (subject to `sessions.scope`). Human interactions are
forwarded to every answering client, so with the web UI or several Neovim instances connected,
each one shows the same question or approval and the first answer settles it; set
`interactions.enabled = false` in instances that should not prompt.

## Install

With `lazy.nvim`:

```lua
{
  "you/dsh-nvim",
  config = function()
    require("dsh").setup({
      chat = { open_in = "tab" },   -- one tab page per session (default: "split")
      keymaps = { global = { new_session = "<leader>dn", pick = "<leader>ds" } },
    })
  end,
}
```

Or manually, then `:helptags doc` and `:help dsh`.

## Commands

| Command | Does |
|---|---|
| `:Dsh` | open the current session, or pick one in this directory |
| `:DshNew` | create a session in this directory's workspace and open it |
| `:DshNew!` | same, then open the prompt |
| `:DshSessions` | pick a session rooted at the current directory |
| `:DshMenu` | nested menu: new session, open session, skills, commands |
| `:DshPrompt` | prompt for the current session |
| `:DshRefresh` | re-open the stream and re-read history |
| `:DshCancel` | cancel the running turn |
| `:DshClose` | close the session view |
| `:DshDelete` | delete (archive) the current session; `:DshDelete!` skips the confirmation |
| `:DshWarmup` | boot/attach the server and wait; `:DshWarmup!` exits 0 when ready, 1 on failure |
| `:DshStop` | stop the DSH server (shared included), or detach from an attached one |
| `:DshStatus` | server, WebSocket and question status |
| `:checkhealth dsh` | diagnostics |

## Menu

`:DshMenu` (or a `keymaps.global.menu` mapping) opens a nested `vim.ui.select` menu:

- **new session** — create a session in this directory's workspace and open it.
- **open session…** — pick one of this workspace's sessions, the same filtered list as
  `:DshSessions`.
- **dsh skills…** — list the session's human-invocable skills (`skills/list`). Choosing one
  opens the prompt prefilled with `/skill-name `; type the task and send it, and DSH injects
  the skill instructions on that prompt.
- **dsh commands…** — list the session's slash commands (`commands/list`). A command that
  advertises input asks for it with `vim.ui.input`; the line then runs through
  `commands/execute` and its result text is notified.

Skills and commands are session-scoped. The menu resolves its target session when it opens: the
view at the cursor, or the most recently used view still open in another tab or window. Only
when no view is open at all does it offer the session picker first, open the chosen session, and
continue with the submenu. `<Esc>` cancels any level.

## Chat buffer keys

| Key | Action |
|---|---|
| `<CR>` | open the prompt |
| `R` | re-open the stream |
| `<localleader>s` | pick another session |
| `<C-c>` | cancel the running turn |
| `q` | close the view |

In the floating prompt popup: `<C-s>` sends, `<CR>` sends (normal mode), and `<Esc>` or `q`
cancels. Enter inserts newlines in insert mode, so multi-line prompts work.

`prompt.open_in = "split"` types the prompt in a scratch buffer in its own window instead of
the popup — handy for long prompts. `<C-s>` sends from either mode and normal-mode `q`
cancels; `<Esc>` keeps its normal buffer meaning (leaving insert mode), so the window is only
dismissed with `q`. Closing the window (`:q`) cancels too.

Closing the prompt returns to the session view in normal mode. After a send the cursor is put
on the newest line, so the reply keeps scrolling into view as the stream appends it.

Each session view is a scratch buffer named after the DSH session title, e.g.
`dsh://Fix the flaky retry test`. Until DSH titles the session the name falls back to
`dsh://<short id>`; the name follows retitles, and two sessions with the same title get the
session id appended (`dsh://Fix the flaky retry test (1a2b3c4d)`). The `dsh://` scheme keeps
Neovim from treating the title as a file path relative to the cwd.

Session views and prompt buffers are **unlisted**: they never appear in `:ls`, `:bnext` /
`:bp`, or bufferline-style lists. You switch sessions with `:Dsh`, `:DshSessions` and the menu.

## Questions and approvals

While a session view is open the plugin also answers the human decisions DSH forwards to
connected clients, so a blocking tool call never waits for another DSH client to pick it up:

- **`ask_user_question`** — one picker per question. Options show their description; a
  `Other…` entry accepts free text; a multi-select question keeps asking (chosen rows are
  marked `✓` and toggle off) until `Done selecting`. `Skip this question` sends DSH's blank
  answer; `<Esc>` skips too, or finishes a multi-select with what is already chosen. Several
  questions in one call are asked in order and submitted as one answer batch.
- **Tool approvals** — `Allow once` / `Reject` for an action that needs permission.
  Rejecting (including `<Esc>`) fails closed, the same choice the Web approval panel makes.

Both use `vim.ui.select` and `vim.ui.input`, so telescope, fzf-lua, snacks.nvim,
dressing.nvim or any other `vim.ui` provider applies unchanged. A question's long detail (a
plan under review, for example) is put in a notification, because a picker prompt is one
line.

The prompts ride the same WebSocket as the live session: they become available with the
first session view and stop with the last one. A question asked while no view is open is
delivered by DSH when the next view connects. A timed question is claimed while its prompt is
open, so the model does not time out mid-decision; an answer given after DSH released the
wait arrives as a follow-up turn. `interactions.questions`, `interactions.approvals` and
`interactions.enabled` turn the behaviour off.

## Tree-sitter

The `dshchat` filetype has a bundled Tree-sitter grammar in `tree-sitter-dshchat/`; the
generated `src/parser.c` is committed, so only a C compiler is needed to build it. Queries
live in `queries/dshchat/` (`highlights.scm`, `folds.scm`). The grammar is line oriented: the
first text line after a header is typed `user_prompt` / `assistant_message_header`, later
message lines stay `text`, and each tool call groups its indented output.

With nvim-treesitter installed the parser is registered automatically, so this builds it
from the plugin checkout — no network access, and the `tree-sitter` CLI is only needed to
regenerate `grammar.js`:

```vim
:TSInstall dshchat
```

Without nvim-treesitter, build the parser onto the plugin runtimepath instead:

```sh
scripts/build_parser.sh      # writes parser/dshchat.so
```

The renderer's extmarks still own the styling; Tree-sitter adds structure for folds over
rendered code and tool-output blocks, incremental selection and `:InspectTree`, and its
highlight captures reuse the same `Dsh…` groups. `treesitter = false` turns the wiring off.

## Configuration

```lua
require("dsh").setup({
  cmd = nil,                  -- nil => {"dsh"} if present, else {"npx","--yes","@deepseek-ai/dsh@latest"}
  port = 0,                   -- 0 => OS-assigned
  cwd = nil,                  -- server working directory (default: Neovim's cwd)
  auto_start = true,
  url = nil,                  -- attach to a running server (printed URL incl. token)
  shared = false,             -- share one detached server across Neovim instances
  shared_dir = nil,           -- registry/log directory (default: stdpath("run")/dsh-nvim)
  startup_timeout = 120000,   -- first launch may install the dsh profile
  request_timeout = 60000,
  max_messages = 200,         -- messages in the follow snapshot / history page
  sessions = {
    order = "oldest",         -- "oldest" | "newest" | "none"
    scope = "cwd",            -- "cwd" | "all"
    include_subagents = true, -- false => list only root sessions
    include_archived = false, -- true => list deleted/archived sessions too
  },
  tool_output_lines = 8,      -- tool output rows shown as a code block
  stream = {
    enabled = true,           -- false => read history once per open/refresh over HTTP
    render_interval = 60,     -- coalesce chunks into at most one render per N ms
    reconnect_attempts = 5,
    reconnect_delay = 1500,
  },
  show_reasoning = false,
  treesitter = true,          -- register/start the bundled dshchat parser
  markdown = {
    enabled = true,           -- render agent output as Markdown
    code_highlight = true,    -- treesitter highlighting inside fenced code
    show_language = true,     -- fence language as virtual text
    max_highlight_lines = 300, -- skip highlighting huge blocks
  },
  chat = {
    open_in = "split",        -- "split" | "tab" | "current"
    split = "vertical",       -- orientation when open_in = "split"
    width = 100,
    height = 20,
    show_title = true,        -- write the session title as the first buffer line
  },
  prompt = {
    open_in = "float",        -- "float" (popup) | "split" (scratch buffer window)
    split = "horizontal",     -- orientation when open_in = "split"
    width = 80,               -- columns for "vertical"
    height = 10,              -- rows for "horizontal"
  },
  interactions = {
    enabled = true,           -- answer forwarded questions and approvals
    questions = true,         -- ask_user_question tool calls
    approvals = true,         -- permission prompts for sensitive tools
  },
  notifications = true,
})
```

Set `chat.open_in = "tab"` to give every session its own tab page instead of a split
window. Reopening a session focuses its existing tab, and closing the view closes the tab it
owns. The old spelling `chat.split = "tab"` still works.

`chat.show_title = false` omits the `# Title` line at the top of the session buffer; the
winbar keeps showing the session title while the session is idle.

The winbar reads `dsh · <title> · <status>`. While a turn runs (`streaming`), it replaces the
title with the newest assistant message, clipped to the window width; when the turn settles
(`idle`) the title returns. The buffer name keeps the session title in both states.

`prompt.open_in = "split"` puts prompt entry in a separate window backed by a
`dsh://prompt/<n>` scratch buffer (`filetype=dsh-prompt`, so a `FileType` autocmd can add
spell checking and the like) instead of the floating popup. `prompt.split` picks the
orientation, and `prompt.width` / `prompt.height` size the window. Both keys normalize to
`"float"` / `"horizontal"` with a warning when misspelled, and the popup stays the default.

Sessions are scoped to the directory Neovim runs in. `:DshNew` resolves (or registers) the DSH
workspace for that directory and creates the session inside it, so new sessions appear under the
same project in the DSH web UI, and `:DshSessions` lists only sessions whose cwd is that
directory — including symlinked spellings of it. `sessions.order` controls how that list is
ordered: `"oldest"` (default), `"newest"`, or `"none"` for the server order. Set
`sessions.scope = "all"` to list every session on the server again; the picker prompt drops the
directory name in that mode. Any other value is rejected with a warning and falls back to
`"cwd"`, so a typo cannot silently hide every session. `sessions.include_subagents = false`
hides sessions spawned by subagents (`parentSessionId`/`origin = "subagent"`), leaving only root
sessions in `:DshSessions`, `:Dsh`, and the menu's picker; the default keeps listing them.

`:DshDelete` deletes the current session view. DSH has no hard delete, so this is its archive
operation: running work is stopped, the session disappears from the Web UI sidebar and from
this plugin's pickers, and the transcript stays on disk (unarchive it in the Web UI to get it
back). Pickers hide archived sessions by default; set `sessions.include_archived = true` to
list them again. `:DshDelete!` skips the confirmation prompt.

If DSH creates the session but then fails to attach it to the workspace, the error carries the
new session id: the plugin opens that session and warns instead of creating a second one. Only
errors that happen before creation — or a deployment without a workspace registry — fall back to
a plain `cwd` session.

## How it works

DSH's web UI is not a documented REST API, so this plugin drives the real protocols the UI uses.

**1. Auth — launch-token exchange.** `dsh web --port 0 --no-open` prints
`dsh web: http://127.0.0.1:<port>/?token=<launch-token>`. That token is printed only in that
line (shared mode records it in the private registry so other instances can attach), so the
plugin scrapes it from stdout and calls `GET /connect?token=…&interactions=none`, which answers
with a signed, authority-bound cookie. Socket peers are minted separately with
`interactions=answer`, because only such a peer may receive and answer human decisions.

**2. Unary calls — HTTP.** `POST /api/<namespace>/<method>` with the cookie:

```json
{"type":"client-request","rpcId":"nvim-1","method":"session/create",
 "payload":{"args":{"request":{"workspaceId":"…"}}}}
```

Used for `session/list`, `session/create`, `session/page`, `session/prompt`,
`session/cancel`, and `workspace/create`. `workspace/create` is an idempotent lookup-or-register
call: it returns the workspace whose directory is the current canonical cwd, creating that
project registration if it does not exist yet. `session/create` then names the workspace, which
is what accounts the new session to it. `session/list` has no server-side cwd filter, so the
picker filters the returned summaries client-side after canonicalizing both paths with
`realpath`.

**3. Live updates — one multiplexed WebSocket.** `/api/remote.mux` carries logical streams as
JSON text frames:

```
client -> {"type":"open","streamId":"nvim-1","endpoint":"session/follow",
           "payload":{"args":{"request":{"address":{"kind":"session","sessionId":"…"},
                                         "assistantStream":true,"maxMessages":200}}}}
server -> {"type":"item","streamId":"nvim-1","value":{…}}
          {"type":"end"|"error","streamId":"nvim-1",…}
```

The follow stream opens with a snapshot (records, cursor, projections, in-flight assistant
stream) and then delivers durable events plus process-local `assistant-stream` frames whose
`text-delta` chunks are rendered as they arrive.

Neovim has no WebSocket client, so `lua/dsh/ws.lua` implements the RFC 6455 client over `vim.uv`
(handshake, masked frames, fragmentation, ping/pong). That ping handling is not optional: DSH
pings every 2s and terminates a peer after two missed pongs.

Two protocol facts shape the design:

- DSH rejects unary methods on the stream carrier (`gateway/signature-invalid`), so HTTP cannot be
  removed entirely.
- An authenticated peer may own only one socket (a second upgrade gets `409`), and DSH **disposes
  the peer when its socket closes** — a reuse of that cookie answers `401`. The plugin therefore
  keeps two credentials: a long-lived peer cookie for HTTP, and a freshly minted, disposable peer
  for each socket. All session views share one multiplexed connection.

**4. Human decisions — forwarded events.** The same socket also opens the Gateway-owned
`$events` stream (payload `{args:{}}`). Its first item is
`{"type":"ready","clientId":…,"host":{…}}`; afterwards DSH forwards
`{"type":"waterfall","event":"user-questions/request"|"approval/request","eventId":…,
"agentId":…,"request":{…}}` and `{"type":"cancel","eventId":…}` items. The plugin presents
questions and approvals with `vim.ui.select` / `vim.ui.input` and answers with a unary RPC:

```
POST /api/$events/result
{"type":"client-request","rpcId":"…","method":"$events/result",
 "payload":{"args":{"clientId":"…","eventId":"…",
                    "outcome":{"kind":"result","value":{…}}}}}
```

DSH matches that result to the peer that owns the event stream, so the plugin sends the
socket's own cookie (`mux.credential()`), never the long-lived HTTP one. An answer decided
while the socket is down is held and flushed when the next `$events` generation announces
itself; DSH redelivers pending requests to every new event stream. A `user-questions` result
is `{answers = [{id, selected = {labels…}, custom?}]}`; an approval result is one of DSH's
`allowed-once` / `rejected` outcome strings.

**5. Rendering.** History arrives as raw session events. `lua/dsh/surface.lua` reduces them to the
model-visible surface — dropping system prompts, runtime context and inbox bookkeeping, and
honouring `surfaceOp = replace` so compaction summaries replace the messages they shadow.

Assistant text then goes through `lua/dsh/markdown.lua`, a small Markdown renderer that produces
lines plus column-precise spans applied as extmarks: headings, lists, task boxes, quotes, rules,
inline emphasis and links are styled, and fenced code is indented, grouped and highlighted with
treesitter when that language's parser is present. Span styling sits on a higher extmark priority
than each line's base group, so a bold word inside a heading keeps both. Prompts you type bypass
the renderer and stay literal.

## Limitations

- DSH is in developer preview (`0.2.1-rc.2` at the time of writing) and states there will be
  breaking changes. Endpoint and frame shapes are isolated in `http.lua`, `session.lua`,
  `workspace.lua`, `mux.lua`, `follow.lua` and `interactions.lua` to keep updates cheap.
- Unary calls still use HTTP because DSH forbids them on the WebSocket carrier.
- One snapshot window is loaded (`max_messages`); older pages are not paginated in the UI yet.
- Markdown tables are shown as source text, and code highlighting depends on the language's
  treesitter parser being installed.
- Approvals offer allow-once and reject only; permission presets and approval policies are not
  editable from Neovim. Attachments, model selection and queue editing are not exposed yet.
- A question's choices are rendered as plain picker rows, so option lists are text, not the Web
  card's Markdown preview. Plan-review detail appears in a notification.
- The cookie is bound to the process that minted it, which is why the plugin owns its server.

## Development

```sh
nvim --headless -l scripts/spec.lua               # rendering/UI specs, no server needed
nvim --headless -l scripts/scope_spec.lua         # cwd workspace scoping, with stubbed transports
nvim --headless -l scripts/ui_spec.lua            # tab vs split placement, with stubbed transports
nvim --headless -l scripts/interactions_spec.lua  # questions/approvals via scripted vim.ui
nvim --headless -l scripts/menu_spec.lua          # nested vim.ui menu, skills and commands
nvim --headless -l scripts/delete_spec.lua        # session deletion (archive), with stubbed transports
nvim --headless -l scripts/server_spec.lua        # attach/shared server discovery, with stubbed transports
nvim --headless -l scripts/treesitter_spec.lua    # dshchat grammar, queries and wiring
nvim --headless -l scripts/ws_spec.lua            # WebSocket transport: handshake, streams, heartbeat
nvim --headless -l scripts/smoke.lua              # boots dsh web and drives the full UI path
```

`treesitter_spec.lua` compiles `tree-sitter-dshchat/src/parser.c` to a temporary library when
`parser/dshchat.so` is not already on the runtimepath. `scripts/build_parser.sh` builds that
library in the checkout for interactive use.

`smoke.lua` points `$DSH_HOME` at a temporary directory, so a run cannot touch the projects,
sessions or profile in your real DSH home; the directory is deleted when the run ends.

## License

MIT
