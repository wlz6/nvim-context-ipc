local context = require("nvim_context_ipc.context")
local transport = require("nvim_context_ipc.transport")
local util = require("nvim_context_ipc.util")

local M = {}
local state = { opts = {}, server = nil }

local function default_socket_path()
  local home = os.getenv("CODEX_HOME") or "~/.codex"
  return util.normalize_path(home .. "/ipc/ipc.sock")
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

local function response(client, message, value, result_type, error_message)
  local actual_type = result_type or "success"
  local result = {
    type = "response",
    requestId = message.requestId,
    resultType = actual_type,
    method = message.method,
    handledByClientId = "nvim-client",
  }
  if actual_type == "success" then result.result = { type = "broadcast", ideContext = value }
  else result.error = error_message or "no-handler-for-request" end
  client:send(result)
end

local function handle_message(client, message)
  local kind = message.type
  if kind == "request" then
    if message.method == "ide-context" then
      local requested = message.params and message.params.workspaceRoot
      if workspace_matches(requested) then
        response(client, message, ide_context(requested))
      else
        response(client, message, nil, "error", "no-client-found")
      end
    else
      response(client, message, nil, "error", "no-handler-for-request")
    end
  elseif kind == "client-discovery-request" then
    local request = message.request or {}
    local requested = request.params and request.params.workspaceRoot
    client:send({
      type = "client-discovery-response",
      requestId = message.requestId,
      response = { canHandle = workspace_matches(requested), clientId = "nvim-client" },
    })
  end
end

M.handle_message = handle_message

function M.start(opts)
  if state.server and state.server:status().running then return true end
  state.opts = opts or state.opts or {}
  if vim.fn.has("win32") == 1 then return false, "Codex Named Pipe mode is not implemented on Windows in this release" end
  local server = transport.new({
    name = "Codex IPC",
    socket_path = state.opts.socket_path or default_socket_path(),
    on_message = handle_message,
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
