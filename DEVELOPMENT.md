# Neovim → Codex CLI / Claude Code IDE Context 实现文档

> 本文件是开发文档。README.md 只保留安装、配置和日常使用说明；协议研究、架构决策、测试记录和迭代日志统一维护在这里。

## 开发迭代日志

### 2026-08-21 — 首轮完整实现

- 新增共享 context collector：workspace、active file、UTF-16 选区、open tabs、未保存状态和 diagnostics；
- 新增 Codex direct provider：Unix socket、little-endian length-prefixed JSON、workspace 路由、discovery 和安全 socket 生命周期；
- 新增 Codex router provider client 与 `bin/nvim-context-ipc-router`，支持多个 Neovim 实例；
- 新增 Claude provider：RFC 6455 WebSocket、token header、lock file、MCP initialize/tools/list/tools/call、selection_changed/at_mentioned；
- 新增 `openFile`、`openDiff`、selection、editors、workspace、diagnostics、dirty/save/close、diff accept/reject 和持久 Python/Jupyter 执行；
- 新增权限、workspace path 限制、私有目录/文件权限、token 常量时间比较和不覆盖既有 Codex socket 的安全策略；
- 已完成 Neovim 0.12.4 模块加载、Codex framing、SHA-1/Base64、Claude WebSocket handshake/MCP tools/list 的本机检查；
- 发现并修复 Neovim fast event 中调用 API 的问题：WebSocket/Codex/Jupyter 回调现在统一切回主事件循环；
- 文档结构调整：使用说明放 README.md，研究与实现记录保留本文。

后续每次修改都要在本文追加日期、变更、验证命令和仍存在的兼容性风险；README 只有用户可见的安装/配置/命令发生变化时才更新。

### 2026-08-21 — 端到端验证与修复

执行过的验证包括：

```text
make test
python3 -m py_compile bin/nvim-context-ipc-router
Claude WebSocket: HTTP 101 → initialize → tools/list
Codex direct: Unix socket → ide-context success response
Codex router: provider register → workspaceRoot route → ide-context success response
openDiff: reject callback = DIFF_REJECTED
executeCode: persistent worker evaluates 2 + 3
```

本轮修复了四个实际问题：Codex success response 的默认分支错误、libuv fast event 中直接调用 Neovim API、router 不应修改用户已有父目录权限，以及 `openFile(makeFrontmost=false)` 错误切换当前 buffer。另修正最近选区在普通光标移动后被空选区覆盖的问题。

当前已知边界：

- Codex Windows Named Pipe provider 尚未实现；项目在 Unix/WSL 路径上完整验证；
- Codex 官方已有 router 占用默认 socket 时，Neovim 不会强行接管，需要使用本仓库的 router/provider 模式；
- Claude WebSocket/MCP 和 Codex IDE IPC 都是私有协议，兼容性必须随 CLI/扩展版本复测；
- `dsh` 在本机项目和 Neovim 配置中没有找到可识别的接口或命令，因此尚未加入专用适配器。

### 2026-08-21 — 替换旧 stdio MCP

为完整替换旧的 `wlz6/nvim-context-mcp`，新增 `bin/nvim-context-ipc-mcp`：它读取新的 Neovim 私有快照 `~/.cache/nvim-context-ipc/context.json`，提供只读的当前 context、buffer、diagnostics 和 open buffers 工具。Neovim 发布器现在同时服务原生 Codex/Claude provider 和该 bridge，快照使用临时文件 rename，目录/文件权限分别为 `0700`/`0600`。

已完成的本机配置迁移：

- 删除旧 Neovim `config.nvim_context_mcp` 加载入口；
- 加入 `/home/sanzenin/test/nvim-context-ipc` 的 lazy.nvim 本地插件配置；
- Codex `nvim-context` 从旧 wrapper 改为新 `bin/nvim-context-ipc-mcp`；
- Claude Code `nvim-context` 从旧 wrapper 改为新 `bin/nvim-context-ipc-mcp`；
- GitHub 旧仓库 `wlz6/nvim-context-mcp` 的删除已发起，但当前 token 缺少 `delete_repo` scope，等待设备授权。

> 项目实现状态：开发中，当前仓库已经包含可运行的 Neovim Lua provider。本文中的协议研究仍然保留作兼容性依据；“实现状态”与“当前已验证”小节以源码和本机测试结果为准。

## 当前实现

本项目现在提供一套共享的 Neovim context collector，以及两个独立适配器：

- Codex：Unix Domain Socket、4 字节 little-endian 长度前缀 JSON、`ide-context` 响应、workspace 匹配、discovery 响应和安全的 socket 生命周期；
- Claude Code：`127.0.0.1` WebSocket、RFC 6455 握手和 token header、`~/.claude/ide/<port>.lock`、MCP JSON-RPC、selection 通知、完整 IDE tool 集合；
- 编辑器动作：打开文件、范围定位、当前/最近选区、open editors、workspace folders、diagnostics、dirty 状态、保存、关闭 tab、原生 diff 接受/拒绝；
- Python/Jupyter：优先通过 `jupyter_client` 启动持久 kernel；没有该依赖时自动使用持久 Python namespace 作为降级执行器；
- 安全控制：lock/socket 目录和文件权限、loopback-only WebSocket、token 常量时间比较、workspace 路径限制、文件写入/保存/diff/执行代码权限开关。

Codex 的官方 socket 已经被其他 Codex 进程占用时，插件不会删除或覆盖它；这种情况下请使用下面的独立 router 模式，或在 Codex 未运行时让插件直接接管该 socket。协议属于 Codex private transport，Claude 的内部 IDE contract 也不是公开稳定 API，因此本项目会把适配器隔离并记录目标 CLI 版本。

## 安装与启动

将仓库目录加入 Neovim runtimepath（lazy.nvim 示例）：

```lua
{
  dir = "/home/sanzenin/test/nvim-context-ipc",
  name = "nvim-context-ipc",
  config = function()
    require("nvim_context_ipc").setup({
      permissions = {
        -- 默认限制为当前 workspace；需要跨 workspace 时显式关闭。
        restrict_to_workspace = true,
        allow_file_writes = true,
        -- executeCode 默认关闭，避免 Claude/其它客户端执行任意代码。
        allow_execute_code = false,
      },
    })
  end,
}
```

本项目也带有 `plugin/nvim-context-ipc.lua`，直接放入 runtimepath 时会自动 setup。启动后可使用：

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

默认启动 Claude provider；Codex provider 会尝试绑定 `$CODEX_HOME/ipc/ipc.sock`。如果该路径已经存在，插件会安全地报告占用状态而不作破坏性清理。

