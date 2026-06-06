# InkLab — Progress & To-Do

_Living status doc. Last updated: 2026-06-06._
For the system overview see [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md); for decisions, [docs/decisions/](docs/decisions/).

## Snapshot
- **133 passing tests** (114 Swift across 12 library packages + 19 TypeScript in the proxy), 0 failures.
- iPad app **builds** (`xcodebuild` → BUILD SUCCEEDED) and runs to a **Home/Library → Canvas** with paper picker, toolbar, and an `@`-command bar that runs the deterministic engines.
- All four §12 foundational decisions resolved (ADRs 0001–0005). Git baseline committed.
- **The deterministic "brain" is done; the remaining work is runtime-coupled** (device, WebView, real cloud calls, persistence) — writable here but validated on a device.

---

## ✅ Done

### Decisions (recorded as ADRs)
- [x] **0001** Recognition provider — MyScript (on-device math) · Apple Vision (text) · Claude (cloud fallback), swappable, spike-gated.
- [x] **0002** Minors/cloud — **Policy A** (cloud + verifiable parental consent), ship general-audience, backend proxy required.
- [x] **0003** iPadOS 18 floor + backend proxy.
- [x] **0004** Object model — event-sourced op-log "journal".
- [x] **0005** Canvas — PKCanvasView-hosted hybrid.

### Tested Swift libraries (12 + `InkLabKit` umbrella)
- [x] **InkLabRecognition** (9) — swappable handwriting→formal-structure routing + consent gate.
- [x] **InkLabDoc** (7) — the journal/object model (fold·invert·merge·remap, undo, conflict-free merge).
- [x] **InkLabCanvasCore** (11) — canvas geometry (lasso hit-test, transform math, coords, paging logic).
- [x] **InkLabMath** (21) — red-pen tutor: algebra **+ calculus**, first-wrong-line + counterexamples.
- [x] **InkLabUnits** (9) — dimensional conscience.
- [x] **InkLabChem** (9) — equation balancing + molar mass.
- [x] **InkLabBio** (8) — DNA→protein, mutations, Punnett squares.
- [x] **InkLabReactive** (9) — reactive worked-solutions (knob → downstream recompute).
- [x] **InkLabFit** (6) — lab-notebook least squares + R² + error bars.
- [x] **InkLabMultiRep** (8) — equation ↔ table ↔ best-fit.
- [x] **InkLabRouter** (11) — intent router + "@" ask-marker → deterministic/native/generative dispatch.
- [x] **InkLabSearch** (6) — notebook content search (inverted index + extractor from the journal).
- [x] **InkLabKit** — umbrella re-exporting all of the above (`import InkLabKit`).

### Backend proxy (`Server/`, TypeScript/Node, 19 tests)
- [x] Consent/age gate (server-enforced).
- [x] Make-real multi-pass assembler.
- [x] Correct-or-silent recognition validation + widget-safety check.
- [x] HTTP entry (`/recognize`, `/make-real`, `/health`) with a mockable Anthropic client.

### iPad app (`InkLab/InkLab.xcodeproj`) — builds
- [x] Home/Library (notebook grid, add, settings).
- [x] Canvas with PencilKit ink (pencil-only) + object overlay driven by the journal.
- [x] Paper picker (ruled/grid/dotted/blank) rendered behind ink.
- [x] Toolbar: pen (color + width), highlighter, eraser, lasso, sticky-note, undo/redo, paper.
- [x] "@" command bar → runs engines (`@balance`, `@molar`, `@units`, `@transcribe`, `@punnett`) and drops results as cards.
- [x] Settings (default paper, handedness).

---

## 🔜 To do

