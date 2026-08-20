local bit = require("bit")

local M = {}

local function add(...)
  local result = 0
  for index = 1, select("#", ...) do
    result = (result + (select(index, ...) or 0)) % 4294967296
  end
  return bit.tobit(result)
end

local function rol(value, count)
  return bit.rol(value, count)
end

local function u32be(value)
  value = value % 4294967296
  return string.char(
    math.floor(value / 16777216) % 256,
    math.floor(value / 65536) % 256,
    math.floor(value / 256) % 256,
    value % 256
  )
end

local function read_u32be(value, offset)
  local a, b, c, d = value:byte(offset, offset + 3)
  return a * 16777216 + b * 65536 + c * 256 + d
end

function M.sha1(message)
  local bit_length = #message * 8
  message = message .. string.char(0x80)
  while (#message % 64) ~= 56 do
    message = message .. "\0"
  end
  local high = math.floor(bit_length / 4294967296)
  local low = bit_length % 4294967296
  message = message .. u32be(high) .. u32be(low)

  local h0, h1, h2, h3, h4 = 0x67452301, 0xEFCDAB89, 0x98BADCFE, 0x10325476, 0xC3D2E1F0
  for chunk = 1, #message, 64 do
    local words = {}
    local block = message:sub(chunk, chunk + 63)
    for index = 1, 16 do
      words[index] = bit.tobit(read_u32be(block, (index - 1) * 4 + 1))
    end
    for index = 17, 80 do
      words[index] = rol(bit.bxor(words[index - 3], words[index - 8], words[index - 14], words[index - 16]), 1)
    end

    local a, b, c, d, e = h0, h1, h2, h3, h4
    for index = 1, 80 do
      local f, k
      if index <= 20 then
        f = bit.bor(bit.band(b, c), bit.band(bit.bnot(b), d))
        k = 0x5A827999
      elseif index <= 40 then
        f = bit.bxor(b, c, d)
        k = 0x6ED9EBA1
      elseif index <= 60 then
        f = bit.bor(bit.band(b, c), bit.band(b, d), bit.band(c, d))
        k = 0x8F1BBCDC
      else
        f = bit.bxor(b, c, d)
        k = 0xCA62C1D6
      end
      local temporary = add(rol(a, 5), f, e, k, words[index])
      e = d
      d = c
      c = rol(b, 30)
      b = a
      a = temporary
    end
    h0, h1, h2, h3, h4 = add(h0, a), add(h1, b), add(h2, c), add(h3, d), add(h4, e)
  end
  return u32be(h0) .. u32be(h1) .. u32be(h2) .. u32be(h3) .. u32be(h4)
end

function M.base64_encode(value)
  local alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
  local result = {}
  for index = 1, #value, 3 do
    local a = value:byte(index) or 0
    local b = value:byte(index + 1)
    local c = value:byte(index + 2)
    local triple = a * 65536 + (b or 0) * 256 + (c or 0)
    result[#result + 1] = alphabet:sub(math.floor(triple / 262144) % 64 + 1, math.floor(triple / 262144) % 64 + 1)
    result[#result + 1] = alphabet:sub(math.floor(triple / 4096) % 64 + 1, math.floor(triple / 4096) % 64 + 1)
    result[#result + 1] = b and alphabet:sub(math.floor(triple / 64) % 64 + 1, math.floor(triple / 64) % 64 + 1) or "="
    result[#result + 1] = c and alphabet:sub(triple % 64 + 1, triple % 64 + 1) or "="
  end
  return table.concat(result)
end

function M.constant_time_equal(left, right)
  if type(left) ~= "string" or type(right) ~= "string" or #left ~= #right then
    return false
  end
  local difference = 0
  for index = 1, #left do
    difference = bit.bor(difference, bit.bxor(left:byte(index), right:byte(index)))
  end
  return difference == 0
end

return M