### 多 Neovim 实例的 Codex router

仓库内的 `bin/nvim-context-ipc-router` 是无第三方依赖的 Unix router：它占用 Codex 的 `ipc.sock`，另开 `providers.sock` 接收多个 Neovim provider，并按 `workspaceRoot` 转发 `ide-context` 请求。先启动 router，再在每个 Neovim 中使用：

```bash
/home/sanzenin/test/nvim-context-ipc/bin/nvim-context-ipc-router
```

```lua
require("nvim_context_ipc").setup({
  codex = {
    mode = "router",
    provider_socket = "~/.cache/nvim-context-ipc/providers.sock",
  },
})
```

router 不会覆盖一个仍能连接的 socket；退出时只清理自己创建的两个 socket。Codex private router/provider 注册消息不是官方稳定 API，本项目的 router 使用显式、版本化隔离的本地 provider contract，直接 provider 模式仍保留用于没有 router 的单实例场景。

## 工具与权限

Claude WebSocket MCP 的 `tools/list` 暴露 `openFile`、`openDiff`、`getCurrentSelection`、`getLatestSelection`、`getOpenEditors`、`getWorkspaceFolders`、`getDiagnostics`、`checkDocumentDirty`、`saveDocument`、`closeAllDiffTabs` 和 `executeCode`。`close_tab` 默认作为内部工具保留；可以配置 `claude.expose_internal_tools = true` 显式暴露。

`openDiff` 会创建两个 diff buffer。保存右侧 buffer 返回 `FILE_SAVED`，关闭或执行 `:NvimContextRejectDiff` 返回 `DIFF_REJECTED`。保存、打开、关闭和 diff 均经过权限及 workspace 路径检查。`executeCode` 使用持久 worker，首次调用会启动 Jupyter kernel；若环境没有 `jupyter_client`，响应会来自隔离的 Python 子进程 namespace。

## 验证记录

当前已在 Neovim 0.12.4、Codex CLI 0.148.0、Claude Code 2.1.226、LuaJIT 2.1 上完成模块加载、Codex framing、SHA-1/WebSocket 基础算法和启动/停止生命周期检查。真实 Claude/ Codex CLI 端到端检查仍需分别在 CLI 运行期间执行，因为两个协议都可能随 CLI/扩展版本变化；每次协议调整都要同步更新本节和测试。

> 调研日期：2026-08-20
>
> 目标：给出面向 Codex CLI、Claude Code 的 Neovim IDE context 实现方案，并保留向 Emacs、Obsidian、Zed、VS Code forks 以及其他 Agent 平台扩展的适配边界。

本文只整理与自动编辑器上下文有关的事实：发现、IPC/MCP 传输、lock file、选区/活动文件、diff、diagnostics 和兼容性。第三方仓库只做静态阅读，不执行其代码，也不复制大段源码。

## 结论摘要

可行，但 Codex 和 Claude Code 需要分别实现各自的适配器，而不是把 MCP server 改名成 VS Code context。

Codex 的 `/ide` 使用私有 Unix Socket / Named Pipe；Claude Code 在 VS Code 中使用扩展启动的本地 WebSocket MCP server。两者可以共享 Neovim 状态采集层，但不能共享传输层。

Codex CLI 的 `/ide` 不是 MCP 工具调用。CLI 会在发送用户消息前，通过本机 Unix Domain Socket（Windows 下是 Named Pipe）主动请求 `ide-context`，收到 `activeFile` 和 `openTabs` 后，在本地将其渲染为：

```text
# Context from my IDE setup:

## Active file: ...

## Active selection of the file:
...

## Open tabs:
...
```

因此，Neovim 插件只要实现同一条本地 IPC 协议，Codex CLI 的 `/ide` 就可以把 Neovim 当作 IDE context 提供者。

当前结论的依据是 Codex 官方仓库中的三部分源码：

