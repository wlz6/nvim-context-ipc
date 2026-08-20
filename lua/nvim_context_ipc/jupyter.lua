local util = require("nvim_context_ipc.util")

local uv = util.uv
local M = {}
local state = { worker = nil, stdout_buffer = "", queue = {}, current = nil }

local WORKER = [=[
import base64, contextlib, io, json, os, sys, traceback

def emit(value):
    sys.stdout.write(json.dumps(value, ensure_ascii=False) + "\n")
    sys.stdout.flush()

try:
    from jupyter_client import KernelManager
    km = KernelManager()
    km.start_kernel()
    client = km.client()
    client.start_channels()
    use_kernel = True
except Exception:
    use_kernel = False
    namespace = {}

def execute_kernel(code):
    msg_id = client.execute(code)
    content = []
    while True:
        message = client.get_iopub_msg(timeout=60)
        if message.get("parent_header", {}).get("msg_id") != msg_id:
            continue
        kind = message.get("msg_type")
        value = message.get("content", {})
        if kind == "stream":
            content.append({"type": "text", "text": value.get("text", "")})
        elif kind in ("execute_result", "display_data"):
            data = value.get("data", {})
            if "text/plain" in data:
                content.append({"type": "text", "text": data["text/plain"]})
            if "image/png" in data:
                content.append({"type": "image", "data": data["image/png"], "mimeType": "image/png"})
        elif kind == "error":
            content.append({"type": "text", "text": "\n".join(value.get("traceback", []))})
        elif kind == "status" and value.get("execution_state") == "idle":
            break
    return {"content": content}

def execute_fallback(code):
    output = io.StringIO()
    try:
        with contextlib.redirect_stdout(output), contextlib.redirect_stderr(output):
            compiled = compile(code, "<nvim-context-ipc>", "exec")
            exec(compiled, namespace, namespace)
        text = output.getvalue()
        return {"content": [{"type": "text", "text": text}]} if text else {"content": []}
    except Exception:
        return {"content": [{"type": "text", "text": output.getvalue() + traceback.format_exc()}]}

for line in sys.stdin:
    try:
        request = json.loads(line)
        result = execute_kernel(request["code"]) if use_kernel else execute_fallback(request["code"])
        emit(result)
    except Exception as exc:
        emit({"content": [{"type": "text", "text": str(exc)}], "isError": True})
]=]

local function fail_all(message)
  local current = state.current
  state.current = nil
  if current then current.callback(nil, message) end
  for _, item in ipairs(state.queue) do item.callback(nil, message) end
  state.queue = {}
end

local function stop_worker()
  if state.worker then
    if state.worker.stdin and not state.worker.stdin:is_closing() then state.worker.stdin:close() end
    if state.worker.stdout and not state.worker.stdout:is_closing() then state.worker.stdout:close() end
    if state.worker.stderr and not state.worker.stderr:is_closing() then state.worker.stderr:close() end
    if state.worker.handle and not state.worker.handle:is_closing() then state.worker.handle:kill(15) end
  end
  state.worker = nil
  state.stdout_buffer = ""
end

local function pump()
  if state.current or #state.queue == 0 then return end
  local item = table.remove(state.queue, 1)
  state.current = item
  local request = util.json_encode({ code = item.code }) .. "\n"
  local worker = state.worker
  if not worker or not worker.stdin or worker.stdin:is_closing() then
    state.current = nil
    item.callback(nil, "Python/Jupyter worker is not available")
    pump()
    return
  end
  worker.stdin:write(request, function(err)
    if err then
      local current = state.current
      state.current = nil
      if current then current.callback(nil, err) end
      stop_worker()
      pump()
    end
  end)
end

local function start_worker(opts)
  if state.worker then return true end
  local stdin = uv.new_pipe(false)
  local stdout = uv.new_pipe(false)
  local stderr = uv.new_pipe(false)
  local python = opts.python or "python3"
  local handle, pid_or_err = uv.spawn(python, { args = { "-u", "-c", WORKER }, stdio = { stdin, stdout, stderr } }, function(code, signal)
    if state.worker and state.worker.handle == handle then
      state.worker = nil
      fail_all("Python/Jupyter worker exited (code=" .. tostring(code) .. ", signal=" .. tostring(signal) .. ")")
    end
    if stdin and not stdin:is_closing() then stdin:close() end
    if stdout and not stdout:is_closing() then stdout:close() end
    if stderr and not stderr:is_closing() then stderr:close() end
  end)
  if not handle then
    stdin:close(); stdout:close(); stderr:close()
    return false, tostring(pid_or_err or "could not start Python")
  end
  state.worker = { handle = handle, pid = pid_or_err, stdin = stdin, stdout = stdout, stderr = stderr }
  stdout:read_start(function(err, data)
    if err then return fail_all(tostring(err)) end
    if not data then return end
    state.stdout_buffer = state.stdout_buffer .. data
    while true do
      local newline = state.stdout_buffer:find("\n", 1, true)
      if not newline then break end
      local line = state.stdout_buffer:sub(1, newline - 1)
      state.stdout_buffer = state.stdout_buffer:sub(newline + 1)
      local current = state.current
      if current then
        state.current = nil
        local ok, value = pcall(util.json_decode, line)
        vim.schedule(function()
          if ok then current.callback(value) else current.callback(nil, value) end
          pump()
        end)
      end
    end
  end)
  stderr:read_start(function() end)
  return true
end

function M.execute(code, callback, opts)
  opts = opts or {}
  local ok, err = start_worker(opts)
  if not ok then return vim.schedule(function() callback(nil, err) end) end
  state.queue[#state.queue + 1] = { code = code, callback = callback }
  pump()
end

function M.stop()
  fail_all("Python/Jupyter worker stopped")
  stop_worker()
end

return M
