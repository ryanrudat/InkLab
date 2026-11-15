import { test } from 'node:test'
import assert from 'node:assert/strict'
import type { AddressInfo } from 'node:net'
import {
  handleWritingTutor, parseWritingRequest, reviewWritingReply, writingFallback, writingSystemPrompt, buildWritingMessages,
} from '../src/writingTutor.ts'
import { createInkLabServer } from '../src/server.ts'
import type { AnthropicClient, AnthropicResponse, CompleteOpts, Session } from '../src/types.ts'

const adult: Session = { isOnline: true, userKind: 'adult', aiConsentGranted: true, ageVerified: true }

/// A history answer, as read from two handwritten lines.
const historyBody = (extra: Record<string, unknown> = {}) => ({
  session: adult,
  mode: 'writing',
  lines: ['The Civil War started because of', 'taxes in 1861.'],
  thread: [],
  ...extra,
})
const STUDENT = 'The Civil War started because of taxes in 1861.'

function replying(...texts: Array<string | AnthropicResponse>): AnthropicClient & { calls: CompleteOpts[] } {
  const calls: CompleteOpts[] = []
  return {
    calls,
    async complete(opts) {
      calls.push(opts)
      const r = texts[Math.min(calls.length - 1, texts.length - 1)]
      return typeof r === 'string' ? { text: r, stopReason: 'end_turn' } : r
    },
  }
}

const QUESTION = 'What is the main reason you want your reader to remember about why the war started?'

test('writing: an ineligible session is refused before any model call', async () => {
  const client = replying(QUESTION)
  const out = await handleWritingTutor(client, historyBody({ session: { ...adult, userKind: 'minorUnconsented' } }))
  assert.equal(out.status, 403)
  assert.equal(client.calls.length, 0)
})

test('writing: malformed requests are rejected without a model call', async () => {
  const client = replying(QUESTION)
  for (const body of [
    historyBody({ lines: [] }),
    historyBody({ lines: ['x'.repeat(500)] }),
    historyBody({ thread: [{ role: 'tutor', text: 'hi' }] }),          // nothing to reply to
    historyBody({ thread: [{ role: 'robot', text: 'hi' }] }),
  ]) {
    const out = await handleWritingTutor(client, body)
    assert.equal(out.status, 400, JSON.stringify(body))
  }
  assert.equal(client.calls.length, 0)
  assert.ok(parseWritingRequest(historyBody()).ok)
})

test('writing: &Co coaches without writing it for them, one level at a time', () => {
  const p = writingSystemPrompt(1, false)
  assert.match(p, /You are &Co, InkLab's writing tutor for English and History/)
  assert.match(p, /Current level: 1 of 4/)
  assert.match(p, /never write a sentence, thesis, topic sentence or answer they could copy/)
  assert.match(p, /no dates, names, events or figures they did not write/)
  // Its quotes of their own words are what the app lights up on the page.
  assert.match(p, /quote two to eight of their own words in double quotes/)
  assert.match(writingSystemPrompt(2, true), /previous draft was rejected/)
  // The page's lines go in as the student's writing; their replies as messages.
  const parsed = parseWritingRequest(historyBody({
    thread: [{ role: 'tutor', text: QUESTION }, { role: 'student', text: 'because <b>taxes</b>' }],
  }))
  if (!parsed.ok) throw new Error(parsed.error)
  const messages = buildWritingMessages(parsed.req)
  assert.equal(messages.length, 3)
  assert.match(messages[0].content as string, /<writing>[\s\S]*The Civil War started because of\ntaxes in 1861\.[\s\S]*<\/writing>/)
  assert.equal(messages[2].content, '<student_message>because ‹b›taxes‹/b›</student_message>')
})

test('writing review: a sentence handed to them is rejected; their own words are fine', () => {
  // A rewrite in quotes, or "you could write …".
  assert.equal(reviewWritingReply('You could write "The war began over states disagreeing about slavery." Does that help?', STUDENT, 1), 'rewrite')
  assert.equal(reviewWritingReply('Try starting with: the main cause was slavery. What do you think?', STUDENT, 2), 'rewrite')
  assert.equal(reviewWritingReply("Here's a stronger sentence for you. Can you see the difference?", STUDENT, 2), 'rewrite')
  // Quoting the student's own words to point at a spot is how &Co focuses.
  assert.equal(reviewWritingReply('You wrote "started because of taxes": which taxes do you mean?', STUDENT, 2), null)
  // Level 4 may show the move on a different topic, in quotes.
  assert.equal(reviewWritingReply('Here is the move: "Our team lost because we missed practice all week." Can you try it with your reason?', STUDENT, 4), null)
})

test('writing review: &Co never supplies or corrects a fact', () => {
  assert.equal(reviewWritingReply('The war actually began in 1860, so what happened first?', STUDENT, 1), 'fact')
  assert.equal(reviewWritingReply('Actually, it was about slavery. Why do you think so?', STUDENT, 1), 'fact')
  assert.equal(reviewWritingReply('Where did you find that it began in 1861?', STUDENT, 1), null)   // their own date
})

test('writing: a draft that writes it for them is regenerated strictly, then falls back', async () => {
  const rewrite = 'You could write "The war started because the states disagreed about slavery." Does that help?'
  const client = replying(rewrite, QUESTION)
  const out = await handleWritingTutor(client, historyBody())
  assert.deepEqual(out.body, { reply: QUESTION, rung: 1, guard: 'regenerated' })
  assert.equal(client.calls.length, 2)
  assert.match(client.calls[1].system ?? '', /previous draft was rejected/)

  const stubborn = replying(rewrite)
  const fallback = await handleWritingTutor(stubborn, historyBody())
  assert.deepEqual(fallback.body, { reply: writingFallback(1), rung: 1, guard: 'fallback' })
  assert.equal(stubborn.calls.length, 2)
})

test('writing: the ladder climbs only when they ask for more help', async () => {
  const client = replying(QUESTION)
  const out = await handleWritingTutor(client, historyBody({
    thread: [{ role: 'tutor', text: QUESTION }, { role: 'student', text: 'another hint', wantsHint: true }],
  }))
  assert.equal(out.body.rung, 2)
  assert.match(client.calls[0].system ?? '', /Current level: 2 of 4/)
  for (let rung = 1; rung <= 4; rung++) assert.match(writingFallback(rung), /\?$/)
})

test('POST /tutor with mode "writing" reaches the writing coach (auth still required)', async (t) => {
  const client = replying(QUESTION)
  const server = createInkLabServer({ client, authSecret: 's3cret' })
  await new Promise<void>((resolve) => server.listen(0, '127.0.0.1', resolve))
  t.after(() => server.close())
  const url = `http://127.0.0.1:${(server.address() as AddressInfo).port}/tutor`
  const post = (headers: Record<string, string>) =>
    fetch(url, { method: 'POST', headers: { 'content-type': 'application/json', ...headers }, body: JSON.stringify(historyBody()) })
  assert.equal((await post({})).status, 401)
  const res = await post({ authorization: 'Bearer s3cret' })
  assert.equal(res.status, 200)
  assert.deepEqual(await res.json(), { reply: QUESTION, rung: 1, guard: 'clean' })
  assert.match(client.calls[0].system ?? '', /writing tutor/)
})
