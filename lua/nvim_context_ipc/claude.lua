local actions = require("nvim_context_ipc.actions")
local context = require("nvim_context_ipc.context")
local lockfile = require("nvim_context_ipc.lockfile")
local util = require("nvim_context_ipc.util")
local websocket = require("nvim_context_ipc.websocket")

local M = {}
local state = { opts = {}, server = nil, lock_path = nil, token = nil, pending = {}, started = false }
local publish_selection
local mark_mcp_ready

local function response(client, id, result)
  if id == nil then return end
  client:send_json({ jsonrpc = "2.0", id = id, result = result })
end

local function error_response(client, id, code, message, data)
  if id == nil then return end
  client:send_json({ jsonrpc = "2.0", id = id, error = { code = code, message = message, data = data } })
end

local function all_tools()
  return actions.tool_schemas(state.opts.expose_internal_tools)
end

local function handle_initialize(client, message)
  local params = message.params or {}
  response(client, message.id, {
    protocolVersion = params.protocolVersion or "2025-03-26",
    capabilities = { tools = { listChanged = false } },
    serverInfo = { name = "ide", version = "0.1.0" },
  })
  client.initialize_responded = true
  -- MCP clients normally follow this with notifications/initialized. Keep a
  -- delayed fallback for clients that omit that notification, but never send
  -- editor notifications during the WebSocket handshake itself.
  vim.defer_fn(function()
    if not client.closed and client.initialize_responded and not client.mcp_ready then
      mark_mcp_ready(client)
    end
  end, 1000)
end

local function handle_tool_call(client, message)
  local params = message.params or {}
  if type(params.name) ~= "string" then return error_response(client, message.id, -32602, "tools/call requires params.name") end
  local pending_key = tostring(client.id) .. ":" .. tostring(message.id)
  local callback
  callback = function(first, second)
    if not client or client.closed then return end
    if first then response(client, message.id, second) else error_response(client, message.id, -32000, tostring(second)) end
    state.pending[pending_key] = nil
  end
  local ok, result = actions.invoke(params.name, params.arguments or {}, callback)
  if not ok then return error_response(client, message.id, -32000, tostring(result)) end
  if type(result) == "table" and result.deferred then
    state.pending[pending_key] = { client = client, action = result, name = params.name }
    return
  end
  response(client, message.id, result)
end

local function on_message(client, message)
  if message.jsonrpc ~= "2.0" and message.type == nil then
    return error_response(client, message.id, -32600, "JSON-RPC 2.0 message required")
  end
  local method = message.method
  if method == "initialize" then return handle_initialize(client, message) end
  if method == "notifications/initialized" then
    return mark_mcp_ready(client)
  end
  if method == "notifications/cancelled" then return end
  if method == "ping" then return response(client, message.id, {}) end
  if method == "tools/list" then return response(client, message.id, { tools = all_tools() }) end
  if method == "tools/call" then return handle_tool_call(client, message) end
  if message.id ~= nil then return error_response(client, message.id, -32601, "Method not found: " .. tostring(method)) end
end

publish_selection = function(client)
  if client.closed or not client.mcp_ready then return end
  local snapshot = context.snapshot()
  local file = snapshot.activeFile
  local selection = snapshot.selection
  if not file or not selection then return end
  client:send_json({
    jsonrpc = "2.0",
    method = "selection_changed",
    params = {
      text = selection.text or "",
      filePath = file.fsPath,
      fileUrl = file.uri,
      selection = { start = selection.start, ["end"] = selection["end"], isEmpty = selection.isEmpty == true },
    },
  })
end

mark_mcp_ready = function(client)
  if client.closed or client.mcp_ready then return end
  client.mcp_ready = true
  if client.initial_publish_scheduled then return end
  client.initial_publish_scheduled = true
  -- Match the official VS Code extension: let MCP finish its connection
  -- bookkeeping before delivering the first selection notification.
  vim.defer_fn(function()
    client.initial_publish_scheduled = false
    if not client.closed and client.mcp_ready then publish_selection(client) end
  end, 500)
