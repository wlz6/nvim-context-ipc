local actions = require("nvim_context_ipc.actions")
local context = require("nvim_context_ipc.context")
local lockfile = require("nvim_context_ipc.lockfile")
local util = require("nvim_context_ipc.util")
local websocket = require("nvim_context_ipc.websocket")

local M = {}
local state = { opts = {}, server = nil, lock_path = nil, token = nil, pending = {}, started = false }

local TOOL_SCHEMAS = {
  openFile = { description = "Open a file and optionally select text.", inputSchema = { type = "object", properties = { filePath = { type = "string" }, preview = { type = "boolean" }, startText = { type = "string" }, endText = { type = "string" }, selectToEndOfLine = { type = "boolean" }, makeFrontmost = { type = "boolean" } }, required = { "filePath" } } },
  openDiff = { description = "Open proposed file contents in a native Neovim diff and wait for save or rejection.", inputSchema = { type = "object", properties = { old_file_path = { type = "string" }, new_file_path = { type = "string" }, new_file_contents = { type = "string" }, tab_name = { type = "string" } }, required = { "new_file_contents" } } },
  getCurrentSelection = { description = "Read the current active editor selection.", inputSchema = { type = "object", properties = {} } },
  getLatestSelection = { description = "Read the most recent editor selection.", inputSchema = { type = "object", properties = {} } },
  getOpenEditors = { description = "List open Neovim file buffers.", inputSchema = { type = "object", properties = {} } },
  getWorkspaceFolders = { description = "List the current workspace folders.", inputSchema = { type = "object", properties = {} } },
  getDiagnostics = { description = "Read Neovim diagnostics for one file or all open files.", inputSchema = { type = "object", properties = { uri = { type = "string" } } } },
  checkDocumentDirty = { description = "Check whether an open document has unsaved changes.", inputSchema = { type = "object", properties = { filePath = { type = "string" } }, required = { "filePath" } } },
  saveDocument = { description = "Save an open document.", inputSchema = { type = "object", properties = { filePath = { type = "string" } }, required = { "filePath" } } },
  closeAllDiffTabs = { description = "Close all nvim-context-ipc diff views.", inputSchema = { type = "object", properties = {} } },
  executeCode = { description = "Execute Python code in a persistent Jupyter kernel when available.", inputSchema = { type = "object", properties = { code = { type = "string" } }, required = { "code" } } },
}

local INTERNAL_TOOLS = {
  close_tab = { description = "Close a named Neovim tab/buffer.", inputSchema = { type = "object", properties = { tab_name = { type = "string" }, force = { type = "boolean" } }, required = { "tab_name" } } },
}

local function response(client, id, result)
  if id == nil then return end
  client:send_json({ jsonrpc = "2.0", id = id, result = result })
end

local function error_response(client, id, code, message, data)
  if id == nil then return end
  client:send_json({ jsonrpc = "2.0", id = id, error = { code = code, message = message, data = data } })
end

local function all_tools()
  local result = {}
  local names = {}
  for name in pairs(TOOL_SCHEMAS) do names[#names + 1] = name end
  if state.opts.expose_internal_tools then
    for name in pairs(INTERNAL_TOOLS) do names[#names + 1] = name end
  end
  table.sort(names)
  for _, name in ipairs(names) do
    local schema = TOOL_SCHEMAS[name] or INTERNAL_TOOLS[name]
    result[#result + 1] = { name = name, description = schema.description, inputSchema = schema.inputSchema }
  end
  return result
end

local function handle_initialize(client, message)
  local params = message.params or {}
  response(client, message.id, {
    protocolVersion = params.protocolVersion or "2025-03-26",
    capabilities = { tools = { listChanged = false } },
    serverInfo = { name = "ide", version = "0.1.0" },
  })
end

local function handle_tool_call(client, message)
  local params = message.params or {}
  if type(params.name) ~= "string" then return error_response(client, message.id, -32602, "tools/call requires params.name") end
  local pending_key = tostring(client.id) .. ":" .. tostring(message.id)
  local callback
  callback = function(first, second)
    if not client or client.closed then return end
    if params.name == "executeCode" then
      if first then response(client, message.id, second) else error_response(client, message.id, -32000, tostring(second)) end
    else
      response(client, message.id, util.mcp_text(first))
    end
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
  if method == "notifications/initialized" or method == "notifications/cancelled" then return end
  if method == "ping" then return response(client, message.id, {}) end
  if method == "tools/list" then return response(client, message.id, { tools = all_tools() }) end
  if method == "tools/call" then return handle_tool_call(client, message) end
  if message.id ~= nil then return error_response(client, message.id, -32601, "Method not found: " .. tostring(method)) end
end

local function publish_selection(client)
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
    client:send_json({ jsonrpc = "2.0", method = "at_mentioned", params = { filePath = snapshot.activeFile.fsPath, lineStart = start_line, lineEnd = end_line } })
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
    on_connect = function(client)
      publish_selection(client)
    end,
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

function M.server()
  return state.server
end

return M