- [IDE IPC transport](https://github.com/openai/codex/blob/main/codex-rs/tui/src/ide_context/ipc.rs)
- [IDE context 数据模型](https://github.com/openai/codex/blob/main/codex-rs/tui/src/ide_context.rs)
- [IDE context Prompt 注入](https://github.com/openai/codex/blob/main/codex-rs/tui/src/ide_context/prompt.rs)

证据等级：Codex 官方源码和 Claude 官方文档用于确认协议事实；`pengchengneo/Claude-Code` 是非官方 source-map 还原，仅用于交叉核对 CLI 侧行为；第三方编辑器插件用于确认可行的 provider 实现和工程细节，不代表 Anthropic 的稳定 API 承诺。

## 1. Codex CLI 的实际调用链

```text
用户在 Codex CLI 输入消息
        │
        │ /ide 已启用
        ▼
Codex TUI 调用 fetch_ide_context()
        │
        │ 连接本地 IPC Socket
        │ 发送 method = "ide-context"
        ▼
本地 IPC Router / IDE context client
        │
        │ VS Code、Cursor 或 Neovim 读取编辑器状态
        │ 返回 result.ideContext
        ▼
Codex TUI 解析 IdeContext
        │
        │ 把 IDE context 前置到用户文本
        ▼
Codex 请求模型
```

Codex 的 TUI 代码将这条传输称为 `private transport for fetching IDE context`。`fetch_ide_context` 在 Unix 上优先查找 `$CODEX_HOME/ipc/ipc.sock`，再回退到 `$TMPDIR/codex-ipc/ipc-$uid.sock`；Windows 使用 `\\.\pipe\codex-ipc`。

源码：[ipc.rs](https://github.com/openai/codex/blob/main/codex-rs/tui/src/ide_context/ipc.rs#L0-L25)、[Socket 路径](https://github.com/openai/codex/blob/main/codex-rs/tui/src/ide_context/ipc.rs#L133-L183)

## 2. 传输格式：长度前缀 JSON，而不是 MCP

Codex 原生 IPC 的单帧格式是：

```text
4 字节 little-endian 无符号长度
JSON payload
```

发送逻辑等价于：

```text
payload = UTF-8(JSON.stringify(message))
write_u32_le(payload.length)
write(payload)
```

读取逻辑是先读取 4 字节长度，再读取完整 JSON。它不是：

- MCP 的 stdio JSON-RPC；
- HTTP；
- WebSocket；
- 单纯的换行分隔 JSON。

源码：[写帧与读帧](https://github.com/openai/codex/blob/main/codex-rs/tui/src/ide_context/ipc.rs#L648-L679)

## 3. Codex 发出的请求

请求结构的关键字段如下：

```json
{
  "type": "request",
  "requestId": "uuid",
  "sourceClientId": "codex-tui",
  "version": 0,
  "method": "ide-context",
  "params": {
    "workspaceRoot": "/home/sanzenin/test/algo"
  }
}
```

字段含义：

| 字段 | 含义 |
| --- | --- |
| `type` | 请求消息类型，固定为 `request` |
| `requestId` | 本次请求的 UUID，响应必须原样返回 |
| `sourceClientId` | 请求方标识，Codex CLI 使用 `codex-tui` |
| `version` | 当前协议版本，源码使用 `0` |
| `method` | 请求方法，固定为 `ide-context` |
| `workspaceRoot` | Codex 当前工作区根目录 |

源码：[构造 `ide-context` 请求](https://github.com/openai/codex/blob/main/codex-rs/tui/src/ide_context/ipc.rs#L618-L646)

## 4. Codex 期望的响应

一个兼容响应可以采用以下结构：

```json
{
  "type": "response",
  "requestId": "uuid",
  "resultType": "success",
  "method": "ide-context",
  "handledByClientId": "nvim-client",
  "result": {
    "type": "broadcast",
    "ideContext": {
      "activeFile": {
        "label": "main.cpp",
        "path": "main.cpp",
        "fsPath": "/home/sanzenin/test/algo/main.cpp",
        "selection": {
          "start": { "line": 10, "character": 0 },
          "end": { "line": 20, "character": 0 }
        },
        "activeSelectionContent": "选中的代码",
        "selections": []
      },
      "openTabs": [
        { "label": "main.cpp", "path": "main.cpp" }
      ]
    }
  }
}
```

Codex CLI 当前真正解析的是：

```text
resultType == "success"
result.ideContext
```

它不要求 `handledByClientId` 必须是 `vscode-client`。官方测试样例中使用了 `vscode-client`，但 `extract_ide_context` 只读取 `result.ideContext`，所以 Neovim 使用 `nvim-client` 更合适。

源码：[响应解析](https://github.com/openai/codex/blob/main/codex-rs/tui/src/ide_context/ipc.rs#L780-L809)、[官方测试响应样例](https://github.com/openai/codex/blob/main/codex-rs/tui/src/ide_context/ipc.rs#L822-L856)

## 5. `IdeContext` 数据模型

Codex CLI 的数据模型如下：

```text
IdeContext
├── activeFile?: ActiveFile
│   ├── label: string
│   ├── path: string
│   ├── selection: Range
│   ├── activeSelectionContent: string
│   └── selections: Range[]
└── openTabs: FileDescriptor[]
    ├── label: string
    └── path: string
```

位置对象是：

```json
{
  "start": { "line": 0, "character": 0 },
  "end": { "line": 3, "character": 12 }
}
```

行号和字符列使用 0-based 坐标。Codex 在最终渲染“范围描述”时才加 1。

源码：[数据结构](https://github.com/openai/codex/blob/main/codex-rs/tui/src/ide_context.rs#L12-L49)

### 当前原生通道支持的内容

- 活动文件路径；
- 当前选区范围；
- 当前选中的文本；
- 多选区范围；
- 打开的文件标签与路径；
- 工作区根目录请求参数。

### 当前原生通道不直接支持的内容

当前 `IdeContext` 结构中没有专门的字段用于：

- 整个未保存 buffer 文本；
- Neovim diagnostics；
- LSP references；
- workspace symbols；
- 代码操作或 diff 接受/拒绝。

因此建议保留 MCP 作为补充：原生 IPC 负责 VS Code 风格的自动 IDE context，MCP 负责完整未保存 buffer、诊断和 LSP 数据。

## 6. Codex 如何注入 Prompt

Codex 收到 `ideContext` 后，不会发起模型可见的工具调用，而是在本地将上下文前置到用户的文本消息：

```text
# Context from my IDE setup:

## Active file: main.cpp

## Active selection of the file:
...

## Open tabs:
- main.cpp: main.cpp

## My request for Codex:
请修复这个问题
```

当前限制包括：

- 活动选区最多渲染 40,000 个字符；
- 最多渲染 100 个打开的 tab；
- 打开 tab 的总渲染长度最多 20,000 个字符。

源码：[Prompt 注入](https://github.com/openai/codex/blob/main/codex-rs/tui/src/ide_context/prompt.rs#L7-L24)、[上下文渲染限制](https://github.com/openai/codex/blob/main/codex-rs/tui/src/ide_context/prompt.rs#L88-L154)

## 7. Router、client 和 provider 角色

不能简单地把 Neovim 插件写成一个 MCP server，然后期待 Codex `/ide` 找到它。两条链路的角色不同：

```text
MCP：
Codex ──stdio──> MCP server ──tools/call──> 结果

原生 IDE IPC：
Codex TUI ──本地 IPC──> IPC Router ──ide-context──> IDE provider
```

Codex TUI 自己是一个短连接请求方：发送一次 `ide-context`，等待匹配 `requestId` 的响应，然后关闭或结束本次连接。它同时能够处理 Router 在等待期间发来的几类消息：

- `broadcast`：忽略；
- `client-discovery-request`：返回 `canHandle: false`；
- 未支持的 `request`：返回 `no-handler-for-request`；
- 其他非预期消息：报协议错误。

源码：[响应循环与 discovery 处理](https://github.com/openai/codex/blob/main/codex-rs/tui/src/ide_context/ipc.rs#L708-L754)

### 简化实现

如果只考虑：

```text
一个 Neovim 实例 + 一个 Codex CLI
```

可以让 Neovim 在 Socket 空闲时直接成为本地 provider/router，收到请求后立即生成响应。

### 完整实现

如果还要兼容 VS Code、Cursor、Codex App 或多个 Neovim 实例，则需要处理：

1. Socket 路径竞争；
2. Router 角色和 client 角色；
3. client 注册/初始化；
4. `client-discovery-request`；
5. 按 `workspaceRoot` 选择正确的 Neovim 实例；
6. 连接断开和 Socket 清理；
7. 同一用户权限校验。

官方 CLI 源码主要公开了“客户端请求侧”和响应数据合同，没有提供完整的、稳定的 IDE provider 注册 API。因此 Router 的注册细节应当视为私有协议的一部分，必须在目标 Codex CLI 版本上做集成测试。

## 8. Socket 安全要求

Codex 在 Unix 上不会无条件连接任意 Socket。源码会检查：

- Socket 父目录属于当前用户；
- 父目录不能对其他用户可写；
- Socket 本身属于当前用户；
- 对端进程 UID 与当前用户一致。

因此 Neovim 插件必须：

```text
创建目录：0700
创建 Socket 后限制权限
不要使用 TCP 端口暴露服务
不要允许其他用户接入
```

这也是采用 Unix Domain Socket 而不是 localhost TCP 的重要原因。

源码：[Socket 所有权和权限校验](https://github.com/openai/codex/blob/main/codex-rs/tui/src/ide_context/ipc.rs#L494-L591)

## 9. Neovim 插件的推荐架构

建议新项目拆成以下模块：

```text
nvim-context-ipc/
├── README.md
├── lua/
│   └── nvim_context_ipc/
│       ├── init.lua       # setup、启动和停止
│       ├── protocol.lua   # 4 字节长度前缀 JSON 帧
│       ├── context.lua    # 当前 buffer、选区、tab、workspace
│       ├── socket.lua     # Unix Socket 生命周期
│       ├── router.lua     # router/client/discovery
│       └── prompt.lua     # 可选的 :CodexIdeContext 调试输出
└── tests/
```

### `context.lua`

优先从 Neovim 内存直接读取：

```text
vim.api.nvim_get_current_buf()
vim.api.nvim_buf_get_name(bufnr)
vim.api.nvim_win_get_cursor(0)
vim.fn.mode()
vim.fn.getpos("v")
vim.api.nvim_buf_get_text(...)
vim.api.nvim_list_bufs()
```

不要把磁盘上的 `context.json` 作为原生 IPC 的唯一数据源。磁盘快照可以作为 MCP 的兼容后备，但原生 `/ide` 请求发生时应该直接读取当前 Neovim 状态，避免光标和选区过期。

### 选区转换

当前已有 MCP 采集逻辑使用 1-based 行列，而 Codex 原生协议使用 0-based 行列。转换时应明确分开：

```text
Neovim API 内部坐标
        ↓
Codex IdeContext：0-based line / character
        ↓
Codex prompt renderer：显示范围时再 +1
```

最容易出现的错误是把 Neovim 的 1-based 行号直接写入 `activeFile.selection`，导致 Codex 显示选区整体偏移一行。

### `socket.lua`

负责：

1. 创建 `$CODEX_HOME/ipc`；
2. 绑定 Unix Socket；
3. 监听连接；
4. 读取 4 字节长度和 JSON；
5. 写回同样格式的响应；
6. 处理连接关闭和异常；
7. 清理残留 Socket。

### `router.lua`

第一阶段可以只处理 `ide-context`。完整版本再处理 client discovery 和多实例路由。

路由规则建议是：

```text
request.params.workspaceRoot
        == Neovim 当前工作区根目录
```

只有匹配的 Neovim 实例回答 `canHandle: true` 或返回自己的 `ideContext`，避免多个项目窗口互相串上下文。

## 10. 与当前本机实现的对应关系

当前 MCP 实现位于：

```text
/home/sanzenin/test/nvim-context-mcp/src/nvim_context_mcp/server.py
/home/sanzenin/.config/nvim/lua/config/nvim_context_mcp.lua
```

当前实现的优点：

- 能读取未保存 buffer；
- 能读取 diagnostics；
- 能读取 listed buffers；
- 已经验证 MCP 工具可以被当前 Codex 会话发现和调用；
- 状态文件使用临时文件 + rename，避免半写入 JSON。

当前实现不能直接承担原生 `/ide` 的原因：

| 当前 MCP 实现 | Codex 原生 IDE IPC |
| --- | --- |
| stdin/stdout | Unix Domain Socket / Named Pipe |
| 换行分隔 JSON-RPC | 4 字节长度前缀 JSON |
| `initialize` / `tools/list` / `tools/call` | `ide-context` request/response |
| 模型决定是否调用工具 | Codex CLI 发送消息前自动拉取 |
| 能提供完整 buffer、diagnostics | 原生模型主要消费 activeFile、selection、openTabs |

因此建议保留现有 MCP server，并在本项目中增加一条原生 IPC 通道，而不是把两者强行合并成一个协议。

## 11. 实现和验证计划

### 阶段 A：协议最小闭环

1. 在 `/home/sanzenin/test/nvim-context-ipc` 建立 Lua 模块；
2. 实现长度前缀 JSON 编解码；
3. 实现单 Socket 直接响应模式；
4. 返回固定的 `activeFile` 和 `openTabs`；
5. 用真实 Codex CLI 执行 `/ide` 验证。

### 阶段 B：接入真实 Neovim 状态

1. 活动 buffer → `activeFile`；
2. Visual 选区 → `selection` 与 `activeSelectionContent`；
3. listed buffers / tabs → `openTabs`；
4. cwd 或 LSP workspace folder → `workspaceRoot` 匹配；
5. 用临时文件或测试 buffer 验证未保存选区。

### 阶段 C：Router/client 兼容

1. 多个 Neovim 实例；
2. Codex App/VS Code 已占用 Socket；
3. client 初始化；
4. discovery 请求；
5. 断线重连；
6. Socket 权限和残留清理。

### 阶段 D：MCP 补充能力

继续通过现有 MCP 提供：

- 完整未保存 buffer；
- diagnostics；
- LSP references；
- workspace symbols；
- 需要模型主动调用的扩展信息。

## 12. 风险与边界

### 私有协议变化

Codex 源码将它称为 private transport，当前接口不是稳定公共 API。实现时应记录已测试的 Codex CLI 版本；本机当前版本为 `codex-cli 0.148.0`。

### WSL 边界

Unix Socket 只在同一个 Linux/WSL 环境内可见。如果 Neovim 在 WSL 中，而 Codex CLI 在 Windows 原生环境中运行，两者不能直接共享 WSL 的 Unix Socket。最稳定的组合是：

```text
Neovim：WSL
Codex CLI：WSL
Socket：WSL 文件系统
```

如果必须跨 WSL/Windows，则需要 Windows Named Pipe 或额外桥接层，不能简单地把 Unix Socket 路径写成 Windows 路径。

### 原生 IDE context 的信息范围

它不是一个通用 IDE 数据总线。原生协议重点是：

```text
当前文件 + 当前选区 + 打开文件
```

完整 buffer 和 diagnostics 仍然适合通过 MCP 提供。

## 13. Claude Code 的 IDE Context

### 13.1 公开资料确认的真实架构

Claude Code 的 IDE context 不是 VS Code Agent Host Protocol 直接提供的。Claude Code 官方文档明确描述了另一条链路：

```text
VS Code Claude Code 扩展
        │ 启动
        ▼
本机 loopback WebSocket MCP server，server name = ide
        │ 通过 lock file 发现端口和 token
        ▼
Claude Code CLI 自动连接
        │
        ├── 将当前选区和活动文件路径附加到每次 prompt
        ├── 读取 VS Code diagnostics
        ├── 打开原生 diff
        ├── 读取/保存选区或文件
        └── 在 Jupyter 中执行代码
```

官方文档确认的细节：

| 项目 | Claude Code VS Code 集成的行为 |
| --- | --- |
| 服务名 | `ide`，并且在 `/mcp` 中隐藏 |
| 监听地址 | `127.0.0.1` |
| 端口 | 每次启动随机选择 `10000–65535`，不可配置 |
| WebSocket | 未加密的 `ws://` loopback 连接 |
| 认证 | 每次扩展激活生成随机 token，通过 `X-Claude-Code-Ide-Authorization` 请求头发送 |
| 发现文件 | `~/.claude/ide/<port>.lock`；设置 `CLAUDE_CONFIG_DIR` 时位于 `$CLAUDE_CONFIG_DIR/ide/` |
| 文件权限 | lock file 为 `0600`，目录为 `0700` |
| 模型可见工具 | `mcp__ide__getDiagnostics`、`mcp__ide__executeCode` |
| CLI 内部 RPC | 打开 diff、读取选区、保存文件等；官方文档说明这些工具会在发给模型前被过滤 |
| 自动 context | 当前选区和活动文件路径随 prompt 一起提供 |

因此，Claude Code 的“自动 IDE context”本质上是 **Claude CLI 连接了扩展暴露的本地 MCP server**。它和普通用户在 `claude mcp add` 中配置的外部 MCP server 不完全相同：关键差异在于扩展负责启动、发现和认证，而 CLI 自动连接隐藏的 `ide` server。

### 13.2 哪些协议细节仍然没有公开

官方文档没有完整公开以下内容：

- WebSocket MCP 的具体 URL path、初始化顺序和完整 JSON-RPC 握手样例；
- `~/.claude/ide/<port>.lock` 的完整 JSON schema；
- 内部 RPC 的完整方法名、参数和返回值；
- CLI 在多个 lock file 同时存在时的选择、失效检测和 workspace 匹配规则；
- 内部 RPC 如何把“当前选区”和“活动文件路径”转换为 CLI transcript 中的 context 行。

这意味着可以根据公开资料实现“兼容方向”和最小协议骨架，但不能仅凭公开文档保证完全兼容。要做真正的 Claude Code provider，还需要在允许的本机环境中分析已安装的扩展 bundle，或者运行扩展与 CLI 后对 loopback WebSocket 做协议观测。本项目不把未验证的内部 RPC 名称写死。

### 13.3 与当前 Neovim MCP 实现的关系

当前 `/home/sanzenin/test/nvim-context-mcp` 是 stdio MCP server，适合通过配置显式连接；它不能自动变成 Claude Code 的内置 `ide` server，因为 Claude 官方集成使用的是带 lock file/token 的本地 WebSocket 发现机制。

但是，状态采集不需要重写。推荐把现有实现拆成两层：

```text
Neovim Lua 状态采集器
├── context.json / 内存快照
├── Codex adapter
│   └── Codex 私有 Unix Socket，4 字节长度前缀 JSON
├── Claude adapter
│   └── loopback WebSocket MCP + ~/.claude/ide/<port>.lock
└── MCP adapter
    └── stdio MCP，提供完整 buffer、diagnostics、LSP 扩展能力
```

这样 Codex 和 Claude 可以同时运行，且活动 buffer、选区、打开 tab、诊断等数据只由 Neovim 采集一次。Claude 适配器第一阶段应优先实现只读能力：活动文件、选区、打开文件和 diagnostics；保存文件、打开 diff、执行代码属于有副作用的能力，必须单独做权限控制。

### 13.4 VS Code Agent Host / AHP 是否能直接复用

VS Code 当前源码中的 Agent Host 是另一层架构。`agentHostMain.ts` 创建 `MessagePortProtocolServer` 给本地 renderer 使用，也可以在环境变量指定端口或 socket 时启动外部 WebSocket endpoint；VS Code 文档称本地 IPC 使用 MessagePort，远程连接使用 AHP JSON-RPC over WebSocket。

AHP 的模型是：Agent Host 持有会话的权威状态，客户端通过 JSON-RPC 订阅 URI channel，获得 snapshot 和有序 action。它面向多客户端同步的 sessions、chats、terminals、changesets 等会话状态，并不是“编辑器当前文件/当前选区”的专用 context provider。

因此：

| 目标 | 应实现的协议 | 是否是 Claude IDE context 的必要条件 |
| --- | --- | --- |
| 让 Codex `/ide` 看到 Neovim | Codex private IDE IPC | 是，针对 Codex |
| 让 Claude CLI 自动看到 Neovim 选区/活动文件 | Claude-compatible local MCP bridge | 是，针对 Claude |
| 让 Neovim 成为 VS Code Agent Host 的多客户端 | AHP JSON-RPC / MessagePort 对应实现 | 否，属于独立目标 |
| 让 Neovim 复刻 VS Code Agents 会话窗口 | AHP host/client + session state | 否，明显超出当前需求 |

实现 AHP 不会自动让 Claude Code 把 Neovim 识别为 VS Code；反过来，实现 Claude 的 `ide` MCP bridge 也不需要实现 AHP。VS Code 的开源 Agent Host 源码对于理解“宿主—客户端—agent adapter”很有价值，但不能替代 Claude 扩展的私有 MCP contract。

### 13.5 是否可以和 Codex 一起实现

可以，推荐的整体方案是：

1. 保留一个共享的 Neovim context collector；
2. Codex 使用原生 `ide-context` provider；
3. Claude 使用单独的 loopback WebSocket MCP provider；
4. 现有 stdio MCP 继续提供模型主动调用的补充能力；
5. AHP 仅作为未来的实验性适配器，不放入第一版。

可行性判断：

- Codex 原生 IPC：高。官方源码给出了请求、响应、socket 位置和 framing；
- Claude 自动 IDE context：中高。官方文档给出了 transport、认证、发现文件和功能边界，但内部 RPC schema 未公开；
- VS Code AHP：技术上可行，但与当前需求不等价，优先级低。

### 13.6 Claude 适配器的验证顺序

后续真正编码时应按以下顺序验证，而不是一开始实现所有内部 RPC：

1. 检查 `~/.claude/ide/` 是否出现 lock file，并验证权限；
2. 读取 lock file，确认真实 schema、端口和 token 字段；
3. 使用只读 WebSocket MCP client 完成连接与初始化；
4. 先实现 diagnostics 和当前选区读取；
5. 启动 Claude CLI，验证 prompt 中出现活动文件/选区 context；
6. 再补打开 diff、保存文件等有副作用 RPC；
7. 对 Claude Code 版本做兼容性记录，因为该接口不是公开稳定 API。

## 14. 对 `pengchengneo/Claude-Code` 的静态审计

`pengchengneo/Claude-Code` 的 README 声称它是从 `@anthropic-ai/claude-code` npm 包 source map 还原的非官方 TypeScript 源码；仓库自己也声明版权属于 Anthropic、仅用于研究。因此它不能作为官方 API 规范，但其中的 IDE 相关代码可以帮助确认 CLI 侧的实际接口形状。[仓库声明与来源说明](https://github.com/pengchengneo/Claude-Code#数据来源)

### 14.1 发现与选择

`src/utils/ide.ts` 是最有价值的文件。它定义了 CLI 解析的 lock file 字段：

```text
workspaceFolders?: string[]
pid?: number
ideName?: string
transport?: "ws" | "sse"
runningInWindows?: boolean
authToken?: string
```

对应的实现路径和职责如下：

| 路径 / identifier | 可确认的行为 |
| --- | --- |
| [`src/utils/ide.ts`](https://github.com/pengchengneo/Claude-Code/blob/main/src/utils/ide.ts#L67-L93) | lock file 数据模型；端口从 `<port>.lock` 文件名解析 |
| [`getSortedIdeLockfiles`](https://github.com/pengchengneo/Claude-Code/blob/main/src/utils/ide.ts#L282-L330) | 扫描候选 `ide` 目录，只收集 `.lock`，按修改时间倒序 |
| [`readIdeLockfile`](https://github.com/pengchengneo/Claude-Code/blob/main/src/utils/ide.ts#L332-L376) | 读取 JSON；兼容旧版“每行一个 workspace path”的格式 |
| [`getIdeLockfilesPaths`](https://github.com/pengchengneo/Claude-Code/blob/main/src/utils/ide.ts#L441-L491) | 读取当前配置目录；WSL 下额外尝试 Windows 用户目录 |
| [`cleanupStaleIdeLockfiles`](https://github.com/pengchengneo/Claude-Code/blob/main/src/utils/ide.ts#L492-L553) | 通过 PID 和端口响应性清理失效 lock file |
| [`findAvailableIDE` / `detectIDEs`](https://github.com/pengchengneo/Claude-Code/blob/main/src/utils/ide.ts#L593-L827) | 轮询可用 IDE；按 workspace、`CLAUDE_CODE_SSE_PORT`、PID 祖先链和 WSL 路径匹配 |

这解释了多实例下的行为：workspace 匹配后仍可能需要 PID 祖先链消歧；如果候选不唯一，CLI 让用户通过 `/ide` 选择，而不是随意连接最新文件。

### 14.2 WebSocket MCP client 与工具边界

`src/services/mcp/types.ts` 定义了内部配置类型 `ws-ide`，核心字段是 `url`、`ideName`、`authToken` 和 `ideRunningInWindows`。[类型定义](https://github.com/pengchengneo/Claude-Code/blob/main/src/services/mcp/types.ts#L68-L87)

`src/services/mcp/client.ts` 在连接 `ws-ide` 时：

- 使用 `X-Claude-Code-Ide-Authorization` 请求头发送 token；
- 使用 WebSocket MCP transport；Bun 路径声明 `mcp` subprotocol；
- 将 MCP server 名称固定识别为 `ide`；
- 只把 `mcp__ide__getDiagnostics` 和 `mcp__ide__executeCode` 放进模型可见 tool list；
- 通过 `callIdeRpc` 让 CLI 自己调用其它 IDE 内部工具。[连接与工具过滤](https://github.com/pengchengneo/Claude-Code/blob/main/src/services/mcp/client.ts#L567-L573)、[WebSocket 连接](https://github.com/pengchengneo/Claude-Code/blob/main/src/services/mcp/client.ts#L708-L734)、[直接 RPC](https://github.com/pengchengneo/Claude-Code/blob/main/src/services/mcp/client.ts#L2109-L2128)

这和 Claude 官方文档形成了互相验证：官方也明确说 server 约有一打工具，但只有 diagnostics 和 Jupyter 执行对模型可见，其余用于 CLI 自己的选区、diff、读写文件流程。[Claude 官方说明](https://code.claude.com/docs/en/ide-integrations#the-built-in-ide-mcp-server)

### 14.3 自动选区、`@` mention、diff 和 diagnostics

CLI 侧的事件入口在这些路径：

- [`src/hooks/useIdeSelection.ts`](https://github.com/pengchengneo/Claude-Code/blob/main/src/hooks/useIdeSelection.ts#L24-L141) 监听 `selection_changed`，读取 0-based `start/end`、文本和文件路径，并换算 transcript 中的行数；
- [`src/hooks/useIdeAtMentioned.ts`](https://github.com/pengchengneo/Claude-Code/blob/main/src/hooks/useIdeAtMentioned.ts#L10-L71) 监听 `at_mentioned`，把 IDE 的 0-based 行号转换为 CLI 内部使用的 1-based 行号；
- [`src/hooks/useDiffInIDE.ts`](https://github.com/pengchengneo/Claude-Code/blob/main/src/hooks/useDiffInIDE.ts#L257-L340) 调用 `openDiff`，传入 `old_file_path`、`new_file_path`、`new_file_contents`、`tab_name`，并在结束时调用 `close_tab`；
- [`src/services/diagnosticTracking.ts`](https://github.com/pengchengneo/Claude-Code/blob/main/src/services/diagnosticTracking.ts#L99-L151) 先用 `openFile` 确保语言服务加载，再通过 `getDiagnostics` 获取单文件结果；另有全量 diagnostics 路径。

因此“自动 context”和“模型工具”必须分开实现：`selection_changed` 是 provider → CLI 的通知，CLI 将它并入 prompt；`getDiagnostics` 是 CLI → provider 的 MCP tool call；`openDiff` 是 CLI 内部发起的、可能阻塞等待用户接受或拒绝的 RPC。

### 14.4 该仓库带来的兼容性警告

源码还原显示了更多容错逻辑，但不能据此认为这些行为是稳定协议：

- 同时兼容 WebSocket 和旧 SSE transport；
- WSL 中需要 Windows/WSL path 和 distro 匹配；
- 通过 `CLAUDE_CODE_SSE_PORT` 可以绕过部分 workspace 选择；
- lock file 失效清理依赖 PID、端口探测和当前运行环境；
- `ws-ide`、`selection_changed`、`at_mentioned`、`openDiff`、`close_tab` 等名称属于实现观察，不是公开稳定扩展点。

实现 Neovim provider 时，应该兼容这些名称和字段，但必须把它们放在可替换的 Claude adapter 中，不能污染共享的 context collector。

## 15. 第三方 Neovim 实现：`coder/claudecode.nvim`

目前最完整、最直接的公开 Neovim 实现是 [`coder/claudecode.nvim`](https://github.com/coder/claudecode.nvim)。它不是简单地在 Neovim 中打开 Claude terminal，而是让 Neovim 运行 provider：纯 Lua 实现 RFC 6455 WebSocket、JSON-RPC/MCP、lock file、选区通知、内部工具和 native diff。[项目说明](https://github.com/coder/claudecode.nvim#how-it-works)

### 15.1 对实现最有用的路径

| 路径 | 作用 |
| --- | --- |
| [`PROTOCOL.md`](https://github.com/coder/claudecode.nvim/blob/main/PROTOCOL.md) | 根据 VS Code 扩展逆向整理的发现、认证、消息和工具说明；属于第三方文档 |
| [`lua/claudecode/lockfile.lua`](https://github.com/coder/claudecode.nvim/blob/main/lua/claudecode/lockfile.lua) | 目录、token、lock JSON、原子写入和退出清理 |
| [`lua/claudecode/server/tcp.lua`](https://github.com/coder/claudecode.nvim/blob/main/lua/claudecode/server/tcp.lua) | `127.0.0.1` TCP listener、端口选择和客户端管理 |
| [`lua/claudecode/server/handshake.lua`](https://github.com/coder/claudecode.nvim/blob/main/lua/claudecode/server/handshake.lua) | RFC 6455 upgrade 和 `x-claude-code-ide-authorization` 校验 |
| [`lua/claudecode/selection.lua`](https://github.com/coder/claudecode.nvim/blob/main/lua/claudecode/selection.lua) | Visual/Normal 状态、选区提取、debounce、demotion 和通知 |
| [`lua/claudecode/tools/init.lua`](https://github.com/coder/claudecode.nvim/blob/main/lua/claudecode/tools/init.lua) | MCP tool registry；带 schema 的工具才进入 `tools/list` |
| [`lua/claudecode/diff.lua`](https://github.com/coder/claudecode.nvim/blob/main/lua/claudecode/diff.lua) | native diff、保存接受、关闭拒绝和阻塞结果 |

### 15.2 可复用的工程经验

1. lock file 使用 `pid`、`workspaceFolders`、`ideName: "Neovim"`、`transport: "ws"`、`authToken`；目录收紧到 `0700`，文件使用 `0600`，写入采用临时文件后 rename。[lock file 实现](https://github.com/coder/claudecode.nvim/blob/main/lua/claudecode/lockfile.lua#L71-L185)
2. token 使用 16 个 CSPRNG 字节编码为 32 位小写 hex，而不是 `math.random`。[token 实现](https://github.com/coder/claudecode.nvim/blob/main/lua/claudecode/lockfile.lua#L19-L64)
3. 选区不能只监听一次 `CursorMoved`：插件区分 charwise、linewise、blockwise，退出 Visual mode 时从 `'<`/`'>` marks 同步 flush，并用 debounce 避免高频广播。[选区监听](https://github.com/coder/claudecode.nvim/blob/main/lua/claudecode/selection.lua#L110-L208)、[选区坐标与文本](https://github.com/coder/claudecode.nvim/blob/main/lua/claudecode/selection.lua#L438-L485)
4. blockwise 不能由 Claude 的单一 start/end range 完整表达；该插件把它近似为连续 charwise span。这是应写入兼容性测试的语义损失。[blockwise 限制](https://github.com/coder/claudecode.nvim/blob/main/lua/claudecode/selection.lua#L609-L635)
5. diff 是状态机而不是一次 `diffsplit`：Claude 等待 `FILE_SAVED` 或 `DIFF_REJECTED`，Neovim 端要处理 `:w`、`:q`、窗口关闭、buffer 删除和清理。[diff 生命周期](https://github.com/coder/claudecode.nvim/blob/main/lua/claudecode/diff.lua#L883-L945)

### 15.3 不能直接照抄的部分

`PROTOCOL.md` 中的 tool schema、事件例子和“100% compatible”是第三方逆向结果，不是 Anthropic 的正式协议文档。尤其是 WebSocket path、initialize 时序、CLI 版本差异和内部 tool 的阻塞语义，仍然应以目标 Claude Code 版本做集成测试。当前实现应优先复用其结构和测试思路，不应复制源码或把所有内部 tool 都默认开放。

## 16. 后续平台支持：把协议适配和编辑器状态解耦

公开项目已经说明同一套 provider 思路可以迁移到多个宿主：

| 平台 | 公开实现/证据 | 适配重点 | 当前定位 |
| --- | --- | --- | --- |
| Neovim | [`coder/claudecode.nvim`](https://github.com/coder/claudecode.nvim) | Lua WebSocket、Visual selection、native diff、LSP diagnostics | 第一目标 |
| Emacs | [`Axiweave/claude-code-ide.el`](https://github.com/Axiweave/claude-code-ide.el) | WebSocket/MCP、buffer/selection、ediff、Flycheck/Flymake、project.el | 可作为第二个完整 provider 参考 |
| Obsidian | [`obsidian-claude-code-ide-pro`](https://github.com/Transept-AI/obsidian-claude-code-ide-pro) | Markdown note、active note、vault search、loopback WebSocket 和 lock file | 证明非代码编辑器也能实现同一 contract |
| Zed | [native integration discussion](https://github.com/zed-industries/zed/discussions/58338) | Rust provider、workspace/session、多窗口 diff、WSL/路径边界 | 未来 adapter，依赖 Zed 上游状态 |
| VS Code forks / Cursor / Windsurf | Claude 官方文档列出的扩展宿主，以及 CLI 的 `IdeType` 识别路径 | 复用扩展或实现同一 WebSocket-MCP provider | 不需要接入 AHP 才能提供 Claude context |
| VS Code Agent Host | [AHP 文档](https://github.com/microsoft/vscode-docs/blob/main/docs/agents/concepts/agent-host.md) | session、multi-client、JSON-RPC、MessagePort/WebSocket | 独立协议，不是 Claude IDE context 的必要条件 |

推荐抽象为：

```text
ContextSnapshot
├── workspace roots
├── active document: path, URI, dirty, language
├── selections: ranges, text, coordinate encoding
├── open documents/tabs
└── diagnostics

ProviderAdapter
├── discover() / cleanup()
├── authenticate(connection)
├── publish_selection(snapshot)
├── call_read_only_tool(name, args)
├── call_editor_action(name, args)
└── close()

TransportAdapter
├── Codex: Unix socket / Named Pipe + length-prefixed JSON
├── Claude: loopback WebSocket + MCP JSON-RPC + lock file
├── AHP: optional JSON-RPC session host
└── ordinary MCP: stdio/HTTP for explicit tool access
```

共享层只处理编辑器事实和坐标；Claude、Codex、AHP 适配器分别处理发现、认证、消息和副作用。这样未来增加 Gemini CLI、OpenCode、Pi、ACP 或其它 agent 时，不会把 Claude 的私有 `lock file` 逻辑复制到所有平台。

## 17. 面向本项目的落地顺序与验收标准

### 17.1 第一版：只读自动 context

先实现：

1. Neovim 内存快照：workspace、当前文件、未保存内容、Visual 选区、open buffers/tabs；
2. Codex `/ide` 的原生 Unix Socket provider；
3. Claude 的 loopback WebSocket MCP provider、lock file、token header；
4. Claude `selection_changed` 通知和 `getDiagnostics`；
5. 同时运行 Codex 和 Claude 时，两个连接看到同一个快照。

验收：切换 buffer、改变 Visual 选区、修改但不保存的内容后，Codex 下一次 prompt 和 Claude 下一次 prompt 都能看到新路径/新选区；诊断只通过 Claude MCP tool 或现有 stdio MCP 提供，不伪装成 Codex 原生字段。

### 17.2 第二版：编辑器动作

在只读链路稳定后，再实现：

- `openFile` 和行范围定位；
- `openDiff` 阻塞等待接受/拒绝；
- `saveDocument`、`checkDocumentDirty`；
- `close_tab`、`closeAllDiffTabs`；
- workspace 多实例、PID/parent process 和 WSL path 消歧。

每个动作都要有权限开关和超时；默认拒绝执行代码、写文件和保存文件。Claude 的模型可见工具仍只保留 diagnostics，内部 RPC 不应无意间泄漏到模型 tool list。

### 17.3 版本和安全测试

最低测试集合：

- 目标 Codex CLI 版本记录和 framing/response regression test；
- 目标 Claude Code CLI 版本的 lock file、WebSocket handshake、MCP initialize、`tools/list`、`selection_changed`、`openDiff` 测试；
- 选区的 0-based 行列、Unicode/UTF-16 列、CRLF、空选区和 blockwise 行为；
- 多个 Neovim 实例和多个 Claude lock file；
- lock directory/file 权限、过期 lock 清理、端口冲突、异常退出清理；
- WSL 内外路径、不同 distro、Windows CLI 与 WSL Neovim 的失败提示。

## 最终建议

采用“三层双适配器”架构：

```text
Neovim context collector
├── Codex native IDE IPC
│   └── /ide 自动获得当前文件、选区、打开 tab
├── Claude-compatible IDE MCP
│   └── Claude CLI 自动获得当前文件、选区、diagnostics
└── ordinary stdio MCP
    └── 完整 buffer、LSP、workspace 扩展信息
```

不要把 VS Code 的 AHP 当成 Claude Code 的 IDE context 接口。第一版应以 `coder/claudecode.nvim` 已验证的 provider 结构为参考，重用现有 Neovim context collector，同时分别实现 Codex 原生 IPC 和 Claude 只读 WebSocket MCP。等目标 Claude 版本的真实握手与内部 RPC 被验证后，再加入 diff/save；其它平台通过同一个 `ContextSnapshot` 和 `ProviderAdapter` 扩展。

## 参考资料

1. [openai/codex — `ipc.rs`](https://github.com/openai/codex/blob/main/codex-rs/tui/src/ide_context/ipc.rs)
2. [openai/codex — `ide_context.rs`](https://github.com/openai/codex/blob/main/codex-rs/tui/src/ide_context.rs)
3. [openai/codex — `prompt.rs`](https://github.com/openai/codex/blob/main/codex-rs/tui/src/ide_context/prompt.rs)
4. 本机 MCP 服务：`/home/sanzenin/test/nvim-context-mcp/src/nvim_context_mcp/server.py`
5. 本机 Neovim 状态发布器：`/home/sanzenin/.config/nvim/lua/config/nvim_context_mcp.lua`
6. [Claude Code 官方 VS Code 集成文档](https://code.claude.com/docs/en/ide-integrations#the-built-in-ide-mcp-server)
7. [VS Code Agent Host 概念与进程架构](https://github.com/microsoft/vscode-docs/blob/main/docs/agents/concepts/agent-host.md)
8. [VS Code Agent Host 源码：`agentHostMain.ts`](https://github.com/microsoft/vscode/blob/main/src/vs/platform/agentHost/node/agentHostMain.ts)
9. [Microsoft Agent Host Protocol](https://github.com/microsoft/agent-host-protocol)
10. [AHP JSON-RPC message types](https://github.com/microsoft/agent-host-protocol/blob/main/types/common/messages.ts)
11. [pengchengneo/Claude-Code（非官方 source-map 还原）](https://github.com/pengchengneo/Claude-Code)
12. [`pengchengneo/Claude-Code` CLI IDE discovery](https://github.com/pengchengneo/Claude-Code/blob/main/src/utils/ide.ts)
13. [`pengchengneo/Claude-Code` MCP client](https://github.com/pengchengneo/Claude-Code/blob/main/src/services/mcp/client.ts)
14. [`pengchengneo/Claude-Code` IDE selection hook](https://github.com/pengchengneo/Claude-Code/blob/main/src/hooks/useIdeSelection.ts)
15. [`pengchengneo/Claude-Code` IDE diff hook](https://github.com/pengchengneo/Claude-Code/blob/main/src/hooks/useDiffInIDE.ts)
16. [`coder/claudecode.nvim` protocol document](https://github.com/coder/claudecode.nvim/blob/main/PROTOCOL.md)
17. [`coder/claudecode.nvim` lock file implementation](https://github.com/coder/claudecode.nvim/blob/main/lua/claudecode/lockfile.lua)
18. [`coder/claudecode.nvim` selection tracking](https://github.com/coder/claudecode.nvim/blob/main/lua/claudecode/selection.lua)
19. [`Axiweave/claude-code-ide.el`](https://github.com/Axiweave/claude-code-ide.el)
20. [`Transept-AI/obsidian-claude-code-ide-pro`](https://github.com/Transept-AI/obsidian-claude-code-ide-pro)
