--- Command registration and process cleanup.
if vim.g.loaded_dsh_nvim == 1 then
  return
end
vim.g.loaded_dsh_nvim = 1

local function dsh()
  return require("dsh")
end

vim.api.nvim_create_user_command("Dsh", function()
  dsh().open()
end, { desc = "DSH: open or pick a session in this directory" })

vim.api.nvim_create_user_command("DshNew", function(command)
  dsh().new_session({ prompt = command.bang })
end, { bang = true, desc = "DSH: create a session in this directory's workspace (bang: prompt immediately)" })

vim.api.nvim_create_user_command("DshNextChat", function()
  dsh().next_chat()
end, { desc = "DSH: next open session view; from elsewhere, new session + prompt" })

vim.api.nvim_create_user_command("DshSessions", function()
  dsh().pick()
end, { desc = "DSH: pick a session in this directory" })

vim.api.nvim_create_user_command("DshMenu", function()
  dsh().menu()
end, { desc = "DSH: open the action menu (sessions, skills, commands)" })

vim.api.nvim_create_user_command("DshPrompt", function()
  dsh().prompt()
end, { desc = "DSH: send a prompt to the current session" })

vim.api.nvim_create_user_command("DshRefresh", function()
  dsh().refresh()
end, { desc = "DSH: refresh the current session history" })

vim.api.nvim_create_user_command("DshCancel", function()
  dsh().cancel()
end, { desc = "DSH: cancel the running turn" })

vim.api.nvim_create_user_command("DshInterrupt", function()
  dsh().interrupt()
end, { desc = "DSH: interrupt the running turn of the session in view" })

vim.api.nvim_create_user_command("DshClose", function()
  dsh().close()
end, { desc = "DSH: close the current session view" })

vim.api.nvim_create_user_command("DshDelete", function(command)
  dsh().delete(command.bang)
end, { bang = true, desc = "DSH: delete (archive) the current session; ! skips confirmation" })

vim.api.nvim_create_user_command("DshWarmup", function(command)
  dsh().warmup(command.bang)
end, { bang = true, desc = "DSH: ensure the server is ready (bang: exit 0/1 for scripts)" })

vim.api.nvim_create_user_command("DshStop", function()
  dsh().stop()
end, { desc = "DSH: stop the DSH server (detach when attached)" })

vim.api.nvim_create_user_command("DshStatus", function()
  local status = dsh().status()
  if status.running then
    local liveness
    if status.server_live == false then
      liveness = "server not responding"
    elseif status.server_live == nil then
      liveness = "server liveness unknown"
    else
      liveness = "server live"
    end
    local details = status.mode or "connected"
    if status.pid then
      details = details .. ", pid " .. tostring(status.pid)
    end
    vim.notify(("dsh: %s (%s; %s); websocket %s; questions %s; %d view%s"):format(
      tostring(status.url),
      details,
      liveness,
      status.websocket and "connected" or "disconnected",
      status.interactions and "ready" or "unavailable",
      status.views,
      status.views == 1 and "" or "s"
    ))
  else
    local reason = status.starting and "starting" or status.error
    vim.notify("dsh: not connected" .. (reason and (": " .. reason) or ""))
  end
end, { desc = "DSH: show connection status" })

local group = vim.api.nvim_create_augroup("dsh-nvim", { clear = true })

vim.api.nvim_create_autocmd("VimLeavePre", {
  group = group,
  callback = function()
    require("dsh.ui.chat").shutdown()
    -- Without `force`, a shared or attached server keeps running for the
    -- other Neovim instances; a private one is stopped as before.
    require("dsh.server").stop()
  end,
})
