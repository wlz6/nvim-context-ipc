import net from 'node:net'
import os from 'node:os'
import path from 'node:path'
import crypto from 'node:crypto'
import { defineTool } from '@deepseek-ai/dsh-tools'

export const name = 'dsh-nvim-context-ipc'
export const inject = ['tools']

const DEFAULT_SOCKET_PATH = '~/.cache/nvim-context-ipc/dsh.sock'
// Keep the cross-language client aligned with protocol.lua's 256 MiB frame
// ceiling. Normal context snapshots are much smaller; large frames are only
// useful for full-file native diffs.
const MAX_FRAME_BYTES = 256 * 1024 * 1024

function expandPath(value) {
  const source = value || DEFAULT_SOCKET_PATH
  const home = os.homedir()
  if (source === '~') return home
  if (source.startsWith('~/')) return path.join(home, source.slice(2))
  return path.resolve(source)
}

function encodeFrame(value) {
  const payload = Buffer.from(JSON.stringify(value), 'utf8')
  if (payload.length > MAX_FRAME_BYTES) {
    throw new Error('Neovim context IPC frame is too large')
  }
  const frame = Buffer.allocUnsafe(payload.length + 4)
  frame.writeUInt32LE(payload.length, 0)
  payload.copy(frame, 4)
  return frame
}

function decodeFrames(buffer) {
  const messages = []
  let offset = 0
  while (buffer.length - offset >= 4) {
    const length = buffer.readUInt32LE(offset)
    if (length > MAX_FRAME_BYTES) throw new Error('Neovim context IPC frame is too large')
    if (buffer.length - offset < length + 4) break
    const payload = buffer.subarray(offset + 4, offset + 4 + length).toString('utf8')
    messages.push(JSON.parse(payload))
    offset += length + 4
  }
  return { messages, remainder: buffer.subarray(offset) }
}

function request(socketPath, method, params, timeoutMs) {
  return new Promise((resolve, reject) => {
    const id = crypto.randomUUID()
    const socket = net.createConnection(socketPath)
    let buffer = Buffer.alloc(0)
    let settled = false

    const finish = (error, value) => {
      if (settled) return
      settled = true
      socket.destroy()
      if (error) reject(error)
      else resolve(value)
    }

    socket.setTimeout(timeoutMs, () => finish(new Error(`Timed out connecting to Neovim at ${socketPath}`)))
    socket.once('connect', () => {
      // A native diff deliberately keeps this request open until the user
      // saves or rejects it; the timeout only covers establishing the socket.
      socket.setTimeout(0)
      try {
        socket.write(encodeFrame({ type: 'request', id, method, params }))
      } catch (error) {
        finish(error)
      }
    })
    socket.on('data', (chunk) => {
      try {
        buffer = Buffer.concat([buffer, chunk])
        const decoded = decodeFrames(buffer)
        buffer = decoded.remainder
        for (const message of decoded.messages) {
          if (message.id !== id) continue
          if (message.ok !== true) finish(new Error(message.error || 'Neovim context IPC request failed'))
          else finish(null, message.result)
          return
        }
      } catch (error) {
        finish(error)
      }
    })
    socket.once('error', (error) => finish(new Error(`Cannot reach Neovim context IPC at ${socketPath}: ${error.message}`)))
    socket.once('end', () => {
      if (!settled) finish(new Error('Neovim closed the context IPC connection before responding'))
    })
  })
}

function textFromResult(result) {
  if (typeof result === 'string') return result
  if (result && Array.isArray(result.content)) {
    return result.content.map((block) => block.type === 'text' ? block.text : '').join('')
  }
  return JSON.stringify(result, null, 2) ?? String(result)
}

function outputText() {
  return {
    schema: { type: 'string' },
    render: (_args, value) => [{ type: 'text', text: value }],
  }
}

function tool(client, definition) {
  const { rpcMethod, requestParams, format, ...toolDefinition } = definition
  return defineTool({
    ...toolDefinition,
    output: outputText(),
    async execute(args = {}) {
      const params = requestParams ? requestParams(args) : args
      const result = await client(rpcMethod, params)
      return format ? format(result) : textFromResult(result)
    },
  })
}

export function apply(ctx, config = {}) {
  const socketPath = expandPath(config.socketPath || process.env.NVIM_CONTEXT_IPC_DSH_SOCKET)
  const configuredTimeout = Number(config.timeoutMs)
  const timeoutMs = Number.isFinite(configuredTimeout) && configuredTimeout > 0 ? configuredTimeout : 3000
  const includeBufferText = config.includeBufferText === true
  const call = (method, params) => request(socketPath, method, params, timeoutMs)

  ctx.tools.register(tool(call, {
    name: 'nvim_context',
    description: 'Read the current Neovim file, selection, open tabs, workspace, diagnostics, and dirty state.',
    rpcMethod: 'context',
    parameters: {
      include_buffer_text: { type: 'boolean', description: 'Include the current buffer text when true.' },
    },
    requestParams: (args) => ({
      include_buffer_text: args.include_buffer_text === true || (args.include_buffer_text === undefined && includeBufferText),
    }),
    format: (result) => JSON.stringify(result, null, 2),
  }))

  ctx.tools.register(tool(call, {
    name: 'nvim_open_file',
    description: 'Open a workspace file in Neovim and optionally select text.',
    rpcMethod: 'action',
    requestParams: (args) => ({ name: 'openFile', arguments: args }),
    parameters: {
      filePath: { type: 'string', required: true, description: 'Absolute path of the workspace file.' },
      startText: { type: 'string', description: 'Text at which the selection starts.' },
      endText: { type: 'string', description: 'Text at which the selection ends.' },
      selectToEndOfLine: { type: 'boolean', description: 'Extend the selection to the end of its line.' },
      makeFrontmost: { type: 'boolean', description: 'Make the opened buffer current; defaults to true.' },
    },
  }))

  ctx.tools.register(tool(call, {
    name: 'nvim_save_document',
    description: 'Save an open Neovim document after the configured permission check.',
    rpcMethod: 'action',
    requestParams: (args) => ({ name: 'saveDocument', arguments: args }),
    parameters: {
      filePath: { type: 'string', required: true, description: 'Absolute path of the open workspace file.' },
    },
  }))

  ctx.tools.register(tool(call, {
    name: 'nvim_open_diff',
    description: 'Open proposed file contents in a native Neovim diff and wait until it is saved or rejected.',
    rpcMethod: 'action',
    requestParams: (args) => ({ name: 'openDiff', arguments: args }),
    parameters: {
      old_file_path: { type: 'string', description: 'Existing file to compare against.' },
      new_file_path: { type: 'string', required: true, description: 'Workspace path for the proposed file.' },
      new_file_contents: { type: 'string', required: true, description: 'Complete proposed file contents.' },
      tab_name: { type: 'string', description: 'Optional diff tab label.' },
    },
  }))
}