end

local function replace_previous_clients(clients, current)
  for _, existing in pairs(clients or {}) do
    if existing ~= current and not existing.closed then
      existing:close(1000, "replaced by new Claude client")
    end
  end
end

local function handle_connect(client)
  replace_previous_clients(state.server and state.server.clients, client)
  client.mcp_ready = false
  client.initialize_responded = false
  client.initial_publish_scheduled = false
end

function M.publish()
  context.snapshot()
  if not state.server then return end
  for _, client in pairs(state.server.clients) do
    if client.handshaken then publish_selection(client) end
  end
end

function M.at_mentioned(line_start, line_end)
  local snapshot = context.snapshot()
  if not snapshot.activeFile then return false end
  local start_line = tonumber(line_start) or (snapshot.selection and snapshot.selection.start.line) or 0
  local end_line = tonumber(line_end) or (snapshot.selection and snapshot.selection["end"].line) or start_line
  for _, client in pairs(state.server and state.server.clients or {}) do
    if client.handshaken and client.mcp_ready then
      client:send_json({ jsonrpc = "2.0", method = "at_mentioned", params = { filePath = snapshot.activeFile.fsPath, lineStart = start_line, lineEnd = end_line } })
    end
  end
  return true
end

local function choose_port(server, opts)
  local min_port, max_port = opts.port_min or 10000, opts.port_max or 65535
  local attempts = {}
  for _ = 1, math.min(256, max_port - min_port + 1) do
    local port = math.random(min_port, max_port)
    if not attempts[port] then
      attempts[port] = true
      local result = server:start(port)
      if result then return result end
    end
  end
  return nil, "could not bind a Claude WebSocket port in configured range"
end

function M.start(opts)
  if state.started then return true end
  state.opts = opts or state.opts or {}
  lockfile.cleanup_stale(state.opts)
  local server = websocket.new({
    auth_token = nil,
    on_message = on_message,
    on_connect = handle_connect,
    on_disconnect = function(client)
      for id, pending in pairs(state.pending) do
        if pending.client == client then
          state.pending[id] = nil
          if pending.action and pending.action.close then pending.action.close("DIFF_REJECTED") end
        end
      end
    end,
    on_error = function(err) util.notify("Claude WebSocket: " .. tostring(err), vim.log.levels.WARN) end,
  })
  local port, err = choose_port(server, state.opts)
  if not port then return false, err end
  local workspace_folders = context.snapshot().workspaceFolders
  state.opts.workspace_folders = workspace_folders
  local path, token_or_err = lockfile.create(state.opts, port)
  if not path then
    server:stop()
    return false, token_or_err
  end
  server.opts.auth_token = token_or_err
  state.server, state.lock_path, state.token, state.started = server, path, token_or_err, true
  return true
end

function M.stop()
  if not state.started then return end
  for id, pending in pairs(state.pending) do
    if pending.action and pending.action.close then pending.action.close("DIFF_REJECTED") end
    state.pending[id] = nil
  end
  if state.server then state.server:stop() end
  if state.lock_path then pcall(util.uv.fs_unlink, state.lock_path) end
  state.server, state.lock_path, state.token, state.started = nil, nil, nil, false
end

function M.status()
  local clients = 0
  for _ in pairs(state.server and state.server.clients or {}) do clients = clients + 1 end
  return { running = state.started, port = state.server and state.server.port or nil, lockPath = state.lock_path, clients = clients }
end

-- Kept as a narrow test seam for validating the JSON sent by tools/list.
M._all_tools = all_tools
M._handle_connect = handle_connect
M._on_message = on_message
M._publish_selection = publish_selection
M._replace_previous_clients = replace_previous_clients

function M.server()
  return state.server
end

return M
