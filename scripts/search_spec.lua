-- Transcript search specs. No server, no Telescope, no buffers on disk.
-- Run with: nvim --headless -l scripts/search_spec.lua
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h:h")
vim.opt.rtp:append(root)

local config = require("dsh.config")
config.setup({ notifications = false })

local transcript = require("dsh.transcript")
local search = require("dsh.ui.search")

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

local function kinds(entries)
  local list = {}
  for _, entry in ipairs(entries) do
    list[#list + 1] = entry.kind
  end
  return table.concat(list, ",")
end

local function find(entries, kind, needle)
  for _, entry in ipairs(entries) do
    if entry.kind == kind and (needle == nil or entry.text:find(needle, 1, true)) then
      return entry
    end
  end
  return nil
end

local sample = {
  "# Fix the flaky retry test",
  "",
  "▌ You",
  "fix the flaky retry test",
  "and a second prompt line",
  "",
  "▌ Assistant",
  "The retry loop copies the backoff value before the jitter is applied.",
  "Second line of the reply.",
  "",
  "  ⚙ read(path=src/retry.ts)",
  "    1  export function retry(fn, opts) {",
  "    … 42 more lines",
  "",
  "✖ something failed",
  "",
  "▌ You",
  "second question",
  "",
  "▌ Assistant",
  "(no text)",
  "",
  "· a notice",
}

local buf = vim.api.nvim_create_buf(false, true)
vim.bo[buf].filetype = "dshchat"
vim.api.nvim_buf_set_lines(buf, 0, -1, false, sample)
vim.api.nvim_set_current_buf(buf)

-- 1. Every message is one entry, in transcript order.
local all = transcript.entries(buf)
check("transcript is detected", transcript.available(buf) == true)
check("one entry per message", #all == 8, tostring(#all))
check(
  "entries follow transcript order",
  kinds(all) == "title,prompt,reply,tool,error,prompt,reply,notice",
  kinds(all)
)
check("title is stripped of its marker", find(all, "title") and find(all, "title").text == "Fix the flaky retry test", find(all, "title") and find(all, "title").text)
check(
  "prompt text spans its lines",
  find(all, "prompt") and find(all, "prompt").text == "fix the flaky retry test\nand a second prompt line",
  find(all, "prompt") and vim.inspect(find(all, "prompt").text)
)
check(
  "reply text spans its lines",
  find(all, "reply") and find(all, "reply").text:find("Second line of the reply", 1, true) ~= nil,
  find(all, "reply") and vim.inspect(find(all, "reply").text)
)
check(
  "tool entries keep the call and its output",
  find(all, "tool") and find(all, "tool").text:find("read(path=src/retry.ts)", 1, true) and find(all, "tool").text:find("export function retry", 1, true),
  find(all, "tool") and vim.inspect(find(all, "tool").text)
)
check("entries carry the header line", find(all, "prompt") and find(all, "prompt").lnum == 2, find(all, "prompt") and tostring(find(all, "prompt").lnum))
check("tool entry points at the call", find(all, "tool") and find(all, "tool").lnum == 10, find(all, "tool") and tostring(find(all, "tool").lnum))

-- 2. Scopes narrow the rows without changing the text.
local prompts = transcript.entries(buf, "prompts")
check("prompts scope keeps prompts only", kinds(prompts) == "prompt,prompt", kinds(prompts))
check("second prompt is found", prompts[2] and prompts[2].text == "second question", prompts[2] and prompts[2].text)

local replies = transcript.entries(buf, "replies")
check("replies scope keeps replies only", kinds(replies) == "reply,reply", kinds(replies))
check("empty replies keep the renderer placeholder", replies[2] and replies[2].text == "(no text)", replies[2] and replies[2].text)

local tools = transcript.entries(buf, "tools")
check("tools scope keeps tool calls only", kinds(tools) == "tool", kinds(tools))

local notes = transcript.entries(buf, "notes")
check("notes scope keeps errors and notices", kinds(notes) == "error,notice", kinds(notes))
check("notes text is stripped of its marker", notes[1] and notes[1].text == "something failed", notes[1] and notes[1].text)

check("unknown scope falls back to everything", #transcript.entries(buf, "nonsense") == 8)

-- 3. Rows are labelled and fuzzy-matchable over the whole message.
local rows = search.rows(buf, "all")
check("rows carry a display label", rows[1] and rows[1].display:find("title", 1, true) == 1, rows[1] and rows[1].display)
check("prompt rows start with You", rows[2] and rows[2].display:find("You", 1, true) == 1, rows[2] and rows[2].display)
local label, ordinal = search.format({ kind = "reply", text = "line one\nline two" })
check("rows flatten the message for matching", ordinal:find("line one line two", 1, true) ~= nil, ordinal)
check("rows keep the text in the label", label:find("line one", 1, true) ~= nil, label)
local long_label = search.format({ kind = "reply", text = string.rep("x", 300) })[1]
check("long snippets are truncated", vim.fn.strchars(long_label) < 130, tostring(vim.fn.strchars(long_label)))

-- 4. Jumping moves the cursor to the message.
local entry = find(rows, "tool")
search.jump(entry)
check("jump lands on the tool call", vim.api.nvim_win_get_cursor(0)[1] == 11, tostring(vim.api.nvim_win_get_cursor(0)[1]))
local reply = find(rows, "reply")
search.jump(reply)
check("jump lands on the reply header", vim.api.nvim_win_get_cursor(0)[1] == 7, tostring(vim.api.nvim_win_get_cursor(0)[1]))

-- 5. The session buffer is found from other buffers.
local other = vim.api.nvim_create_buf(false, true)
vim.api.nvim_set_current_buf(other)
check("search finds the session buffer from elsewhere", search.target_bufnr() == buf, tostring(search.target_bufnr()))

-- 6. Buffers without a transcript produce nothing.
local empty = vim.api.nvim_create_buf(false, true)
vim.bo[empty].filetype = "dshchat"
vim.api.nvim_buf_set_lines(empty, 0, -1, false, { "", "" })
check("an empty transcript has no entries", #transcript.entries(empty) == 0)
check("a non-session buffer is declined", transcript.available(other) == false)

print(("\n=== %d checks, %d failed ==="):format(checks, failures))
vim.cmd("cquit " .. (failures > 0 and 1 or 0))
