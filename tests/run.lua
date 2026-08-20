local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local function test(name, fn)
  local ok, err = pcall(fn)
  if not ok then error(name .. ": " .. tostring(err)) end
  print("ok - " .. name)
end

test("Codex protocol round trip and partial frames", function()
  local protocol = require("nvim_context_ipc.protocol")
  local first = assert(protocol.encode({ type = "request", method = "ide-context" }))
  local second = assert(protocol.encode({ type = "broadcast", value = "选区" }))
  local messages, remainder = assert(protocol.decode(first:sub(1, 2)))
  assert(#messages == 0 and remainder == first:sub(1, 2))
  messages, remainder = assert(protocol.decode(first:sub(1, 2) .. first:sub(3) .. second))
  assert(#messages == 2 and messages[1].method == "ide-context" and messages[2].value == "选区" and remainder == "")
  local bad, bad_error = protocol.decode("bad!")
  assert(bad == nil and bad_error)
end)

test("SHA-1 and Base64 WebSocket primitives", function()
  local crypto = require("nvim_context_ipc.crypto")
  local digest = crypto.sha1("abc"):gsub(".", function(char) return string.format("%02x", string.byte(char)) end)
  assert(digest == "a9993e364706816aba3e25717850c26c9cd0d89d")
  assert(crypto.base64_encode("any carnal pleasure.") == "YW55IGNhcm5hbCBwbGVhc3VyZS4=")
  assert(crypto.constant_time_equal("secret", "secret"))
  assert(not crypto.constant_time_equal("secret", "secreT"))
end)

test("WebSocket handshake validates the Claude token", function()
  local websocket = require("nvim_context_ipc.websocket")
  local request = table.concat({
    "GET /mcp HTTP/1.1", "Host: 127.0.0.1", "Upgrade: websocket", "Connection: Upgrade",
    "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==", "Sec-WebSocket-Version: 13",
    "Sec-WebSocket-Protocol: mcp", "X-Claude-Code-Ide-Authorization: token-123456", "", "",
  }, "\r\n")
  local info, response = websocket._handshake(request, "token-123456")
  assert(info and info.protocol == "mcp" and response:find("101 Switching Protocols", 1, true))
  local rejected = websocket._handshake(request, "wrong-token")
  assert(rejected == nil)
end)

test("Context snapshot uses active in-memory buffer", function()
  local context = require("nvim_context_ipc.context")
  local buffer = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_set_name(buffer, root .. "/tests/context-fixture.lua")
  vim.bo[buffer].buflisted = true
  vim.api.nvim_buf_set_lines(buffer, 0, -1, false, { "local emoji = '😀'", "return emoji" })
  vim.api.nvim_win_set_cursor(0, { 1, 7 })
  local snapshot = context.snapshot({ include_buffer_text = true })
  assert(snapshot.activeFile.fsPath == root .. "/tests/context-fixture.lua")
  assert(snapshot.buffer.text:find("emoji", 1, true))
  assert(snapshot.activeFile.selection.start.line == 0)
  assert(snapshot.activeFile.selection.start.character == 7)
end)

print("all nvim-context-ipc tests passed")
