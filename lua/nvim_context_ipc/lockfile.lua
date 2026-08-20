local util = require("nvim_context_ipc.util")

local M = {}

local function lock_dir(opts)
  if opts and opts.lock_dir then
    return util.normalize_path(opts.lock_dir)
  end
  local configured = os.getenv("CLAUDE_CONFIG_DIR")
  if configured and configured ~= "" then
    return util.normalize_path(configured .. "/ide")
  end
  return util.normalize_path("~/.claude/ide")
end

local function lock_path(opts, port)
  return lock_dir(opts) .. "/" .. tostring(port) .. ".lock"
end

function M.directory(opts)
  return lock_dir(opts)
end

function M.create(opts, port, token)
  local directory = lock_dir(opts)
  local generated, err = token and token or util.random_hex(16)
  if not generated then
    return nil, err or "could not generate authentication token"
  end
  vim.fn.mkdir(directory, "p", 448)
  pcall(util.uv.fs_chmod, directory, 448)
  local data = {
    pid = vim.fn.getpid(),
    workspaceFolders = opts.workspace_folders,
    ideName = opts.ide_name or "Neovim",
    transport = "ws",
    authToken = generated,
  }
  local path = lock_path(opts, port)
  local ok, write_err = util.write_file_atomic(path, util.json_encode(data), 384)
  if not ok then
    return nil, write_err
  end
  pcall(util.uv.fs_chmod, path, 384)
  return path, generated
end

function M.remove(opts, port)
  local path = lock_path(opts, port)
  local ok, err = pcall(util.uv.fs_unlink, path)
  if not ok then
    return false, err
  end
  return true
end

function M.read(path)
  local content, err = util.read_file(path)
  if not content then return nil, err end
  local ok, value = pcall(util.json_decode, content)
  if not ok or type(value) ~= "table" then return nil, "invalid Claude lock file JSON" end
  local port = tonumber(vim.fn.fnamemodify(path, ":t:r"))
  if not port or type(value.authToken) ~= "string" then return nil, "invalid Claude lock file fields" end
  value.port = port
  value.path = path
  return value
end

function M.list(opts)
  local result = {}
  local directory = lock_dir(opts)
  for _, path in ipairs(vim.fn.glob(directory .. "/*.lock", false, true)) do
    local item = M.read(path)
    if item then result[#result + 1] = item end
  end
  table.sort(result, function(left, right) return (left.port or 0) < (right.port or 0) end)
  return result
end

local function pid_alive(pid)
  if type(pid) ~= "number" or pid <= 0 then return false end
  if util.uv.kill then
    local ok, result = pcall(util.uv.kill, pid, 0)
    return ok and result ~= false and result ~= nil
  end
  return vim.fn.isdirectory("/proc/" .. pid) == 1
end

function M.cleanup_stale(opts)
  local removed = 0
  for _, item in ipairs(M.list(opts)) do
    if item.pid ~= vim.fn.getpid() and not pid_alive(item.pid) then
      local ok = pcall(util.uv.fs_unlink, item.path)
      if ok then removed = removed + 1 end
    end
  end
  return removed
end

return M
