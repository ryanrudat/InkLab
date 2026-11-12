import type { AnthropicClient } from './types.ts'
import { cloudEligible } from './consent.ts'
import { assembleGeneration, DONE_MARKER } from './assembler.ts'
import { extractWidgetHtml, validateWidgetHtml, widgetLayout } from './validate.ts'
import { httpOpenAIClient } from './openai.ts'

/// Default widget model: GPT-6.1 Sol (chosen 2026-11-12 after a head-to-head: comparable or better designs,
/// ~$0.04/widget). Without OPENAI_API_KEY the proxy falls back to Claude so a deployment missing the key keeps
/// working. MAKE_REAL_MODEL overrides both; any `gpt-…` id routes to OpenAI, anything else to Anthropic.
/// Handwriting recognition (/recognize) stays on Claude, which read handwriting more accurately.
export const MAKE_REAL_MODEL = 'gpt-6.1-sol'
export const MAKE_REAL_FALLBACK_MODEL = 'claude-opus-4-8'

export function configuredMakeRealModel(env: NodeJS.ProcessEnv = process.env): string {
  const override = env.MAKE_REAL_MODEL?.trim()
  if (override) return override
  return env.OPENAI_API_KEY?.trim() ? MAKE_REAL_MODEL : MAKE_REAL_FALLBACK_MODEL
}

export const isOpenAIModel = (model: string) => /^gpt-/i.test(model)

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
  '- Clean, modern, light design that matches the InkLab notebook (calm, mid-century, warm). Always set an explicit background color on body and explicit text colors; the card is always shown in light mode.',
  '- Palette: background warm cream #FFFBF6, panels #F7ECDF, text charcoal #1E2530, secondary text #85867F, thin borders #DCD2C6. The one accent is sun orange #E8742F (primary buttons, the active state, the key result); steel #5F6B7A for secondary controls; rust #C2452A only for errors. Charts and diagrams may add steel blue #3D6FA3, sage #4E8A5E and mustard #E2A93B for data.',
  '- Type: ui-rounded, -apple-system, system-ui, sans-serif for the interface; headings may use Futura, "Avenir Next", sans-serif (installed fonts, nothing to load). Soft corners (10-14 px), clear visual hierarchy, consistent spacing.',
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
  /** Overrides `MAKE_REAL_MODEL` (tests). */
  model?: string
  /** Client for `gpt-…` models (tests inject a mock; default is the real OpenAI client). */
  openaiClient?: AnthropicClient
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

  const model = opts.model ?? configuredMakeRealModel()
  const openai = isOpenAIModel(model)
  const generator = openai ? (opts.openaiClient ?? httpOpenAIClient()) : client

  let gen
  try {
    gen = await assembleGeneration(generator, {
      system: MAKE_REAL_SYSTEM_PROMPT,
      userPrompt: `Build this widget: ${prompt}`,
      model,
      // One pass for most widgets. GPT reasoning tokens count toward its output cap, so give it room.
      maxTokens: openai ? 16000 : 8192,
      ...(openai ? { effort: 'medium' as const } : {}),
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
  return { status: 200, body: { html, layout: widgetLayout(html), complete: true, passes: gen.passes, model } }
}
