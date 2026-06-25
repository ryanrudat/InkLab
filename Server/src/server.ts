import { createServer, type IncomingMessage } from 'node:http'
import { httpAnthropicClient } from './anthropic.ts'
import { handleRecognize } from './recognize.ts'
import { assembleGeneration, DONE_MARKER } from './assembler.ts'
import { validateWidgetHtml } from './validate.ts'
import { cloudEligible } from './consent.ts'
import { timingSafeEqual } from 'node:crypto'

const client = httpAnthropicClient()
const PORT = Number(process.env.PORT ?? 8787)

// Shared-secret gate for the Claude-calling endpoints. When INKLAB_PROXY_SECRET is set (Railway/prod),
// /make-real and /recognize require `Authorization: Bearer <secret>`. When unset (local dev / tests),
// they stay open. NOTE: a secret embedded in a distributed app is obfuscation, not strong auth — it
// stops opportunistic abuse of the public URL, not a determined attacker. See README "Auth".
const AUTH_SECRET = process.env.INKLAB_PROXY_SECRET ?? ''
if (!AUTH_SECRET) console.warn('⚠️  INKLAB_PROXY_SECRET not set — /make-real and /recognize are OPEN (no auth).')

function authorized(req: IncomingMessage): boolean {
  if (!AUTH_SECRET) return true
  const expected = Buffer.from(`Bearer ${AUTH_SECRET}`)
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

const server = createServer(async (req, res) => {
  const json = (status: number, body: unknown) => {
    res.writeHead(status, { 'content-type': 'application/json' })
    res.end(JSON.stringify(body))
  }
  try {
    if ((req.url === '/make-real' || req.url === '/recognize') && req.method === 'POST' && !authorized(req)) {
      return json(401, { error: 'unauthorized' })
    }
    if (req.method === 'POST' && req.url === '/recognize') {
      const parsed = await parseJsonBody(req)
      if (!parsed.ok) return json(parsed.status, { error: parsed.error })
      const out = await handleRecognize(client, parsed.body)
      return json(out.status, out.error ? { error: out.error } : out.result)
    }
    if (req.method === 'POST' && req.url === '/make-real') {
      const parsed = await parseJsonBody(req)
      if (!parsed.ok) return json(parsed.status, { error: parsed.error })
      const body = parsed.body
      const decision = cloudEligible(body?.session)
      if (!decision.allowed) return json(403, { error: decision.reason })
      const system = [
        'You generate ONE self-contained interactive HTML widget: a single HTML document with inline CSS and JavaScript.',
        'It runs in a locked-down sandbox with NO internet. Do not use any external resources — no external scripts, fonts, images, stylesheets, no fetch/XHR/WebSocket, no <iframe>. Everything must be inline.',
        'It is displayed inside a FIXED portrait card about 360 x 540 CSS pixels. Make the ENTIRE UI fit that card with NO scrolling:',
        '- Set html, body { margin: 0; height: 100%; } and have your root element fill 100% width and height.',
        '- Use box-sizing: border-box and a flexbox or CSS grid layout so every control fits at that size.',
        '- Choose font sizes, paddings, and button sizes that fit; never overflow the card.',
        '- Design for touch: large tap targets, no hover-only interactions.',
        'Implement real, correct behavior (e.g. a calculator must compute correctly; a simulation must animate).',
        'If the widget has a primary text/expression input (e.g. a grapher or calculator), expose `window.inklab = { setInput: function(text){ /* put text into your main input field AND run/plot it */ } }` so the user can fill it by handwriting. Setting it must also trigger your plot/compute routine.',
        `When the document is complete, end your output with exactly: ${DONE_MARKER}`,
      ].join('\n')
      // Sonnet 4.6 (faster + cheaper than Opus, plenty for widget HTML) + a max_tokens high enough that
      // most widgets finish in ONE pass (the 2048 default truncated → 2–3 sequential round-trips).
      const gen = await assembleGeneration(client, {
        system,
        userPrompt: String(body.prompt ?? ''),
        model: 'claude-opus-4-8',   // back to Opus for best widget quality (user request)
        maxTokens: 8192,            // keep: lets a widget finish in ONE pass (no truncation round-trips)
      })
      const safety = validateWidgetHtml(gen.output)
      if (!safety.safe) return json(422, { error: 'unsafe widget', violations: safety.violations })
      return json(200, { html: gen.output, complete: gen.complete, passes: gen.passes })
    }
    if (req.method === 'GET' && req.url === '/health') return json(200, { ok: true })
    return json(404, { error: 'not found' })
  } catch (e) {
    // Never leak internal/upstream detail to the client (this proxy is the opaque server boundary —
    // ADR 0002). Upstream Anthropic failures map to a generic 502; everything else to a generic 500.
    // The detail is logged server-side only (status/message, never request/response content — ZDR).
    if ((e as any)?.upstream) {
      console.error('upstream error', (e as any)?.status ?? '')
      return json(502, { error: 'upstream error' })
    }
    console.error('proxy error:', (e as any)?.message ?? 'unknown')
    return json(500, { error: 'internal error' })
  }
})

server.listen(PORT, () => console.log(`InkLab proxy listening on :${PORT}`))
