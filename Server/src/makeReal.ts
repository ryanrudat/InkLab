import type { AnthropicClient } from './types.ts'
import { cloudEligible } from './consent.ts'
import { assembleGeneration, DONE_MARKER } from './assembler.ts'
import { extractWidgetHtml, validateWidgetHtml, widgetLayout } from './validate.ts'

export const MAKE_REAL_MODEL = 'claude-opus-4-8'

/// Whole-request budget across every pass. The app waits a little longer than this (MakeReal.swift
/// `timeoutInterval`), so a slow generation ends as a clear 504 here instead of a client-side timeout
/// that would look like "server unreachable". Override with MAKE_REAL_DEADLINE_MS.
export const DEFAULT_MAKE_REAL_DEADLINE_MS = 170_000

/// A request is a short natural-language ask ("a pendulum sim"); cap it so the proxy can't be used to
/// push arbitrary long prompts through our key.
export const MAX_PROMPT_CHARS = 2000

/// The card sizes below must match `WidgetLayout.contentSize` in the app (MakeReal.swift).
export const MAKE_REAL_SYSTEM_PROMPT = [
  "You build ONE self-contained interactive HTML widget that sits on a student's notebook page on an iPad.",
  '',
  'Output format',
  `- Reply with the HTML document ONLY: start with <!DOCTYPE html>, end with </html>, then on its own line ${DONE_MARKER}`,
  '- No markdown code fences, no explanation, nothing before <!DOCTYPE html> or after the marker. Anything outside the document shows up as stray text in the widget.',
  '- Put all CSS and JavaScript inline.',
  '',
  'Sandbox',
  '- The widget runs offline in a locked-down web view. Use no external resources: no external scripts, fonts, images or stylesheets, no fetch/XMLHttpRequest/WebSocket/EventSource, no <iframe>. Draw pictures with inline SVG or <canvas>.',
  '',
  'Size and layout',
  '- Pick the card shape that suits the content and declare it in <head>: <meta name="inklab-layout" content="portrait"> (or "landscape" / "square").',
  '  - portrait: 360 x 540 CSS px. Calculators, converters, forms, quizzes, step-by-step tools.',
  '  - landscape: 560 x 360 CSS px. Graphs, timelines, number lines, wide simulations.',
  '  - square: 440 x 440 CSS px. Clocks, dials, diagrams, small games.',
  '- Design for that size, but the student can resize the card, so the layout must stay responsive: html, body { margin: 0; height: 100%; overflow: hidden; }, a root element that fills 100% width and height, box-sizing: border-box, and flexbox or CSS grid with relative sizing (fr, %, min(), clamp()) instead of fixed pixel widths and heights.',
  '- Everything must fit with no scrolling at the declared size. Size <canvas> and SVG drawings from the current viewport and redraw them on window resize.',
  '',
  'Look and feel',
  '- Clean, modern, light design. Always set an explicit background color on body and explicit text colors; the card is always shown in light mode.',
  '- Use the system font stack (-apple-system, system-ui, sans-serif), clear visual hierarchy, consistent spacing, and one accent color.',
  '- The app shows your <title> in a header bar above the card. Give the document a short <title> (2-4 words) and do not spend space on a large heading that repeats it.',
  '- Design for touch: tap targets at least 40 px, no hover-only interactions.',
  '',
  'Behavior',
  '- Implement real, correct behavior (a calculator must compute correctly; a simulation must animate).',
  '- If the widget has a primary text/expression input (e.g. a grapher or calculator), expose `window.inklab = { setInput: function (text) { /* put text into the main input AND run/plot it */ } }` so the student can fill it by handwriting. Calling it must also trigger the plot/compute routine.',
].join('\n')

export interface MakeRealResult {
  status: number
  body: Record<string, unknown>
}

export interface MakeRealOptions {
  /** Cancels generation when the downstream client disconnects. */
  signal?: AbortSignal
  deadlineMs?: number
}

/// make-real orchestration: gate the session, generate (multi-pass), keep only the HTML document, and
/// return it only if it is complete and passes the sandbox tripwire. Never returns partial HTML.
export async function handleMakeReal(
  client: AnthropicClient,
  body: any,
  opts: MakeRealOptions = {},
): Promise<MakeRealResult> {
  const decision = cloudEligible(body?.session)
  if (!decision.allowed) return { status: 403, body: { error: decision.reason } }

  const prompt = typeof body?.prompt === 'string' ? body.prompt.trim() : ''
  if (!prompt) return { status: 400, body: { error: 'empty prompt' } }
  if (prompt.length > MAX_PROMPT_CHARS) return { status: 400, body: { error: 'prompt too long' } }

  const deadlineMs = opts.deadlineMs ?? DEFAULT_MAKE_REAL_DEADLINE_MS
  const deadline = new AbortController()
  const timer = setTimeout(() => deadline.abort(), deadlineMs)
  const signal = opts.signal ? AbortSignal.any([opts.signal, deadline.signal]) : deadline.signal

  let gen
  try {
    gen = await assembleGeneration(client, {
      system: MAKE_REAL_SYSTEM_PROMPT,
      userPrompt: `Build this widget: ${prompt}`,
      model: MAKE_REAL_MODEL,   // Opus for best widget quality (user request)
      maxTokens: 8192,          // high enough that most widgets finish in ONE pass
      timeoutMs: deadlineMs,    // one long pass may use the whole budget; `deadline` bounds the total
      signal,
    })
  } catch (e) {
    if (deadline.signal.aborted && !opts.signal?.aborted) return { status: 504, body: { error: 'generation timed out' } }
    throw e
  } finally {
    clearTimeout(timer)
  }

  if (gen.refused) return { status: 422, body: { error: 'declined' } }
  // A max-pass exhaustion is not a usable widget. Never return partial HTML as a success: the app keeps
  // the page as it was and the user can retry.
  if (!gen.complete) return { status: 502, body: { error: 'incomplete generation' } }
  const html = extractWidgetHtml(gen.output)
  if (!html) return { status: 502, body: { error: 'no widget' } }
  const safety = validateWidgetHtml(html)
  if (!safety.safe) return { status: 422, body: { error: 'unsafe widget', violations: safety.violations } }
  return { status: 200, body: { html, layout: widgetLayout(html), complete: true, passes: gen.passes } }
}
