import { createServer, type IncomingMessage, type ServerResponse } from 'node:http'
import { resolve } from 'node:path'
import { pathToFileURL } from 'node:url'
import { httpAnthropicClient } from './anthropic.ts'
import { handleRecognize } from './recognize.ts'
import { handleMakeReal, DEFAULT_MAKE_REAL_DEADLINE_MS } from './makeReal.ts'
import { timingSafeEqual } from 'node:crypto'
import type { AnthropicClient } from './types.ts'

const PORT = Number(process.env.PORT ?? 8787)

// Shared-secret gate for the Claude-calling endpoints. When INKLAB_PROXY_SECRET is set (Railway/prod),
// /make-real and /recognize require `Authorization: Bearer <secret>`. When unset (local dev / tests),
// they stay open. NOTE: a secret embedded in a distributed app is obfuscation, not strong auth — it
// stops opportunistic abuse of the public URL, not a determined attacker. See README "Auth".
function authorized(req: IncomingMessage, authSecret: string): boolean {
  if (!authSecret) return true
  const expected = Buffer.from(`Bearer ${authSecret}`)
  const provided = Buffer.from(String(req.headers['authorization'] ?? ''))
  return provided.length === expected.length && timingSafeEqual(provided, expected)
}

// Hard cap on request body size. /recognize and /make-real accept a base64 PNG of a lassoed region;
// 8 MB is generous for that while preventing an unbounded in-memory accumulation (memory-exhaustion
// DoS) on the single-process proxy. Exceeding it rejects with a tagged error → HTTP 413.
const MAX_BODY_BYTES = 8 * 1024 * 1024

function readBody(req: IncomingMessage): Promise<string> {
  return new Promise((resolve, reject) => {
    let data = ''
    let size = 0
    req.on('data', (c) => {
      size += (c as Buffer).length
      if (size > MAX_BODY_BYTES) {
        reject(Object.assign(new Error('body too large'), { tooLarge: true }))
        req.destroy()
        return
      }
      data += c
    })
    req.on('end', () => resolve(data))
    req.on('error', reject)
  })
}

// Read + JSON-parse the body, mapping the failure modes to the correct client status (413 too-large,
// 400 malformed) instead of letting them throw into the generic 500 handler (which also leaked the
// raw parser message).
async function parseJsonBody(
  req: IncomingMessage,
): Promise<{ ok: true; body: any } | { ok: false; status: number; error: string }> {
  let raw: string
  try {
    raw = await readBody(req)
  } catch (e) {
    if ((e as any)?.tooLarge) return { ok: false, status: 413, error: 'request too large' }
    return { ok: false, status: 400, error: 'invalid request' }
  }
  try {
    return { ok: true, body: JSON.parse(raw) }
  } catch {
    return { ok: false, status: 400, error: 'invalid JSON' }
  }
}

export interface InkLabServerOptions {
  client?: AnthropicClient
  authSecret?: string
  /** Whole-request budget for /make-real (default MAKE_REAL_DEADLINE_MS env, else 170 s). */
  makeRealDeadlineMs?: number
}

function configuredMakeRealDeadlineMs(): number {
  const value = Number(process.env.MAKE_REAL_DEADLINE_MS)
  return Number.isFinite(value) && value > 0 ? value : DEFAULT_MAKE_REAL_DEADLINE_MS
}

export function createInkLabRequestListener(options: InkLabServerOptions = {}) {
  const client = options.client ?? httpAnthropicClient()
  const authSecret = options.authSecret ?? process.env.INKLAB_PROXY_SECRET ?? ''
  const makeRealDeadlineMs = options.makeRealDeadlineMs ?? configuredMakeRealDeadlineMs()

  return async (req: IncomingMessage, res: ServerResponse) => {
    // Stop upstream work when the inbound request is aborted or the response socket closes before a
    // response is written. The same signal is threaded through generation/recognition to fetch().
    const requestController = new AbortController()
    const abortRequest = () => requestController.abort()
    const abortOnPrematureClose = () => {
      if (!res.writableEnded) requestController.abort()
    }
    req.once('aborted', abortRequest)
    res.once('close', abortOnPrematureClose)

    const json = (status: number, body: unknown) => {
      if (res.destroyed || res.writableEnded) return
      res.writeHead(status, { 'content-type': 'application/json' })
      res.end(JSON.stringify(body))
    }
    try {
      if ((req.url === '/make-real' || req.url === '/recognize') && req.method === 'POST' && !authorized(req, authSecret)) {
        return json(401, { error: 'unauthorized' })
      }
      if (req.method === 'POST' && req.url === '/recognize') {
        const parsed = await parseJsonBody(req)
        if (!parsed.ok) return json(parsed.status, { error: parsed.error })
        const out = await handleRecognize(client, parsed.body, requestController.signal)
        return json(out.status, out.error ? { error: out.error } : out.result)
      }
      if (req.method === 'POST' && req.url === '/make-real') {
        const parsed = await parseJsonBody(req)
        if (!parsed.ok) return json(parsed.status, { error: parsed.error })
        const out = await handleMakeReal(client, parsed.body, {
          signal: requestController.signal,
          deadlineMs: makeRealDeadlineMs,
        })
        return json(out.status, out.body)
      }
      if (req.method === 'GET' && req.url === '/health') return json(200, { ok: true })
      return json(404, { error: 'not found' })
    } catch (e) {
      // A disconnected downstream client intentionally cancels its upstream request. There is no
      // response socket left to write and this is not an upstream incident worth logging.
      if (requestController.signal.aborted && (req.aborted || res.destroyed)) return
      // Never leak internal/upstream detail to the client (this proxy is the opaque server boundary —
      // ADR 0002). Upstream Anthropic failures map to a generic 502; everything else to a generic 500.
      // The detail is logged server-side only (status/message, never request/response content — ZDR).
      if ((e as any)?.upstream) {
        console.error('upstream error', (e as any)?.status ?? '')
        return json(502, { error: 'upstream error' })
      }
      console.error('proxy error:', (e as any)?.message ?? 'unknown')
      return json(500, { error: 'internal error' })
    } finally {
      req.off('aborted', abortRequest)
      res.off('close', abortOnPrematureClose)
    }
  }
}

export function createInkLabServer(options: InkLabServerOptions = {}) {
  return createServer(createInkLabRequestListener(options))
}

const isEntrypoint = process.argv[1] !== undefined
  && import.meta.url === pathToFileURL(resolve(process.argv[1])).href

if (isEntrypoint) {
  const authSecret = process.env.INKLAB_PROXY_SECRET ?? ''
  if (!authSecret) console.warn('⚠️  INKLAB_PROXY_SECRET not set — /make-real and /recognize are OPEN (no auth).')
  const server = createInkLabServer({ authSecret })
  server.listen(PORT, () => console.log(`InkLab proxy listening on :${PORT}`))
}
