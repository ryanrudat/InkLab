import { test } from 'node:test'
import assert from 'node:assert/strict'
import {
  compileTargets, differentiate, equivalent, extractMath, findLeak, normalizeMathText, parseExpression,
  studentMathKeys, type ProtectedTarget,
} from '../src/mathGuard.ts'

const leakIn = (reply: string, targets: ProtectedTarget[], studentLines: string[]) =>
  findLeak(reply, compileTargets(targets)!, studentMathKeys(studentLines))

const linear: ProtectedTarget[] = [{ kind: 'equation', value: '2x + 3 = 7' }]
const linearWork = ['2x + 3 = 7', '2x = 10', 'x = 5']

// --- parsing + equivalence ------------------------------------------------------------------------

test('the parser follows the InkLabMath grammar (implicit multiplication, right-assoc powers)', () => {
  const p = (s: string) => parseExpression(s)!
  assert.ok(equivalent(p('2(x+1)'), p('2x + 2')))
  assert.ok(equivalent(p('(x+1)(x-1)'), p('x^2 - 1')))
  assert.ok(equivalent(p('2^3^2'), p('512')))
  assert.ok(equivalent(p('-x^2'), p('-(x^2)')))
  assert.ok(equivalent(p('xy'), p('yx')))
  assert.equal(parseExpression('2x +'), null)
  assert.equal(parseExpression('x = 2'), null)
})

test('equivalence is mathematical, not textual', () => {
  const p = (s: string) => parseExpression(s)!
  assert.ok(equivalent(p('(x+1)^2'), p('1 + 2x + x^2')))
  assert.ok(!equivalent(p('(x+1)^2'), p('x^2 + 1')))
  assert.ok(equivalent(p('1/3'), p('2/6')))
  assert.ok(!equivalent(p('1/3'), p('0.333')))
  assert.ok(equivalent(p('sqrt(x^2 + 2x + 1)'), p('x + 1')) === false)   // |x+1|, not x+1 (negative samples)
})

test('symbolic differentiation matches the power, product, quotient and chain rules', () => {
  const p = (s: string) => parseExpression(s)!
  assert.ok(equivalent(differentiate(p('x^3/3 + C'), 'x')!, p('x^2')))
  assert.ok(equivalent(differentiate(p('x sin(x)'), 'x')!, p('sin(x) + x cos(x)')))
  assert.ok(equivalent(differentiate(p('1/x'), 'x')!, p('-1/x^2')))
  assert.ok(equivalent(differentiate(p('(2x+1)^3'), 'x')!, p('6(2x+1)^2')))
})

// --- pulling math out of prose --------------------------------------------------------------------

test('typography is normalized: Unicode, light LaTeX, and answers stated in words', () => {
  assert.equal(normalizeMathText('x² − 1'), 'x^2 - 1')
  assert.match(normalizeMathText('$\\frac{x}{2}$'), /\(\(x\)\/\(2\)\)/)
  assert.match(normalizeMathText('so x is 4'), /x = 4/)
  assert.match(normalizeMathText('x = ±2'), /x = 2 or x = -2/)
  assert.match(normalizeMathText('x = 2 or -2'), /x = 2 or x = -2/)
})

test('line and step references are never read as math', () => {
  const texts = extractMath('Look at line 2 and lines 3 and 4. Step 1 was fine.').map((c) => c.text)
  assert.deepEqual(texts, [])
})

test('prose words break math runs; equations are split at "="', () => {
  const texts = extractMath('What do you get when you subtract 3 from both sides of 2x + 3 = 7?').map((c) => c.text)
  assert.ok(texts.includes('2x + 3 = 7'))
  assert.ok(texts.includes('3'))
  assert.ok(!texts.some((t) => /subtract|sides/.test(t)))
})

// --- the leak check ---------------------------------------------------------------------------------

test('stating the solution is a leak', () => {
  assert.ok(leakIn('So x = 2.', linear, linearWork))
  assert.ok(leakIn('Then x is 2!', linear, linearWork))
  assert.ok(leakIn('2 = x', linear, linearWork))
})

