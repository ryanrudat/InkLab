// The tutor's answer-leak guard. Before the proxy returns a tutor reply, every piece of math in it is
// checked against what the app's deterministic engine protects (the problem's value, its solution set,
// the correct derivative, the integrand of an integral). A reply that contains something mathematically
// EQUIVALENT to one of those (not merely the same string) is a leak. Equivalence is tested numerically:
// both sides are evaluated at several fixed, "generic" points and must agree everywhere — a standard
// polynomial-identity test that is exact in practice for the algebra and calculus the red pen covers.
//
// This module is deliberately conservative (fail closed): an unclear case counts as a leak and the
// caller regenerates or falls back to a generic hint. It never decides whether the STUDENT is right —
// that is the Swift engine's job; this only stops the tutor from handing over the answer.

// --- Expression AST + parser (mirrors InkLabMath's grammar: implicit multiplication, single-letter
// variables, right-associative ^, unary minus, known functions) -------------------------------------

export type Node =
  | { t: 'num'; v: number }
  | { t: 'var'; name: string }
  | { t: 'neg'; a: Node }
  | { t: 'bin'; op: '+' | '-' | '*' | '/' | '^'; a: Node; b: Node }
  | { t: 'fn'; name: string; arg: Node }

const FUNCTIONS = new Set(['sin', 'cos', 'tan', 'cot', 'sec', 'csc', 'log', 'ln', 'exp', 'sqrt', 'abs'])
const CONSTANTS = new Set(['pi'])

type Tok = { k: 'num'; v: number } | { k: 'id'; v: string } | { k: 'op'; v: string }

function tokenize(s: string): Tok[] | null {
  const out: Tok[] = []
  let i = 0
  while (i < s.length) {
    const c = s[i]
    if (c === ' ' || c === '\t') { i++; continue }
    if (/[0-9]/.test(c) || (c === '.' && /[0-9]/.test(s[i + 1] ?? ''))) {
      const m = /^[0-9]*\.?[0-9]+|^[0-9]+/.exec(s.slice(i))
      if (!m) return null
      out.push({ k: 'num', v: Number(m[0]) })
      i += m[0].length
      continue
    }
    if (/[a-zA-Z]/.test(c)) {
      const m = /^[a-zA-Z]+/.exec(s.slice(i))!
      out.push({ k: 'id', v: m[0] })
      i += m[0].length
      continue
    }
    if ('+-*/^()'.includes(c)) { out.push({ k: 'op', v: c }); i++; continue }
    return null
  }
  return out
}

class Parser {
  pos = 0
  toks: Tok[]
  constructor(toks: Tok[]) { this.toks = toks }
  peek(): Tok | undefined { return this.toks[this.pos] }
  isOp(v: string): boolean { const t = this.peek(); return t?.k === 'op' && t.v === v }
  eat(v: string): boolean { if (this.isOp(v)) { this.pos++; return true } return false }

