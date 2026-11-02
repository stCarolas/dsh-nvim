--- `:checkhealth dsh` provider.
local M = {}

function M.check()
  vim.health.start("dsh.nvim")

  if vim.fn.has("nvim-0.10") == 1 then
    vim.health.ok("Neovim " .. tostring(vim.version()))
  else
    vim.health.error("Neovim 0.10 or newer is required (vim.system, vim.uv)")
  end

  if vim.fn.executable("curl") == 1 then
    vim.health.ok("curl found (HTTP transport)")
  else
    vim.health.error("curl not found; the plugin cannot talk to DSH")
  end

  local config = require("dsh.config").options
  if config.cmd then
    local executable = config.cmd[1]
    if vim.fn.executable(executable) == 1 then
      vim.health.ok("launch command: " .. table.concat(config.cmd, " "))
    else
      vim.health.error("launch command not executable: " .. executable)
    end
  elseif vim.fn.executable("dsh") == 1 then
    vim.health.ok("`dsh` found on PATH")
  elseif vim.fn.executable("npx") == 1 then
    vim.health.warn("`dsh` not on PATH; will fall back to `npx --yes @deepseek-ai/dsh`")
  else
    vim.health.error("neither `dsh` nor `npx` is available; install DeepSeek Harness")
  end

  local describe = require("dsh.server").describe()
  if describe.running then
    vim.health.ok("connected to " .. tostring(describe.url) .. " (pid " .. tostring(describe.pid) .. ")")
  else
    vim.health.info("no server started yet; it boots on first use")
  end
  if describe.error then
    vim.health.warn("last error: " .. tostring(describe.error))
  end

  if not config.stream.enabled then
    vim.health.info("live updates disabled (stream.enabled = false); history is read over HTTP")
  elseif require("dsh.mux").is_connected() then
    vim.health.ok("websocket connected (/api/remote.mux)")
  else
    vim.health.info("websocket opens with the first session view")
  end

  if not config.interactions.enabled then
    vim.health.info("human interactions disabled (interactions.enabled = false)")
  elseif require("dsh.interactions").is_ready() then
    vim.health.ok("question and approval prompts are ready ($events stream)")
  else
    vim.health.info("question and approval prompts open with the first session view")
  end

  vim.health.start("dsh.nvim transports")
  vim.health.info("HTTP  POST /api/<namespace>/<method> for unary calls (list, create, page, prompt, cancel, workspace)")
  vim.health.info("WS    /api/remote.mux logical streams for session/follow and $events")
  vim.health.info("DSH rejects unary methods on the stream carrier, so both transports are required")
end

return M
