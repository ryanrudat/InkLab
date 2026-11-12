import { test, type TestContext } from 'node:test'
import assert from 'node:assert/strict'
import { httpOpenAIClient, toResponsesInput, fromResponsesOutput } from '../src/openai.ts'
import { handleMakeReal, MAKE_REAL_MODEL, MAKE_REAL_FALLBACK_MODEL, configuredMakeRealModel } from '../src/makeReal.ts'

// The default widget model depends on these; keep tests offline and deterministic whatever the shell has set.
delete process.env.OPENAI_API_KEY
delete process.env.MAKE_REAL_MODEL
import { DONE_MARKER } from '../src/assembler.ts'
import type { AnthropicClient, CompleteOpts, Session } from '../src/types.ts'

function mockFetch(t: TestContext, reply: { status?: number; json: unknown }) {
  const original = globalThis.fetch
  t.after(() => { globalThis.fetch = original })
  const calls: { url: string; init: RequestInit }[] = []
  globalThis.fetch = (async (url: string, init: RequestInit) => {
    calls.push({ url: String(url), init })
    return new Response(JSON.stringify(reply.json), { status: reply.status ?? 200 })
  }) as typeof fetch
  return calls
}

const message = (text: string) => ({ type: 'message', content: [{ type: 'output_text', text }] })

test('request maps to the Responses API (instructions, input, output cap, effort, bearer key)', async (t) => {
  const calls = mockFetch(t, { json: { status: 'completed', output: [message('hi')] } })
  const r = await httpOpenAIClient('test-key', 'gpt-test').complete({
    system: 'sys', messages: [{ role: 'user', content: 'hello' }], maxTokens: 123, effort: 'medium',
    thinking: { type: 'adaptive' }, betas: ['ignored'], fallbacks: 'default',
  })
  assert.deepEqual(r, { text: 'hi', stopReason: 'end_turn' })
  assert.equal(calls[0].url, 'https://api.openai.com/v1/responses')
  assert.equal((calls[0].init.headers as any).authorization, 'Bearer test-key')
  assert.deepEqual(JSON.parse(String(calls[0].init.body)), {
    model: 'gpt-test', instructions: 'sys', input: [{ role: 'user', content: 'hello' }],
    max_output_tokens: 123, reasoning: { effort: 'medium' },
  })   // Anthropic-only options (thinking, betas, fallbacks) are not sent
})

test('image and assistant blocks map to input_image / output_text parts', () => {
  assert.deepEqual(toResponsesInput([
    { role: 'user', content: [{ type: 'image', source: { type: 'base64', media_type: 'image/png', data: 'AAAA' } }, { type: 'text', text: 'read' }] },
    { role: 'assistant', content: [{ type: 'text', text: 'partial' }] },
  ]), [
    { role: 'user', content: [{ type: 'input_image', image_url: 'data:image/png;base64,AAAA' }, { type: 'input_text', text: 'read' }] },
    { role: 'assistant', content: [{ type: 'output_text', text: 'partial' }] },
  ])
})

test('stop reasons: truncation → max_tokens, refusal or content filter → refusal', () => {
  assert.equal(fromResponsesOutput({ status: 'incomplete', incomplete_details: { reason: 'max_output_tokens' }, output: [message('<html>')] }).stopReason, 'max_tokens')
  assert.equal(fromResponsesOutput({ status: 'incomplete', incomplete_details: { reason: 'content_filter' }, output: [] }).stopReason, 'refusal')
  assert.equal(fromResponsesOutput({ status: 'completed', output: [{ type: 'message', content: [{ type: 'refusal', refusal: 'no' }] }] }).stopReason, 'refusal')
  assert.equal(fromResponsesOutput({ status: 'completed', output: [{ type: 'reasoning' }, message('a'), message('b')] }).text, 'ab')
})

test('HTTP errors surface as a generic tagged upstream error (no upstream body)', async (t) => {
  mockFetch(t, { status: 401, json: { error: { code: 'invalid_api_key', message: 'secret detail' } } })
  await assert.rejects(httpOpenAIClient('bad').complete({ messages: [{ role: 'user', content: 'x' }] }), (e: any) => {
    assert.equal(e.upstream, true); assert.equal(e.status, 401); assert.equal(e.message, 'upstream error')
    return true
  })
})

const adult: Session = { isOnline: true, userKind: 'adult', aiConsentGranted: true, ageVerified: true }
const doc = '<!DOCTYPE html><html><head><title>T</title></head><body>x</body></html>'
const recorder = (): AnthropicClient & { calls: CompleteOpts[] } => {
  const calls: CompleteOpts[] = []
  return { calls, async complete(o) { calls.push(o); return { text: `${doc}\n${DONE_MARKER}`, stopReason: 'end_turn' } } }
}

test('a gpt- model routes make-real to the OpenAI client with room for reasoning', async () => {
  const anthropic = recorder(), openai = recorder()
  const out = await handleMakeReal(anthropic, { session: adult, prompt: 'a clock' }, { model: 'gpt-6.1-sol', openaiClient: openai })
  assert.equal(out.status, 200)
  assert.equal(anthropic.calls.length, 0)
  assert.equal(openai.calls[0].model, 'gpt-6.1-sol')
  assert.equal(openai.calls[0].maxTokens, 16000)
  assert.equal(openai.calls[0].effort, 'medium')
})

test('Sol is the default widget model when an OpenAI key is configured; override wins; no key → Claude', () => {
  assert.equal(MAKE_REAL_MODEL, 'gpt-6.1-sol')
  assert.equal(configuredMakeRealModel({ OPENAI_API_KEY: 'sk-x' }), 'gpt-6.1-sol')
  assert.equal(configuredMakeRealModel({}), MAKE_REAL_FALLBACK_MODEL)
  assert.equal(configuredMakeRealModel({ OPENAI_API_KEY: '  ' }), MAKE_REAL_FALLBACK_MODEL)
  assert.equal(configuredMakeRealModel({ OPENAI_API_KEY: 'sk-x', MAKE_REAL_MODEL: 'claude-sonnet-5-5' }), 'claude-sonnet-5-5')
})

test('without an OpenAI key, make-real falls back to Claude and reports the model used', async () => {
  const anthropic = recorder(), openai = recorder()
  const out = await handleMakeReal(anthropic, { session: adult, prompt: 'a clock' }, { openaiClient: openai })
  assert.equal(openai.calls.length, 0)
  assert.equal(anthropic.calls[0].model, MAKE_REAL_FALLBACK_MODEL)
  assert.equal(anthropic.calls[0].maxTokens, 8192)
  assert.equal(out.body.model, MAKE_REAL_FALLBACK_MODEL)
})
