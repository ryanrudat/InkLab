import { createServer, type IncomingMessage } from 'node:http'
import { httpAnthropicClient } from './anthropic.ts'
import { handleRecognize } from './recognize.ts'
import { assembleGeneration } from './assembler.ts'
import { validateWidgetHtml } from './validate.ts'
import { cloudEligible } from './consent.ts'

const client = httpAnthropicClient()
const PORT = Number(process.env.PORT ?? 8787)

function readBody(req: IncomingMessage): Promise<string> {
  return new Promise((resolve, reject) => {
    let data = ''
    req.on('data', (c) => { data += c })
    req.on('end', () => resolve(data))
    req.on('error', reject)
  })
}

const server = createServer(async (req, res) => {
  const json = (status: number, body: unknown) => {
    res.writeHead(status, { 'content-type': 'application/json' })
    res.end(JSON.stringify(body))
  }
  try {
    if (req.method === 'POST' && req.url === '/recognize') {
      const body = JSON.parse(await readBody(req))
      const out = await handleRecognize(client, body)
      return json(out.status, out.error ? { error: out.error } : out.result)
    }
    if (req.method === 'POST' && req.url === '/make-real') {
      const body = JSON.parse(await readBody(req))
      const decision = cloudEligible(body.session)
      if (!decision.allowed) return json(403, { error: decision.reason })
      const system =
        'Generate a single self-contained HTML document (inline CSS/JS, no external network) implementing the requested interactive widget. ' +
        'It must run in a locked-down WKWebView. End your output with the completion marker.'
      const gen = await assembleGeneration(client, { system, userPrompt: String(body.prompt ?? '') })
      const safety = validateWidgetHtml(gen.output)
      if (!safety.safe) return json(422, { error: 'unsafe widget', violations: safety.violations })
      return json(200, { html: gen.output, complete: gen.complete, passes: gen.passes })
    }
    if (req.method === 'GET' && req.url === '/health') return json(200, { ok: true })
    return json(404, { error: 'not found' })
  } catch (e) {
    return json(500, { error: String(e) })
  }
})

server.listen(PORT, () => console.log(`InkLab proxy listening on :${PORT}`))
