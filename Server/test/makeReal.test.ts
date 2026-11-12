import { test } from 'node:test'
import assert from 'node:assert/strict'
import { handleMakeReal, MAKE_REAL_SYSTEM_PROMPT, MAX_PROMPT_CHARS } from '../src/makeReal.ts'
import { assembleGeneration, DONE_MARKER } from '../src/assembler.ts'
import { extractWidgetHtml, widgetLayout } from '../src/validate.ts'
import type { AnthropicClient, AnthropicResponse, CompleteOpts, Session } from '../src/types.ts'

const adult: Session = { isOnline: true, userKind: 'adult', aiConsentGranted: true, ageVerified: true }
const doc = '<!DOCTYPE html>\n<html><head><meta name="inklab-layout" content="landscape"><title>Clock</title></head><body><div>tick</div></body></html>'

function replying(...responses: AnthropicResponse[]): AnthropicClient & { calls: CompleteOpts[] } {
  const calls: CompleteOpts[] = []
  return {
    calls,
    async complete(opts) {
      calls.push(opts)
      return responses[Math.min(calls.length - 1, responses.length - 1)]
    },
  }
}

// --- extraction ---------------------------------------------------------------------------------

test('preamble + ```html fence + trailing marker → only the document is kept', () => {
  const raw = `I'll build a clean clock that fits the card.\n\n\`\`\`html\n${doc}\n\`\`\`\n${DONE_MARKER}`
  assert.equal(extractWidgetHtml(raw), doc)
})

test('trailing remark after </html> is dropped; a clean document is unchanged', () => {
  assert.equal(extractWidgetHtml(`${doc}\n\nLet me know if you want changes!`), doc)
  assert.equal(extractWidgetHtml(doc), doc)
})

test('a document without </html> keeps its body but loses the trailing fence and marker', () => {
  const raw = '```html\n<!DOCTYPE html><html><body><p>hi</p></body>\n<!-- INKLAB_DONE -->\n```'
  assert.equal(extractWidgetHtml(raw), '<!DOCTYPE html><html><body><p>hi</p></body>')
})

test('a fenced body fragment returns just the fragment', () => {
  assert.equal(extractWidgetHtml('Here you go:\n```html\n<div id="a">x</div>\n```\nEnjoy.'), '<div id="a">x</div>')
})

test('a prose-only reply has no widget', () => {
  assert.equal(extractWidgetHtml("Sorry, I can't build that."), null)
})

test('layout meta is read in either attribute order and defaults to portrait', () => {
  assert.equal(widgetLayout(doc), 'landscape')
  assert.equal(widgetLayout('<meta content="square" name="inklab-layout">'), 'square')
  assert.equal(widgetLayout('<meta name="inklab-layout" content="banana">'), 'portrait')
  assert.equal(widgetLayout('<html></html>'), 'portrait')
})

// --- assembler --------------------------------------------------------------------------------------

test('a refusal stops immediately instead of re-asking five times', async () => {
  const client = replying({ text: '', stopReason: 'refusal' })
  const r = await assembleGeneration(client, { system: 's', userPrompt: 'p' })
  assert.equal(r.refused, true)
  assert.equal(r.complete, false)
  assert.equal(client.calls.length, 1)
})

test('an empty truncated pass never sends an empty assistant turn', async () => {
  const client = replying({ text: '', stopReason: 'max_tokens' })
  const r = await assembleGeneration(client, { system: 's', userPrompt: 'p' })
  assert.equal(r.complete, false)
  assert.equal(client.calls.length, 1)
})

// --- handler ------------------------------------------------------------------------------------------

test('/make-real returns the cleaned document and its layout', async () => {
  const client = replying({ text: `Sure!\n\`\`\`html\n${doc}\n\`\`\`\n${DONE_MARKER}`, stopReason: 'end_turn' })
  const out = await handleMakeReal(client, { session: adult, prompt: '  a clock  ' })
  assert.equal(out.status, 200)
  assert.equal(out.body.html, doc)
  assert.equal(out.body.layout, 'landscape')
  assert.equal(client.calls[0].system, MAKE_REAL_SYSTEM_PROMPT)
  assert.deepEqual(client.calls[0].messages, [{ role: 'user', content: 'Build this widget: a clock' }])
})

test('ineligible session is refused before any model call', async () => {
  const client = replying({ text: doc, stopReason: 'end_turn' })
  const out = await handleMakeReal(client, { session: { ...adult, aiConsentGranted: false }, prompt: 'a clock' })
  assert.equal(out.status, 403)
  assert.equal(client.calls.length, 0)
})

test('empty and oversized prompts are rejected without a model call', async () => {
  const client = replying({ text: doc, stopReason: 'end_turn' })
  assert.deepEqual(await handleMakeReal(client, { session: adult, prompt: '   ' }), { status: 400, body: { error: 'empty prompt' } })
  const long = 'x'.repeat(MAX_PROMPT_CHARS + 1)
  assert.deepEqual(await handleMakeReal(client, { session: adult, prompt: long }), { status: 400, body: { error: 'prompt too long' } })
  assert.equal(client.calls.length, 0)
})

test('a declined request maps to 422 "declined"', async () => {
  const out = await handleMakeReal(replying({ text: '', stopReason: 'refusal' }), { session: adult, prompt: 'x' })
  assert.deepEqual(out, { status: 422, body: { error: 'declined' } })
})

test('a prose-only completion maps to 502 "no widget"', async () => {
  const out = await handleMakeReal(replying({ text: 'I cannot do that.', stopReason: 'end_turn' }), { session: adult, prompt: 'x' })
  assert.deepEqual(out, { status: 502, body: { error: 'no widget' } })
})

test('the whole-request deadline ends a slow generation with 504', async () => {
  let callTimeout: number | undefined
  const hanging: AnthropicClient = {
    complete(opts) {
      callTimeout = opts.timeoutMs
      return new Promise((_resolve, reject) => {
        opts.signal?.addEventListener('abort', () => reject(Object.assign(new Error('upstream error'), { upstream: true })), { once: true })
      })
    },
  }
  const out = await handleMakeReal(hanging, { session: adult, prompt: 'x' }, { deadlineMs: 20 })
  assert.deepEqual(out, { status: 504, body: { error: 'generation timed out' } })
  assert.equal(callTimeout, 20)
})

test('a client disconnect is not reported as a deadline', async () => {
  const caller = new AbortController()
  const hanging: AnthropicClient = {
    complete(opts) {
      return new Promise((_resolve, reject) => {
        opts.signal?.addEventListener('abort', () => reject(Object.assign(new Error('upstream error'), { upstream: true })), { once: true })
      })
    },
  }
  const pending = handleMakeReal(hanging, { session: adult, prompt: 'x' }, { signal: caller.signal, deadlineMs: 10_000 })
  caller.abort()
  await assert.rejects(pending, (e: any) => e.upstream === true)
})

test('the prompt asks for raw HTML only, a layout declaration, and responsive sizing', () => {
  assert.match(MAKE_REAL_SYSTEM_PROMPT, /No markdown code fences/)
  assert.match(MAKE_REAL_SYSTEM_PROMPT, /inklab-layout/)
  assert.match(MAKE_REAL_SYSTEM_PROMPT, /resize the card/)
  assert.ok(MAKE_REAL_SYSTEM_PROMPT.includes(DONE_MARKER))
})
