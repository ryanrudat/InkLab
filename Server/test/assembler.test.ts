import { test } from 'node:test'
import assert from 'node:assert/strict'
import { assembleGeneration, DONE_MARKER } from '../src/assembler.ts'
import type { AnthropicClient, AnthropicResponse } from '../src/types.ts'

function mockClient(responses: AnthropicResponse[]): AnthropicClient {
  let i = 0
  return { async complete() { return responses[Math.min(i++, responses.length - 1)] } }
}

test('single complete response → one pass', async () => {
  const c = mockClient([{ text: '<html>ok</html>', stopReason: 'end_turn' }])
  const r = await assembleGeneration(c, { system: 's', userPrompt: 'p' })
  assert.equal(r.complete, true)
  assert.equal(r.passes, 1)
  assert.equal(r.output, '<html>ok</html>')
})

test('truncated then completed → stitched across two passes', async () => {
  const c = mockClient([
    { text: 'part1', stopReason: 'max_tokens' },                  // truncated, no marker
    { text: 'part2 ' + DONE_MARKER, stopReason: 'end_turn' },     // finishes with the marker
  ])
  const r = await assembleGeneration(c, { system: 's', userPrompt: 'p', maxPasses: 5 })
  assert.equal(r.complete, true)
  assert.equal(r.passes, 2)
  assert.equal(r.output, 'part1part2')   // marker stripped, trailing space trimmed
})

test('never-completing generation stops at maxPasses and reports incomplete', async () => {
  const c = mockClient([{ text: 'x', stopReason: 'max_tokens' }]) // always truncated
  const r = await assembleGeneration(c, { system: 's', userPrompt: 'p', maxPasses: 3 })
  assert.equal(r.complete, false)
  assert.equal(r.passes, 3)
  assert.equal(r.output, 'xxx')
})