  addSub(): Node {
    let lhs = this.mulDiv()
    while (this.isOp('+') || this.isOp('-')) {
      const op = (this.toks[this.pos++] as { v: string }).v as '+' | '-'
      lhs = { t: 'bin', op, a: lhs, b: this.mulDiv() }
    }
    return lhs
  }
  mulDiv(): Node {
    let lhs = this.unary()
    for (;;) {
      if (this.eat('*')) lhs = { t: 'bin', op: '*', a: lhs, b: this.unary() }
      else if (this.eat('/')) lhs = { t: 'bin', op: '/', a: lhs, b: this.unary() }
      else {
        const t = this.peek()
        // Juxtaposition => implicit multiplication ("2x", "2(x+1)", "(x+1)(x-1)").
        if (t && (t.k === 'num' || t.k === 'id' || (t.k === 'op' && t.v === '('))) {
          lhs = { t: 'bin', op: '*', a: lhs, b: this.unary() }
        } else return lhs
      }
    }
  }
  unary(): Node {
    if (this.eat('-')) return { t: 'neg', a: this.unary() }
    if (this.eat('+')) return this.unary()
    return this.pow()
  }
  pow(): Node {
    const base = this.atom()
    if (this.eat('^')) return { t: 'bin', op: '^', a: base, b: this.unary() }
    return base
  }
  atom(): Node {
    const t = this.peek()
    if (!t) throw new Error('end')
    if (t.k === 'num') { this.pos++; return { t: 'num', v: t.v } }
    if (t.k === 'op' && t.v === '(') {
      this.pos++
      const e = this.addSub()
      if (!this.eat(')')) throw new Error('expected )')
      return e
    }
    if (t.k === 'id') {
      this.pos++
      const name = t.v
      if (FUNCTIONS.has(name.toLowerCase()) && this.isOp('(')) {
        this.pos++
        const arg = this.addSub()
        if (!this.eat(')')) throw new Error('expected )')
        return { t: 'fn', name: name.toLowerCase(), arg }
      }
      if (CONSTANTS.has(name.toLowerCase())) return { t: 'num', v: Math.PI }
      // A multi-letter run is a product of single-letter variables ("xy" = x·y), as in InkLabMath.
      const vars: Node[] = [...name].map((ch) => (ch === 'e' ? { t: 'num', v: Math.E } : { t: 'var', name: ch }))
      return vars.slice(1).reduce<Node>((acc, v) => ({ t: 'bin', op: '*', a: acc, b: v }), vars[0])
    }
    throw new Error('unexpected token')
  }
}

/// Parse an ASCII expression (already normalized). Returns null when it isn't one.
export function parseExpression(s: string): Node | null {
  const toks = tokenize(s.trim())
  if (!toks || toks.length === 0) return null
  try {
    const p = new Parser(toks)
    const e = p.addSub()
    return p.pos === toks.length ? e : null
  } catch {
    return null
  }
}

export function variables(n: Node, into: Set<string> = new Set()): Set<string> {
  switch (n.t) {
    case 'var': into.add(n.name); break
    case 'neg': variables(n.a, into); break
    case 'bin': variables(n.a, into); variables(n.b, into); break
    case 'fn': variables(n.arg, into); break
  }
  return into
}

export function evaluate(n: Node, env: Record<string, number>): number {
  switch (n.t) {
    case 'num': return n.v
    case 'var': return env[n.name] ?? NaN
    case 'neg': return -evaluate(n.a, env)
    case 'bin': {
      const a = evaluate(n.a, env), b = evaluate(n.b, env)
      switch (n.op) {
        case '+': return a + b
        case '-': return a - b
        case '*': return a * b
        case '/': return a / b
        case '^': return Math.pow(a, b)
      }
    }
    // falls through (unreachable)
    case 'fn': {
      const x = evaluate(n.arg, env)
      switch (n.name) {
        case 'sin': return Math.sin(x)
        case 'cos': return Math.cos(x)
        case 'tan': return Math.tan(x)
        case 'cot': return 1 / Math.tan(x)
        case 'sec': return 1 / Math.cos(x)
        case 'csc': return 1 / Math.sin(x)
        case 'log': return Math.log10(x)
        case 'ln': return Math.log(x)
        case 'exp': return Math.exp(x)
        case 'sqrt': return Math.sqrt(x)
        case 'abs': return Math.abs(x)
      }
      return NaN
    }
  }
}

const num = (v: number): Node => ({ t: 'num', v })
const bin = (op: '+' | '-' | '*' | '/' | '^', a: Node, b: Node): Node => ({ t: 'bin', op, a, b })
const fn = (name: string, arg: Node): Node => ({ t: 'fn', name, arg })
const hasVar = (n: Node, v: string) => variables(n).has(v)

