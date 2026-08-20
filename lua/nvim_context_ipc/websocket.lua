local crypto = require("nvim_context_ipc.crypto")
local util = require("nvim_context_ipc.util")
local bit = require("bit")

local uv = util.uv
local M = {}

local MAX_HTTP_BYTES = 64 * 1024
local MAX_MESSAGE_BYTES = 16 * 1024 * 1024

local function close_handle(handle)
  if handle and not handle:is_closing() then
    handle:close()
  end
end

local function parse_headers(request)
  local headers = {}
  for line in request:gmatch("[^\r\n]+") do
    local name, value = line:match("^([^:]+):%s*(.*)$")
    if name and value then
      headers[name:lower()] = value
    end
  end
  return headers
end

local function handshake(request, expected_token)
  local method, path, version = request:match("^([^%s]+)%s+([^%s]+)%s+([^%s]+)")
  if method ~= "GET" or not path or not version or not version:match("^HTTP/1%.1") then
    return nil, "HTTP/1.1 400 Bad Request\r\nConnection: close\r\nContent-Length: 11\r\n\r\nBad request"
  end
  local headers = parse_headers(request)
  if (headers.upgrade or ""):lower() ~= "websocket" or not (headers.connection or ""):lower():find("upgrade", 1, true) then
    return nil, "HTTP/1.1 426 Upgrade Required\r\nConnection: close\r\nContent-Length: 19\r\n\r\nUpgrade required"
  end
  local key = headers["sec-websocket-key"]
  if not key or #key < 20 or not headers["sec-websocket-version"] or headers["sec-websocket-version"] ~= "13" then
    return nil, "HTTP/1.1 400 Bad Request\r\nConnection: close\r\nContent-Length: 16\r\n\r\nInvalid WebSocket"
  end
  if expected_token and not crypto.constant_time_equal(headers["x-claude-code-ide-authorization"] or "", expected_token) then
    return nil, "HTTP/1.1 401 Unauthorized\r\nConnection: close\r\nContent-Length: 12\r\n\r\nUnauthorized"
  end
  local accept = crypto.base64_encode(crypto.sha1(key .. "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"))
  local protocol = nil
  if headers["sec-websocket-protocol"] then
    for candidate in headers["sec-websocket-protocol"]:gmatch("[^, ]+") do
      if candidate == "mcp" then
        protocol = "mcp"
        break
      end
    end
  end
  local response = {
    "HTTP/1.1 101 Switching Protocols",
    "Upgrade: websocket",
    "Connection: Upgrade",
    "Sec-WebSocket-Accept: " .. accept,
  }
  if protocol then
    response[#response + 1] = "Sec-WebSocket-Protocol: " .. protocol
  end
  response[#response + 1] = ""
  response[#response + 1] = ""
  return { headers = headers, path = path, protocol = protocol }, table.concat(response, "\r\n")
end

local function frame(opcode, payload, mask)
  local first = 0x80 + opcode
  local length = #payload
  local header
  if length < 126 then
    header = string.char(first, (mask and 0x80 or 0) + length)
  elseif length < 65536 then
    header = string.char(first, (mask and 0x80 or 0) + 126, math.floor(length / 256), length % 256)
  else
    local high = math.floor(length / 4294967296)
    local low = length % 4294967296
    header = string.char(first, (mask and 0x80 or 0) + 127,
      0, 0, 0, 0,
      math.floor(high / 16777216) % 256,
      math.floor(high / 65536) % 256,
      math.floor(high / 256) % 256,
      high % 256,
      math.floor(low / 16777216) % 256,
      math.floor(low / 65536) % 256,
      math.floor(low / 256) % 256,
      low % 256)
  end
  if not mask then
    return header .. payload
  end
  local key, err = util.random_hex(4)
  if not key then
    return nil, err
  end
  local mask_bytes = {}
  for index = 1, 8, 2 do
    mask_bytes[#mask_bytes + 1] = tonumber(key:sub(index, index + 1), 16)
  end
  local bytes = {}
  for index = 1, #payload do
    bytes[index] = string.char(bit.bxor(payload:byte(index), mask_bytes[(index - 1) % 4 + 1]) % 256)
  end
  return header .. key:gsub("..", function(pair) return string.char(tonumber(pair, 16)) end) .. table.concat(bytes)
end

local function parse_frames(buffer)
  local messages = {}
  local offset = 1
  while #buffer - offset + 1 >= 2 do
    local first, second = buffer:byte(offset, offset + 1)
    local fin = first >= 128
    local opcode = first % 16
    local masked = second >= 128
    local length = second % 128
    local header_length = 2
    if length == 126 then
      if #buffer - offset + 1 < 4 then break end
      length = buffer:byte(offset + 2) * 256 + buffer:byte(offset + 3)
      header_length = 4
    elseif length == 127 then
      if #buffer - offset + 1 < 10 then break end
      local high = buffer:byte(offset + 2) * 16777216 + buffer:byte(offset + 3) * 65536 + buffer:byte(offset + 4) * 256 + buffer:byte(offset + 5)
      local low = buffer:byte(offset + 6) * 16777216 + buffer:byte(offset + 7) * 65536 + buffer:byte(offset + 8) * 256 + buffer:byte(offset + 9)
      if high > 0 or low > MAX_MESSAGE_BYTES then return nil, "WebSocket message is too large" end
      length = low
      header_length = 10
    end
    if length > MAX_MESSAGE_BYTES then return nil, "WebSocket message is too large" end
    local mask_length = masked and 4 or 0
    if #buffer - offset + 1 < header_length + mask_length + length then break end
    local mask_key
    if masked then mask_key = { buffer:byte(offset + header_length, offset + header_length + 3) } end
    local payload_start = offset + header_length + mask_length
    local payload = buffer:sub(payload_start, payload_start + length - 1)
    if masked then
      local bytes = {}
      for index = 1, #payload do
        bytes[index] = string.char(bit.bxor(payload:byte(index), mask_key[(index - 1) % 4 + 1]) % 256)
      end
      payload = table.concat(bytes)
    end
    messages[#messages + 1] = { fin = fin, opcode = opcode, payload = payload, masked = masked }
    offset = payload_start + length
  end
  return messages, buffer:sub(offset)
end

local Client = {}
Client.__index = Client

function Client:send_frame(opcode, payload, callback)
  if self.closed then
    if callback then callback("WebSocket is closed") end
    return
  end
  local data, err = frame(opcode, payload, false)
  if not data then
    if callback then callback(err) end
    return
  end
  self.write_queue[#self.write_queue + 1] = { data = data, callback = callback }
  self:flush()
end

function Client:flush()
  if self.writing or self.closed or #self.write_queue == 0 then return end
  self.writing = true
  local item = table.remove(self.write_queue, 1)
  self.tcp:write(item.data, function(err)
    self.writing = false
    if item.callback then item.callback(err) end
    if err then self:close(1011, err) else self:flush() end
  end)
end

function Client:send_text(text, callback)
  self:send_frame(1, text, callback)
end

function Client:send_json(value, callback)
  local ok, text = pcall(util.json_encode, value)
  if not ok then
    if callback then callback(text) end
    return
  end
  self:send_text(text, callback)
end

function Client:close(code, reason)
  if self.closed then return end
  self.closed = true
  if self.tcp and not self.tcp:is_closing() then
    local payload = string.char(math.floor((code or 1000) / 256), (code or 1000) % 256) .. (reason or "")
    local data = frame(8, payload, false)
    self.tcp:write(data, function() close_handle(self.tcp) end)
  end
  if self.server and self.server.clients[self.id] then
    self.server.clients[self.id] = nil
    vim.schedule(function()
      self.server.on_disconnect(self, code, reason)
    end)
  end
end

function Client:handle_frame(item)
  if item.opcode == 8 then
    self:close(1000, "peer closed")
    return
  elseif item.opcode == 9 then
    self:send_frame(10, item.payload)
    return
  elseif item.opcode == 10 then
    return
  elseif item.opcode == 0 then
    self.fragments[#self.fragments + 1] = item.payload
    if item.fin then
      local payload = table.concat(self.fragments)
      self.fragments = {}
      self:handle_message(self.fragment_opcode, payload)
      self.fragment_opcode = nil
    end
  elseif item.opcode == 1 or item.opcode == 2 then
    if item.fin then self:handle_message(item.opcode, item.payload)
    else self.fragment_opcode, self.fragments = item.opcode, { item.payload } end
  end
end

function Client:handle_message(opcode, payload)
  if opcode ~= 1 then return end
  local ok, value = pcall(util.json_decode, payload)
  if not ok or type(value) ~= "table" then
    self:close(1007, "invalid JSON")
    return
  end
  vim.schedule(function()
    if not self.closed then self.server.on_message(self, value) end
  end)
end

local Server = {}
Server.__index = Server

function Server.new(opts)
  local server = setmetatable({
    opts = opts or {},
    clients = {},
    on_message = (opts or {}).on_message or function() end,
    on_connect = (opts or {}).on_connect or function() end,
    on_disconnect = (opts or {}).on_disconnect or function() end,
    on_error = (opts or {}).on_error or function() end,
  }, Server)
  return server
end

function Server:_accept()
  local tcp = uv.new_tcp()
  if not tcp then return self.on_error("could not create WebSocket client") end
  local ok, err = self.tcp:accept(tcp)
  if not ok then
    close_handle(tcp)
    return self.on_error(err or "could not accept WebSocket client")
  end
  local client = setmetatable({
    id = util.uuid(), tcp = tcp, server = self, http_buffer = "", ws_buffer = "", handshaken = false,
    closed = false, writing = false, write_queue = {}, fragments = {},
  }, Client)
  self.clients[client.id] = client
  tcp:read_start(function(read_err, data)
    if read_err then
      self.on_error(read_err)
      client:close(1006, read_err)
      return
    end
    if not data then
      client:close(1006, "EOF")
      return
    end
    if not client.handshaken then
      client.http_buffer = client.http_buffer .. data
      if #client.http_buffer > MAX_HTTP_BYTES then
        client:close(1009, "HTTP request too large")
        return
      end
      local end_at = client.http_buffer:find("\r\n\r\n", 1, true)
      if not end_at then return end
      local request = client.http_buffer:sub(1, end_at + 3)
      client.ws_buffer = client.http_buffer:sub(end_at + 4)
      local info, response = handshake(request, self.opts.auth_token)
      if not info then
        tcp:write(response or "HTTP/1.1 400 Bad Request\r\n\r\n", function() client:close(1002, "handshake failed") end)
        return
      end
      client.handshaken = true
      client.path = info.path
      tcp:write(response)
      vim.schedule(function()
        if not client.closed then self.on_connect(client, info) end
      end)
    else
      client.ws_buffer = client.ws_buffer .. data
    end
    if client.handshaken then
      local frames, remainder = parse_frames(client.ws_buffer)
      if not frames then return client:close(1009, remainder) end
      client.ws_buffer = remainder
      for _, item in ipairs(frames) do client:handle_frame(item) end
    end
  end)
end

function Server:start(port)
  self.tcp = uv.new_tcp()
  if not self.tcp then return nil, "could not create TCP server" end
  local bind_ok, bind_err = self.tcp:bind("127.0.0.1", port or 0)
  if not bind_ok then close_handle(self.tcp); self.tcp = nil; return nil, bind_err end
  local listen_ok, listen_err = self.tcp:listen(128, function(err)
    if err then return self.on_error(err) end
    self:_accept()
  end)
  if not listen_ok then close_handle(self.tcp); self.tcp = nil; return nil, listen_err end
  local address = self.tcp:getsockname()
  self.port = address and address.port or port
  return self.port
end

function Server:broadcast(value)
  for _, client in pairs(self.clients) do
    client:send_json(value)
  end
end

function Server:stop()
  for _, client in pairs(self.clients) do client:close(1001, "server stopped") end
  self.clients = {}
  close_handle(self.tcp)
  self.tcp = nil
end

M.new = Server.new
M._parse_frames = parse_frames
M._handshake = handshake
M._frame = frame

return M
