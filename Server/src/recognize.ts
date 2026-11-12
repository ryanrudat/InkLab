import type { AnthropicClient, AnthropicMessage, ContentBlock, RecognitionRequest, RecognitionResult, Domain } from './types.ts'
import { cloudEligible } from './consent.ts'
import { validateRecognition } from './validate.ts'

export interface HandlerResult {
  status: number
  result?: RecognitionResult
  error?: string
}

function systemPrompt(domain: Domain): string {
  const target =
    domain === 'math' ? 'LaTeX (kind "latex")'
    : domain === 'chemistry' ? 'a SMILES string (kind "smiles")'
    : domain === 'diagram' ? 'a structured description (kind "plainText")'
    : 'plain text (kind "plainText")'
  return [
    `You translate a student's handwriting into formal structure. Target: ${target}.`,
    'You ONLY transcribe — you do not solve or evaluate; deterministic engines do that.',
    'Return STRICT JSON and nothing else: {"formal":{"kind":...,"value":...},"confidence":0..1,"readAs":"..."}.',
    'If you cannot read it confidently, return {"formal":{"kind":"unrecognized","value":""},"confidence":0,"readAs":""}.',
  ].join(' ')
}

export function buildRecognitionMessages(req: RecognitionRequest): AnthropicMessage[] {
  const blocks: ContentBlock[] = []
  if (req.rasterPngBase64) {
    blocks.push({ type: 'image', source: { type: 'base64', media_type: 'image/png', data: req.rasterPngBase64 } })
  }
  const note = req.context ? ` Context near the writing: ${req.context}.` : ''
  blocks.push({ type: 'text', text: `Transcribe the handwriting in this region.${note}` })
  return [{ role: 'user', content: blocks }]
}

/// Recognition fallback: gate the session, ask Claude to transcribe to formal structure, and return
/// only a validated result (correct-or-silent). The server enforces the gate independently.
export async function handleRecognize(
  client: AnthropicClient,
  req: RecognitionRequest,
  signal?: AbortSignal,
): Promise<HandlerResult> {
  const decision = cloudEligible(req.session)
  if (!decision.allowed) return { status: 403, error: decision.reason }

  const res = await client.complete({
    system: systemPrompt(req.domain),
    messages: buildRecognitionMessages(req),
    maxTokens: 1024,
    signal,
  })
  return { status: 200, result: validateRecognition(res.text) }
}
