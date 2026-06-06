import type { RecognitionResult, FormalKind } from './types.ts'

/// Pull the first balanced JSON object out of a model response (models sometimes wrap JSON in prose
/// or ```json fences).
export function extractJson(raw: string): string | null {
  const start = raw.indexOf('{')
  const end = raw.lastIndexOf('}')
  if (start < 0 || end <= start) return null
  return raw.slice(start, end + 1)
}

const VALID_KINDS: FormalKind[] = ['latex', 'smiles', 'plainText', 'unrecognized']

/// "Correct or silent": the model is asked to return strict JSON
/// `{ formal: { kind, value }, confidence, readAs }`. If the response doesn't parse into a valid,
/// non-empty structure, we return `unrecognized` rather than passing a hallucinated/garbage string
/// downstream (brief §3.5). The deterministic engines remain the correctness authority.
export function validateRecognition(raw: string): RecognitionResult {
  const unrecognized: RecognitionResult = { formal: { kind: 'unrecognized', value: '' }, confidence: 0, readAs: '' }
  const jsonText = extractJson(raw)
  if (!jsonText) return unrecognized
  let j: any
  try {
    j = JSON.parse(jsonText)
  } catch {
    return unrecognized
  }
  const kind = j?.formal?.kind
  const value = j?.formal?.value
  const readAs = j?.readAs
  const confidence = j?.confidence
  const valid =
    VALID_KINDS.includes(kind) &&
    kind !== 'unrecognized' &&
    typeof value === 'string' &&
    value.trim().length > 0 &&
    typeof readAs === 'string' &&
    typeof confidence === 'number' &&
    isFinite(confidence)
  if (!valid) return unrecognized
  return {
    formal: { kind, value },
    confidence: Math.max(0, Math.min(1, confidence)),
    readAs,
  }
}

/// Basic safety check on a generated make-real widget: it must be self-contained (no external network
/// loads), so it can run in a locked-down WKWebView. Returns the violations found (empty = safe).
export function validateWidgetHtml(html: string): { safe: boolean; violations: string[] } {
  const violations: string[] = []
  const lower = html.toLowerCase()
  if (/<script[^>]+src\s*=\s*["']https?:/i.test(html)) violations.push('external script src')
  if (/<link[^>]+href\s*=\s*["']https?:/i.test(html)) violations.push('external stylesheet')
  if (/\bfetch\s*\(\s*["']https?:/i.test(html) || /xmlhttprequest/i.test(lower)) violations.push('network request')
  if (/<iframe/i.test(lower)) violations.push('iframe')
  return { safe: violations.length === 0, violations }
}
