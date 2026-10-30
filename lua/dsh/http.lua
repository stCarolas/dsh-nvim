--- HTTP transport for the DSH web API.
---
--- DSH exposes a JSON RPC over plain HTTP:
---   POST /api/<namespace>/<method>
---   Content-Type: application/json
---   Cookie: <cookie minted by GET /connect>
---   {"type":"client-request","rpcId":"…","method":"<namespace>/<method>",
---    "payload":{"args":{…}}}
--- answered with
---   {"type":"server-response","rpcId":"…","result":{"ok":true,"value":…}}
---
--- Authentication is a launch-token exchange: `GET /connect?token=<token>` answers
--- with a signed, authority-bound session cookie. The token lives only in the URL
--- printed by `dsh web`.
local M = {}

local json = vim.json

local rpc_seq = 0

--- Monotonic correlation id for one request.
local function next_rpc_id()
  rpc_seq = rpc_seq + 1
  return ("nvim-%d-%d"):format(vim.uv.os_getpid(), rpc_seq)
end

--- Run curl, returning stdout on success.
--- @param args string[] curl arguments
--- @param opts {body: string|nil, timeout: number|nil}
--- @return string|nil stdout
--- @return string|nil error
local function curl(args, opts)
  local timeout = opts.timeout or 60000
  local cmd = {
    "curl",
    "--silent",
    "--show-error",
    "--max-time",
    tostring(math.max(1, math.ceil(timeout / 1000))),
  }
  vim.list_extend(cmd, args)

  local ok, proc = pcall(vim.system, cmd, { stdin = opts.body, text = true })
  if not ok then
    return nil, "cannot run curl: " .. tostring(proc)
  end

  local done = proc:wait(timeout + 5000)
  if done.code ~= 0 then
    local err = (done.stderr or ""):gsub("%s+$", "")
    if err == "" then
      err = "curl exited with code " .. tostring(done.code)
    end
    return nil, err
  end
  return done.stdout or ""
end

--- Exchange a launch token for a session cookie.
--- @param base_url string e.g. "http://127.0.0.1:3080"
--- @param token string launch token from the `dsh web` URL
--- @param timeout number|nil
--- @return string|nil cookie in `name=value` form
--- @return string|nil error
function M.connect(base_url, token, timeout)
  local url = ("%s/connect?token=%s&interactions=none"):format(base_url:gsub("/+$", ""), token)
  local out, err = curl({
    "--dump-header",
    "-",
    "--output",
    vim.fn.has("win32") == 1 and "NUL" or "/dev/null",
    url,
  }, { timeout = timeout })
  if not out then
    return nil, err
  end

  local cookie = out:match("[Ss]et%-[Cc]ookie:%s*([^;\r\n]+)")
  if not cookie then
    return nil, "no session cookie returned; the launch token is probably stale"
  end
  return vim.trim(cookie)
end

--- Call one Remote method.
--- @param ctx {url: string, cookie: string}
--- @param endpoint string "<namespace>/<method>"
--- @param args table|nil method arguments (the `args` object)
--- @param timeout number|nil
--- @return any|nil value
--- @return string|nil error
function M.rpc(ctx, endpoint, args, timeout)
  local body = json.encode({
    type = "client-request",
    rpcId = next_rpc_id(),
    method = endpoint,
    payload = { args = args or vim.empty_dict() },
  })

  local out, err = curl({
    "--request",
    "POST",
    "--header",
    "Content-Type: application/json",
    "--header",
    "Cookie: " .. ctx.cookie,
    "--data-binary",
    "@-",
    ctx.url .. "/api/" .. endpoint,
  }, { body = body, timeout = timeout })
  if not out then
    return nil, err
  end

  local ok, decoded = pcall(json.decode, out)
  if not ok or type(decoded) ~= "table" then
    return nil, "malformed response: " .. out:sub(1, 200)
  end

  local result = decoded.result
  if type(result) ~= "table" then
    return nil, "response carried no result"
  end
  if not result.ok then
    local e = result.error or {}
    local message = e.message or "request failed"
    if e.code then
      message = e.code .. ": " .. message
    end
    return nil, message
  end

  return result.value
end

return M
