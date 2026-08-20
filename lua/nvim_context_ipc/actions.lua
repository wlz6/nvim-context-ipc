local context = require("nvim_context_ipc.context")
local util = require("nvim_context_ipc.util")
local jupyter = require("nvim_context_ipc.jupyter")

local M = {}
local state = { opts = {}, diffs = {}, sequence = 0, notify = function() end }

local function permission(name)
  local permissions = state.opts.permissions or {}
  if permissions[name] == false then
    return false, "Permission denied by nvim-context-ipc configuration: " .. name
  end
  return true
end

local function allowed_path(path, write)
  local normalized = util.normalize_path(path)
  if not normalized then return nil, "filePath must be an absolute or expandable path" end
  local permissions = state.opts.permissions or {}
  if permissions.restrict_to_workspace ~= false then
    local allowed = false
    for _, root in ipairs(context.snapshot().workspaceFolders or {}) do
      if util.is_within(normalized, root) then allowed = true break end
    end
    if not allowed then
      return nil, "path is outside the active workspace"
    end
  end
  if write and permissions.allow_file_writes == false then
    return nil, "file writes are disabled by configuration"
  end
  return normalized
end

local function find_buffer(path)
  return context.buffer_for_path(path)
end

local function buffer_result(buffer, path)
  return {
    success = true,
    filePath = path,
    languageId = vim.bo[buffer].filetype,
    lineCount = vim.api.nvim_buf_line_count(buffer),
    isDirty = vim.bo[buffer].modified,
  }
end