/// Symbolic d/dv. Returns null for a function we don't differentiate (|x|) so the caller skips it.
export function differentiate(n: Node, v: string): Node | null {
  const d = (m: Node) => differentiate(m, v)
  switch (n.t) {
    case 'num': return num(0)
    case 'var': return num(n.name === v ? 1 : 0)
    case 'neg': { const a = d(n.a); return a && { t: 'neg', a } }
    case 'bin': {
      const da = d(n.a), db = d(n.b)
      if (!da || !db) return null
      switch (n.op) {
        case '+': return bin('+', da, db)
        case '-': return bin('-', da, db)
        case '*': return bin('+', bin('*', da, n.b), bin('*', n.a, db))
        case '/': return bin('/', bin('-', bin('*', da, n.b), bin('*', n.a, db)), bin('^', n.b, num(2)))
        case '^':
          if (!hasVar(n.b, v)) return bin('*', bin('*', n.b, bin('^', n.a, bin('-', n.b, num(1)))), da)
          // General a^b = exp(b ln a): d = a^b (b' ln a + b a'/a)
          return bin('*', n, bin('+', bin('*', db, fn('ln', n.a)), bin('/', bin('*', n.b, da), n.a)))
      }
    }
    // falls through (unreachable)
    case 'fn': {
      const du = d(n.arg)
      if (!du) return null
      const u = n.arg
      switch (n.name) {
        case 'sin': return bin('*', fn('cos', u), du)
        case 'cos': return bin('*', { t: 'neg', a: fn('sin', u) }, du)
        case 'tan': return bin('/', du, bin('^', fn('cos', u), num(2)))
        case 'cot': return bin('/', { t: 'neg', a: du }, bin('^', fn('sin', u), num(2)))
        case 'sec': return bin('*', bin('/', fn('sin', u), bin('^', fn('cos', u), num(2))), du)
        case 'csc': return bin('*', bin('/', { t: 'neg', a: fn('cos', u) }, bin('^', fn('sin', u), num(2))), du)
        case 'ln': return bin('/', du, u)
        case 'log': return bin('/', du, bin('*', u, num(Math.LN10)))
        case 'exp': return bin('*', n, du)
        case 'sqrt': return bin('/', du, bin('*', num(2), n))
        default: return null
      }
    }
  }
}

// --- Numeric identity testing -----------------------------------------------------------------------

// Fixed, irrational-looking sample values (no accidental roots at 0, ±1, small integers).
const SAMPLES = [0.6180339887, 1.4142135624, -0.7320508076, 2.2360679775, -1.3247179572, 0.3819660113,
  1.7320508076, -2.0943951024, 0.5772156649, -0.4142135624, 2.7182818285, -1.6180339887, 0.8414709848]
const TRIALS = 8

function envFor(vars: string[], trial: number): Record<string, number> {
  const env: Record<string, number> = {}
  vars.forEach((name, j) => { env[name] = SAMPLES[(trial * 5 + j * 3) % SAMPLES.length] })
  return env
}

const close = (a: number, b: number) => Math.abs(a - b) <= 1e-8 * Math.max(1, Math.abs(a), Math.abs(b))

/// a ≡ b as functions of their variables (at least 4 finite sample points, all agreeing).
export function equivalent(a: Node, b: Node): boolean {
  const vars = [...new Set([...variables(a), ...variables(b)])].sort()
  let finite = 0
  for (let i = 0; i < TRIALS; i++) {
    const env = envFor(vars, i)
    const x = evaluate(a, env), y = evaluate(b, env)
    if (!Number.isFinite(x) || !Number.isFinite(y)) continue
    if (!close(x, y)) return false
    finite++
  }
  return finite >= 4
}

/// a ≡ 0 everywhere (an identity such as "2x = 2x").
function identicallyZero(a: Node): boolean { return equivalent(a, num(0)) }

/// (A − B) is a nonzero constant multiple of (L − R): the same equation, rearranged by legal moves.
function proportional(d1: Node, d2: Node): boolean {
  const vars = [...new Set([...variables(d1), ...variables(d2)])].sort()
  let ratio: number | null = null
  let finite = 0
  for (let i = 0; i < TRIALS; i++) {
    const env = envFor(vars, i)
    const x = evaluate(d1, env), y = evaluate(d2, env)
    if (!Number.isFinite(x) || !Number.isFinite(y) || Math.abs(y) < 1e-12) continue
    const r = x / y
    if (ratio === null) ratio = r
    else if (!close(r, ratio)) return false
    finite++
  }
  return finite >= 4 && ratio !== null && Math.abs(ratio) > 1e-12
}

// --- Pulling math out of a prose reply --------------------------------------------------------------

