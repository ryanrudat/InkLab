import { test } from 'node:test'
import assert from 'node:assert/strict'
import { EventEmitter } from 'node:events'
import { Readable } from 'node:stream'
import type { IncomingMessage, ServerResponse } from 'node:http'
import { createInkLabRequestListener } from '../src/server.ts'
import type { AnthropicClient, CompleteOpts } from '../src/types.ts'

// The default widget model depends on these; keep tests offline and deterministic whatever the shell has set.
delete process.env.OPENAI_API_KEY
delete process.env.MAKE_REAL_MODEL


const eligibleSession = {
  isOnline: true,
  userKind: 'adult' as const,
  aiConsentGranted: true,
  ageVerified: true,
}

class MockResponse extends EventEmitter {
  destroyed = false
  writableEnded = false
  status = 0
  body = ''

  writeHead(status: number): this {
    this.status = status
    return this
  }

  end(chunk?: string): this {
    this.body += chunk ?? ''
    this.writableEnded = true
    return this
  }
}

test('/make-real rejects output that remains incomplete after all passes', async () => {
  let calls = 0
  let requestSignal: AbortSignal | undefined
  const client: AnthropicClient = {
    async complete(opts: CompleteOpts) {
      calls++
      requestSignal = opts.signal
      return { text: '<html><body>partial', stopReason: 'max_tokens' }
    },
  }
  const request = Readable.from([
    JSON.stringify({ session: eligibleSession, prompt: 'make a timer' }),
  ]) as IncomingMessage
  request.method = 'POST'
  request.url = '/make-real'
  request.headers = { 'content-type': 'application/json' }

  const response = new MockResponse()

  const handle = createInkLabRequestListener({ client, authSecret: '' })
  await handle(request, response as unknown as ServerResponse)

  assert.equal(response.status, 502)
  assert.deepEqual(JSON.parse(response.body), { error: 'incomplete generation' })
  assert.equal(calls, 5)
  assert.ok(requestSignal instanceof AbortSignal)
})
