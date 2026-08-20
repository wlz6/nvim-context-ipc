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

test("dsh IPC handler returns a versioned ping response", function()
  local dsh = require("nvim_context_ipc.dsh")
  local protocol = require("nvim_context_ipc.protocol")
  local frames = {}
  local client = { closed = false, keep_alive = true }
  function client:send(value, callback)
    frames[#frames + 1] = assert(protocol.encode(value))
    if callback then callback() end
  end
  function client:close() self.closed = true end
  dsh._handle_message(client, { id = "ping-1", method = "ping" })
  local messages = assert(protocol.decode(table.concat(frames)))
  assert(#messages == 1)
  assert(messages[1].id == "ping-1" and messages[1].ok == true)
  assert(messages[1].result.provider == "dsh")
end)

test("dsh provider is a reconnecting socket client", function()
  local dsh = require("nvim_context_ipc.dsh")
  local path = vim.fn.tempname() .. ".sock"
  local ok, err = dsh.start({ socket_path = path })
  assert(ok, err)
  assert(dsh.status().running == true and dsh.status().connected == false and dsh.status().path == path)
  dsh.stop()
  assert(vim.uv.fs_stat(path) == nil)
end)

test("shared transport exposes a persistent client contract", function()
  local transport = require("nvim_context_ipc.transport")
  local path = vim.fn.tempname() .. ".sock"
  local client = transport.new_client({ name = "test IPC", socket_path = path })
  assert(client:status().running == false)
  local ok = client:start()
  assert(ok and client:status().running == true and client:status().connected == false)
  client:stop()
  assert(client:status().running == false)
end)

test("Codex provider uses the shared transport client contract", function()
  local codex = require("nvim_context_ipc.codex")
  local sent = {}
  local client = { closed = false }
  function client:send(value) sent[#sent + 1] = value end
  codex.handle_message(client, {
    type = "client-discovery-request",
    requestId = "discovery-1",
    request = { params = { workspaceRoot = root } },
  })
  assert(#sent == 1 and sent[1].type == "client-discovery-response")
  assert(sent[1].requestId == "discovery-1" and sent[1].response.canHandle == true)
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

test("WebSocket reset closes once without warning spam", function()
  local websocket = require("nvim_context_ipc.websocket")
  local warnings = {}
  local closes = 0
  local server = { on_error = function(err) warnings[#warnings + 1] = err end }
  local client = { closed = false }
  function client:terminate()
    if self.closed then return end
    self.closed = true
    closes = closes + 1
  end
  websocket._handle_read(server, client, "ECONNRESET", nil)
  websocket._handle_read(server, client, "ECONNRESET", nil)
  assert(closes == 1, "reset client must close exactly once")
  assert(#warnings == 0, "ECONNRESET is a normal peer disconnect")
  local unexpected = { closed = false, terminate = client.terminate }
  websocket._handle_read(server, unexpected, "EINVAL", nil)
  assert(#warnings == 1 and warnings[1] == "EINVAL", "unexpected read errors must still be reported")
end)

test("Claude lock file advertises the WebSocket transport", function()
  local lockfile = require("nvim_context_ipc.lockfile")
  local directory = vim.fn.tempname()
  local path = assert(lockfile.create({
    lock_dir = directory,
    workspace_folders = { "/tmp/nvim-context-ipc" },
    ide_name = "Neovim",
  }, 43123))
  local data = vim.json.decode(table.concat(vim.fn.readfile(path), "\n"))
  assert(data.useWebSocket == true, "Claude lock file must set useWebSocket=true")
  assert(data.runningInWindows == false, "Claude lock file must set runningInWindows=false")
  vim.fn.delete(directory, "rf")
end)

test("Claude tool schemas encode empty properties as objects", function()
  local claude = require("nvim_context_ipc.claude")
  local encoded = vim.json.encode({ tools = claude._all_tools() })
  assert(not encoded:find('"properties":%[%]'), "empty MCP properties must encode as an object")
end)

test("Claude exposes the shared provider-neutral action contract", function()
  local actions = require("nvim_context_ipc.actions")
  local claude = require("nvim_context_ipc.claude")
  local shared, exposed = actions.tool_schemas(false), claude._all_tools()
  assert(#shared == #exposed)
  for index, schema in ipairs(shared) do
    assert(schema.name == exposed[index].name, "Claude action schema drifted from actions.invoke")
  end
end)

test("deferred diff callbacks use the common action result contract", function()
  local actions = require("nvim_context_ipc.actions")
  local buffer = vim.api.nvim_get_current_buf()
  local old_path = root .. "/tests/diff-old-fixture.lua"
  local new_path = root .. "/tests/diff-new-fixture.lua"
  vim.api.nvim_buf_set_name(buffer, old_path)
  vim.bo[buffer].buflisted = true
  vim.api.nvim_buf_set_lines(buffer, 0, -1, false, { "old" })
  local callback_ok, callback_value
  local ok, pending = actions.invoke("openDiff", {
    old_file_path = old_path,
    new_file_path = new_path,
    new_file_contents = "new\n",
  }, function(result_ok, result_value)
    callback_ok, callback_value = result_ok, result_value
  end)
  assert(ok and pending.deferred)
  assert(actions.reject_diff(pending.id))
  assert(callback_ok == true)
  assert(callback_value.content[1].text == "DIFF_REJECTED")
end)

test("Claude waits for MCP initialization before publishing selection", function()
  local claude = require("nvim_context_ipc.claude")
  local buffer = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_set_name(buffer, root .. "/tests/connection-fixture.lua")
  vim.bo[buffer].buflisted = true
  vim.api.nvim_buf_set_lines(buffer, 0, -1, false, { "return true" })
  local messages = {}
  local client = { handshaken = true, closed = false }
  function client:send_json(message) messages[#messages + 1] = message end
  claude._handle_connect(client)
  assert(#messages == 0, "selection_changed must wait for MCP initialization")
end)

test("Claude marks the WebSocket ready after MCP initialized", function()
  local claude = require("nvim_context_ipc.claude")
  local messages = {}
  local client = { handshaken = true, closed = false }
  function client:send_json(message) messages[#messages + 1] = message end
  claude._handle_connect(client)
  claude._on_message(client, { jsonrpc = "2.0", id = 1, method = "initialize", params = {} })
  assert(client.mcp_ready == false)
  claude._on_message(client, { jsonrpc = "2.0", method = "notifications/initialized" })
  assert(client.mcp_ready == true)
  client.closed = true
end)

test("Claude keeps only the newest WebSocket client", function()
  local claude = require("nvim_context_ipc.claude")
  local previous = { closed = false }
  function previous:close() self.closed = true end
  local current = { closed = false }
  function current:close() self.closed = true end
  claude._replace_previous_clients({ previous = previous, current = current }, current)
  assert(previous.closed == true)
  assert(current.closed == false)
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

test("Context snapshot reads an active characterwise Visual selection", function()
  local context = require("nvim_context_ipc.context")
  local buffer = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_set_name(buffer, root .. "/tests/visual-character-fixture.lua")
  vim.bo[buffer].buflisted = true
  vim.api.nvim_buf_set_lines(buffer, 0, -1, false, { "alpha beta", "second line" })
  vim.cmd("normal! gg0ve")
  local snapshot = context.snapshot()
  assert(snapshot.selection, "active Visual selection must be present")
  assert(snapshot.selection.mode == "character")
  assert(snapshot.selection.text == "alpha", "active Visual text must come from the live selection")
  assert(snapshot.selection.start.line == 0 and snapshot.selection.start.character == 0)
  assert(snapshot.selection["end"].line == 0 and snapshot.selection["end"].character == 5)
  vim.cmd("normal! \27")
end)

test("Context snapshot reads an active Visual Line selection", function()
  local context = require("nvim_context_ipc.context")
  local buffer = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_set_name(buffer, root .. "/tests/visual-line-fixture.lua")
  vim.bo[buffer].buflisted = true
  vim.api.nvim_buf_set_lines(buffer, 0, -1, false, { "alpha", "beta", "gamma" })
  vim.cmd("normal! ggVj")
  local snapshot = context.snapshot()
  assert(snapshot.selection, "active Visual Line selection must be present")
  assert(snapshot.selection.mode == "line")
  assert(snapshot.selection.text == "alpha\nbeta", "Visual Line text must include every selected line")
  assert(snapshot.selection.start.line == 0 and snapshot.selection.start.character == 0)
  assert(snapshot.selection["end"].line == 2 and snapshot.selection["end"].character == 0)
  vim.cmd("normal! \27")
end)

test("Claude publishes the live Visual Line selection", function()
  local claude = require("nvim_context_ipc.claude")
  local buffer = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_set_name(buffer, root .. "/tests/claude-visual-line-fixture.lua")
  vim.bo[buffer].buflisted = true
  vim.api.nvim_buf_set_lines(buffer, 0, -1, false, { "first", "second", "third" })
  vim.cmd("normal! ggVj")
  local messages = {}
  local client = { closed = false, mcp_ready = true }
  function client:send_json(message) messages[#messages + 1] = message end
  claude._publish_selection(client)
  assert(#messages == 1 and messages[1].method == "selection_changed")
  assert(messages[1].params.text == "first\nsecond")
  assert(messages[1].params.selection.start.line == 0)
  assert(messages[1].params.selection["end"].line == 2)
  assert(messages[1].params.selection.isEmpty == false)
  vim.cmd("normal! \27")
end)

test("Visual Line selection reaches the debounced publisher", function()
  local plugin = require("nvim_context_ipc")
  local buffer = vim.api.nvim_get_current_buf()
  local state_path = vim.fn.tempname()
  vim.api.nvim_buf_set_name(buffer, root .. "/tests/visual-publish-fixture.lua")
  vim.bo[buffer].buflisted = true
  vim.api.nvim_buf_set_lines(buffer, 0, -1, false, { "first", "second", "third" })
  plugin.setup({
    auto_start = false,
    state_file = state_path,
    codex = { enabled = false, auto_start = false },
    claude = { enabled = false, auto_start = false },
  })
  vim.cmd("normal! ggVj")
  local published
  assert(vim.wait(500, function()
    local content = require("nvim_context_ipc.util").read_file(state_path)
    if not content then return false end
    local ok, value = pcall(vim.json.decode, content)
    if ok and value.selection and value.selection.text == "first\nsecond" then
      published = value
      return true
    end
    return false
  end, 10), "Visual Line selection must reach the published context")
  assert(published.selection.mode == "line")
  assert(published.selection["end"].line == 2)
  vim.cmd("normal! \27")
  plugin.stop()
  vim.fn.delete(state_path)
end)

print("all nvim-context-ipc tests passed")
