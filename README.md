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
  ↳ 1  export function retry(fn, opts) {
  ↳ … 42 more lines
```

Assistant output is rendered as Markdown: headings, bullet and numbered lists, task
checkboxes, blockquotes, rules and inline emphasis are styled, fenced code is indented and
syntax-highlighted with treesitter when that language's parser is installed, and fence
languages appear as virtual text (never in the buffer contents). Prompts you type are echoed
verbatim, so Markdown in your own text is left alone. When the agent needs a decision, the
plugin asks through `vim.ui.select` / `vim.ui.input`, so your picker plugin handles it.

## Requirements

| | |
|---|---|
| Neovim | 0.10+ (`vim.uv`, `vim.system`, `vim.json`) |
| `curl` | HTTP transport for unary calls |
| `dsh` | on `PATH`, or `npx` for the `@deepseek-ai/dsh` fallback |

The plugin **boots and owns its own `dsh web` process** (`--port 0`, so it never collides with a
server you already run) and stops it when Neovim exits.

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
| `:DshNew!` | same, then open the prompt popup |
| `:DshSessions` | pick a session rooted at the current directory |
| `:DshPrompt` | prompt popup for the current session |
| `:DshRefresh` | re-open the stream and re-read history |
| `:DshCancel` | cancel the running turn |
| `:DshClose` | close the session view |
| `:DshStop` | stop the `dsh web` process the plugin started |
| `:DshStatus` | server, WebSocket and question status |
| `:checkhealth dsh` | diagnostics |

## Chat buffer keys

| Key | Action |
|---|---|
| `<CR>` | open the prompt popup |
| `R` | re-open the stream |
| `<localleader>s` | pick another session |
| `<C-c>` | cancel the running turn |
| `q` | close the view |

In the popup: `<C-s>` sends, `<CR>` sends (normal mode), `<Esc>` cancels.
Enter inserts newlines in insert mode, so multi-line prompts work.

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

## Configuration

```lua
require("dsh").setup({
  cmd = nil,                  -- nil => {"dsh"} if present, else {"npx","--yes","@deepseek-ai/dsh"}
  port = 0,                   -- 0 => OS-assigned
  cwd = nil,                  -- server working directory (default: Neovim's cwd)
  auto_start = true,
  startup_timeout = 120000,   -- first launch may install the dsh profile
  request_timeout = 60000,
  max_messages = 200,         -- messages in the follow snapshot / history page
  sessions = { order = "oldest", scope = "cwd" }, -- scope: "cwd" | "all"
  tool_output_lines = 8,      -- tool output rendered before truncation
  stream = {
    enabled = true,           -- false => read history once per open/refresh over HTTP
    render_interval = 60,     -- coalesce chunks into at most one render per N ms
    reconnect_attempts = 5,
    reconnect_delay = 1500,
  },
  show_reasoning = false,
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

Sessions are scoped to the directory Neovim runs in. `:DshNew` resolves (or registers) the DSH
workspace for that directory and creates the session inside it, so new sessions appear under the
same project in the DSH web UI, and `:DshSessions` lists only sessions whose cwd is that
directory — including symlinked spellings of it. `sessions.order` controls how that list is
ordered: `"oldest"` (default), `"newest"`, or `"none"` for the server order. Set
`sessions.scope = "all"` to list every session on the server again; the picker prompt drops the
directory name in that mode. Any other value is rejected with a warning and falls back to
`"cwd"`, so a typo cannot silently hide every session.

If DSH creates the session but then fails to attach it to the workspace, the error carries the
new session id: the plugin opens that session and warns instead of creating a second one. Only
errors that happen before creation — or a deployment without a workspace registry — fall back to
a plain `cwd` session.

## How it works

DSH's web UI is not a documented REST API, so this plugin drives the real protocols the UI uses.

**1. Auth — launch-token exchange.** `dsh web --port 0 --no-open` prints
`dsh web: http://127.0.0.1:<port>/?token=<launch-token>`. That token exists only in that line, so
the plugin scrapes it from stdout and calls `GET /connect?token=…&interactions=none`, which
answers with a signed, authority-bound cookie. Socket peers are minted separately with
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
nvim --headless -l scripts/ws_spec.lua            # WebSocket transport: handshake, streams, heartbeat
nvim --headless -l scripts/smoke.lua              # boots dsh web and drives the full UI path
```

`smoke.lua` points `$DSH_HOME` at a temporary directory, so a run cannot touch the projects,
sessions or profile in your real DSH home; the directory is deleted when the run ends.

## License

MIT
