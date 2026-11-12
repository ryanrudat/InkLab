import type { AnthropicClient, AnthropicMessage, AnthropicResponse, CompleteOpts } from './types.ts'

export const DEFAULT_OPENAI_TIMEOUT_MS = 120_000

function upstreamError(details: { timeout?: boolean; aborted?: boolean; status?: number } = {}): Error {
  return Object.assign(new Error('upstream error'), { upstream: true, ...details })
}

/// Anthropic-style messages → Responses API `input` items. Text blocks become `input_text` (or
/// `output_text` for an assistant turn, e.g. the multi-pass assembler's partial); images become
/// `input_image` data URLs.
export function toResponsesInput(messages: AnthropicMessage[]): unknown[] {
  return messages.map((m) => ({
    role: m.role,
    content: typeof m.content === 'string'
      ? m.content
      : m.content.map((b) => b.type === 'text'
        ? { type: m.role === 'assistant' ? 'output_text' : 'input_text', text: b.text }
        : { type: 'input_image', image_url: `data:${b.source.media_type};base64,${b.source.data}` }),
  }))
}

/// Responses API result → the proxy's `{ text, stopReason }`, using Anthropic's stop-reason names so the
/// assembler and handlers work unchanged: completed → end_turn, cut off at the output cap → max_tokens,
/// a refusal or content filter → refusal.
export function fromResponsesOutput(json: any): AnthropicResponse {
  const parts = (json?.output ?? [])
    .filter((o: any) => o?.type === 'message')
    .flatMap((o: any) => o.content ?? [])
  const text = parts.filter((c: any) => c?.type === 'output_text').map((c: any) => c.text).join('')
  if (parts.some((c: any) => c?.type === 'refusal')) return { text, stopReason: 'refusal' }
  if (json?.status === 'incomplete') {
    const reason = json?.incomplete_details?.reason
    return { text, stopReason: reason === 'max_output_tokens' ? 'max_tokens' : 'refusal' }
  }
  return { text, stopReason: 'end_turn' }
}

/// OpenAI (GPT) behind the same client interface as `httpAnthropicClient`, via the Responses API, so
/// make-real can switch provider by model name (`MAKE_REAL_MODEL=gpt-…`). Same posture as anthropic.ts:
/// the key lives only on the server, no request/response content is logged, every call has a finite
/// deadline and observes the caller's cancellation, and failures surface as generic tagged errors.
/// Anthropic-only options (`thinking`, `betas`, `fallbacks`) are ignored.
export function httpOpenAIClient(
  apiKey: string = process.env.OPENAI_API_KEY ?? '',
  defaultModel: string = 'gpt-6.1-sol',
  requestTimeoutMs: number = DEFAULT_OPENAI_TIMEOUT_MS,
): AnthropicClient {
  return {
    async complete(opts: CompleteOpts): Promise<AnthropicResponse> {
      const controller = new AbortController()
      let timedOut = false
      const timeout = setTimeout(() => { timedOut = true; controller.abort() }, opts.timeoutMs ?? requestTimeoutMs)
      const abortFromCaller = () => controller.abort(opts.signal?.reason)
      if (opts.signal?.aborted) abortFromCaller()
      else opts.signal?.addEventListener('abort', abortFromCaller, { once: true })

      try {
        if (controller.signal.aborted) throw upstreamError({ aborted: true })
        const res = await fetch('https://api.openai.com/v1/responses', {
          method: 'POST',
          headers: { 'content-type': 'application/json', authorization: `Bearer ${apiKey}` },
          body: JSON.stringify({
            model: opts.model ?? defaultModel,
            ...(opts.system ? { instructions: opts.system } : {}),
            input: toResponsesInput(opts.messages),
            max_output_tokens: opts.maxTokens ?? 2048,
            ...(opts.effort ? { reasoning: { effort: opts.effort } } : {}),
          }),
          signal: controller.signal,
        })
        if (!res.ok) {
          // Generic error only: the upstream body can carry request ids / internal detail.
          await res.text().catch(() => '')
          throw upstreamError({ status: res.status })
        }
        return fromResponsesOutput(await res.json())
      } catch (error) {
        if ((error as any)?.upstream) throw error
        throw upstreamError({ timeout: timedOut, aborted: controller.signal.aborted })
      } finally {
        clearTimeout(timeout)
        opts.signal?.removeEventListener('abort', abortFromCaller)
      }
    },
  }
}