test('a corrected or rearranged step of the equation is a leak, however it is written', () => {
  assert.ok(leakIn('Line 2 should be 2x = 4.', linear, linearWork))
  assert.ok(leakIn('You could write 4 = 2x instead.', linear, linearWork))
  assert.ok(leakIn('Try 2x + 3 - 3 = 7 - 3 next.', linear, linearWork))
})

test('quoting the student\'s own lines back is not a leak', () => {
  assert.equal(leakIn('You wrote 2x = 10 on line 2. How did you get from 2x + 3 = 7 to that?', linear, linearWork), null)
  assert.equal(leakIn('Is x = 5 really true? Try it in line 1.', linear, linearWork), null)
})

test('a worked example of a different problem is not a leak', () => {
  assert.equal(leakIn('For example, if 3y + 2 = 11, subtract 2 from both sides to get 3y = 9, so y = 3.', linear, linearWork), null)
})

test('the expanded form of the problem expression is a leak; a numeric hint is not', () => {
  const t: ProtectedTarget[] = [{ kind: 'expression', value: '(x+1)^2' }]
  const work = ['(x+1)^2', '= x^2 + 1']
  assert.ok(leakIn('It should be x² + 2x + 1.', t, work))
  assert.ok(leakIn('The answer is 1 + x^2 + 2x', t, work))
  assert.ok(leakIn('Write it as $x^{2}+2x+1$', t, work))
  assert.equal(leakIn('Try x = -5 in both (x+1)^2 and x^2 + 1. Do you get the same number?', t, work), null)
})

test('a quadratic\'s roots are protected one at a time', () => {
  const t: ProtectedTarget[] = [{ kind: 'equation', value: 'x^2 = 4' }]
  const work = ['x^2 = 4', 'x = 2']
  assert.ok(leakIn('Don\'t forget x = -2.', t, work))
  assert.ok(leakIn('x = ±2', t, work))
  assert.equal(leakIn('You found x = 2. Is that the only number whose square is 4?', t, work), null)
})

test('an antiderivative is protected up to its constant', () => {
  const t: ProtectedTarget[] = [{ kind: 'antiderivative', value: 'x^2', variable: 'x' }]
  const work = ['∫ x^2 dx = x^3/2 + C']
  assert.ok(leakIn('It should be x³/3 + C.', t, work))
  assert.ok(leakIn('Try (1/3)x^3.', t, work))
  assert.equal(leakIn('Differentiate x^3/2 + C. Do you get back x^2?', t, work), null)
})

test('a correct derivative is a leak when the student has not written it', () => {
  const t: ProtectedTarget[] = [{ kind: 'expression', value: '3x^2 + 2' }]
  assert.ok(leakIn('The derivative is 2 + 3x^2.', t, ['d/dx(x^3 + 2x) = 3x^2']))
  assert.equal(leakIn('You wrote 3x^2 + 2 and that matches.', t, ['d/dx(x^3 + 2x) = 3x^2 + 2']), null)
})

test('a leak cannot hide behind a token that does not parse', () => {
  assert.ok(leakIn('e.g. x = 2', linear, linearWork))
})

test('unreadable protected targets are refused, not guessed around', () => {
  assert.equal(compileTargets([{ kind: 'equation', value: '2x + = 7' }]), null)
  assert.equal(compileTargets([{ kind: 'equation', value: 'x + 1' }]), null)
  assert.ok(compileTargets([{ kind: 'expression', value: '2x·(x − 1)' }]))   // Swift's renderer output
})

test('contractions and articles next to the math do not hide a leak', () => {
  const t: ProtectedTarget[] = [{ kind: 'expression', value: '3x^2 + 2' }]
  const work = ['d/dx(x^3 + 2x) = 3x^2']
  assert.ok(leakIn("It's 2 + 3x^2.", t, work))
  assert.ok(leakIn('The derivative is a 3x^2 + 2 shape.', t, work))
  assert.ok(leakIn("I'm sure it is 3x^2 + 2", t, work))
  assert.ok(leakIn('Let a = 3x^2 + 2', t, work))   // "a" bound by "=" stays a variable; the RHS still leaks
})