const SUPERSCRIPTS: Record<string, string> = { '⁰': '0', '¹': '1', '²': '2', '³': '3', '⁴': '4', '⁵': '5', '⁶': '6', '⁷': '7', '⁸': '8', '⁹': '9', '⁻': '-' }

/// Map a reply's typography (Unicode math, light LaTeX, "x is 4") to the ASCII grammar above.
export function normalizeMathText(raw: string): string {
  let s = raw
  s = s.replace(/\\[()[\]]/g, ' ').replace(/[`$]/g, ' ')
  // Light LaTeX: \frac{a}{b}, \sqrt{a}, ^{...}, \cdot, \times.
  for (let i = 0; i < 4; i++) s = s.replace(/\\[dt]?frac\s*\{([^{}]*)\}\s*\{([^{}]*)\}/g, '(($1)/($2))')
  s = s.replace(/\\sqrt\s*\{([^{}]*)\}/g, 'sqrt($1)')
  s = s.replace(/\\(cdot|times|ast)/g, '*').replace(/\\div/g, '/').replace(/\\(left|right)/g, '')
  s = s.replace(/\\(sin|cos|tan|cot|sec|csc|log|ln|exp|pi)\b/g, '$1')
  s = s.replace(/\{/g, '(').replace(/\}/g, ')')
  // Unicode operators.
  s = s.replace(/[−–‒‐]/g, '-').replace(/[×·⋅∙✕]/g, '*').replace(/÷/g, '/')
  s = s.replace(/π/g, 'pi').replace(/√\s*\(/g, 'sqrt(').replace(/√\s*([0-9a-zA-Z.]+)/g, 'sqrt($1)')
  s = s.replace(/[⁰¹²³⁴⁵⁶⁷⁸⁹⁻]+/g, (m) => '^' + (m.length > 1 ? `(${[...m].map((c) => SUPERSCRIPTS[c]).join('')})` : SUPERSCRIPTS[m]))
  // Answers stated in words: "x is 4", "x equals 4", "x should be -2".
  s = s.replace(/\b([a-zA-Z])\s+(?:is equal to|equals|is|should be|must be|would be|will be)\s+(?=[-(0-9.])/g, '$1 = ')
  s = s.replace(/\bequals\b/gi, '=')
  // "x = ±2" and "x = 2 or -2" state every solution: spell each one out as "x = …".
  s = s.replace(/\b([a-zA-Z])\s*=\s*±\s*([0-9.]+)/g, '$1 = $2 or $1 = -$2')
  for (let i = 0; i < 3; i++) {
    s = s.replace(/\b([a-zA-Z])\s*=\s*(-?[0-9.]+(?:\/[0-9.]+)?)\s*(?:,|or|and)\s*(-?[0-9.]+(?:\/[0-9.]+)?)\b/g, '$1 = $2 or $1 = $3')
  }
  // References to lines/steps/hints are never math ("line 3", "lines 2 and 3", "step 1-2").
  s = s.replace(/\b(lines?|steps?|hints?|levels?|rows?|parts?|questions?|problems?|examples?|rules?|pages?)\s+\d+(?:\s*(?:,|and|to|or|-|&)\s*\d+)*/gi, '$1')
  s = s.replace(/\b\d+(st|nd|rd|th)\b/gi, ' ')
  // Contractions are prose: "it's 4" must not glue a stray "s" onto the math.
  s = s.replace(/([A-Za-z])['’](?:s|t|m|re|ve|d|ll)\b/g, '$1')
  return s
}

export interface MathCandidate {
  /** The math as written (normalized). */
  text: string
  /** Normalized comparison key (whitespace/`*` dropped, lower-cased) for "the student wrote this". */
  key: string
  kind: 'expr' | 'eq'
  expr?: Node
  lhs?: Node
  rhs?: Node
}

export const comparisonKey = (s: string) => s.replace(/[\s*]/g, '').toLowerCase()

/// The key without a trailing constant of integration, so "x^3/3" matches a student's "x^3/3 + C".
const withoutConstant = (key: string) => key.replace(/\+[ck]$/, '')

const MATHY = /^[0-9a-zA-Z+\-*/^=().]+$/

function isMathyToken(tok: string): boolean {
  if (!MATHY.test(tok)) return false
  if (/^[a-zA-Z]$/.test(tok)) return true                         // a single-letter variable
  const runs = tok.match(/[a-zA-Z]+/g) ?? []
  const pureAlpha = /^[a-zA-Z]+$/.test(tok)
  for (const r of runs) {
    const lower = r.toLowerCase()
    if (FUNCTIONS.has(lower) || CONSTANTS.has(lower)) continue
    if (pureAlpha) return false                                     // a word ("is", "dx", "xy")
    if (r.length >= 3) return false                                  // "x-axis", "y-intercept"
  }
  return true
}

/// Every piece of math in a prose reply: maximal runs of math-looking tokens, split at '='.
export function extractMath(text: string): MathCandidate[] {
  const s = normalizeMathText(text)
  // Non-math punctuation separates runs; a trailing sentence period is not a decimal point.
  const tokens = s.replace(/[,;:!?"'“”‘’<>≤≥≠≈→←⇒]/g, ' | ').split(/\s+/).map((t) => t.replace(/\.+$/, '')).filter(Boolean)
  const runs: string[][] = []
  let current: string[] = []
  for (const tok of tokens) {
    if (tok !== '|' && isMathyToken(tok)) current.push(tok)
    else { if (current.length) runs.push(current); current = [] }
  }
  if (current.length) runs.push(current)
  // "is a 3x + 1", "I x = 2": an article-like single letter next to the math is prose, unless an
  // operator binds it ("a = 3", "x + a").
  const ARTICLE = /^[aAI]$/
  const binds = (tok: string | undefined, atStart: boolean) => !!tok && (atStart ? /^[+\-*/^=]/ : /[+\-*/^=]$/).test(tok)
  for (const run of runs) {
    while (run.length > 1 && ARTICLE.test(run[0]) && !binds(run[1], true)) run.shift()
    while (run.length > 1 && ARTICLE.test(run[run.length - 1]) && !binds(run[run.length - 2], false)) run.pop()
  }

  const out: MathCandidate[] = []
  const seen = new Set<string>()
  const push = (c: MathCandidate) => {
    const id = `${c.kind}:${c.key}`
    if (!seen.has(id)) { seen.add(id); out.push(c) }
  }
  /// Adds the run's math; returns false when some part of it didn't parse.
  const add = (raw: string): boolean => {
    const text = raw.trim().replace(/^[+*/^=]+/, '').replace(/[+\-*/^=]+$/, '').trim()
    if (!text) return true
    const parts = text.split('=').map((p) => p.trim()).filter(Boolean)
    const exprs = parts.map((p) => parseExpression(p))
    for (let i = 0; i + 1 < parts.length; i++) {
      const lhs = exprs[i], rhs = exprs[i + 1]
      if (lhs && rhs) push({ text: `${parts[i]} = ${parts[i + 1]}`, key: comparisonKey(`${parts[i]}=${parts[i + 1]}`), kind: 'eq', lhs, rhs })
    }
    parts.forEach((p, i) => { const expr = exprs[i]; if (expr) push({ text: p, key: comparisonKey(p), kind: 'expr', expr }) })
    return exprs.every(Boolean)
  }
  for (const run of runs) {
    if (add(run.join(' ')) || run.length < 2) continue
    // A stray token kept the run from parsing as a whole. Try its contiguous windows, so a leak can't
    // hide next to a piece of junk (fail closed).
    for (let i = 0; i < run.length; i++) {
      for (let j = i + 1; j <= Math.min(run.length, i + 12); j++) add(run.slice(i, j).join(' '))
    }
  }
  return out
}

// --- What the engine protects, and the leak check -----------------------------------------------------

/// What the app's engine says must never be handed over (sent by the app, computed by InkLabMath):
///  • expression    — the problem's value (an expression chain) or the exact derivative (a derivative claim)
///  • equation      — the problem equation: any rearrangement of it, or a value that solves it, is a leak
///  • antiderivative — the integrand: any expression whose derivative is the integrand is a leak
export type ProtectedTarget =
  | { kind: 'expression'; value: string }
  | { kind: 'equation'; value: string }
  | { kind: 'antiderivative'; value: string; variable: string }

export interface CompiledTarget {
  target: ProtectedTarget
  expr?: Node        // expression / integrand
  diff?: Node        // equation: L − R
  variable?: string  // antiderivative variable
}

/// Parse the protected targets; null if any can't be read (the caller must not guess around it).
export function compileTargets(targets: ProtectedTarget[]): CompiledTarget[] | null {
  const out: CompiledTarget[] = []
  for (const t of targets) {
    const value = normalizeMathText(t.value)
    if (t.kind === 'equation') {
      const parts = value.split('=')
      if (parts.length !== 2) return null
      const l = parseExpression(parts[0]), r = parseExpression(parts[1])
      if (!l || !r) return null
      out.push({ target: t, diff: bin('-', l, r) })
    } else {
      const expr = parseExpression(value)
      if (!expr) return null
      if (t.kind === 'antiderivative') {
        if (!/^[a-zA-Z]$/.test(t.variable)) return null
        out.push({ target: t, expr, variable: t.variable })
      } else out.push({ target: t, expr })
    }
  }
  return out
}

export interface Leak { candidate: string; target: ProtectedTarget['kind'] }

/// The first piece of math in `reply` that gives away a protected result, or null if the reply is clean.
/// `studentWrote` holds comparison keys of math the student wrote themselves (their lines, their
/// replies) — quoting the student's own work back is never a leak.
export function findLeak(reply: string, targets: CompiledTarget[], studentWrote: Set<string>): Leak | null {
  const candidates = extractMath(reply).filter((c) => !studentWrote.has(c.key) && !studentWrote.has(withoutConstant(c.key)))
  for (const t of targets) {
    for (const c of candidates) {
      if (t.target.kind === 'expression' && c.kind === 'expr' && equivalent(c.expr!, t.expr!)) {
        return { candidate: c.text, target: 'expression' }
      }
      if (t.target.kind === 'antiderivative' && c.kind === 'expr' && hasVar(c.expr!, t.variable!)) {
        const d = differentiate(c.expr!, t.variable!)
        if (d && equivalent(d, t.expr!)) return { candidate: c.text, target: 'antiderivative' }
      }
      if (t.target.kind === 'equation' && c.kind === 'eq') {
        const d = bin('-', c.lhs!, c.rhs!)
        if (identicallyZero(d)) continue
        if (proportional(d, t.diff!)) return { candidate: c.text, target: 'equation' }
        if (solvesTarget(c, t.diff!)) return { candidate: c.text, target: 'equation' }
      }
    }
  }
  return null
}

/// "x = 2" (or "2 = x") where 2 solves the protected equation: a stated solution.
function solvesTarget(c: MathCandidate, targetDiff: Node): boolean {
  const pairs: Array<[Node, Node]> = [[c.lhs!, c.rhs!], [c.rhs!, c.lhs!]]
  const targetVars = [...variables(targetDiff)]
  for (const [side, value] of pairs) {
    if (side.t !== 'var' || variables(value).size !== 0) continue
    const v = side.name
    if (!targetVars.includes(v)) continue
    const r = evaluate(value, {})
    if (!Number.isFinite(r)) continue
    // Single-variable target: substitute directly. Multi-variable: the other variables stay generic.
    let solves = true
    for (let i = 0; i < 3 && solves; i++) {
      const env = envFor(targetVars.filter((x) => x !== v), i)
      env[v] = r
      const z = evaluate(targetDiff, env)
      solves = Number.isFinite(z) && Math.abs(z) <= 1e-7 * Math.max(1, Math.abs(r))
      if (targetVars.length === 1) break
    }
    if (solves) return true
  }
  return false
}

/// Comparison keys for everything the student wrote (lines + their replies), so quoting is allowed.
export function studentMathKeys(texts: string[]): Set<string> {
  const keys = new Set<string>()
  for (const t of texts) {
    const whole = comparisonKey(normalizeMathText(t))
    keys.add(whole); keys.add(withoutConstant(whole))
    for (const c of extractMath(t)) { keys.add(c.key); keys.add(withoutConstant(c.key)) }
  }
  return keys
}
