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

/// Pull the widget's HTML out of a model reply. The model is told to reply with the document only, but a
/// reply can still carry a sentence of preamble, a ```html fence, or a closing remark. The WKWebView would
/// render that stray text inside the card, and text before `<!DOCTYPE>` also drops the page into quirks
/// mode, which shifts the whole layout. So the proxy returns only the document (or, for a fragment, only
/// the fenced/markup part). Returns null when the reply contains no HTML at all (e.g. a prose-only answer).
export function extractWidgetHtml(raw: string): string | null {
  const trailingMarker = /<!--\s*INKLAB_DONE\s*-->\s*$/i
  const docStart = raw.search(/<!doctype\s+html|<html[\s>]/i)
  if (docStart >= 0) {
    const closeTag = raw.toLowerCase().lastIndexOf('</html>')
    if (closeTag > docStart) return raw.slice(docStart, closeTag + '</html>'.length)
    // No closing tag: drop a trailing fence / marker, keep the rest of the document.
    return raw.slice(docStart).replace(/\s*```\s*$/, '').replace(trailingMarker, '').trim()
  }
  // A body-level fragment: prefer the first fenced block's contents when the reply is fenced.
  const fenced = /```[ \t]*(?:html?)?[ \t]*\r?\n([\s\S]*?)(?:\r?\n[ \t]*```|$)/i.exec(raw)
  const fragment = (fenced ? fenced[1] : raw).replace(trailingMarker, '').trim()
  return /<[a-z][\s\S]*>/i.test(fragment) ? fragment : null
}

/// The card shape a widget declares with `<meta name="inklab-layout" content="…">`. The app sizes the card
/// from it (portrait 360×540, landscape 560×360, square 440×440 CSS px). Unknown/missing → portrait.
export type WidgetLayout = 'portrait' | 'landscape' | 'square'

export function widgetLayout(html: string): WidgetLayout {
  const meta = /<meta\b[^>]*\bname\s*=\s*["']?inklab-layout["']?[^>]*>/i.exec(html)?.[0]
  const value = meta && /\bcontent\s*=\s*["']?\s*([a-z]+)/i.exec(meta)?.[1]?.toLowerCase()
  return value === 'landscape' || value === 'square' ? value : 'portrait'
}

/// Best-effort, DEFENSE-IN-DEPTH safety scan of a generated make-real widget. It rejects the obvious
/// external-load / exfiltration / navigation shapes so a malformed widget is caught before it ever
/// reaches a device. It is NOT a complete allowlist and is NOT the security boundary: the real boundary
/// is the on-device WKWebView lockdown (CSP `default-src 'none'`, nil baseURL, a navigation delegate
/// that cancels every navigation, non-persistent store — see WebWidgetView), which is deny-by-default
/// and independently blocks every vector below. This scan is a redundant tripwire. Empty = no obvious
/// violation. (Matches absolute `https?://` AND protocol-relative `//host` references.)
export function validateWidgetHtml(html: string): { safe: boolean; violations: string[] } {
  const violations: string[] = []
  const lower = html.toLowerCase()
  const URL = String.raw`["']?\s*(?:https?:)?\/\/`   // absolute or protocol-relative URL (quotes optional)
  // External resource/navigation references in attributes.
  if (new RegExp(`<script[^>]+src\\s*=\\s*${URL}`, 'i').test(html)) violations.push('external script src')
  if (new RegExp(`<link[^>]+href\\s*=\\s*${URL}`, 'i').test(html)) violations.push('external stylesheet')
  if (new RegExp(`(?:src|href|action|formaction|poster|data|xlink:href)\\s*=\\s*${URL}`, 'i').test(html)) {
    violations.push('external resource url')
  }
  if (new RegExp(`url\\(\\s*${URL}`, 'i').test(lower)) violations.push('css external url')
  if (/<base\b/i.test(lower)) violations.push('base tag')
  if (/<meta[^>]+http-equiv\s*=\s*["']\s*refresh/i.test(html)) violations.push('meta refresh')
  if (/<iframe/i.test(lower)) violations.push('iframe')
  if (/<frame\b/i.test(lower) || /<object\b/i.test(lower) || /<embed\b/i.test(lower)) violations.push('embedded object')
  // Network / dynamic-load APIs (a self-contained offline widget needs none of these).
  if (/\bfetch\s*\(/i.test(lower)) violations.push('fetch')
  if (/xmlhttprequest/i.test(lower)) violations.push('XMLHttpRequest')
  if (/\bwebsocket\b/i.test(lower)) violations.push('WebSocket')
  if (/\beventsource\b/i.test(lower)) violations.push('EventSource')
  if (/sendbeacon/i.test(lower)) violations.push('sendBeacon')
  if (/\bimport\s*\(/i.test(lower)) violations.push('dynamic import')
  return { safe: violations.length === 0, violations }
}
