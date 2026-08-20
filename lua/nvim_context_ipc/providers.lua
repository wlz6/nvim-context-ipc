local claude = require("nvim_context_ipc.claude")
local codex = require("nvim_context_ipc.codex")
local codex_client = require("nvim_context_ipc.codex_client")
local dsh = require("nvim_context_ipc.dsh")

local M = {}

-- Every provider implements the same small lifecycle surface:
--   start(opts), stop(), status(), and optionally publish().
-- Transport and protocol details stay inside the provider module; init.lua
-- only coordinates these common operations.
local function specs(opts)
  opts = opts or {}
  local codex_opts = opts.codex or {}
  return {
    { name = "claude", module = claude, opts = opts.claude or {}, enabled = opts.claude and opts.claude.enabled ~= false },
    {
      name = "codex",
      module = codex_opts.mode == "router" and codex_client or codex,
      opts = codex_opts,
      enabled = codex_opts.enabled ~= false,
    },
    { name = "dsh", module = dsh, opts = opts.dsh or {}, enabled = opts.dsh and opts.dsh.enabled ~= false },
  }
end

function M.start(opts, auto_only, notify, level)
  for _, provider in ipairs(specs(opts)) do
    if provider.enabled and (not auto_only or provider.opts.auto_start ~= false) then
      local ok, err = provider.module.start(provider.opts)
      if not ok and notify then
        notify(provider.name .. " context provider is unavailable: " .. tostring(err), level)
      end
    end
  end
end

function M.stop()
  -- Stop both Codex transports so changing mode on a reconfigure cannot leave
  -- the old direct socket or router connection alive.
  claude.stop()
  codex.stop()
  codex_client.stop()
  dsh.stop()
end

function M.publish(opts)
  for _, provider in ipairs(specs(opts)) do
    if provider.enabled and provider.module.publish then provider.module.publish() end
  end
end

function M.status(opts)
  local result = {}
  for _, provider in ipairs(specs(opts)) do result[provider.name] = provider.module.status() end
  return result
end

function M.at_mentioned(line_start, line_end)
  return claude.at_mentioned(line_start, line_end)
end

return M
