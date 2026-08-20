local protocol = require("nvim_context_ipc.protocol")
local util = require("nvim_context_ipc.util")

local uv = util.uv
local M = {}

local Server = {}
Server.__index = Server

local function close_handle(handle)
  if handle and not handle:is_closing() then handle:close() end
end

local function socket_is_active(path)
  local ok, channel = pcall(vim.fn.sockconnect, "pipe", path, { rpc = false })
  if not ok or type(channel) ~= "number" or channel <= 0 then return false end
  pcall(vim.fn.chanclose, channel)
  return true
end

local function send(client, value, on_written)
  local encoded, err = protocol.encode(value)
  if not encoded then
    client:close(err)
    return false
  end
  client.queue[#client.queue + 1] = { data = encoded, callback = on_written }
  if client.writing then return true end
  client.writing = true
  local function write_next()
    if client.closed then client.writing = false; return end
    local item = table.remove(client.queue, 1)
    if not item then client.writing = false; return end
    client:write(item.data, function(write_err)
      if write_err then
        client:close(write_err)
      else
        if item.callback then item.callback() end
        write_next()
      end
    end)
  end
  write_next()
  return true
end

function M.new(opts)
  opts = opts or {}
  local server = setmetatable({
    name = opts.name or "IPC",
    opts = opts,
    clients = {},
    pipe = nil,
    path = nil,
    started = false,
  }, Server)
  return server
end

function Server:_accept_client()
  local handle = uv.new_pipe(false)
  if not handle then return end
  local ok, err = self.pipe:accept(handle)
  if not ok then
    close_handle(handle)
    if self.opts.on_error then self.opts.on_error(self.name .. " accept failed: " .. tostring(err)) end
    return
  end

  local client = {
    handle = handle,
    buffer = "",
    queue = {},
    writing = false,
    closed = false,
    server = self,
  }
  self.clients[client] = true
  function client:write(data, callback) self.handle:write(data, callback) end
  function client:send(value, callback) return send(self, value, callback) end
  function client:close(reason)
    if self.closed then return end
    self.closed = true
    self.server.clients[self] = nil
    close_handle(self.handle)
    if self.server.opts.on_disconnect then self.server.opts.on_disconnect(self, reason) end
  end

  if self.opts.on_connect then self.opts.on_connect(client) end
  handle:read_start(function(read_err, data)
    if client.closed then return end
    if read_err then client:close(read_err); return end
    if not data then client:close("EOF"); return end
    client.buffer = client.buffer .. data
    local messages, remainder = protocol.decode(client.buffer)
    if not messages then
      client:close("invalid " .. self.name .. " frame")
      return
    end
    client.buffer = remainder
    for _, message in ipairs(messages) do
      vim.schedule(function()
        if not client.closed and self.opts.on_message then self.opts.on_message(client, message) end
      end)
    end
  end)
end

function Server:start()
  if self.started then return true end
  if vim.fn.has("win32") == 1 then return false, self.name .. " Unix socket mode is not implemented on Windows in this release" end
  local requested_path = self.opts.socket_path
  local path = util.normalize_path(requested_path)
  if not path then return false, self.name .. " socket_path is invalid" end
  local directory = util.dirname(path)
  vim.fn.mkdir(directory, "p", 448)
  pcall(uv.fs_chmod, directory, 448)
  local stat = uv.fs_stat(path)
  if stat then
    if stat.type ~= "socket" then
      return false, self.name .. " path exists and is not a socket: " .. path
    end
    if socket_is_active(path) then
      return false, self.name .. " socket is already occupied: " .. path .. "; refusing to remove another process's socket"
    end
    local removed, remove_err = pcall(uv.fs_unlink, path)
    if not removed then
      return false, self.name .. " socket is stale but could not be removed: " .. tostring(remove_err)
    end
  end

  local pipe = uv.new_pipe(false)
  if not pipe then return false, "could not create " .. self.name .. " pipe" end
  local bind_ok, bind_err = pipe:bind(path)
  if not bind_ok then close_handle(pipe); return false, bind_err end
  local listen_ok, listen_err = pipe:listen(self.opts.backlog or 64, function(err)
    if err then
      if self.opts.on_error then self.opts.on_error(self.name .. " listen failed: " .. tostring(err)) end
      return
    end
    self:_accept_client()
  end)
  if not listen_ok then
    close_handle(pipe)
    pcall(uv.fs_unlink, path)
    return false, listen_err
  end
  pcall(uv.fs_chmod, path, 384)
  self.pipe, self.path, self.started = pipe, path, true
  return true
end

function Server:stop()
  if not self.started then return end
  local clients = {}
  for client in pairs(self.clients) do clients[#clients + 1] = client end
  for _, client in ipairs(clients) do client:close("server stopped") end
  close_handle(self.pipe)
  if self.path then pcall(uv.fs_unlink, self.path) end
  self.clients, self.pipe, self.path, self.started = {}, nil, nil, false
end

function Server:status()
  local clients = 0
  for _ in pairs(self.clients) do clients = clients + 1 end
  return { running = self.started, path = self.path, clients = clients }
end

M._socket_is_active = socket_is_active
M._send = send

return M
