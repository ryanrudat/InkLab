import { test } from 'node:test'
import assert from 'node:assert/strict'
import { handleRecognize } from '../src/recognize.ts'
import type { AnthropicClient, RecognitionRequest, Session } from '../src/types.ts'

const adult: Session = { isOnline: true, userKind: 'adult', aiConsentGranted: true, ageVerified: true }
const req = (session: Session): RecognitionRequest => ({ session, domain: 'math', rasterPngBase64: 'AAAA' })

function clientReturning(text: string): AnthropicClient {
  return { async complete() { return { text, stopReason: 'end_turn' } } }
}

test('ineligible session is refused (403) and the model is never called', async () => {
  let called = false
  const spy: AnthropicClient = { async complete() { called = true; return { text: '', stopReason: 'end_turn' } } }
  const out = await handleRecognize(spy, req({ ...adult, userKind: 'minorUnconsented' }))
  assert.equal(out.status, 403)
  assert.equal(called, false)   // server-side gate stops before any Anthropic call
})

test('eligible session returns a validated result', async () => {
  const client = clientReturning('{"formal":{"kind":"latex","value":"2x+3"},"confidence":0.88,"readAs":"2x + 3"}')
  const out = await handleRecognize(client, req(adult))
  assert.equal(out.status, 200)
  assert.equal(out.result?.formal.kind, 'latex')
  assert.equal(out.result?.formal.value, '2x+3')
})

test('eligible session but unreadable handwriting → unrecognized (not a guess)', async () => {
  const out = await handleRecognize(clientReturning('sorry, too messy'), req(adult))
  assert.equal(out.status, 200)
  assert.equal(out.result?.formal.kind, 'unrecognized')
})
