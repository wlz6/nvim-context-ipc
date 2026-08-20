if vim.g.loaded_nvim_context_ipc then
  return
end
vim.g.loaded_nvim_context_ipc = true

vim.schedule(function()
  local module = require("nvim_context_ipc")
  if not module.is_configured() then module.setup() end
end)
