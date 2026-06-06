import type { AnthropicClient, AnthropicMessage } from './types.ts'

/// The model emits this marker when a generation is complete. Make-real output can exceed one
/// response, so we ask the model to finish with the marker; if a response is truncated (max_tokens)
/// without it, we feed the partial back and continue, then stitch (brief §6.1).
export const DONE_MARKER = '<!-- INKLAB_DONE -->'

export interface AssembleOpts {
  system: string
  userPrompt: string
  maxPasses?: number
  maxTokens?: number
}

export interface AssembleResult {
  output: string
  passes: number
  complete: boolean
}

function stripMarker(s: string): string {
  return s.split(DONE_MARKER).join('').trimEnd()
}

/// Multi-pass assembler: call the model, and while the response is truncated (no DONE marker and a
/// length stop), continue from the accumulated partial. Deterministic given the client — unit-tested
/// with a mock that returns chunks.
export async function assembleGeneration(client: AnthropicClient, opts: AssembleOpts): Promise<AssembleResult> {
  const maxPasses = opts.maxPasses ?? 5
  let accumulated = ''
  let passes = 0

  while (passes < maxPasses) {
    const isFirst = passes === 0
    const messages: AnthropicMessage[] = isFirst
      ? [{ role: 'user', content: opts.userPrompt }]
      : [
          { role: 'user', content: opts.userPrompt },
          { role: 'assistant', content: accumulated },
          { role: 'user', content: `Continue exactly where you left off; do not repeat anything. End with ${DONE_MARKER}` },
        ]

    const res = await client.complete({ system: opts.system, messages, maxTokens: opts.maxTokens })
    accumulated += res.text
    passes++

    if (accumulated.includes(DONE_MARKER) || res.stopReason === 'end_turn') {
      return { output: stripMarker(accumulated), passes, complete: true }
    }
    // otherwise: truncated → loop and continue
  }
  return { output: stripMarker(accumulated), passes, complete: false }
}
