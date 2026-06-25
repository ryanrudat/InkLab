import type { AnthropicClient, CompleteOpts, AnthropicResponse } from './types.ts'

/// The real Anthropic client over HTTP. The API key lives ONLY here on the server (never on the
/// device — ADR 0002). Configured for zero-data-retention posture: no request/response content is
/// logged here. Returns the concatenated text + the stop reason (used by the multi-pass assembler).
export function httpAnthropicClient(
  apiKey: string = process.env.ANTHROPIC_API_KEY ?? '',
  defaultModel: string = 'claude-opus-4-8',
): AnthropicClient {
  return {
    async complete(opts: CompleteOpts): Promise<AnthropicResponse> {
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
      })
      if (!res.ok) {
        // Surface a GENERIC upstream error. Do NOT embed the upstream response body (which can carry a
        // request_id / internal detail) into a message that propagates to the client — the catch-all in
        // server.ts turns an `upstream`-tagged error into a bare 502. Status only is logged server-side.
        await res.text().catch(() => '') // drain the body so the socket can be reused; value discarded
        throw Object.assign(new Error('upstream error'), { upstream: true, status: res.status })
      }
      const json: any = await res.json()
      const text = (json.content ?? [])
        .filter((b: any) => b.type === 'text')
        .map((b: any) => b.text)
        .join('')
      return { text, stopReason: json.stop_reason ?? 'end_turn' }
    },
  }
}
