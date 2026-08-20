# nvim-context-ipc

让 Neovim 同时为 Codex CLI、Claude Code 和 DeepSeek Harness（dsh）提供 IDE context：当前文件、选区、打开的文件、workspace、diagnostics，以及可复用的文件操作和 native diff。

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
- Codex provider：绑定 `$CODEX_HOME/ipc/ipc.sock`；陈旧且无法连接的 socket 会被安全清理，仍在使用的 socket 不会覆盖；
- 文件路径默认限制在当前 workspace；
- 文件打开、保存、diff 和关闭 tab 可用；
- `executeCode` 默认关闭，避免客户端执行任意代码；启用后优先使用 Jupyter kernel，没有 `jupyter_client` 时降级为持久 Python worker。
- 只读 stdio MCP bridge：`bin/nvim-context-ipc-mcp`，供需要显式 MCP 配置的 Codex/Claude 会话读取同一份内存快照。
- dsh Unix IPC：默认监听 `~/.cache/nvim-context-ipc/dsh.sock`，使用与 Codex 相同的 4 字节 little-endian JSON framing；dsh bundle 注册 context、打开文件、保存文档和 native diff 工具。

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
  dsh = {
    enabled = true,
    auto_start = true,
    -- socket_path = "~/.cache/nvim-context-ipc/dsh.sock",
  },
})
```

### DeepSeek Harness（dsh）插件

先启动 Neovim，再将本仓库作为 dsh bundle 安装到 profile：

```bash
dsh plugin --profile default add github:wlz6/nvim-context-ipc
```

启动该 profile 后，dsh 会注册以下工具：`nvim_context`、`nvim_open_file`、`nvim_save_document` 和 `nvim_open_diff`。工具请求通过本机 Unix socket 回到 Neovim，仍受 `permissions` 配置和 workspace 路径限制保护。socket 路径不一致时，在 profile 的 `cordis.patch.yml` 覆盖 bundle row 的 `config.socketPath`：

```yaml
- insert:
    - id: nvim-context-ipc
      name: dsh-nvim-context-ipc
      config:
        socketPath: /tmp/my-nvim-context.sock
        timeoutMs: 3000
```

这是一个纯 JavaScript bundle，不需要构建步骤；`timeoutMs` 只限制连接建立时间，`nvim_open_diff` 会一直等待用户保存或拒绝。GitHub 安装时仍应只安装自己信任的仓库。

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

启动顺序

1. 先启动 Neovim 并打开项目；
2. 在 Neovim 中确认 `:NvimContextStatus` 的 `providers.claude.running`、`providers.codex.running` 和 `providers.dsh.running`；
3. 通过 Neovim 的 ClaudeCode 窗口启动 Claude Code（配置已自动加入 `--ide`），或在现有 Claude 会话中重新运行 `/ide`；
4. 启动 Codex 后运行 `/ide`。

如果手动从 shell 启动 Claude Code，请使用 `claude --ide`。Codex 和 Neovim 必须运行在同一个 WSL 环境中。

插件更新后请先完全重启 Neovim 以加载新的 Lua 模块；运行期间仅需重连时，可执行 `:NvimContextStop`，再执行 `:NvimContextStart`，然后在 Claude 中重新运行 `/ide`。`:NvimContextStatus` 应显示 `claude.clients=1`。同一 workspace 同时只保留一个 Neovim IDE provider。

Claude 启动或重连时产生的短暂 `ECONNRESET` 属于 peer disconnect，插件会静默清理；只有其它非预期 WebSocket 错误才会显示通知。

## Claude 工具

支持 `openFile`、`openDiff`、`getCurrentSelection`、`getLatestSelection`、`getOpenEditors`、`getWorkspaceFolders`、`getDiagnostics`、`checkDocumentDirty`、`saveDocument`、`closeAllDiffTabs` 和 `executeCode`。`close_tab` 默认隐藏，可通过 `claude.expose_internal_tools = true` 暴露。

保存 diff 右侧 buffer 返回 `FILE_SAVED`；关闭 diff 或执行 `:NvimContextRejectDiff` 返回 `DIFF_REJECTED`。

## 环境要求

- Neovim 0.10+（当前开发环境为 0.12.4）；
- Unix/WSL：Codex direct socket 和 router；
- Claude provider 需要支持 `vim.uv`/`vim.loop` 的 Neovim；
- dsh provider 需要 Unix domain socket；Windows Named Pipe 适配尚未实现。
- `executeCode` 需要 Python；Jupyter kernel 需要 `jupyter_client`。

Codex IDE IPC 和 Claude IDE MCP 都属于目标客户端的私有/非稳定接口。使用 WSL 时，Neovim 与 Codex/Claude CLI 应运行在同一个 WSL 环境；跨 Windows/WSL 不会自动打通 Unix socket。
