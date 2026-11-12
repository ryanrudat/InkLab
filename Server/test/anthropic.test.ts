import { test, type TestContext } from 'node:test'
import assert from 'node:assert/strict'
import { httpAnthropicClient } from '../src/anthropic.ts'

const messages = [{ role: 'user' as const, content: 'hello' }]

function installHangingFetch(
  t: TestContext,
): Promise<AbortSignal> {
  const originalFetch = globalThis.fetch
  t.after(() => { globalThis.fetch = originalFetch })

  let resolveSignal!: (signal: AbortSignal) => void
  const signalSeen = new Promise<AbortSignal>((resolve) => { resolveSignal = resolve })
  globalThis.fetch = ((_input: string | URL | Request, init?: RequestInit) => {
    const signal = init?.signal as AbortSignal
    resolveSignal(signal)
    return new Promise<Response>((_resolve, reject) => {
      const rejectOnAbort = () => reject(signal.reason ?? new DOMException('aborted', 'AbortError'))
      if (signal.aborted) rejectOnAbort()
      else signal.addEventListener('abort', rejectOnAbort, { once: true })
    })
  }) as typeof fetch
  return signalSeen
}

test('Anthropic requests time out and surface a tagged upstream error', async (t) => {
  const signalSeen = installHangingFetch(t)
  const client = httpAnthropicClient('test-key', 'test-model', 20)

  const completion = client.complete({ messages })
  const fetchSignal = await signalSeen
  await assert.rejects(completion, (error: any) => {
    assert.equal(error.upstream, true)
    assert.equal(error.timeout, true)
    assert.equal(error.aborted, true)
    return true
  })
  assert.equal(fetchSignal.aborted, true)
})

test('a caller abort cancels the in-flight Anthropic request', async (t) => {
  const signalSeen = installHangingFetch(t)
  const caller = new AbortController()
  const client = httpAnthropicClient('test-key', 'test-model', 10_000)

  const completion = client.complete({ messages, signal: caller.signal })
  const fetchSignal = await signalSeen
  caller.abort()

  await assert.rejects(completion, (error: any) => {
    assert.equal(error.upstream, true)
    assert.equal(error.timeout, false)
    assert.equal(error.aborted, true)
    return true
  })
  assert.equal(fetchSignal.aborted, true)
})
