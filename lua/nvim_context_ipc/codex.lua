local context = require("nvim_context_ipc.context")
local protocol = require("nvim_context_ipc.protocol")
local util = require("nvim_context_ipc.util")

local uv = util.uv
local M = {}
local state = { opts = {}, pipe = nil, clients = {}, path = nil, started = false }

local function close_handle(handle)
  if handle and not handle:is_closing() then handle:close() end
end

local function workspace_matches(requested)
  if type(requested) ~= "string" or requested == "" then return false end
  local wanted = util.normalize_path(requested)
  local snapshot = context.snapshot()
  for _, root in ipairs(snapshot.workspaceFolders or {}) do
    if util.normalize_path(root) == wanted then return true end
  end
  return util.normalize_path(snapshot.workspaceRoot) == wanted
end

local function ide_context(requested)
  local snapshot = context.snapshot()
  local root = util.normalize_path(requested) or snapshot.workspaceRoot
  local file = snapshot.activeFile
  local active_file
  if file then
    active_file = {
      label = file.label,
      path = util.relative_path(file.fsPath, root),
      fsPath = file.fsPath,
      selection = file.selection,
      activeSelectionContent = file.activeSelectionContent,
      selections = file.selections or {},
    }
  end
  local tabs = {}
  for _, tab in ipairs(snapshot.openTabs or {}) do
    tabs[#tabs + 1] = { label = tab.label, path = util.relative_path(tab.fsPath or tab.path, root) }
  end
  return { activeFile = active_file, openTabs = tabs }
end

local function send(client, value)
  local encoded, err = protocol.encode(value)
  if not encoded then return client:close(err) end
  client.queue = client.queue or {}
  client.queue[#client.queue + 1] = encoded
  if client.writing then return end
  client.writing = true
  local function write_next()
    if client.closed then client.writing = false; return end
    local data = table.remove(client.queue, 1)
    if not data then client.writing = false; return end
    client:write(data, function(write_err)
      if write_err then client:close() else write_next() end
    end)
  end
  write_next()
end

local function response(client, message, value, result_type, error_message)
  local actual_type = result_type or "success"
  local result = { type = "response", requestId = message.requestId, resultType = actual_type, method = message.method, handledByClientId = "nvim-client" }
  if actual_type == "success" then result.result = { type = "broadcast", ideContext = value }
  else result.error = error_message or "no-handler-for-request" end
  send(client, result)
end

local function handle_message(client, message)
  local kind = message.type
  if kind == "request" then
    if message.method == "ide-context" then
      local requested = message.params and message.params.workspaceRoot
      if workspace_matches(requested) then response(client, message, ide_context(requested)) else response(client, message, nil, "error", "no-client-found") end
    else
      response(client, message, nil, "error", "no-handler-for-request")
    end
  elseif kind == "client-discovery-request" then
    local request = message.request or {}
    local requested = request.params and request.params.workspaceRoot
    send(client, { type = "client-discovery-response", requestId = message.requestId, response = { canHandle = workspace_matches(requested), clientId = "nvim-client" } })
  end
end

M.handle_message = handle_message

local function accept_client()
  local client = uv.new_pipe(false)
  if not client then return end
  local ok, err = state.pipe:accept(client)
  if not ok then close_handle(client); return util.notify("Codex IPC accept failed: " .. tostring(err), vim.log.levels.WARN) end
  local connection = { handle = client, buffer = "", queue = {}, writing = false, closed = false }
  state.clients[connection] = true
  function connection:write(data, callback) self.handle:write(data, callback) end
  function connection:close(reason)
    if self.closed then return end
    self.closed = true
    state.clients[self] = nil
    close_handle(self.handle)
  end
  client:read_start(function(read_err, data)
    if read_err then connection:close(read_err); return end
    if not data then connection:close("EOF"); return end
    connection.buffer = connection.buffer .. data
    local messages, remainder = protocol.decode(connection.buffer)
    if not messages then connection:close("invalid frame"); return end
    connection.buffer = remainder
    for _, message in ipairs(messages) do
      vim.schedule(function()
        if not connection.closed then handle_message(connection, message) end
      end)
    end
  end)
end

local function default_socket_path()
  local home = os.getenv("CODEX_HOME") or "~/.codex"
  return util.normalize_path(home .. "/ipc/ipc.sock")
end

function M.start(opts)
  if state.started then return true end
  state.opts = opts or state.opts or {}
  if vim.fn.has("win32") == 1 then return false, "Codex Named Pipe mode is not implemented on Windows in this release" end
  local path = util.normalize_path(state.opts.socket_path or default_socket_path())
  local directory = util.dirname(path)
  vim.fn.mkdir(directory, "p", 448)
  pcall(uv.fs_chmod, directory, 448)
  local stat = uv.fs_stat(path)
  if stat then
    return false, "Codex IPC socket is already occupied: " .. path .. "; refusing to remove another process's socket"
  end
  local pipe = uv.new_pipe(false)
  if not pipe then return false, "could not create Codex IPC pipe" end
  local bind_ok, bind_err = pipe:bind(path)
  if not bind_ok then close_handle(pipe); return false, bind_err end
  local listen_ok, listen_err = pipe:listen(64, function(err)
    if err then return util.notify("Codex IPC listen failed: " .. tostring(err), vim.log.levels.WARN) end
    accept_client()
  end)
  if not listen_ok then close_handle(pipe); pcall(uv.fs_unlink, path); return false, listen_err end
  pcall(uv.fs_chmod, path, 384)
  state.pipe, state.path, state.started = pipe, path, true
  return true
end

function M.stop()
  if not state.started then return end
  for client in pairs(state.clients) do client:close("server stopped") end
  state.clients = {}
  close_handle(state.pipe)
  if state.path then pcall(uv.fs_unlink, state.path) end
  state.pipe, state.path, state.started = nil, nil, false
end

function M.status()
  local clients = 0
  for _ in pairs(state.clients) do clients = clients + 1 end
  return { running = state.started, path = state.path, clients = clients }
end

return M
