# dsh.nvim

A Neovim front-end for [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness) (`dsh`):
browse sessions, read their history in a buffer, and send prompts — with the agent's
reply streaming into the buffer token by token over DSH's WebSocket, rendered as Markdown.

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
verbatim, so Markdown in your own text is left alone.

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
| `:Dsh` | open the current session, or pick one |
| `:DshNew` | create a session rooted at the current directory and open it |
| `:DshNew!` | same, then open the prompt popup |
| `:DshSessions` | pick a session with `vim.ui.select` |
| `:DshPrompt` | prompt popup for the current session |
| `:DshRefresh` | re-open the stream and re-read history |
| `:DshCancel` | cancel the running turn |
| `:DshClose` | close the session view |
| `:DshStop` | stop the `dsh web` process the plugin started |
| `:DshStatus` | server + WebSocket status |
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
  sessions = { order = "oldest" }, -- "oldest" | "newest" | "none" (server order)
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
  notifications = true,
})
```

Set `chat.open_in = "tab"` to give every session its own tab page instead of a split
window. Reopening a session focuses its existing tab, and closing the view closes the tab it
owns. The old spelling `chat.split = "tab"` still works.

## How it works

DSH's web UI is not a documented REST API, so this plugin drives the real protocols the UI uses.

**1. Auth — launch-token exchange.** `dsh web --port 0 --no-open` prints
`dsh web: http://127.0.0.1:<port>/?token=<launch-token>`. That token exists only in that line, so
the plugin scrapes it from stdout and calls `GET /connect?token=…&interactions=none`, which
answers with a signed, authority-bound cookie.

**2. Unary calls — HTTP.** `POST /api/<namespace>/<method>` with the cookie:

```json
{"type":"client-request","rpcId":"nvim-1","method":"session/create",
 "payload":{"args":{"request":{"cwd":"/work/project"}}}}
```

Used for `session/list`, `session/create`, `session/page`, `session/prompt`, `session/cancel`.

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

**4. Rendering.** History arrives as raw session events. `lua/dsh/surface.lua` reduces them to the
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
  breaking changes. Endpoint and frame shapes are isolated in `http.lua`, `session.lua`, `mux.lua`
  and `follow.lua` to keep updates cheap.
- Unary calls still use HTTP because DSH forbids them on the WebSocket carrier.
- One snapshot window is loaded (`max_messages`); older pages are not paginated in the UI yet.
- Markdown tables are shown as source text, and code highlighting depends on the language's
  treesitter parser being installed.
- Approvals, attachments, model selection and queue editing are not exposed yet.
- The cookie is bound to the process that minted it, which is why the plugin owns its server.

## Development

```sh
nvim --headless -l scripts/spec.lua      # rendering/UI specs, no server needed
nvim --headless -l scripts/ui_spec.lua   # tab vs split placement, with stubbed transports
nvim --headless -l scripts/ws_spec.lua   # WebSocket transport: handshake, streams, heartbeat
nvim --headless -l scripts/smoke.lua     # boots dsh web and drives the full UI path
```

## License

MIT
