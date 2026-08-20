local actions = require("nvim_context_ipc.actions")
local context = require("nvim_context_ipc.context")
local transport = require("nvim_context_ipc.transport")
local util = require("nvim_context_ipc.util")

local M = {}
local state = {
  opts = {},
  client = nil,
  retry_timer = nil,
  stopped = true,
  ide_id = nil,
  latest_snapshot = nil,
}

local function default_socket_path()
  if vim.fn.has("win32") == 1 then return [[\\.\pipe\dsh-ide-ipc]] end
  return util.normalize_path("~/.cache/nvim-context-ipc/dsh.sock")
end

local function response(client, message, ok, result, error_message)
  local value = {
    type = "response",
    id = message.id or message.requestId,
    ok = ok == true,
  }
  if ok then value.result = result else value.error = tostring(error_message or result or "request failed") end
  client:send(value, function()
    -- dsh owns the long-lived connection. A deferred diff must keep it open
    -- until the user saves or rejects the proposal.
    if value.id ~= nil and not client.keep_alive then client:close() end
  end)
end

local function action_response(client, message, name, args)
  local callback_called = false
  local callback = function(ok, result)
    if callback_called or client.closed then return end
    callback_called = true
    client.pending = nil
    response(client, message, ok, result, ok and nil or result)
  end

  local call_ok, result_ok, result = pcall(function()
    return actions.invoke(name, args, callback)
  end)
  if not call_ok then return response(client, message, false, nil, result_ok) end
  if not result_ok then return response(client, message, false, nil, result) end
  if type(result) == "table" and result.deferred then
    client.pending = result
    return
  end
  callback_called = true
  response(client, message, true, result)
end

local function handle_message(client, message)
  if type(message) ~= "table" then return end
  -- Registration/update acknowledgements are responses from the dsh server,
  -- not requests for the editor to handle.
  if message.type == "response" or message.type == "registered" then return end
  local method = message.method
  local params = type(message.params) == "table" and message.params or {}
  if method == "ping" then
    return response(client, message, true, { protocolVersion = 1, provider = "dsh", ideId = state.ide_id })
  end
  if method == "context" then
    local ok, result = pcall(context.snapshot, { include_buffer_text = params.include_buffer_text == true })
    if not ok then return response(client, message, false, nil, result) end
    return response(client, message, true, result)
  end
  if method == "action" or method == "invoke" then
    local name = params.name or params.action
    if type(name) ~= "string" or name == "" then
      return response(client, message, false, nil, "action name is required")
    end
    return action_response(client, message, name, params.arguments or params.args or {})
  end
  if message.id then response(client, message, false, nil, "method not found: " .. tostring(method)) end
end

local function cancel_retry()
  if state.retry_timer then
    state.retry_timer:stop()
    state.retry_timer = nil
  end
end

local function schedule_retry()
  if state.stopped or state.retry_timer then return end
  state.retry_timer = vim.defer_fn(function()
    state.retry_timer = nil
    if not state.stopped then M.start(state.opts) end
  end, state.opts.reconnect_delay_ms or 1000)
end

local function current_snapshot()
  local snapshot = context.snapshot({ include_buffer_text = state.opts.publish_buffer_text ~= false })
  state.latest_snapshot = snapshot
  return snapshot
end

local function register(client)
  local snapshot = current_snapshot()
  state.ide_id = state.opts.ide_id or ("nvim:" .. tostring(snapshot.nvimPid or vim.fn.getpid()))
  local ok, err = client:send({
    type = "register",
    id = util.uuid(),
    protocolVersion = 1,
    ideId = state.ide_id,
    ideType = "nvim",
    ideName = state.opts.ide_name or "Neovim",
    clientVersion = "nvim-context-ipc",
    workspaceRoots = snapshot.workspaceFolders or {},
    context = snapshot,
    capabilities = { "context", "openFile", "saveDocument", "openDiff" },
  })
  if not ok and err then schedule_retry() end
end

M._handle_message = handle_message

function M.start(opts)
  state.opts = opts or state.opts or {}
  state.stopped = false
  if state.client and state.client:status().running then return true end
  cancel_retry()
  local client = transport.new_client({
    name = "dsh IDE IPC",
    keep_alive = true,
    socket_path = state.opts.socket_path or default_socket_path(),
    on_connect = register,
    on_message = handle_message,
    on_disconnect = function(disconnected, reason)
      if disconnected.pending and disconnected.pending.close then
        vim.schedule(function()
          if disconnected.pending and disconnected.pending.close then disconnected.pending.close(reason or "dsh disconnected") end
          disconnected.pending = nil
        end)
      end
      if not state.stopped then schedule_retry() end
    end,
  })
  local ok, err = client:start()
  state.client = client
  if not ok then
    schedule_retry()
    return false, err
  end
  return true
end

function M.stop()
  state.stopped = true
  cancel_retry()
  if state.client then state.client:stop() end
  state.client = nil
  state.ide_id = nil
end

function M.publish()
  local snapshot = current_snapshot()
  local client = state.client
  if not client or not client:status().connected then return false end
  local ok = client:send({
    type = "update",
    id = util.uuid(),
    protocolVersion = 1,
    ideId = state.ide_id,
    workspaceRoots = snapshot.workspaceFolders or {},
    context = snapshot,
    capabilities = { "context", "openFile", "saveDocument", "openDiff" },
  })
  return ok == true
end

function M.status()
  if not state.client then
    return { running = false, connected = false, path = nil, clients = 0, ideId = state.ide_id }
  end
  local result = state.client:status()
  result.ideId = state.ide_id
  return result
end

return M
