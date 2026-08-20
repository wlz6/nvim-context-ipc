local actions = require("nvim_context_ipc.actions")
local claude = require("nvim_context_ipc.claude")
local codex = require("nvim_context_ipc.codex")
local codex_client = require("nvim_context_ipc.codex_client")
local context = require("nvim_context_ipc.context")
local jupyter = require("nvim_context_ipc.jupyter")
local util = require("nvim_context_ipc.util")

local M = {}
local state = { configured = false, opts = {}, timer = nil }

local defaults = {
  auto_start = true,
  include_buffer_text = false,
  max_buffer_bytes = 1024 * 1024,
  permissions = {
    restrict_to_workspace = true,
    allow_file_writes = true,
    allow_open_file = true,
    allow_save_document = true,
    allow_open_diff = true,
    allow_close_tab = true,
    allow_execute_code = false,
  },
  codex = {
    enabled = true,
    auto_start = true,
    socket_path = nil,
  },
  claude = {
    enabled = true,
    auto_start = true,
    port_min = 10000,
    port_max = 65535,
    lock_dir = nil,
    expose_internal_tools = false,
    python = "python3",
  },
}

local function publish()
  context.snapshot()
  claude.publish()
  if state.opts.codex.mode == "router" then codex_client.publish() end
end

local function schedule_publish()
  if state.timer then return end
  state.timer = vim.defer_fn(function()
    state.timer = nil
    publish()
  end, 80)
end

local function command(name, callback, opts)
  vim.api.nvim_create_user_command(name, callback, vim.tbl_extend("force", { force = true }, opts or {}))
end

local function start_services()
  if state.opts.claude.enabled and state.opts.claude.auto_start then
    local ok, err = claude.start(state.opts.claude)
    if not ok then util.notify("Claude IDE context is unavailable: " .. tostring(err), vim.log.levels.WARN) end
  end
  if state.opts.codex.enabled and state.opts.codex.auto_start then
    local adapter = state.opts.codex.mode == "router" and codex_client or codex
    local ok, err = adapter.start(state.opts.codex)
    if not ok then util.notify("Codex IDE context is unavailable: " .. tostring(err), vim.log.levels.WARN) end
  end
end

function M.setup(opts)
  opts = opts or {}
  if state.configured and next(opts) == nil then
    return M
  end
  if state.configured then
    M.stop()
    state.configured = false
  end
  state.opts = vim.tbl_deep_extend("force", vim.deepcopy(defaults), opts)
  context.setup(state.opts)
  actions.setup(state.opts, util.notify)
  if state.configured then
    publish()
    return M
  end
  state.configured = true

  local group = vim.api.nvim_create_augroup("nvim_context_ipc", { clear = true })
  vim.api.nvim_create_autocmd({ "BufEnter", "BufWinEnter", "BufWritePost", "CursorMoved", "CursorMovedI", "TextChanged", "TextChangedI", "DiagnosticChanged", "ModeChanged", "TabEnter", "BufDelete" }, {
    group = group,
    callback = schedule_publish,
  })
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = group,
    callback = function()
      M.stop()
    end,
  })

  command("NvimContextStart", function()
    local ok, err = claude.start(state.opts.claude)
    if not ok then util.notify("Claude: " .. tostring(err), vim.log.levels.ERROR) end
    local adapter = state.opts.codex.mode == "router" and codex_client or codex
    ok, err = adapter.start(state.opts.codex)
    if not ok then util.notify("Codex: " .. tostring(err), vim.log.levels.ERROR) end
  end, { desc = "Start nvim-context-ipc providers" })
  command("NvimContextStop", M.stop, { desc = "Stop nvim-context-ipc providers" })
  command("NvimContextPublish", publish, { desc = "Publish the current Neovim context" })
  command("NvimContextStatus", function()
    vim.notify(util.json_encode(M.status()), vim.log.levels.INFO, { title = "nvim-context-ipc" })
  end, { desc = "Show nvim-context-ipc status" })
  command("NvimContextDump", function()
    vim.notify(util.json_encode(context.snapshot({ include_buffer_text = true })), vim.log.levels.INFO, { title = "nvim-context-ipc" })
  end, { desc = "Show the current context snapshot" })
  command("NvimContextAcceptDiff", function(params)
    local id = params.args ~= "" and params.args or nil
    local diffs = actions.pending_diffs()
    if not id then for key in pairs(diffs) do id = key break end end
    local ok, err = actions.accept_diff(id)
    if not ok then util.notify(tostring(err), vim.log.levels.ERROR) end
  end, { nargs = "?", desc = "Accept a pending Claude diff" })
  command("NvimContextRejectDiff", function(params)
    local id = params.args ~= "" and params.args or nil
    local diffs = actions.pending_diffs()
    if not id then for key in pairs(diffs) do id = key break end end
    if not actions.reject_diff(id) then util.notify("No matching diff", vim.log.levels.WARN) end
  end, { nargs = "?", desc = "Reject a pending Claude diff" })
  command("NvimContextAtMention", function(params)
    local start_line, end_line = params.fargs[1], params.fargs[2]
    claude.at_mentioned(start_line, end_line)
  end, { nargs = "*", desc = "Send the active range to Claude Code" })

  if state.opts.auto_start then start_services() end
  schedule_publish()
  return M
end

function M.is_configured()
  return state.configured
end

function M.stop()
  if state.timer then state.timer:stop(); state.timer = nil end
  claude.stop()
  codex.stop()
  codex_client.stop()
  jupyter.stop()
end

function M.status()
  local codex_status = state.opts.codex.mode == "router" and codex_client.status() or codex.status()
  return { claude = claude.status(), codex = codex_status, snapshot = context.snapshot() }
end

function M.snapshot(options)
  return context.snapshot(options)
end

return M
