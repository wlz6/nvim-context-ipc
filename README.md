# nvim-context-ipc

让 Neovim 同时为 Codex CLI 和 Claude Code 提供 IDE context：当前文件、选区、打开的文件、workspace、diagnostics，以及 Claude 的文件操作和 native diff。

协议研究、实现细节、测试记录和每轮开发日志见 [DEVELOPMENT.md](DEVELOPMENT.md)。

## 安装

以 lazy.nvim 为例：

```lua
{
  dir = "/home/sanzenin/test/nvim-context-ipc",
  name = "nvim-context-ipc",
  config = function()
    require("nvim_context_ipc").setup()
  end,
}
```

直接把仓库加入 `runtimepath` 时，`plugin/nvim-context-ipc.lua` 会自动启动默认配置。

## 默认行为

- Claude provider：监听 `127.0.0.1` 随机端口，写入 `~/.claude/ide/<port>.lock`，自动发送选区更新；
- Codex provider：尝试绑定 `$CODEX_HOME/ipc/ipc.sock`；若该 socket 已被 Codex 或其他进程占用，会拒绝覆盖并提示状态；
- 文件路径默认限制在当前 workspace；
- 文件打开、保存、diff 和关闭 tab 可用；
- `executeCode` 默认关闭，避免客户端执行任意代码；启用后优先使用 Jupyter kernel，没有 `jupyter_client` 时降级为持久 Python worker。
- 只读 stdio MCP bridge：`bin/nvim-context-ipc-mcp`，供需要显式 MCP 配置的 Codex/Claude 会话读取同一份内存快照。

## 配置

```lua
require("nvim_context_ipc").setup({
  permissions = {
    restrict_to_workspace = true,
    allow_file_writes = true,
    allow_open_file = true,
    allow_save_document = true,
    allow_open_diff = true,
    allow_close_tab = true,
    allow_execute_code = false,
  },
  claude = {
    port_min = 10000,
    port_max = 65535,
    -- expose_internal_tools = true, -- 暴露 close_tab
    -- python = "python3",
  },
  codex = {
    -- mode = "direct", -- 默认值
    -- socket_path = "~/.codex/ipc/ipc.sock",
  },
})
```

### 显式 MCP 配置

如果客户端不使用原生 IDE provider，可将下面的命令注册为只读 MCP：

```bash
codex mcp add nvim-context -- /home/sanzenin/test/nvim-context-ipc/bin/nvim-context-ipc-mcp
claude mcp add --scope user nvim-context -- /home/sanzenin/test/nvim-context-ipc/bin/nvim-context-ipc-mcp
```

Neovim 会将状态写入 `~/.cache/nvim-context-ipc/context.json`，目录权限为 `0700`，状态文件权限为 `0600`。

已有 Codex router 或需要多个 Neovim 实例时，先启动：

```bash
/home/sanzenin/test/nvim-context-ipc/bin/nvim-context-ipc-router
```

再配置：

```lua
codex = {
  mode = "router",
  provider_socket = "~/.cache/nvim-context-ipc/providers.sock",
}
```

## 命令

```vim
:NvimContextStatus
:NvimContextPublish
:NvimContextDump
:NvimContextStart
:NvimContextStop
:NvimContextAcceptDiff [id]
:NvimContextRejectDiff [id]
:NvimContextAtMention [lineStart] [lineEnd]
```

## Claude 工具

支持 `openFile`、`openDiff`、`getCurrentSelection`、`getLatestSelection`、`getOpenEditors`、`getWorkspaceFolders`、`getDiagnostics`、`checkDocumentDirty`、`saveDocument`、`closeAllDiffTabs` 和 `executeCode`。`close_tab` 默认隐藏，可通过 `claude.expose_internal_tools = true` 暴露。

保存 diff 右侧 buffer 返回 `FILE_SAVED`；关闭 diff 或执行 `:NvimContextRejectDiff` 返回 `DIFF_REJECTED`。

## 环境要求

- Neovim 0.10+（当前开发环境为 0.12.4）；
- Unix/WSL：Codex direct socket 和 router；
- Claude provider 需要支持 `vim.uv`/`vim.loop` 的 Neovim；
- `executeCode` 需要 Python；Jupyter kernel 需要 `jupyter_client`。

Codex IDE IPC 和 Claude IDE MCP 都属于目标客户端的私有/非稳定接口。使用 WSL 时，Neovim 与 Codex/Claude CLI 应运行在同一个 WSL 环境；跨 Windows/WSL 不会自动打通 Unix socket。
