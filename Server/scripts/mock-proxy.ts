// A local stand-in for the InkLab proxy, for Simulator UI runs without an API key or network:
// the REAL server (routing, consent gate, the tutor's hint ladder and answer-leak guard) with a scripted
// fake in place of Claude. The opening tutor draft deliberately leaks the answer, so a run shows the
// guard rejecting it and the stricter regeneration taking its place.
//
//   node scripts/mock-proxy.ts                       # listens on :8799
//   SIMCTL_CHILD_INKLAB_PROXY_URL=http://localhost:8799 xcrun simctl launch booted com.ryanrudat.InkLab
//
// MOCK_PROBLEM / MOCK_REPLY set what "handwriting recognition" returns for the selected problem (math
// domain) and for a reply written next to it (text domain).
import { createInkLabServer } from '../src/server.ts'
import type { AnthropicClient, AnthropicResponse } from '../src/types.ts'

const PORT = Number(process.env.PORT ?? 8799)
const PROBLEM = process.env.MOCK_PROBLEM ?? '2x + 3 = 7\n2x = 10\nx = 5'
const REPLY = process.env.MOCK_REPLY ?? '2x = 4'

const LADDER = [
  'Go back through your working one line at a time: does each line really follow from the one above it?',
  'Look closely at line 2: what did you do to line 1 to get it?',
  'Whatever you do to one side of an equation you do to the other, so when you took 3 away on the left of line 1, what happened on the right?',
  "Here's a different one: from 5y + 4 = 19, take 4 from both sides to get 5y = 15. Can you make the same first move on line 1?",
]

const say = (text: string): AnthropicResponse => ({ text, stopReason: 'end_turn' })

const client: AnthropicClient = {
  async complete(opts) {
    const system = opts.system ?? ''
    if (system.startsWith('You translate')) {
      const value = system.includes('LaTeX') ? PROBLEM : REPLY
      console.log(`[recognize] → ${JSON.stringify(value)}`)
      return say(JSON.stringify({ formal: { kind: 'plainText', value }, confidence: 0.95, readAs: value }))
    }
    if (system.includes("InkLab's math tutor")) {
      const strict = system.includes('previous draft was rejected')
      const level = Number(/Current level: (\d)/.exec(system)?.[1] ?? 1)
      const last = opts.messages[opts.messages.length - 1]
      const lastText = typeof last.content === 'string' ? last.content : ''
      let draft: string
      if (lastText.includes('checker verified the math')) draft = 'Nice fix to line 2. What could you do to both sides next to get x on its own?'
      else if (!strict && opts.messages.length === 1) draft = 'Subtract 3 from both sides and you get x = 2, see?'   // leaks: the guard must reject it
      else draft = LADDER[Math.min(LADDER.length, Math.max(1, level)) - 1]
      console.log(`[tutor] model=${opts.model} effort=${opts.effort} level=${level} strict=${strict} → ${JSON.stringify(draft)}`)
      return say(draft)
    }
    return say('<!DOCTYPE html><html><head><title>Mock</title></head><body>mock widget</body></html>\n<!-- INKLAB_DONE -->')
  },
}

createInkLabServer({ client, authSecret: '' }).listen(PORT, () => console.log(`InkLab MOCK proxy on :${PORT}`))
