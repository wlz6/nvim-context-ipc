local util = require("nvim_context_ipc.util")

local M = {}

local state = {
  latest_selection = nil,
  snapshot = nil,
  opts = {},
}

local function utf16_width(codepoint)
  return codepoint > 0xFFFF and 2 or 1
end

local function utf16_col(text, byte_col)
  local index = 1
  local units = 0
  local limit = math.max(0, math.min(byte_col or 0, #text))
  while index <= limit do
    local first = text:byte(index)
    local codepoint
    local width
    if first < 0x80 then
      codepoint, width = first, 1
    elseif first < 0xE0 then
      codepoint = (first - 0xC0) * 0x40 + (text:byte(index + 1) - 0x80)
      width = 2
    elseif first < 0xF0 then
      codepoint = (first - 0xE0) * 0x1000 + (text:byte(index + 1) - 0x80) * 0x40 + (text:byte(index + 2) - 0x80)
      width = 3
    else
      codepoint = (first - 0xF0) * 0x40000 + (text:byte(index + 1) - 0x80) * 0x1000 + (text:byte(index + 2) - 0x80) * 0x40 + (text:byte(index + 3) - 0x80)
      width = 4
    end
    if index + width - 1 > limit then
      break
    end
    units = units + utf16_width(codepoint)
    index = index + width
  end
  return units
end

local function workspace_roots(buffer)
  local roots = {}
  local seen = {}
  local function add(path)
    local normalized = util.normalize_path(path)
    if normalized and not seen[normalized] then
      seen[normalized] = true
      roots[#roots + 1] = normalized
    end
  end

  add(vim.fn.getcwd())
  if vim.lsp and vim.lsp.get_clients then
    for _, client in ipairs(vim.lsp.get_clients({ bufnr = buffer })) do
      if client.workspace_folders then
        for _, folder in ipairs(client.workspace_folders) do
          add(vim.uri_to_fname(folder.uri))
        end
      elseif client.config and client.config.root_dir then
        add(client.config.root_dir)
      end
    end
  end
  return roots
end

local function current_workspace(buffer, path)
  local roots = workspace_roots(buffer)
  for _, root in ipairs(roots) do
    if path and util.is_within(path, root) then
      return root, roots
    end
  end
  return roots[1] or util.normalize_path(vim.fn.getcwd()), roots
end

local function line_text(buffer, line)
  return vim.api.nvim_buf_get_lines(buffer, line, line + 1, false)[1] or ""
end

local function marks_selection(buffer)
  local start_mark = vim.api.nvim_buf_get_mark(buffer, "<")
  local end_mark = vim.api.nvim_buf_get_mark(buffer, ">")
  if not start_mark or not end_mark or start_mark[1] <= 0 or end_mark[1] <= 0 then
    return nil
  end
  local mode = vim.fn.visualmode()
  local start_line, start_col = start_mark[1] - 1, start_mark[2]
  local end_line, end_col = end_mark[1] - 1, end_mark[2]
  if start_line > end_line or (start_line == end_line and start_col > end_col) then
    start_line, end_line = end_line, start_line
    start_col, end_col = end_col, start_col
  end

  local text
  if mode == "V" then
    start_col = 0
    end_col = 0
    text = util.text_from_lines(vim.api.nvim_buf_get_lines(buffer, start_line, end_line + 1, false))
    end_line = end_line + 1
  elseif mode == "\22" then
    text = util.text_from_lines(vim.api.nvim_buf_get_text(buffer, start_line, start_col, end_line, end_col + 1, {}))
    end_col = end_col + 1
  else
    text = util.text_from_lines(vim.api.nvim_buf_get_text(buffer, start_line, start_col, end_line, end_col + 1, {}))
    end_col = end_col + 1
  end

  local start_text = line_text(buffer, start_line)
  local end_text = line_text(buffer, math.min(end_line, vim.api.nvim_buf_line_count(buffer) - 1))
  return {
    mode = mode == "V" and "line" or mode == "\22" and "block" or "character",
    start = { line = start_line, character = utf16_col(start_text, start_col) },
    ["end"] = { line = end_line, character = utf16_col(end_text, end_col) },
    text = text,
    isEmpty = text == "",
  }
end

local function active_selection(buffer)
  local mode = vim.fn.mode()
  if mode == "v" or mode == "V" or mode == "\22" then
    return marks_selection(buffer)
  end
  local cursor = vim.api.nvim_win_get_cursor(0)
  local text = line_text(buffer, cursor[1] - 1)
  local character = utf16_col(text, cursor[2])
  return {
    mode = "character",
    start = { line = cursor[1] - 1, character = character },
    ["end"] = { line = cursor[1] - 1, character = character },
    text = "",
    isEmpty = true,
  }
end

local function diagnostics(buffer)
  local result = {}
  for _, item in ipairs(vim.diagnostic.get(buffer)) do
    local severity = ({
      [vim.diagnostic.severity.ERROR] = "Error",
      [vim.diagnostic.severity.WARN] = "Warning",
      [vim.diagnostic.severity.INFO] = "Information",
      [vim.diagnostic.severity.HINT] = "Hint",
    })[item.severity] or "Information"
    result[#result + 1] = {
      range = {
        start = { line = item.lnum or 0, character = item.col or 0 },
        ["end"] = { line = item.end_lnum or item.lnum or 0, character = item.end_col or item.col or 0 },
      },
      message = item.message,
      severity = severity,
      source = item.source,
      code = item.code,
    }
  end
  return result
end

local function listed_buffers(active_buffer)
  local result = {}
  local seen = {}
  local buffers = vim.api.nvim_list_bufs()
  table.sort(buffers)
  for _, buffer in ipairs(buffers) do
    if vim.api.nvim_buf_is_valid(buffer) and vim.bo[buffer].buflisted then
      local path = vim.api.nvim_buf_get_name(buffer)
      if path ~= "" then
        path = util.normalize_path(path)
        if not seen[path] then
          seen[path] = true
          result[#result + 1] = {
            label = util.basename(path),
            path = path,
            fsPath = path,
            uri = util.file_uri(path),
            languageId = vim.bo[buffer].filetype,
            isActive = buffer == active_buffer,
            isDirty = vim.bo[buffer].modified,
            buffer = buffer,
          }
        end
      end
    end
  end
  return result
end

local function buffer_text(buffer, max_bytes)
  local lines = {}
  local used = 0
  local truncated = false
  for _, line in ipairs(vim.api.nvim_buf_get_lines(buffer, 0, -1, false)) do
    local bytes = #line + 1
    if used + bytes > max_bytes then
      truncated = true
      break
    end
    lines[#lines + 1] = line
    used = used + bytes
  end
  return { text = util.text_from_lines(lines), bytes = used, truncated = truncated, lineCount = vim.api.nvim_buf_line_count(buffer) }
end

function M.setup(opts)
  state.opts = opts or {}
end

function M.snapshot(options)
  options = options or {}
  local buffer = options.buffer or vim.api.nvim_get_current_buf()
  if not vim.api.nvim_buf_is_valid(buffer) then
    return { workspaceFolders = { util.normalize_path(vim.fn.getcwd()) }, openTabs = {} }
  end
  local path = vim.api.nvim_buf_get_name(buffer)
  path = path ~= "" and util.normalize_path(path) or nil
  local root, roots = current_workspace(buffer, path)
  local active = path and active_selection(buffer) or nil
  local cursor = vim.api.nvim_win_get_cursor(0)
  local file = nil
  if path then
    file = {
      label = util.basename(path),
      path = util.relative_path(path, root),
      fsPath = path,
      uri = util.file_uri(path),
      languageId = vim.bo[buffer].filetype,
      isDirty = vim.bo[buffer].modified,
      selection = active and { start = active.start, ["end"] = active["end"] } or nil,
      activeSelectionContent = active and active.text or "",
      selections = {},
    }
  end
  local result = {
    version = 1,
    updatedAt = os.date("!%Y-%m-%dT%H:%M:%SZ"),
    nvimPid = vim.fn.getpid(),
    cwd = util.normalize_path(vim.fn.getcwd()),
    workspaceRoot = root,
    workspaceFolders = roots,
    activeFile = file,
    openTabs = listed_buffers(buffer),
    current = path and {
      buffer = buffer,
      path = path,
      filetype = vim.bo[buffer].filetype,
      modified = vim.bo[buffer].modified,
      cursor = { line = cursor[1], column = cursor[2] + 1 },
    } or nil,
    selection = active,
    diagnostics = diagnostics(buffer),
  }
  if options.include_buffer_text or state.opts.include_buffer_text then
    result.buffer = buffer_text(buffer, state.opts.max_buffer_bytes or 1024 * 1024)
  end
  if active and not active.isEmpty then
    state.latest_selection = active
  end
  state.snapshot = result
  return result
end

function M.latest_selection()
  return state.latest_selection
end

function M.current_selection()
  local snapshot = M.snapshot()
  return snapshot.selection
end

function M.workspace_folders()
  local snapshot = state.snapshot or M.snapshot()
  local result = {}
  for _, path in ipairs(snapshot.workspaceFolders or {}) do
    result[#result + 1] = { name = util.basename(path), uri = util.file_uri(path), path = path }
  end
  return result
end

function M.diagnostics(path)
  local target = path and util.normalize_path(path) or nil
  local result = {}
  for _, buffer in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(buffer) then
      local buffer_path = util.normalize_path(vim.api.nvim_buf_get_name(buffer))
      if buffer_path and (not target or buffer_path == target) then
        local items = diagnostics(buffer)
        if #items > 0 or target then
          result[#result + 1] = { uri = util.file_uri(buffer_path), filePath = buffer_path, diagnostics = items }
        end
      end
    end
  end
  return result
end

function M.buffer_for_path(path)
  local target = util.normalize_path(path)
  if not target then
    return nil
  end
  for _, buffer in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(buffer) and util.normalize_path(vim.api.nvim_buf_get_name(buffer)) == target then
      return buffer
    end
  end
  return nil
end

return M