local function byte_position(lines, offset)
  local before = lines:sub(1, offset - 1)
  local line = 0
  for _ in before:gmatch("\n") do line = line + 1 end
  local last_newline = before:match(".*()\n")
  local column = last_newline and (#before - last_newline) or #before
  return line, column
end

local function select_by_text(buffer, start_text, end_text, select_to_end)
  if not start_text and not end_text then return end
  local content = util.text_from_lines(vim.api.nvim_buf_get_lines(buffer, 0, -1, false))
  local start_at = start_text and content:find(start_text, 1, true) or 1
  if not start_at then return false, "startText was not found" end
  local finish_at
  if end_text then
    finish_at = content:find(end_text, start_at + #start_text, true)
    if not finish_at then return false, "endText was not found" end
    finish_at = finish_at + #end_text - 1
  else
    finish_at = start_at + #start_text - 1
  end
  local start_line, start_col = byte_position(content, start_at)
  local end_line, end_col = byte_position(content, finish_at + 1)
  if select_to_end then
    end_col = #(vim.api.nvim_buf_get_lines(buffer, end_line, end_line + 1, false)[1] or "")
  end
  vim.api.nvim_win_set_cursor(0, { start_line + 1, start_col })
  vim.fn.setpos("'<", { 0, start_line + 1, start_col + 1, 0 })
  vim.fn.setpos("'>", { 0, end_line + 1, end_col, 0 })
  return true
end

local function open_file(args)
  local path, err = allowed_path(args.filePath)
  if not path then return false, err end
  local ok, result = permission("allow_open_file")
  if not ok then return false, result end
  local buffer = find_buffer(path)
  if not buffer then
    local add_ok, add_err = pcall(function()
      buffer = vim.fn.bufadd(path)
      vim.fn.bufload(buffer)
    end)
    if not add_ok then return false, add_err end
  end
  if args.makeFrontmost ~= false then
    vim.api.nvim_set_current_buf(buffer)
  end
  if args.makeFrontmost ~= false then
    local selected, select_err = select_by_text(buffer, args.startText, args.endText, args.selectToEndOfLine)
    if selected == false then return false, select_err end
  end
  if args.makeFrontmost == false then
    return true, util.mcp_json(buffer_result(buffer, path))
  end
  return true, util.mcp_text("Opened file: " .. path)
end

local function current_selection()
  local value = context.current_selection()
  local snapshot = context.snapshot()
  if not value or not snapshot.activeFile then
    return util.mcp_json({ success = false, message = "No active editor found" })
  end
  return util.mcp_json({
    success = true,
    text = value.text,
    filePath = snapshot.activeFile.fsPath,
    selection = { start = value.start, ["end"] = value["end"] },
  })
end

local function latest_selection()
  local value = context.latest_selection()
  local snapshot = context.snapshot()
  if not value or not snapshot.activeFile then
    return util.mcp_json({ success = false, message = "No selection available" })
  end
  return util.mcp_json({ success = true, text = value.text, filePath = snapshot.activeFile.fsPath, selection = value })
end

local function open_editors()
  return util.mcp_json({ tabs = context.snapshot().openTabs or {} })
end

local function workspace_folders()
  local folders = context.workspace_folders()
  return util.mcp_json({ success = true, folders = folders, rootPath = folders[1] and folders[1].path or nil })
end

local function get_diagnostics(args)
  local path = args and args.uri and vim.uri_to_fname(args.uri) or nil
  return util.mcp_json(context.diagnostics(path))
end

local function check_dirty(args)
  local path, err = allowed_path(args.filePath)
  if not path then return false, err end
  local buffer = find_buffer(path)
  if not buffer then return util.mcp_json({ success = false, message = "Document not open: " .. path }) end
  return util.mcp_json({ success = true, filePath = path, isDirty = vim.bo[buffer].modified, isUntitled = false })
end

local function save_document(args)
  local path, err = allowed_path(args.filePath, true)
  if not path then return false, err end
  local ok, result = permission("allow_save_document")
  if not ok then return false, result end
  local buffer = find_buffer(path)
  if not buffer then return util.mcp_json({ success = false, message = "Document not open: " .. path }) end
  local write_ok, write_err = pcall(function()
    vim.api.nvim_buf_call(buffer, function() vim.cmd("silent noautocmd write") end)
  end)
  if not write_ok then return false, write_err end
  return util.mcp_json({ success = true, filePath = path, saved = true, message = "Document saved successfully" })
end

local function close_tab(args)
  local ok, result = permission("allow_close_tab")
  if not ok then return false, result end
  local requested = args.tab_name or args.filePath
  if type(requested) ~= "string" then return false, "tab_name is required" end
  for _, buffer in ipairs(vim.api.nvim_list_bufs()) do
    local path = vim.api.nvim_buf_get_name(buffer)
    if vim.api.nvim_buf_is_valid(buffer) and (path == requested or util.basename(path) == requested) then
      if vim.bo[buffer].modified and not args.force then return false, "tab has unsaved changes" end
      local delete_ok, delete_err = pcall(vim.api.nvim_buf_delete, buffer, { force = args.force == true })
      if not delete_ok then return false, delete_err end
      return util.mcp_text("TAB_CLOSED")
    end
  end
  return false, "tab not found: " .. requested
end

local function remove_diff(diff, status)
  if not diff or diff.resolved then return end
  diff.resolved = true
  if diff.autocmd then pcall(vim.api.nvim_del_autocmd, diff.autocmd) end
  if diff.new_buffer and vim.api.nvim_buf_is_valid(diff.new_buffer) then
    pcall(vim.api.nvim_buf_set_option, diff.new_buffer, "bufhidden", "wipe")
  end
  if diff.callback then diff.callback(status) end
  state.diffs[diff.id] = nil
end

local function close_diff_windows(diff)
  if diff.new_buffer and vim.api.nvim_buf_is_valid(diff.new_buffer) then
    for _, window in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_win_get_buf(window) == diff.new_buffer then
        pcall(vim.api.nvim_win_close, window, true)
      end
    end
    pcall(vim.api.nvim_buf_delete, diff.new_buffer, { force = true })
  end
  if diff.old_window and vim.api.nvim_win_is_valid(diff.old_window) then
    pcall(vim.api.nvim_set_current_win, diff.old_window)
  end
end

local function open_diff(args, callback)
  local allowed, err = permission("allow_open_diff")
  if not allowed then return false, err end
  local old_path
  old_path, err = allowed_path(args.old_file_path or args.new_file_path)
  if not old_path then return false, err end
  local new_path
  new_path, err = allowed_path(args.new_file_path or old_path, true)
  if not new_path then return false, err end
  if type(args.new_file_contents) ~= "string" then return false, "new_file_contents is required" end

  local old_buffer = find_buffer(old_path)
  if not old_buffer then
    local edit_ok, edit_err = pcall(function() vim.cmd("edit " .. vim.fn.fnameescape(old_path)) end)
    if not edit_ok then return false, edit_err end
    old_buffer = vim.api.nvim_get_current_buf()
  end
  local new_buffer = vim.api.nvim_create_buf(true, true)
  vim.api.nvim_buf_set_name(new_buffer, new_path)
  vim.api.nvim_buf_set_lines(new_buffer, 0, -1, false, util.lines_from_text(args.new_file_contents))
  vim.bo[new_buffer].bufhidden = "wipe"
  vim.bo[new_buffer].swapfile = false
  vim.bo[new_buffer].filetype = vim.filetype.match({ filename = new_path }) or ""
  vim.bo[new_buffer].modified = true

  local old_window = vim.api.nvim_get_current_win()
  vim.cmd("belowright vsplit")
  local new_window = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(new_window, new_buffer)
  vim.api.nvim_win_call(old_window, function() vim.cmd("diffthis") end)
  vim.api.nvim_win_call(new_window, function() vim.cmd("diffthis") end)
  if args.tab_name then vim.api.nvim_buf_set_name(new_buffer, new_path) end

  state.sequence = state.sequence + 1
  local id = tostring(state.sequence)
  local diff = { id = id, new_buffer = new_buffer, old_buffer = old_buffer, old_window = old_window, new_window = new_window, new_path = new_path, callback = callback }
  state.diffs[id] = diff
  local group = vim.api.nvim_create_augroup("nvim_context_ipc_diff_" .. id, { clear = true })
  diff.autocmd = vim.api.nvim_create_autocmd({ "BufWriteCmd", "BufWipeout" }, {
    group = group,
    buffer = new_buffer,
    callback = function(event)
      if event.event == "BufWriteCmd" then
        local lines = vim.api.nvim_buf_get_lines(new_buffer, 0, -1, false)
        local write_ok, write_err = pcall(vim.fn.writefile, lines, new_path, "b")
        if not write_ok then
          util.notify("Could not save proposed diff: " .. tostring(write_err), vim.log.levels.ERROR)
          return
        end
        vim.bo[new_buffer].modified = false
        remove_diff(diff, "FILE_SAVED")
        close_diff_windows(diff)
      else
        remove_diff(diff, "DIFF_REJECTED")
      end
    end,
  })
  return true, { deferred = true, id = id, close = function(status) close_diff_windows(diff); remove_diff(diff, status) end }
end

local function close_all_diff_tabs()
  local count = 0
  local diffs = {}
  for _, diff in pairs(state.diffs) do diffs[#diffs + 1] = diff end
  for _, diff in ipairs(diffs) do
    count = count + 1
    close_diff_windows(diff)
    remove_diff(diff, "DIFF_REJECTED")
  end
  return util.mcp_text("CLOSED_" .. count .. "_DIFF_TABS")
end

local function execute_code(args, callback)
  local allowed, err = permission("allow_execute_code")
  if not allowed then return false, err end
  if type(args.code) ~= "string" or args.code == "" then return false, "code is required" end
  jupyter.execute(args.code, function(result, execute_err)
    if execute_err then callback(false, execute_err) else callback(true, result) end
  end, state.opts)
  return true, { deferred = true }
end

function M.setup(opts, notify)
  state.opts = opts or {}
  state.notify = notify or state.notify
end

function M.resolve_diff(id, status)
  local diff = state.diffs[id]
  if not diff then return false end
  close_diff_windows(diff)
  remove_diff(diff, status or "DIFF_REJECTED")
  return true
end

function M.accept_diff(id)
  local diff = id and state.diffs[id]
  if not diff then return false, "diff not found" end
  local ok, err = pcall(vim.api.nvim_buf_call, diff.new_buffer, function() vim.cmd("silent write") end)
  if not ok then return false, err end
  return true
end

function M.reject_diff(id)
  return M.resolve_diff(id, "DIFF_REJECTED")
end

function M.close_all_diffs()
  return close_all_diff_tabs()
end

function M.invoke(name, args, callback)
  args = args or {}
  if name == "openFile" then
    local ok, result = open_file(args); return ok, ok and result or result
  elseif name == "getCurrentSelection" then return true, current_selection()
  elseif name == "getLatestSelection" then return true, latest_selection()
  elseif name == "getOpenEditors" then return true, open_editors()
  elseif name == "getWorkspaceFolders" then return true, workspace_folders()
  elseif name == "getDiagnostics" then
    local ok, result = get_diagnostics(args); return ok, ok and result or result
  elseif name == "checkDocumentDirty" then
    local ok, result = check_dirty(args); return ok, ok and result or result
  elseif name == "saveDocument" then
    local ok, result = save_document(args); return ok, ok and result or result
  elseif name == "close_tab" then
    local ok, result = close_tab(args); return ok, ok and result or result
  elseif name == "closeAllDiffTabs" then return true, close_all_diff_tabs()
  elseif name == "openDiff" then return open_diff(args, callback)
  elseif name == "executeCode" then return execute_code(args, callback)
  end
  return false, "tool not found: " .. tostring(name)
end

function M.pending_diffs()
  return state.diffs
end

return M
