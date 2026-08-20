local util = require("nvim_context_ipc.util")

local M = {}

local MAX_FRAME_BYTES = 256 * 1024 * 1024

local function u32le(number)
  local a = number % 256
  local b = math.floor(number / 256) % 256
  local c = math.floor(number / 65536) % 256
  local d = math.floor(number / 16777216) % 256
  return string.char(a, b, c, d)
end

local function read_u32le(value)
  local a, b, c, d = value:byte(1, 4)
  return a + b * 256 + c * 65536 + d * 16777216
end

function M.encode(value)
  local payload = util.json_encode(value)
  if #payload > MAX_FRAME_BYTES then
    return nil, "JSON payload exceeds the Codex IPC frame limit"
  end
  return u32le(#payload) .. payload
end

function M.decode(buffer)
  local messages = {}
  local offset = 1
  while #buffer - offset + 1 >= 4 do
    local length = read_u32le(buffer:sub(offset, offset + 3))
    if length > MAX_FRAME_BYTES then
      return nil, "Codex IPC frame exceeds the maximum size"
    end
    if #buffer - offset + 1 < 4 + length then
      break
    end
    local payload = buffer:sub(offset + 4, offset + 3 + length)
    local ok, value = pcall(util.json_decode, payload)
    if not ok or type(value) ~= "table" then
      return nil, "Codex IPC frame is not a JSON object"
    end
    messages[#messages + 1] = value
    offset = offset + 4 + length
  end
  return messages, buffer:sub(offset)
end

function M.max_frame_bytes()
  return MAX_FRAME_BYTES
end

return M
