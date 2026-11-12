import type { AnthropicClient, CompleteOpts, AnthropicResponse } from './types.ts'

export const DEFAULT_ANTHROPIC_TIMEOUT_MS = 120_000

function configuredTimeoutMs(): number {
  const value = Number(process.env.ANTHROPIC_TIMEOUT_MS)
  return Number.isFinite(value) && value > 0 ? value : DEFAULT_ANTHROPIC_TIMEOUT_MS
}

function upstreamError(details: { timeout?: boolean; aborted?: boolean } = {}): Error {
  return Object.assign(new Error('upstream error'), { upstream: true, ...details })
}

/// The real Anthropic client over HTTP. The API key lives ONLY here on the server (never on the
/// device — ADR 0002). Configured for zero-data-retention posture: no request/response content is
/// logged here. Each HTTP call has a finite deadline and also observes a caller cancellation signal.
/// Returns the concatenated text + the stop reason (used by the multi-pass assembler).
export function httpAnthropicClient(
  apiKey: string = process.env.ANTHROPIC_API_KEY ?? '',
  defaultModel: string = 'claude-opus-4-8',
  requestTimeoutMs: number = configuredTimeoutMs(),
): AnthropicClient {
  return {
    async complete(opts: CompleteOpts): Promise<AnthropicResponse> {
      const controller = new AbortController()
      let timedOut = false
      const timeout = setTimeout(() => {
        timedOut = true
        controller.abort()
      }, opts.timeoutMs ?? requestTimeoutMs)

      const abortFromCaller = () => controller.abort(opts.signal?.reason)
      if (opts.signal?.aborted) abortFromCaller()
      else opts.signal?.addEventListener('abort', abortFromCaller, { once: true })

      try {
        if (controller.signal.aborted) {
          throw upstreamError({ aborted: true })
        }

        const res = await fetch('https://api.anthropic.com/v1/messages', {
          method: 'POST',
          headers: {
            'content-type': 'application/json',
            'x-api-key': apiKey,
            'anthropic-version': '2023-06-01',
          },
          body: JSON.stringify({
            model: opts.model ?? defaultModel,
            max_tokens: opts.maxTokens ?? 2048,
            system: opts.system,
            messages: opts.messages,
            ...(opts.thinking ? { thinking: opts.thinking } : {}),
            ...(opts.effort ? { output_config: { effort: opts.effort } } : {}),
          }),
          signal: controller.signal,
        })
        if (!res.ok) {
          // Surface a GENERIC upstream error. Do NOT embed the upstream response body (which can carry a
          // request_id / internal detail) into a message that propagates to the client — the catch-all in
          // server.ts turns an `upstream`-tagged error into a bare 502. Status only is logged server-side.
          await res.text().catch(() => '') // drain the body so the socket can be reused; value discarded
          throw Object.assign(upstreamError(), { status: res.status })
        }
        const json: any = await res.json()
        const text = (json.content ?? [])
          .filter((b: any) => b.type === 'text')
          .map((b: any) => b.text)
          .join('')
        return { text, stopReason: json.stop_reason ?? 'end_turn' }
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
