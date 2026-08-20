local codex = require("nvim_context_ipc.codex")
local context = require("nvim_context_ipc.context")
local protocol = require("nvim_context_ipc.protocol")
local util = require("nvim_context_ipc.util")

local uv = util.uv
local M = {}
local state = { connection = nil, opts = {}, started = false }

local function path_for(opts)
  return util.normalize_path(opts.provider_socket or "~/.cache/nvim-context-ipc/providers.sock")
end

local function send(value)
  local connection = state.connection
  if not connection or connection.closed then return false end
  local encoded = protocol.encode(value)
  if not encoded then return false end
  connection.queue[#connection.queue + 1] = encoded
  if connection.writing then return true end
  connection.writing = true
  local function write_next()
    local data = table.remove(connection.queue, 1)
    if not data or connection.closed then connection.writing = false; return end
    connection.pipe:write(data, function(err)
      if err then connection:close() else write_next() end
    end)
  end
  write_next()
  return true
end

function M.publish()
  if not state.started then return end
  send({ type = "update", clientId = "nvim-client", workspaceRoots = context.snapshot().workspaceFolders or {} })
end

function M.start(opts)
  if state.started then return true end
  state.opts = opts or {}
  local path = path_for(state.opts)
  local pipe = uv.new_pipe(false)
  if not pipe then return false, "could not create Codex router provider pipe" end
  state.connection = { pipe = pipe, buffer = "", queue = {}, writing = false, closed = false }
  function state.connection:write(data, callback)
    self.pipe:write(data, callback)
  end
  function state.connection:close()
    if self.closed then return end
    self.closed = true
    if not self.pipe:is_closing() then self.pipe:close() end
    state.connection = nil
    state.started = false
  end
  local ok, err = pipe:connect(path, function(connect_err)
    if connect_err then
      state.connection:close()
      return util.notify("Codex router provider connection failed: " .. tostring(connect_err), vim.log.levels.WARN)
    end
    vim.schedule(function()
      if state.connection and not state.connection.closed then
        send({ type = "register", clientId = "nvim-client", pid = vim.fn.getpid(), workspaceRoots = context.snapshot().workspaceFolders or {} })
      end
    end)
  end)
  if not ok and err then state.connection:close(); return false, err end
  pipe:read_start(function(read_err, data)
    if read_err or not data then return state.connection and state.connection:close() end
    local connection = state.connection
    connection.buffer = connection.buffer .. data
    local messages, remainder = protocol.decode(connection.buffer)
    if not messages then return connection:close() end
    connection.buffer = remainder
    for _, message in ipairs(messages) do
      vim.schedule(function()
        if not connection.closed then codex.handle_message(connection, message) end
      end)
    end
  end)
  state.started = true
  return true
end

function M.stop()
  if state.connection then state.connection:close() end
  state.started = false
end

function M.status()
  return { running = state.started, providerSocket = path_for(state.opts) }
end

return M