### A. App / UX (Swift — writable here, validate on device)
- [ ] **Paging & scroll (§5.2)** — continuous vertical auto-extend (capped ~4 screens) + horizontal finger paging; provisional page kept once ink lands.
- [ ] **Notebook page-overview** (§7) — thumbnail grid to reorder/jump between pages.
- [ ] **In-canvas "@" ask-marker** — writing "@" on the page (not just the top bar) + the "Ask?" chip for `?`.
- [ ] **"Read as…" confirmation** — inline interpretation + one-tap fix after recognition.
- [ ] **Action chips on a selection** — surface `actionChips(...)` (Solve/Graph/Check/Balance…) when a lasso selects recognizable content; wire to the engines.
- [ ] **Red-pen tutor in-canvas** — run `InkLabMath` on selected/written working, mark the first wrong line in place.
- [ ] **Reactive knobs / linked representations / lab plots** — UI for `InkLabReactive`, `InkLabMultiRep`, `InkLabFit` (the engines exist; need rendering).
- [ ] **Search UI** + **Study hub** (flashcards/quizzes) + **Onboarding** (teach "executable ink" in 30s).
- [ ] **Lasso transform** — move/resize/**rotate** of a mixed ink+object selection, context menu (cut/copy/paste/duplicate/delete) + cross-page/notebook paste.
- [ ] Pen popover with custom color wheel; eraser modes; shapes tool; sticky-note full malleability.
- [ ] Accessibility pass (VoiceOver, Dynamic Type, reduced-motion, handedness).
- [ ] Visual polish (toolbar layout, result-card placement) — **needs eyes on the running app**.

### B. Canvas device gates (ADR 0005 — needs an iPad)
- [ ] **Gate A** native-zoom crispness + overlay↔ink pixel registration under fast pinch _(highest risk; only failure that changes the spine)_.
- [ ] **Gate B** pencil-draws/finger-navigates touch-type partition feel + palm rejection.
- [ ] **Gate C** multi-canvas GPU memory bounded across ~20 pages.
- [ ] **Gate D** ink round-trip (PKDrawing blob → strokes+raster → recognizer) + forward-incompat quarantine.
- [ ] **Gate E** lasso-drag perf at 120 Hz + off-main `PKDrawing.image`.

### C. Recognition
- [ ] Wire the **real providers** behind `InkRecognizer` (MyScript native, Apple Vision, Claude-via-proxy).
- [ ] Run the **recognition spike** on real messy student math (see [docs/recognition-spike-plan.md](docs/recognition-spike-plan.md)); go/no-go on MyScript vs Claude-primary.
- [ ] PencilKit adapter: confirm stroke iteration / `PKDrawing.image` fidelity on device.

### D. Cloud (wire the proxy to the real Anthropic API)
- [ ] Real `/recognize` (Claude vision) and `/make-real` calls; the assembler is ready.
- [ ] Input/output **moderation** (Organizations-Serving-Minors safeguards) — currently an interface.
- [ ] Negotiated **ZDR** + data minimization (crop/strip) + written retention policy.
- [ ] Auth, rate limiting, deploy. App-side `cloudEligible` gate already mirrors the server.

### E. Persistence & sync (ADR 0004)
- [ ] **GRDB** local store (`ops`/`snapshots`/`blobs`) replacing the in-memory journal.
- [ ] **CKSyncEngine** transport (per-object records, offline-first, quarantine-not-clobber for ink).
- [ ] Export/share (PDF + image for page/notebook).

### F. Remaining brief interpreters (§6 — mostly device/WebView/LLM)
- [ ] **§6.1 Make-real** — host generated widgets in a locked-down **WKWebView** (assembler + validation done in the proxy).
- [ ] **§6.2 Bring-to-life** — the life-control bar (Run/Build/Inside/Narrate/Change) over a deterministic trace.
- [ ] **§6.3 Draw→sticker** + sticker tray; promote-to-live/3D.
- [ ] **§6.8 2D→3D** — three.js / RDKit.js in WKWebView.
- [ ] **§6.9 Executable schematics** — circuits via ngspice/WASM.
- [ ] **§6.11 Proof scaffolding** — Socratic next-hint (LLM).
- [ ] **§6.12c** chemistry equilibrium/titration/pH solver (deterministic — could be a Swift engine).
- [ ] **§6.13** 3D biomolecule via PDB viewer.
- [ ] **WKWebView compute sandbox** generally — math.js/Pyodide/three.js/RDKit/ngspice + the Swift↔JS bridge.

### G. Compliance (pre-ship — counsel gates, see [docs/compliance-checklist.md](docs/compliance-checklist.md))
- [ ] Verifiable parental consent flow; FERPA school-official DPA; privacy policy + App Privacy labels; `PrivacyInfo.xcprivacy` (app + MyScript); account deletion; in-app §5.1.2(i) AI-disclosure prompt.
- [ ] 🔴 Counsel sign-off: Kids-Category-vs-general, disclosure-vs-internal-operations, 2-year safety-retention for minors, UK/EU thresholds + DPIA.

---

## How to build / test
```sh
# Swift libraries
for p in Packages/*/; do ( cd "$p" && swift test ); done     # 114 tests
# Backend proxy
( cd Server && npm test )                                     # 19 tests
# iPad app
open InkLab/InkLab.xcodeproj                                  # Run on an iPad (InkLabKit linked)
```

## Suggested next-session priorities
1. **Run the app on a real iPad** → report visual/build issues → I refine (I can reproduce the build via `xcodebuild`).
2. **Gate A** (native zoom + overlay registration) — the one decision-changing risk.
3. Wire **action chips + the red-pen tutor in-canvas** (engines exist; pure SwiftUI/UIKit, verifiable here).
4. **Recognition spike** + wire one real provider end-to-end.
