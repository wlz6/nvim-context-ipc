local actions = require("nvim_context_ipc.actions")
local context = require("nvim_context_ipc.context")
local transport = require("nvim_context_ipc.transport")
local util = require("nvim_context_ipc.util")

local M = {}
local state = { opts = {}, server = nil }

local function default_socket_path()
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
    -- dsh opens one short-lived connection per tool call. Keeping the socket
    -- open until the write completes avoids truncating the last frame.
    if value.id ~= nil then client:close() end
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
  local method = message.method
  local params = type(message.params) == "table" and message.params or {}
  if method == "ping" then
    return response(client, message, true, { protocolVersion = 1, server = "nvim-context-ipc", provider = "dsh" })
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
  response(client, message, false, nil, "method not found: " .. tostring(method))
end

M._handle_message = handle_message

function M.start(opts)
  if state.server and state.server:status().running then return true end
  state.opts = opts or state.opts or {}
  local server = transport.new({
    name = "dsh IPC",
    socket_path = state.opts.socket_path or default_socket_path(),
    backlog = state.opts.backlog or 64,
    on_message = handle_message,
    on_disconnect = function(client, reason)
      if client.pending and client.pending.close then
        vim.schedule(function()
          if client.pending and client.pending.close then client.pending.close(reason or "dsh client disconnected") end
          client.pending = nil
        end)
      end
    end,
    on_error = function(err) util.notify(err, vim.log.levels.WARN) end,
  })
  local ok, err = server:start()
  if not ok then return false, err end
  state.server = server
  return true
end

function M.stop()
  if state.server then state.server:stop() end
  state.server = nil
end

function M.status()
  if not state.server then return { running = false, path = nil, clients = 0 } end
  return state.server:status()
end

return M
