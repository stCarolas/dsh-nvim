--- Minimal RFC 6455 WebSocket client over `vim.uv`, dependency-free.
---
--- DSH streams live session updates over a WebSocket at `/api/remote.mux`. Neovim
--- has no WebSocket client, so this implements the parts the protocol needs:
--- a client handshake carrying the auth cookie, masked text frames, ping/pong
--- keepalive, fragmentation and close handling.
local M = {}

local bit = require("bit")

local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

local GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
M.GUID = GUID

local OPCODE = {
  continuation = 0x0,
  text = 0x1,
  binary = 0x2,
  close = 0x8,
  ping = 0x9,
  pong = 0xA,
}
M.OPCODE = OPCODE

--- Encode bytes as base64.
--- @param data string
--- @return string
local function base64(data)
  local out = {}
  local length = #data
  local index = 1
  while index <= length do
    local a = data:byte(index) or 0
    local b = data:byte(index + 1)
    local c = data:byte(index + 2)
    local triple = a * 65536 + (b or 0) * 256 + (c or 0)

    local c1 = math.floor(triple / 262144) % 64
    local c2 = math.floor(triple / 4096) % 64
    local c3 = math.floor(triple / 64) % 64
    local c4 = triple % 64

    out[#out + 1] = B64:sub(c1 + 1, c1 + 1)
    out[#out + 1] = B64:sub(c2 + 1, c2 + 1)
    out[#out + 1] = b and B64:sub(c3 + 1, c3 + 1) or "="
    out[#out + 1] = c and B64:sub(c4 + 1, c4 + 1) or "="
    index = index + 3
  end
  return table.concat(out)
end
M.base64 = base64

local function random_bytes(count)
  local out = {}
  for index = 1, count do
    out[index] = string.char(math.random(0, 255))
  end
  return table.concat(out)
end

--- XOR a payload with a 4-byte masking key.
local function apply_mask(payload, key)
  local k1, k2, k3, k4 = key:byte(1, 4)
  local out = {}
  local length = #payload
  for index = 1, length do
    local byte = payload:byte(index)
    local shift = (index - 1) % 4
    local mask = shift == 0 and k1 or shift == 1 and k2 or shift == 2 and k3 or k4
    out[index] = string.char(bit.bxor(byte, mask))
  end
  return table.concat(out)
end

--- Build one client frame. Client frames must be masked.
--- @param opcode number
--- @param payload string|nil
--- @return string
local function encode_frame(opcode, payload)
  payload = payload or ""
  local length = #payload
  local key = random_bytes(4)

  local header = { string.char(bit.bor(0x80, opcode)) }
  if length < 126 then
    header[#header + 1] = string.char(bit.bor(0x80, length))
  elseif length < 65536 then
    header[#header + 1] = string.char(bit.bor(0x80, 126), math.floor(length / 256) % 256, length % 256)
  else
    header[#header + 1] = string.char(
      bit.bor(0x80, 127),
      0, 0, 0, 0,
      math.floor(length / 16777216) % 256,
      math.floor(length / 65536) % 256,
      math.floor(length / 256) % 256,
      length % 256
    )
  end
  header[#header + 1] = key
  header[#header + 1] = apply_mask(payload, key)
  return table.concat(header)
end
M.encode_frame = encode_frame

--- Incremental frame parser. Server frames are normally unmasked, but the
--- masked branch is honoured so the parser never depends on the peer.
local Parser = {}
Parser.__index = Parser

function Parser.new(on_frame)
  return setmetatable({ buffer = "", on_frame = on_frame }, Parser)
end

--- Feed received bytes, dispatching every complete frame.
--- @param data string
function Parser:feed(data)
  self.buffer = self.buffer .. data
  while true do
    if #self.buffer < 2 then
      return
    end

    local b1, b2 = self.buffer:byte(1, 2)
    local fin = bit.band(b1, 0x80) ~= 0
    local opcode = bit.band(b1, 0x0F)
    local masked = bit.band(b2, 0x80) ~= 0
    local length = bit.band(b2, 0x7F)
    local offset = 3

    if length == 126 then
      if #self.buffer < 4 then
        return
      end
      local hi, lo = self.buffer:byte(3, 4)
      length = hi * 256 + lo
      offset = 5
    elseif length == 127 then
      if #self.buffer < 10 then
        return
      end
      length = 0
      for index = 3, 10 do
        length = length * 256 + self.buffer:byte(index)
      end
      offset = 11
    end

    local key
    if masked then
      if #self.buffer < offset + 3 then
        return
      end
      key = self.buffer:sub(offset, offset + 3)
      offset = offset + 4
    end

    if #self.buffer < offset + length - 1 then
      return
    end

    local payload = self.buffer:sub(offset, offset + length - 1)
    self.buffer = self.buffer:sub(offset + length)

    if key then
      payload = apply_mask(payload, key)
    end
    self.on_frame(fin, opcode, payload)
  end
end
M.Parser = Parser

--- Split `http://host:port/...` into host and port.
--- @param url string
--- @return string|nil host
--- @return number|nil port
local function split_url(url)
  local host, port = url:match("^https?://([^/:]+):(%d+)")
  if not host then
    host, port = url:match("^([^/:]+):(%d+)")
  end
  if not host then
    return nil, nil
  end
  return host, tonumber(port)
end
M.split_url = split_url

--- Connect to a DSH Remote stream endpoint.
--- @param opts {url: string, path: string|nil, cookie: string, timeout: number|nil,
---              on_open: fun()|nil, on_message: fun(text: string)|nil,
---              on_close: fun(reason: string|nil)|nil}
--- @return table connection
function M.connect(opts)
  local host, port = split_url(opts.url)
  if not host or not port then
    error("dsh.ws: cannot parse host and port from " .. tostring(opts.url))
  end

  math.randomseed(math.floor(vim.uv.hrtime() % 2147483647))

  local path = opts.path or "/api/remote.mux"
  local conn = {
    open = false,
    closed = false,
    on_open = opts.on_open,
    on_message = opts.on_message,
    on_close = opts.on_close,
  }

  local tcp = vim.uv.new_tcp()
  conn.tcp = tcp

  local handshake = ""
  local fragments = nil
  local fragment_opcode = nil

  local function deliver(opcode, payload)
    if opcode ~= OPCODE.text then
      return
    end
    if not conn.on_message then
      return
    end
    local text = payload
    vim.schedule(function()
      if not conn.closed then
        conn.on_message(text)
      end
    end)
  end

  local parser = Parser.new(function(fin, opcode, payload)
    if opcode == OPCODE.ping then
      pcall(function()
        tcp:write(encode_frame(OPCODE.pong, payload))
      end)
      return
    end
    if opcode == OPCODE.pong then
      return
    end
    if opcode == OPCODE.close then
      conn:close("server closed")
      return
    end
    if opcode == OPCODE.text or opcode == OPCODE.binary then
      if fin then
        deliver(opcode, payload)
      else
        fragments = { payload }
        fragment_opcode = opcode
      end
      return
    end
    if opcode == OPCODE.continuation and fragments then
      fragments[#fragments + 1] = payload
      if fin then
        local text = table.concat(fragments)
        fragments = nil
        deliver(fragment_opcode, text)
        fragment_opcode = nil
      end
    end
  end)

  function conn:send_text(text)
    if self.closed or not self.open then
      return nil, "websocket is not open"
    end
    local ok, err = pcall(function()
      tcp:write(encode_frame(OPCODE.text, text))
    end)
    if not ok then
      return nil, tostring(err)
    end
    return true
  end

  --- Close the socket. Idempotent; notifies `on_close` once.
  --- @param reason string|nil
  function conn:close(reason)
    if self.closed then
      return
    end
    self.closed = true
    self.open = false
    if tcp and not tcp:is_closing() then
      pcall(function()
        tcp:write(encode_frame(OPCODE.close, string.char(0x03, 0xE8)))
      end)
      pcall(function()
        tcp:read_stop()
      end)
      pcall(function()
        tcp:close()
      end)
    end
    local callback = self.on_close
    if callback then
      vim.schedule(function()
        callback(reason)
      end)
    end
  end

  tcp:connect(host, port, function(err)
    if err then
      conn:close("connect failed: " .. tostring(err))
      return
    end

    local request = table.concat({
      "GET " .. path .. " HTTP/1.1",
      "Host: " .. host .. ":" .. tostring(port),
      "Upgrade: websocket",
      "Connection: Upgrade",
      "Sec-WebSocket-Key: " .. base64(random_bytes(16)),
      "Sec-WebSocket-Version: 13",
      "Cookie: " .. opts.cookie,
      "",
      "",
    }, "\r\n")

    pcall(function()
      tcp:write(request)
    end)

    tcp:read_start(function(read_err, data)
      if read_err then
        conn:close("read failed: " .. tostring(read_err))
        return
      end
      if not data then
        conn:close("connection closed")
        return
      end

      if not conn.open then
        handshake = handshake .. data
        local header_end = handshake:find("\r\n\r\n", 1, true)
        if not header_end then
          return
        end
        local head = handshake:sub(1, header_end - 1)
        local remainder = handshake:sub(header_end + 4)
        handshake = ""

        local status = head:match("^HTTP/1%.1%s+(%d+)")
        if status ~= "101" then
          local reason = vim.trim(remainder):gsub("%s+", " ")
          conn:close("websocket upgrade rejected: HTTP " .. tostring(status) .. (reason ~= "" and (" " .. reason) or ""))
          return
        end

        conn.open = true
        if conn.on_open then
          local callback = conn.on_open
          vim.schedule(function()
            if not conn.closed then
              callback()
            end
          end)
        end

        if remainder ~= "" then
          parser:feed(remainder)
        end
        return
      end

      parser:feed(data)
    end)
  end)

  local timeout = opts.timeout or 10000
  vim.defer_fn(function()
    if not conn.open and not conn.closed then
      conn:close("websocket handshake timed out")
    end
  end, timeout)

  return conn
end

return M
