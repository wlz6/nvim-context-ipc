local uv = vim.uv or vim.loop

local M = {}

M.uv = uv

function M.json_encode(value)
  return vim.json.encode(value)
end

function M.json_decode(value)
  return vim.json.decode(value)
end

function M.notify(message, level)
  vim.schedule(function()
    vim.notify(message, level or vim.log.levels.INFO, { title = "nvim-context-ipc" })
  end)
end

function M.defer(fn, delay)
  return vim.defer_fn(fn, delay or 0)
end

function M.now_ms()
  return math.floor((uv.hrtime() or 0) / 1000000)
end

function M.uuid()
  local bytes
  if uv.random then
    local ok, value = pcall(uv.random, 16)
    if ok and type(value) == "string" and #value == 16 then
      bytes = value
    end
  end
  if not bytes then
    local file = io.open("/dev/urandom", "rb")
    if file then
      bytes = file:read(16)
      file:close()
    end
  end
  if not bytes then
    return string.format("%x-%x", os.time(), M.now_ms())
  end
  local hex = bytes:gsub(".", function(char)
    return string.format("%02x", string.byte(char))
  end)
  return string.format("%s-%s-%s-%s-%s", hex:sub(1, 8), hex:sub(9, 12), hex:sub(13, 16), hex:sub(17, 20), hex:sub(21, 32))
end

function M.random_hex(bytes_count)
  local file
  local bytes
  if uv.random then
    local ok, value = pcall(uv.random, bytes_count)
    if ok and type(value) == "string" and #value == bytes_count then
      bytes = value
    end
  end
  if not bytes then
    file = io.open("/dev/urandom", "rb")
    if file then
      bytes = file:read(bytes_count)
      file:close()
    end
  end
  if type(bytes) ~= "string" or #bytes ~= bytes_count then
    return nil, "OS CSPRNG is unavailable"
  end
  return bytes:gsub(".", function(char)
    return string.format("%02x", string.byte(char))
  end)
end

function M.normalize_path(path)
  if type(path) ~= "string" or path == "" then
    return nil
  end
  local expanded = vim.fn.expand(path)
  local absolute = vim.fn.fnamemodify(expanded, ":p")
  return vim.fs.normalize(absolute):gsub("/$", "")
end

function M.dirname(path)
  return vim.fs.dirname(path) or "."
end

function M.basename(path)
  return vim.fs.basename(path) or path
end

function M.is_within(path, root)
  local child = M.normalize_path(path)
  local parent = M.normalize_path(root)
  if not child or not parent then
    return false
  end
  if child == parent then
    return true
  end
  return child:sub(1, #parent + 1) == parent .. "/"
end

function M.relative_path(path, root)
  local normalized = M.normalize_path(path)
  local normalized_root = M.normalize_path(root)
  if not normalized or not normalized_root then
    return path
  end
  if normalized == normalized_root then
    return "."
  end
  if M.is_within(normalized, normalized_root) then
    return normalized:sub(#normalized_root + 2)
  end
  return normalized
end

function M.file_uri(path)
  return vim.uri_from_fname(M.normalize_path(path) or path)
end

function M.read_file(path)
  local file, err = io.open(path, "rb")
  if not file then
    return nil, err
  end
  local content = file:read("*a")
  file:close()
  return content
end

function M.write_file_atomic(path, content, mode)
  local directory = M.dirname(path)
  vim.fn.mkdir(directory, "p", 448) -- 0700 for newly-created private directories.
  local temporary = string.format("%s.tmp.%d.%s", path, vim.fn.getpid(), M.uuid():gsub("-", ""))
  local fd, err = uv.fs_open(temporary, "wx", mode or 384) -- 0600
  if not fd then
    return false, err or "could not create temporary file"
  end
  local ok, write_err = pcall(function()
    local offset = 0
    while offset < #content do
      local written, fs_err = uv.fs_write(fd, content:sub(offset + 1), offset)
      if not written or written <= 0 then
        error(fs_err or "short write")
      end
      offset = offset + written
    end
  end)
  pcall(uv.fs_close, fd)
  if not ok then
    pcall(uv.fs_unlink, temporary)
    return false, write_err
  end
  local renamed, rename_err = uv.fs_rename(temporary, path)
  if not renamed then
    pcall(uv.fs_unlink, temporary)
    return false, rename_err or "could not rename temporary file"
  end
  pcall(uv.fs_chmod, path, mode or 384)
  return true
end

function M.lines_from_text(text)
  if text == "" then
    return { "" }
  end
  local lines = vim.split(text, "\n", { plain = true })
  if text:sub(-1) == "\n" then
    table.remove(lines, #lines)
  end
  return lines
end

function M.text_from_lines(lines)
  return table.concat(lines, "\n")
end

function M.mcp_text(text)
  return { content = { { type = "text", text = tostring(text) } } }
end

function M.mcp_json(value)
  return M.mcp_text(M.json_encode(value))
end

function M.safe_call(fn, ...)
  local args = { ... }
  local ok, result = pcall(function()
    return fn(unpack(args))
  end)
  if ok then
    return true, result
  end
  return false, result
end

function M.close_handle(handle)
  if handle and not handle:is_closing() then
    handle:close()
  end
end

return M
