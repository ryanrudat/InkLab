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
  model?: string
  thinking?: { type: 'adaptive' | 'disabled' }
  effort?: 'low' | 'medium' | 'high' | 'max'
  /** Per-call upstream deadline (overrides the client default). */
  timeoutMs?: number
  signal?: AbortSignal
}

export interface AssembleResult {
  output: string
  passes: number
  complete: boolean
  /** The model declined the request (`stop_reason: "refusal"`). Terminal: retrying cannot help. */
  refused?: boolean
}

// Remove ONLY the terminating marker (the model is instructed to END with it). Stripping every
// occurrence would silently delete the literal marker text if a widget legitimately rendered it as
// content (e.g. an HTML-tutorial widget).
function stripMarker(s: string): string {
  let out = s.trimEnd()
  while (out.endsWith(DONE_MARKER)) out = out.slice(0, -DONE_MARKER.length).trimEnd()
  return out
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

    const res = await client.complete({
      system: opts.system,
      messages,
      maxTokens: opts.maxTokens,
      model: opts.model,
      thinking: opts.thinking,
      effort: opts.effort,
      timeoutMs: opts.timeoutMs,
      signal: opts.signal,
    })
    passes++
    // A refusal is final: continuing would only re-ask the same declined request (and send an empty
    // assistant turn, which the API rejects).
    if (res.stopReason === 'refusal') return { output: '', passes, complete: false, refused: true }
    accumulated += res.text

    if (accumulated.includes(DONE_MARKER) || res.stopReason === 'end_turn') {
      return { output: stripMarker(accumulated), passes, complete: true }
    }
    // A pass that produced nothing made no progress; another identical continuation won't either.
    if (!res.text.trim()) break
    // otherwise: truncated → loop and continue
  }
  return { output: stripMarker(accumulated), passes, complete: false }
}
