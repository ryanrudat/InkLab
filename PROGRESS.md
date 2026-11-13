# InkLab — Progress & To-Do

_Living status doc. Last updated: 2026-11-12._
For the system overview see [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md); for decisions, [docs/decisions/](docs/decisions/).
Repo: <https://github.com/ryanrudat/InkLab> (public).

## Snapshot
- **App: 34 unit tests + UI tests** (engine routing incl. the `@molar` fix, calculator-via-engine, widget insert+edit+undo, object delete+undo, sticky text edit+undo, **undo-resurrection identity-strip**, differentiate-parenthesization, Vision-reads-rendered-text incl. "@"); **InkLabDoc package: 10 tests** (incl. `setObjectState`/`promote` one-step undo). Library packages (12) = **137 total** (incl. **InkLabCanvasCore 25** — +14 shape-recognition tests added 2026-06-16); **backend proxy: 42 tests**. All green.
- iPad app **builds and runs on an iPadOS 18 Simulator** to a **Home/Library → Canvas**, and the **full on-device → make-real → cloud loop works end-to-end** (verified live against the real Anthropic API).
- All §12 foundational decisions resolved across ADRs 0001–0005. Git baseline committed.
- **The deterministic "brain" plus the live make-real loop are now real in the app; remaining work is mostly compliance, persistence, on-device validation, and §6 interpreter UI.**
- **Socratic tutor (2026-11-12):** **13 app unit tests** (`TutorTests`) + the `TutorFlowShot` UI run, **InkLabMath 32** (8 new), **43 proxy tests** for `/tutor` + the leak guard. Full suites green: app 48, packages 145, proxy 85. See below.
  Updated the same day (unfinished lines, Write/Type replies, the dock button): **app 54, packages 149 (InkLabMath 36), proxy 95**.
  Then (what was read, unreadable problems, finished-not-fixed): **app 57, packages 149, proxy 96**, TutorFlowShot 4/4.

### 🎓 Socratic tutor (2026-11-12)
A student lassoes a problem and their own working, taps **Tutor**, and gets hints and questions next to
it, never the answer or the corrected step. It builds on the red pen; nothing about correctness moved to
a model.
- **Entry points:** **Tutor** in the lasso selection menu (next to Recognize / Check work / Fit graph) and
  as its own **graduation-cap button in the dock**, next to Add sticky (no lasso = the whole page's ink).
  It used to be in the `＋` menu.
- **READ → COMPUTE → TALK.** The selection is read with the same `bestRead` path as Check work. The
  **verdict is `checkChain`** (first wrong line, reason, counterexample), and the new `problemFacts`
  (InkLabMath `TutorGuard.swift`) derives what must never be handed over: the problem's value, its
  solution set, the exact derivative, or the integrand (all its antiderivatives). The new proxy endpoint
  **`POST /tutor`** (`Server/src/tutor.ts`) only talks: consent gate first (`cloudEligible`), stateless
  (the app sends the thread every turn), `claude-opus-5-5` at **effort `low`** for chat latency (thinking
  stays adaptive; Opus 5.5 can't disable it), server-side refusal fallback on, override with `TUTOR_MODEL`.
- **Hint ladder, decided by the server, not the model:** nudge → question about the specific line →
  name the concept → worked example of a *different* problem. It climbs one rung only when the student
  asks again ("another hint", "I'm stuck", or the **Another hint** button) and drops back to 1 when the
  engine verifies a new step of theirs.
- **Answer-leak guard (two layers, fail closed).** The proxy (`Server/src/mathGuard.ts`) pulls every piece
  of math out of a draft (Unicode, light LaTeX, "x is 4", "x = ±2") and tests it against the engine's
  protected results by **numeric identity testing** — equivalent expressions, rearranged equations (L−R
  proportional), stated solutions, antiderivatives (symbolic d/dx). Quoting the student's own lines is
  allowed. A leak (or a draft that contradicts the checker) is rejected and regenerated once with a
  stricter instruction; if that fails too, a **math-free generic hint** is sent. The app then re-checks
  the reply with the **exact** engine (`tutorReplyLeak`: canonical forms, proportional numerators) and
  re-asks strictly / falls back the same way. A lost-solution counterexample ("x = −2 is a solution…") is
  kept out of the prompt.
- **Unsupported:** when the engine can't check a line, the reply starts with a fixed sentence ("I can't
  check line N … so I won't guess whether it's right"), said **once**, and the model is told not to judge
  it. The engine's "couldn't read …" is its parser, not the handwriting, so the student hears "my checker
  can't work with line N as it's written".
- **Unfinished lines (fix from a live run):** "1+3=" used to come back as "couldn't read", followed by a
  second canned sentence saying the same thing. `checkChain` now reports **`.unfinished(line:)`** for a
  line ending in "=" (or line 1 starting with one), after checking the lines above it. The tutor nudges
  the student to finish it ("What do you get when you put those two numbers together?") without the value,
  which stays protected (`problemFacts` reads "1+3" without its "="). The student's answer finishes the
  line and is checked as such ("4" → "1+3 = 4" ✓, "5" ✗). For that, a variable-free line 1 ("1 + 3 = 5")
  is now checked as true or false; before, a one-line equation always passed. Check work shows
  "Line N isn't finished yet" too.
- **Finished is not fixed (fix from a live run):** a reply that finishes an unfinished line ("1+3=" then
  "4") is described to the model as finishing it, not correcting it ("Nothing was wrong with that line"),
  and the prompt says to acknowledge it as "1 + 3 = 4 checks out". With only finished lines, a draft that
  says "fix" or "correction" is rejected. Once the working checks out, the note's header says "Pip ·
  your working checks out" instead of counting hints.
- **What was read (fix from a live run):** a hooked "1" read as "7+3=" got coached as 7 + 3, with no way
  to tell. The note now starts with a quiet **"I read: 7+3= ✎"** line (all lines, "·" between them, at
  most two lines then "…"). Tapping it drops the note's typing box down, prefilled with the reading; the
  corrected problem **starts the session over** in the same note (`TutorSession.restarted`: same id, fresh
  verdict, no corrections, empty thread, hint 1), and one undo goes back to the old reading.
- **Unreadable problems (fix from a live run):** nothing read used to be a 2.8 s toast. Now the margin
  note goes up at the problem saying it couldn't read it, and stays until the student acts or closes it:
  **Rewrite it** highlights a space (ink written there, or by the problem, is read again after a pause;
  written over the old ink, the two are read together) and **Type it** opens the same box, empty. The
  first reading that works starts the session in that same note, which moves beside the rewritten
  problem. Tapping Tutor again on the same problem reuses the note too. Nothing is sent to `/tutor` while
  nothing has been read.
- **Replies:** the note offers both. **Write on the page** highlights a free space under the problem
  (switching to the pen if needed); after a pause the auto-scan reads the ink written there as the reply
  and the highlight goes away (✕ on it cancels). Writing anywhere else near the problem still counts too,
  as before (consent-gated, works even with auto-"@" off). **Type** drops a box down inside the note
  (no popup): Return or the ↑ sends, **Another hint** asks for the next rung, tapping Type again folds it
  away; if the on-screen keyboard would cover it, the page scrolls it into view. Any math
  in a reply is **checked by the red pen** in context ("You: 2x = 4 ✓ checks out"); a verified step
  replaces the wrong line. Prose is just a message.
- **Pip:** the tutor has a name. The note's header reads "Pip · hint 1 of 4", Pip's earlier messages in
  the thread read "Pip: …", and status lines say "Pip is thinking…". What Pip says is in its own color,
  atomic-age turquoise (`Theme.pip`, 5.3:1 on the light note, 8:1 on the dark one), so it never reads
  like the student's writing or the orange chrome. One constant (`TutorSession.tutorName`) holds the name.
- **On the page (layout A, the margin note):** one note per session in the right margin, level with the
  line the verdict is about, with a thin connector to that line, placed right of all ink and objects in its
  band so it **never covers the student's writing or another object** (a widget's controls, a sticky), and
  below them if the margin is full; it is drawn above every other object. Only the latest tutor
  message shows; earlier hints, the student's replies and the engine's check of each step ("You: 2x = 4
  ✓ checks out") fold into an **"N earlier"** control. One ✕ closes the session; Write on the page and Type stay on the note.
  The note is ONE journal object: each message replaces its payload (`promote` + resize, one undo step),
  so **undo rewinds the conversation a message at a time**, ✕ is undoable, and it survives relaunch. All
  of its colours, fonts and shapes live in `TutorNoteStyle` (`TutorNoteView.swift`), neutral until the
  app theme lands.
- **Corrections are told to the tutor (fix from a live run).** The page lines stay fixed (`lines`), the
  engine's working is sent separately (`working`), and every verified fold-in is sent as a correction
  ("the student corrected line 2 (on the page: 2x = 10) to 2x = 4; the lines after it were dropped").
  The prompt tells the model to acknowledge the fix, never call the original working right, never
  apologize for an earlier hint, and never number a reply-derived step as "line N"; the proxy rejects
  drafts that do (incl. "all along", "already on your line", apologies, line numbers past the page).
- **Questions aren't working (fix from a live run).** "so is x = 2?" (ends in "?" or opens like a
  question) is checked by the engine and passed as `check` with `question: true`, but never folded into
  the working, and it doesn't reset the ladder.
- **Shorter replies.** One or two sentences, ~30 words, exactly one question, no filler: the proxy
  rejects drafts over 280 chars or without exactly one "?", and drops a generic-praise first sentence
  ("Good start writing each step out.") while keeping a specific one ("Nice fix to line 2.").
- **Verified:** server tests for the endpoint and the guard (incl. a leaking reply being rejected,
  regenerated, and a double leak falling back; the three live failures; questions; format), InkLabMath
  guard tests, app unit tests (session, corrections, questions, line finding, margin placement that never
  covers ink, the note's fold, app-side guard with a fake provider, journal/undo), and a **Simulator UI
  run** (`TutorFlowShot`) against `npm run mock` — one note beside line 2, the leaked first draft never
  reached the page, the written fix was read, verified and shown in the thread, the ladder climbed only
  when asked, a typed question didn't reset it, undo rewound one message, ✕ closed the session and undo
  brought it back.
- **Live check (Opus 5.5, reading stubbed, local proxy):** replaying the failing session — opening, the
  written fix, "so is x = 2?", Another hint — every reply was clean on the first draft, one question,
  121–154 chars, 1.6–5.4 s; the fix was acknowledged as "the step you just wrote", the question was
  confirmed as the student's idea without claiming it was on the page, and `TutorFlowShot` passed
  against it. (The opening-praise trim was added after that run; it is covered by tests.) `fallbacks` was
  accepted on API version `2023-06-01`.
- ⚠️ **Not verified on a device / with a Pencil**, and nothing is deployed to Railway. **Minors must not use the tutor until input/output moderation exists**
  (see `docs/compliance-checklist.md`).
- **Known limits:** the guard catches math, not answers spelled out in words ("two"); bare numbers are not
  treated as solutions of an equation (too many false alarms, e.g. "divide by 2"); an expression chain's
  answer is protected by *form*, so a rewrite like (x+1)(x+1) of (x+1)^2 also counts as a leak (fails
  closed). v1 covers the red pen's algebra + calculus only.

### 🎨 Make-real generation fixes (2026-11-12)
A review of how `@` requests become widgets found the card-design problems came from the pipeline, not
the model. Fixed, with server + app tests:
- **Stray model text rendered inside the widget.** The proxy returned Claude's reply verbatim, so a
  sentence of preamble or a ```` ```html ```` fence showed up as text at the top of the card, and (ahead
  of `<!DOCTYPE>`) put the page into quirks mode, pushing the layout off the card. The proxy now keeps only
  the HTML document (`extractWidgetHtml`); the app does the same at render time (`WidgetHTML`), which also
  repairs widgets saved before the fix. The prompt now asks for the document only.
- **CSP placement.** The CSP was only injected when the HTML contained a literal `<head>`; it is now always
  the first element after a standards-mode doctype, ahead of any widget script.
- **Chrome over the content.** The resize grip sat on the widget's bottom-right corner (where a
  calculator's `=` lives); widget cards now have a footer bar for it. Native widget default sizes grew by
  the footer height so their content area is unchanged.
- **One portrait card for everything / fixed layouts.** The model now declares portrait, landscape or square
  and designs a responsive layout; the card is sized from it.
- **Dark mode.** Generated cards render light (the prompt asks for explicit light backgrounds).
- **Header** shows the widget's `<title>` instead of "Generated".
- **Timeouts reported as "server not running".** The app waited 90s while the server allowed 120s × 5
  passes. The server now has a 170s whole-request deadline (504) and the app waits 185s; timeouts, offline,
  refusals, unsafe and incomplete widgets each get their own message.
- **Refusals** no longer loop through all 5 passes (each sending an empty assistant turn).
- **"Designing…" card on the wrong page** after a page switch; it is now hidden unless its page is showing,
  and a queued job's placeholder no longer borrows the visible page's scroll offset.
- **Native calculator** was unreachable; it's now in the `＋` menu (`@calculator` still generates).
- **"Designing…" shimmer** ran past the card's edges (the card can't clip without clipping its shadow);
  it is now clipped to the card.
- **Verified:** 42 server tests, 34 app unit tests (incl. a real-`WKWebView` test: standards mode, no stray
  text, CSP in force before the widget's first script), and a Simulator UI run against a mock proxy
  returning a fenced, prose-wrapped landscape widget (clean card, `<title>` header, grip in the footer,
  placeholder hidden on another page and the widget landing on its own page).
- ⚠️ Not yet verified against the live API or on a device: how the model follows the new prompt (layout
  choice, responsiveness) and how the new card chrome feels with a Pencil. The Railway proxy needs a
  redeploy to pick up the server changes (the app-side cleanup works either way).

### 🛡️ Correctness/safety hardening pass (2026-06-08, multi-agent bug hunt + adversarial verify)
A 12-area deep review (each finding independently re-verified against the real code) surfaced a class of
bugs the all-green test suite didn't cover — overflow, NaN domains, non-ASCII, wrong-verb dispatch, async
page races, disk-write failure. All **Critical/High/Medium** fixed, with regression tests; full suite green
(123 package + 23 app + 23 server). Highlights:
- **CRITICAL — server consent gate was fail-OPEN.** `cloudEligible` (consent.ts) only blocked the literal
  `minorUnconsented`; any typo'd/tampered/unknown `userKind` (unvalidated JSON) fell through to *allowed* —
  a minor's ink could reach Anthropic. Now a **fail-closed whitelist + runtime session-shape validation**.
- **HIGH — engines crashed the app (violating correct-or-silent).** `InkLabMath` `Rational`/`Polynomial`
  and `InkLabChem` `Frac` used trapping `Int` math, so `@check 2^100`, a long decimal, or a big `@balance`
  SIGTRAP'd the process. Both now use **checked arithmetic with an absorbing overflow sentinel** and degrade
  to `.unsupported` / `.cannotBalance`. `numericValue` now returns **finite-or-nil** (a negative base to a
  fractional power was a non-nil NaN that made `InkLabReactive`/`InkLabMultiRep` report success with NaN).
- **HIGH — `@transcribe`/`@translate` called the wrong engine** (both ran DNA→protein): `@transcribe` now
  DNA→mRNA, `@translate` now mRNA→protein.
- **MEDIUM** — HLC counter wrap (→ monotonic across the 16-bit boundary); auto-`@`-scan + async make-real/
  check/recognize results landing on the wrong page after a page switch (→ originating-page captured/guarded);
  op-log interior-corruption now distinguished from a benign torn tail; op-log append failure now **surfaced**
  (throwing `append`) instead of silently dropped; move/resize no longer reloads (wipes) a native widget's
  uncommitted input (geometry-only update); `InkLabFit` exp/power fits were dead code (zero-baseline defeated
  the positivity gate → small positive floor); non-ASCII search snippet crash; proxy error responses no
  longer leak internal/upstream detail; + server hardening (body-size cap, 400 on bad JSON, broadened widget
  validator, strip only the trailing DONE marker).
- **Left (out of this scope):** the Swift `DefaultCloudPolicy` `ageVerified` divergence (LOW, dead code today —
  app gates via `MakeRealSession.blockReason`), and two **uncertain/latent** items: the unreachable
  `fold(_:from:)` compaction high-water trap (fix before GRDB/compaction lands) and the `isRestoringDrawing`
  PencilKit-delegate-timing fragility (needs a device to confirm).

### ✨ Finalized 2026-06-25 (floating dock rewrite — fluid drag + edge-snap reflow)
The floating dock (`FloatingDock` in `CanvasScreen.swift`) was reworked, build-verified on an iPadOS 18
Simulator. Two changes:
- **Drag jitter fixed.** The drag is now tracked in **GLOBAL coordinates** and the dock is moved with
  `.position` (was a `.local`-space `DragGesture` + `.offset` — a feedback loop where moving the dock
  changed the locally-reported translation, so it vibrated). The grip uses a small `minimumDistance` (instant
  grab); the tap-also puck uses a larger one (a wobbly tap isn't swallowed as a micro-drag).
- **NEW: edge-snap + vertical reflow.** Dragging the dock to either **side wall** snaps it flush and reflows
  it **VERTICAL** (`AnyLayout` horizontal↔vertical, preserving child identity so it animates); dropping it
  anywhere else floats it as a horizontal capsule (`DockPlacement` = `.left`/`.right`/`.floating`). One
  spring drives both the snap and the post-reflow re-measure so it reads as a single motion. Works
  identically in both orientations. Center + placement **persist as fractions of the container**
  (`@AppStorage` `inklab.dock.fx`/`fy`/`placement`), so it survives rotation / split-view resize. The
  collapse **puck** (tap to expand, drag to move) is retained. ⚠️ Final feel best confirmed on a real iPad.

### ✨ Finalized 2026-06-09
Small polish/correctness items closed today (built + verified on an iPadOS 18 Simulator):
- **Lasso ✕ pass-through.** A tap on an object's **✕** delete now lands even in **lasso mode** — the overlay
  used to swallow it, so you couldn't remove a result you'd just made by lassoing.
- **Dock drag-fluidity rework.** The stuttering drag is fixed: the toolbar **content is isolated in a child
  `DockBar` view** (so it isn't rebuilt mid-drag), the clamp now **measures the bar** so it can't slide
  half off-screen and snap back, and the always-rendered inline `ColorPicker` (a heavy `UIColorWell`) was
  replaced by a **lightweight color-dot button** that opens a popover. ⚠️ Final feel best confirmed on device.
- **Wording:** **"Check working" → "Check work"** everywhere it appears.

### ✨ Finalized 2026-06-22 (generated-widget render + annotation erase)
Two reported bugs in the AI-generated ("@") widgets, fixed at the root, **build-verified** on an iPadOS 18
Simulator and put through a multi-agent adversarial review (which caught one regression in the first fix —
now also fixed). See [docs/decisions/0005-canvas-rendering.md](docs/decisions/0005-canvas-rendering.md).
- **Generated widgets no longer blur on reopen.** A make-real widget was sharp when first created but fuzzy
  after relaunch. Cause: `CanvasViewController.viewDidLoad` rebuilds every object via `overlay.apply(...)`
  **before the canvas is in a window or laid out**, so each `WebWidgetView` called `loadHTMLString` while
  off-screen at a zero frame / 1× scale — WebKit's single paint rasterized at the wrong size/scale and never
  refreshed until a drag re-composited it (why the one you dragged sharpened up). **Fix:** `WebWidgetView`
  now holds `pendingHTML` and defers the paint to `loadIfReady()`, gated on `window != nil && bounds > 1`
  (driven by `didMoveToWindow` + `layoutSubviews`), so the one-and-only paint always lands on the real screen
  at full resolution. Freshly-generated widgets (created post-layout) stay immediate.
- **You can now ERASE what you wrote on a widget.** `WidgetAnnotationView` only ever *added* strokes — there
  was no erase path. **Fix:** whole-stroke erase (point-to-segment distance, forgiving) via a new per-widget
  **🧽 header toggle** (finger *or* Pencil, so it works in the Simulator), mutually exclusive with the ✏️
  draw toggle; the header turns red while erasing. The **Pencil also erases widget ink whenever the app's
  global Eraser tool is selected** (`pencilErases`, propagated `apply → overlay.setPencilErasesAnnotations →
  host → annotation`) — which **also fixes a latent bug**: with the Eraser tool active, dragging a Pencil
  over a widget previously *drew* red ink instead of erasing. A finger still operates the widget when no
  finger-mode is active. **Regression caught + fixed in review:** a *cancelled* erase (a two-finger scroll
  claiming the touch mid-rub, or app backgrounding) mutated the strokes in memory but never persisted via
  `onChanged`, so rubbed-out ink would resurrect from the stale on-disk blob on reload (same family as the
  undo-resurrection bug) — `touchesCancelled` now persists an in-flight erase. Added accessibility labels to
  the ƒ/✏️/🧽 buttons. ⚠️ **Pencil-vs-finger routing still best confirmed on a real iPad.**

### ✨ Finalized 2026-06-16 → 18 (writing UX · shape snapping · undo robustness · data-safety)
Built + verified on an iPadOS 18 Simulator (engine via `swift test`); the **draw-and-hold** fix was also
**confirmed on a real iPad + Apple Pencil**. The **undo-resurrection** fix is **build- + regression-test-
verified** (a 06-17 attempt did NOT hold; the real fix landed 06-18 — see that bullet; an on-device pass is
still recommended since the race is a runtime PencilKit behavior). Each correctness-critical change went
through a multi-agent adversarial review.
- **Paper style now persists.** Changing a notebook's paper in the canvas writes back to the notebook
  (`Library.setPaper` → `library.json`), so it survives relaunch instead of reverting to ruled. Settings
  **"Default paper"** is now persisted (UserDefaults) and actually applied to new notebooks
  (`addNotebook(paper:)`). (Before: the live change was never saved and `defaultPaper` was a dead setting.)
- **Stylus writing rework.** (1) **Bolder pens** — width presets `2/4/8 → 3/6/10` (default 6). (2) **Color and
  thickness are now independent** — the old "favorite pen" presets bundled color+width so picking a color
  snapped the width back; replaced by a **color-only palette** (`colorsByTool`) that changes color only.
  (3) **Dock can't overflow** — saved colors sit in a **fixed-width horizontal scroller**, so adding many
  colors scrolls rather than pushing the dock off the iPad screen. Per-tool, persisted (`CanvasModel`/`CanvasScreen`).
- **AI / make-real background behavior — investigated, confirmed correct (no code change).** Two independent
  reviews verified: generation is a **single one-shot request**; the generated widget's HTML is **persisted
  to the op-log and replayed from disk on reopen — Claude is never re-invoked** (the widget is effectively
  "set"); the app requests **no background execution**, so closing it suspends both the in-flight request and
  the widget's own JS. A generated widget's animation (e.g. a ticking clock) is local offline JS, not the AI.
- **Lasso DRAG is smooth.** `updateMove` no longer rebuilds + re-renders the whole `PKDrawing` every
  touch-move; the selected strokes are lifted onto a cheap **snapshot layer** translated per frame (the real
  drawing is rebuilt once, on release), and per-frame layer mutations are wrapped in a no-implicit-animation
  `CATransaction` so the marquee tracks the finger instead of easing behind it.
- **Lasso SELECTION captures everything inside the loop.** The hit-test now **applies `PKStroke.transform`**
  (a previously-moved stroke was tested at its stale pre-move location and left behind) and samples the
  **dense interpolated path** instead of sparse control points (a small stroke whose curve was inside could
  be missed). `PencilKitAdapters.hitTestPoints` / `fitLassoedSketch` likewise transform-aware.
- **Draw-and-hold SHAPE SNAPPING (new feature).** Draw a line/shape, hold the pencil still ~0.5s → it snaps
  to a clean form: **lines** (incl. snap-to-horizontal/vertical), **arrows**, **circles/ellipses**, and
  **rectangles/squares/triangles/polygons**. Deterministic, correct-or-silent engine in **InkLabCanvasCore**
  (`ShapeRecognition.swift`: resample → straightness/closed tests, RDP corner detection, axis-aligned ellipse
  fit; **+14 unit tests** incl. end-dwell regressions). Hold detection observes PencilKit's **own** drawing
  gesture **and** reads the finished stroke's end-dwell samples — a separate recognizer can't run alongside
  PencilKit drawing on iOS 18 (devforums 766925). The snap is **one undo step** (undo → freehand sketch; undo
  again → gone). Settings toggle **"Snap shapes on hold"** (persisted, on by default).
  **Confirmed working on a real iPad + Pencil.**
- **Undo no longer "comes back" (real fix 2026-06-18).** A 06-17 attempt (gate input + clear PencilKit's
  `UndoManager` + re-enable one runloop later) did **not** hold — the bug reproduced. A multi-agent
  diagnosis (which adversarially **broke its own first proposed fix**) pinned the real cause: assigning
  `canvasView.drawing` commits through PencilKit's **async render pipeline** (Apple devforums 702903/719944),
  so for a window the canvas's live stroke base is still the PRE-swap drawing and the user's next stroke is
  composited onto it — re-introducing the removed stroke. Tuning the re-enable delay can't close this (the
  window isn't a fixed duration). **Fix:** `setCanvasDrawing` records the content-signature of every stroke a
  swap REMOVES; `canvasViewDrawingDidChange` **strips any of those exact strokes if they reappear** and writes
  the corrected drawing back — resurrection is now structurally impossible regardless of render timing, while
  **bitmap-eraser** edits (new signatures) and **redo** (signatures cleared on a legitimate restore) are
  untouched. **Gotcha caught by the regression test:** `PKDrawing.dataRepresentation()` is **not byte-stable
  for identical content**, so it can't be a stroke identity — signatures hash the stroke's geometry+ink via a
  process-stable `Hasher`. New test `resurrectedStrokesAreStrippedByIdentity` (pure
  `strippingResurrectedStrokes` helper) locks in the primary / interior-tail / eraser-growth cases. **This
  closes the latent `isRestoringDrawing` / PencilKit-delegate-timing item flagged in the 2026-06-08 hardening
  pass.** ⚠️ Final confirmation best done on a real iPad + Pencil.
- **Data-safety: backup decision (ADR 0006).** A user lost notebooks by deleting the dev build (on-device
  storage only, no backup, dev install → no recoverable copy). Decision: back up **serverlessly** — a
  **Files / iCloud Drive export** now as an immediate safety net, then **CloudKit** sync (data lives in the
  user's own iCloud; survives reinstall; no data custody for us). **The Railway proxy stays stateless** —
  storing notebooks there would make us a custodian of minors' handwriting (COPPA/FERPA) and break the
  on-device privacy posture. **Not yet built** — see [docs/decisions/0006-backup-and-sync.md](docs/decisions/0006-backup-and-sync.md).

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
- [x] **InkLabDoc** (10) — the journal/object model (fold·invert·merge·remap, undo, conflict-free merge); now also `setObjectState`/`promote` (one-step undo).
- [x] **InkLabCanvasCore** (25) — canvas geometry (lasso hit-test, transform math, coords, paging logic) **+ draw-and-hold shape recognition** (`ShapeRecognition`: line/arrow/ellipse/polygon, correct-or-silent).
- [x] **InkLabMath** (24) — red-pen tutor: algebra **+ calculus**, first-wrong-line + counterexamples.
- [x] **InkLabUnits** (9) — dimensional conscience.
- [x] **InkLabChem** (10) — equation balancing + molar mass.
- [x] **InkLabBio** (8) — DNA→protein, mutations, Punnett squares.
- [x] **InkLabReactive** (10) — reactive worked-solutions (knob → downstream recompute).
- [x] **InkLabFit** (6) — lab-notebook least squares + R² + error bars.
- [x] **InkLabMultiRep** (8) — equation ↔ table ↔ best-fit.
- [x] **InkLabRouter** (11) — intent router + "@" ask-marker → deterministic/native/generative dispatch.
- [x] **InkLabSearch** (7) — notebook content search (inverted index + extractor from the journal).
- [x] **InkLabKit** — umbrella re-exporting all of the above (`import InkLabKit`).

### Backend proxy (`Server/`, TypeScript/Node)
- [x] Consent/age gate (server-enforced).
- [x] Make-real multi-pass assembler — **now wired to the real Claude API** (`claude-opus-4-8`); orchestration + prompt in `src/makeReal.ts`. The prompt asks for the raw document only, a declared card shape (`inklab-layout`), a responsive light design and a short `<title>`; the proxy keeps only the HTML document, stops on a refusal, and caps a request at 170s (504).
- [x] Correct-or-silent recognition validation + widget-safety check (regex validator is defense-in-depth; the WKWebView lockdown is the real boundary).
- [x] HTTP entry (`/recognize`, `/make-real`, `/health`); reads `ANTHROPIC_API_KEY` from `Server/.env` (gitignored; `npm start` auto-loads via `node --env-file-if-exists=.env`).
- [x] **Verified live end-to-end**: `/health` ok, `/make-real` generated a real widget, `/recognize` read "@a clock" at 0.97 confidence.

### iPad app (`InkLab/InkLab.xcodeproj`) — builds + runs the full loop
- [x] Home/Library (notebook grid, add, settings).
- [x] Canvas with PencilKit ink + object overlay driven by the journal.
- [x] **Drawable in the Simulator** — `PKCanvasView.drawingPolicy = .anyInput` (finger/mouse), toggleable in Settings ("Finger / mouse drawing", default on; off = pencil-draws/finger-navigates on iPad). `canvasViewDrawingDidChange` delegate wired.
- [x] Paper picker (ruled/grid/dotted/blank) rendered behind ink.
- [x] Toolbar: pen (color + width), highlighter, eraser, lasso, sticky-note, **Recognize**, undo/redo, paper.
- [x] **Deployment target = iPadOS 18.0** (was 26.4, which blocked install on most iPads/simulators) — matches ADR 0003 floor.
- [x] **All 12 engine packages are DIRECT local Swift Package references** in the project (previously transitive via the `InkLabKit` umbrella only) — now first-class, linked, and browsable.
- [x] **Fixed a pre-existing crash**: opening any notebook trapped because `apply(...)` ran from `makeUIViewController` before `viewDidLoad` and touched a nil `lassoGesture!`. The gesture is now created eagerly. (The canvas could never open before this.)
- [x] App can reach the local server over HTTP via `Info.plist` `NSAppTransportSecurity → NSAllowsLocalNetworking` (`GENERATE_INFOPLIST_FILE` kept; `INFOPLIST_FILE=Info.plist` merges).

### Recognition (READ side) — wired end-to-end
- [x] **On-device Apple Vision recognizer** (`VisionTextRecognizer`) in the app target (keeps the `InkLabRecognition` package Foundation-pure). Reads flat text.
- [x] **Cloud Claude-vision recognizer** (`ClaudeVisionRecognizer`): app → Server `POST /recognize` → Claude vision. **Verified live** reading "@a clock" at 0.97 confidence. (Apple Vision misreads a handwritten "@" as "a"; Claude reads it correctly — this is why **Recognize** uses Claude, with Apple Vision as the offline/free fallback.)
- [x] **"Read as…" review sheet** — editable transcription + engine chips. **Lasso-region recognition** reads just the lassoed area. The explicit **Recognize** button now uses Claude **only when AI-consent is granted** (else on-device Apple Vision) — never a silent cloud send.
- [x] **Explicit "Check" button** (checkmark.seal, 2026-06-07): on-demand math help — reads the lassoed region (or page) **on-device** and runs the deterministic red-pen tutor (`redPen`/`InkLabMath`). Free, correct-or-silent, no cloud. "I'm stuck" is now a deliberate tap, not something that auto-fires on everything written.
- [x] **"Fit" button** (chart.xyaxis.line, 2026-06-08) — **bring a hand-drawn graph to life.** Lasso a sketched curve (or data points), tap Fit: the stroke points are sampled and run through **InkLabFit's exact least-squares** (`CurveFitter` tries linear/quadratic/cubic/exp/power, picks best R² with a complexity penalty), then a **native, deterministic** `FitGraphView` is dropped on the page showing the original points, the clean best-fit curve, the **equation**, and **R²**. On-device, no OCR, no cloud — correct by construction. This **wires the previously-shelved `InkLabFit` engine into the app**. Inserted as a `native:fitGraph` widget (undoable, persisted). Tested: `curveFitterClassifiesSketchShape`. Note: a freehand sketch has no axes, so coefficients are in the sketch's own normalized units — the trustworthy outputs are the **model type, curve, and R²**.
- [x] **Lasso fixes (2026-06-08, multi-agent bug-hunt + adversarial verify).** Three confirmed bugs that made the lasso "feel broken": (1) in lasso mode the overlay swallowed **all** touches → two-finger scroll + page-swipe were dead and a two-finger drag drew a stray loop — now `lassoGesture.maximumNumberOfTouches=1` and `ObjectOverlayView.hitTest` only captures single-finger, so 2 fingers still scroll/page; (2) the dashed marquee was erased the instant the finger lifted (`finishLasso` `defer … path=nil`) → no sign anything was selected — now a **closed marquee persists** until the selection is invalidated, via a `clearLassoSelection()` helper that keeps the marquee + `lastLassoRect` in lockstep (cleared on new lasso / new ink / tool switch / page change); (3) only placed **objects** were hit-tested, never **ink** → lassoing handwriting always showed a misleading "tip" — now strokes are hit-tested (`strokeHitTest`, renderBounds pre-filter) and the status reads honestly. **Coordinate ruling:** lasso points and stroke points already share content coords (overlay.bounds.origin == contentOffset) — the `adjustedContentInset` hypothesis was **refuted**; no conversion added. Build clean, 20/20 tests pass; gesture feel needs an on-device pass. **Deferred:** acting on a selection (move/delete ink+objects — a feature; ink isn't journaled yet), polygon-vs-bbox raster clipping (minor), and the **lasso-first** UX (make selection the primary flow).
- [x] **Lasso MOVE (drag a selection — 2026-06-08).** The lasso now does its primary job: select a mix of
  **handwriting + objects**, then **drag from inside the selection to move it**. `finishLasso` keeps the
  selection (`selectedObjectIDs` + `selectedStrokeIndices` + marquee); a single-finger drag that begins
  inside `lastLassoRect` enters move mode (`beginMove`/`updateMove`/`endMove`) — objects nudge live and
  commit as **one journal transaction** (`setTransform` × n); ink translates via `PKStroke.transform`
  (rebuilt drawing). A mixed move is **one undo step** via a new combined `HistoryStep.move` (drives the
  journal undo AND the ink restore together, even though ink isn't journaled). Drag from outside the
  selection starts a fresh loop; the selection persists at its new home so it can be moved again or read by
  Recognize/Check/Fit. Build clean (`** TEST BUILD SUCCEEDED **`). ⚠️ **Gesture feel needs an on-device
  pass** (live ink-rebuild perf, grab tolerance). **Still deferred:** group **resize/rotate** handles
  (individual objects already resize via their grip).
- [x] **Lasso DELETE / CUT / COPY / PASTE (2026-06-08).** A lasso selection now supports the full edit set
  via a **native edit menu** (tap inside the selection → Cut / Copy / Delete / Paste) **and ⌘C / ⌘X / ⌘V**.
  Delete/cut/paste reuse the move's combined `HistoryStep.compound` (renamed from `.move`) + a shared
  `commitCompound`, so each is **one undo step** (objects = one journal transaction, ink = before→after
  drawing, reversed together). **Copy/paste use a `static` session clipboard** (objects keep their full
  transform + payload for fresh-id duplication; ink strokes copied), so **paste works across pages AND
  notebooks**; paste lands at the visible center preserving the copied set's relative layout and is
  auto-selected so it can be dragged immediately. Verified build + app tests green on the iPad Simulator.
  ⚠️ Menu/gesture **feel needs an on-device pass**. **Still deferred:** group resize/rotate.

### Home library + toolbar/dock redesign (2026-06-08)
- [x] **Uniform, elevated notebook covers.** Every notebook is now one generic cover design (spine +
  depth gradient + title on a label plaque + soft shadow), identical regardless of paper type.
  **Drag-to-reorder** (long-press → drag; persisted via `Library.reorder`), **change color** (long-press →
  Change Color → curated swatches + a custom system color picker, persisted), and **rename** (long-press →
  Rename). Screenshot-verified on the iPad Simulator (`HomeView.swift` / `Library.swift`).
- [x] **Dock Phase 1 — inline colors/sizes + declutter.** Researched GoodNotes/Notability/Noteshelf/Apple
  Notes/OneNote/Samsung docks (the shared pattern: contextual per-tool color+size, saved presets, recents,
  repositionable). Replaced the open-a-modal color picker with **inline color swatches** (active ring +
  custom "＋") and the hidden weight menu with **size dots** — both shown **only for pen/highlighter**
  (contextual). Moved Recognize/Check/Fit/Paper into a **＋ Insert/Actions menu**, and also surfaced
  Recognize/Check/Fit on the **lasso selection menu** (they act on the selection).
- [x] **Dock Phase 2 — pen favorites/presets.** Saved **(color + width) pens per tool** (pen/highlighter),
  persisted to UserDefaults (`PenPreset` in `CanvasModel`): tap a preset chip to apply both, **long-press to
  edit** (update-to-current / width / delete), a dashed **＋** to save the live pen. Chip size hints width;
  active chip is ringed. Verified build + the `StickyChromeShot` UI test (canvas/toolbar render, addSticky
  works). ⚠️ Look/feel best confirmed on device.
- [x] **Dock Phase 3 — repositionable + collapsible + left-handed.** The toolbar now floats over the canvas
  with a **drag grip** (drag to move; clamped on-screen; position persisted in `@AppStorage`), a **collapse
  chevron** that shrinks it to a small **puck** (active-tool icon; tap to expand; also draggable), and it
  **honors the `leftHanded` setting** (the collapsed puck defaults to the handed bottom corner; the `@`
  command button moves to the handed top corner). The full-screen dock container has **no background**, so
  empty space passes touches through to the canvas (verified: the `StickyChromeShot` UI test still taps a
  mid-canvas object's ✕). **Drag-fluidity fix:** the dock is now its **own `FloatingDock` view** so its
  drag/collapse `@State` no longer invalidates `CanvasScreen` (which had re-run the canvas's
  `updateUIViewController` → `vc.apply` every drag frame, reassigning the PencilKit tool/gestures = stutter);
  `vc.apply` is also now **idempotent** (early-returns when nothing changed), so stray re-renders (typing in
  the command bar, status toasts) are free too. ⚠️ Final feel best confirmed on device. **Optional later:**
  a multi-finger focus-hide gesture (deferred — reserved-gesture conflicts; the collapse puck covers the
  get-out-of-the-way need). **Superseded by the 2026-06-25 dock rewrite** (see that finalized note): the
  drag now uses GLOBAL coords + `.position` (the `.offset`-based grip jittered), position persists as
  container **fractions** (not raw `@AppStorage` points) so it's rotation/split-view-safe, and dragging to a
  side wall snaps flush + reflows the bar VERTICAL via `AnyLayout`. The puck/collapse and pass-through
  container are kept; the `@` command button still honors `leftHanded`.

### Deterministic engines (COMPUTE side) — reachable in the app
- [x] The "@" command bar runs the real engines via shared routing (`CommandRunner`/`EngineKit`): `@balance`, `@molar` (fixed — the router never emitted it), `@units`, `@transcribe`, `@punnett`, `@check` (red-pen tutor via `InkLabMath` `checkChain`), `@differentiate`. Engine chips also appear on the recognition review sheet.

### In-canvas "@" ask-marker
- [x] Handwrite "@…" and pause ~1.5s → the new strokes are read and, if they form an "@" command, it runs **automatically** (no Recognize tap). **Auto-scan is ON-DEVICE ONLY (2026-06-07 gating fix)** — Apple Vision, free/private; it acts **only** when it reads a leading "@", never escalates to the cloud, and shows no toast/animation for ordinary notes (previously it OCR-animated every pause and escalated to Claude on any short word starting with a/o/e/c/g/0/9/( — calling cloud AI on normal writing). Settings toggle "Auto-run @ commands" (default on). Ink is never erased (never-lose-ink); the result appears alongside.

### Make-real (generate live widgets) — the headline feature
- [x] **Journal live-object ops** (InkLabDoc, additive): `setObjectState` (edit a widget/chart/3D inline state) + `promote` (energy-level swap), both one-step-undoable, with fold/invert/remap arms. Tests `test_G`/`test_G2`. Existing case serialization unchanged.
- [x] **Polymorphic live-object host** (`ObjectOverlayView`/`ObjectHostView`): renders text cards (sticky/recognized/callout), native widgets, **and** a locked-down WKWebView; rebuilds in place when an object's payload KIND changes.
- [x] **Locked-down WKWebView sandbox** (`WebWidgetView`): CSP `default-src 'none'`, no network, navigation cancelled, `window.open` denied, non-persistent store — renders generated HTML safely on a minor's device. The CSP is injected into Claude's full HTML document. **(2026-06-08)** `script-src` now also allows **`'unsafe-eval'`** so graphers/calculators can evaluate a user-typed expression (`new Function`/`eval`) — previously they failed with a CSP "Refused to evaluate a string as JavaScript" error. Safe: the boundary is **network isolation** (`default-src 'none'` + `baseURL nil` + nav-delegate + server validator), which eval doesn't touch; the widget already runs arbitrary inline JS and stays fully offline. CSP is injected at **render time**, so existing broken widgets work after the app update — no regeneration.
- [x] **Swappable `MakeRealProvider`**: default is now `ProxyMakeRealProvider` (Server `/make-real` → Claude multi-pass assembler). The silent stub/auto fallback was **removed** (2026-06-07) — when the server is unreachable or the session is ineligible, the request **fails with a clear reason** (`MakeRealError: LocalizedError`), never a fake one-button widget. (This is what masked the original "@x → just a button" bug.)
- [x] **`@<anything>`** (typed or handwritten) generates a live widget via Claude; deterministic verbs stay on the exact engines (READ vs COMPUTE). **Verified live**: "@scientific calculator" generated a working calculator that fits the card; "@a clock" generated a live ticking JS clock.
- [x] **Widget sizing**: the model picks portrait 360×540 / landscape 560×360 / square 440×440 and the card is sized to match (+28pt header, +22pt footer that holds the resize grip, so the grip never covers the widget's controls). Layouts are responsive, so resizing reflows them.
- [~] **Write ON a widget — annotate + erase + handwrite-to-plot (2026-06-08, erase + crisp-render 2026-06-22).** A `WidgetAnnotationView` ink layer sits **above** each generated widget (so ink renders over the graph): **Pencil draws, finger operates the widget**, plus a header **✏️ toggle** so finger-draw works in the Simulator (no Pencil). **Erase (2026-06-22):** a header **🧽 toggle** rubs out whole strokes with finger or Pencil (mutually exclusive with ✏️; header tints red), and a Pencil **erases whenever the global Eraser tool is active** (`pencilErases`) — which also fixed a latent bug where the Eraser tool *drew* on widgets. A header **ƒ** button rasterizes the writing, recognizes it (consent-gated, same pipeline as Recognize), strips a leading `y =`/`f(x) =`, and feeds the expression into the widget via a new **widget input protocol** (`window.inklab.setInput(text)` added to the generator prompt) with a JS **fallback** (fill first input + click a plot/compute button) for already-generated widgets. Annotation strokes **persist per object** (reuses `JournalStorage` keyed by objectID) — incl. a *cancelled* erase (fixed in review). **Crisp render (2026-06-22):** the generated widget's `WKWebView` no longer paints off-screen at the wrong scale, so it's sharp on reopen (see the 06-22 finalized note / ADR 0005). Build clean. ⚠️ **Needs a device pass**: Pencil-vs-finger routing and the recognize→plot round-trip can't be touch-tested here. **TODO:** make annotation strokes undoable (own history step); formalize per-object blob storage (currently shares the ink store); the input protocol only helps widgets that implement it (fallback is best-effort).
- [x] **Native scientific calculator** (Tier A reference — pure Swift, InkLabMath-backed, correct-or-silent) built to prove the substrate; **NOT** the default path (generative is). Kept as the brief's "known→native" option.
- [x] **Robustness**: in-flight guard (no overlapping generations), 90s network timeout, and a **client-side consent gate** that blocks (with a reason) before any network call.

### Object editing chrome (all undoable via the journal)
- [x] **Delete ✕** (top-right) on every object — removes it; undo restores (delete/restore ops).
- [x] **Resize grip** (bottom-right) — drag to resize; generated-widget content reflows; commits a `setTransform`.
- [x] **Double-tap a sticky note** → edit its text inline (Done bar above the keyboard); commits `setProps`; undo reverts.

### Cloud setup (Claude API)
- [x] Server reads `ANTHROPIC_API_KEY` from `Server/.env`; `.env` is gitignored, created with a paste-your-key placeholder; `npm start` auto-loads it.
- [x] Model id `claude-opus-4-8` (confirmed current/correct).
- [x] User supplied a real key; verified live end-to-end (`/health`, `/make-real`, `/recognize`).

---

## 🔜 To do
_(mirrors the changelog's "WHAT STILL NEEDS DOING")_

### Compliance / consent (required before any cloud use by minors)
- [~] Real **consent/compliance surface**: the app now has a **Settings → "Cloud AI" opt-in** (consent toggle + account-type picker) wired into a real `MakeRealSession` (gated client-side **and** re-checked server-side); default is **off**. **Closed (2026-06-07) a real compliance hole:** `ClaudeVisionRecognizer` used to send a HARDCODED "consented adult" session, bypassing both gates — it now sends the real session, and **every** cloud path (`/make-real`, `/recognize`) is consent-gated client-side (`blockReason`) + server-side (`cloudEligible`); verified live (401 no-auth, 403 non-consented/minor). **Still TODO:** a proper **age/onboarding screen** for `userKind`, the App-Store **§5.1.2(i)** first-run prompt, `NWPathMonitor` reachability, and **persisting** the choice (settings are in-memory, reset each launch).
- [ ] Verifiable parental consent flow; FERPA school-official DPA; privacy policy + App Privacy labels; `PrivacyInfo.xcprivacy` (app + MyScript); account deletion. (Counsel gates — see [docs/compliance-checklist.md](docs/compliance-checklist.md).)
- [ ] 🔴 **Input/output moderation on `/tutor` before any minor uses the tutor** (it is a chat with the student). Also: say in the Settings AI-permission copy that the tutor sends the student's working and replies.
- [ ] **Tutor, live pass:** run it against the real API (prompt adherence at effort `low`, latency, that `fallbacks` is accepted on API version `2023-06-01`) and on a device with a Pencil (reading replies written next to the problem); redeploy the proxy.

### Persistence & sync (ADR 0004)
- [x] **File-backed persistence (2026-06-07)** — op log (append-only JSONL) + per-page ink blobs behind a swappable `JournalStorage` protocol (`JournalStorage.swift`), scoped per notebook under Application Support. The **notebook list also persists** (`library.json`) so `Notebook.id` is stable across launches (the chain only works because of this). On launch the op log replays via `fold` with the HLC `Clock` reseeded past it; objects, generated widgets, **and ink** survive relaunch. Hardened (file protection for locked-device writes, background-flush, fsync, error logging) + **adversarially reviewed** (multi-agent: core confirmed correct; the only real must-fix — a background flush — is in). Verified: `journalPersistsAndReloads` + `persistedUndoSurvivesReloadHistoryResets`. **Still TODO:** GRDB/SQLite impl (drop in behind the protocol), log **compaction** for very large notebooks, CloudKit sync.
- [x] **Never-lose-ink (2026-06-07)** — ink persists as per-page `PKDrawing` blobs: debounced ~0.8s during writing, **flushed synchronously on background/suspend** (closes the home-swipe/kill window), restored on launch + page switch. (Stored as blobs alongside the journal, not yet as journal ops — fine for single-device; revisit for sync.)
- [ ] **Backup & sync — SERVERLESS (ADR 0006, decided 2026-06-17).** Notebooks are on-device only today, so
  deleting the app loses them (a user hit this). Plan: **(a)** ship a **Files / iCloud Drive export+import**
  now as an immediate, user-controlled safety net (survives app deletion); **(b)** then **CloudKit /
  `CKSyncEngine`** so notebooks live in the user's own iCloud and reappear on reinstall / new device — **no
  server of ours, no data custody** (keeps the minors privacy posture). **The Railway proxy stays stateless;
  do NOT store notebooks on it.** **re-validate widget HTML** received from another device before loading.
  (Note: the Clock uses a fresh actor per launch — fine single-device, but revisit actor identity before sync.)

### Recognition
- [ ] **MyScript** on-device recognition (needs a paid license + their binary SDK the user must obtain) for dependable offline handwriting/math; run the recognition spike on real messy student math (see [docs/recognition-spike-plan.md](docs/recognition-spike-plan.md)).
- [ ] **Structured math** (exponents/fractions) needs MyScript or a structured provider — Apple Vision/Claude here return flat text.

### Server hardening
- [ ] Real input/output **moderation** (Organizations-Serving-Minors), **rate limiting**, negotiated **ZDR** + data minimization. **Auth:** shared-secret Bearer gate done (`INKLAB_PROXY_SECRET` on `/make-real` + `/recognize`; obfuscation-grade — real per-user auth via tokens/App Attest still needed). **Deploy:** live on Railway (interim; final host = a **pre-publication decision**). (The regex widget-HTML validator is defense-in-depth only; the WKWebView lockdown is the real boundary.)

### Performance
- [ ] Many live WKWebViews (each a separate process) — static-raster default, lazy load on selection, LRU eviction; keep heavy setup off the ink run-loop.

### Make-real polish
- [ ] Streaming/progress while generating; place the result near the source ink; **promote** sticker↔interactive↔3D in the UI (the journal `promote` op exists, no UI yet); editable generated widgets.

### §6 interpreters / compute sandbox
- [ ] The WKWebView compute-sandbox is only a **renderer** so far; the bundled JS engines (math.js / three.js / RDKit.js / ngspice-wasm) for the §6 interpreters are **not bundled yet**.
- [ ] Remaining §6 interpreters: bring-to-life, draw→sticker + tray, 2D→3D, executable circuits, reactive knobs (`InkLabReactive`), linked multi-representation (`InkLabMultiRep`), live lab notebook (`InkLabFit`), proof hints — engines exist for several; UI not wired.

### Around the canvas
- [~] **Paging / scroll (§5.2) — first cut (2026-06-07, needs on-device tuning).** Each page is several screens tall and **two-finger scrolls vertically** (one finger still draws; pencil mode = one-finger scroll). **Two-finger horizontal swipe** (or the new toolbar ◀ ▶ + "n/m" indicator) pages; swiping past the last page **creates a new one**. Multi-page is real: `JournalStore` now has `pageIDs`/`currentPageID`/`addPage`/`goTo` + **per-page undo/redo** (tested: `perPageUndoIsolation`), and the VC keeps **per-page ink + history** (in-memory `[pageID: PKDrawing]`). ⚠️ Compile + data-model verified; the **gesture feel + scroll/overlay coordinate sync need a physical iPad** (I can't test touch here). Per-page ink now **persists** (per-page PKDrawing blobs via `JournalStorage`) — survives relaunch. **(2026-06-08)** Relaunch now **reopens the last-viewed page** (persisted per-notebook in UserDefaults via `JournalStore.goTo`), not always page 1 — fixes "ink persistence isn't working," which was actually work on page 2 looking lost because the app always landed on page 1. On-disk inspection confirmed ink + op-log persist correctly (`journalPersistsAndReloads`, `reloadReopensLastViewedPage`).
- [ ] Notebook page-overview, **Search UI** (`InkLabSearch` exists), Study hub, Onboarding / empty state.
- [~] Object **rotate**; lasso transform of mixed ink+objects — **lasso MOVE + DELETE/CUT/COPY/PASTE shipped (2026-06-08)** (paste works across pages & notebooks); **group resize/rotate** still to do.

### Device / on-real-iPad (ADR 0005 gates)
- [x] **Proxy URL is now configurable** — `Info.plist` `MakeRealBaseURL` (falls back to `localhost` for the Simulator). The iPad can't reach the Mac's `localhost`, so on-device use needs a deployed host.
- [x] **Deployed — interim host: Railway** at `https://inklab-proxy-production.up.railway.app`, **auth-gated** (shared-secret Bearer). `Info.plist` `MakeRealBaseURL` + `MakeRealProxySecret` set; verified live (401 without/with wrong secret, real generation with it). ⚠️ **NOT a final decision** — hosting/placement (region & **data residency for minors**, negotiated ZDR, moderation, real per-user auth, cost) is an open **pre-publication** revisit (ADR 0003).
- [ ] **ADR-0005 device gates** — zoom crispness / overlay registration, palm rejection, GPU memory, ink round-trip — need a physical iPad.

### Accessibility
- [ ] Accessibility pass; **VoiceOver INTO generated WKWebView widgets is unsolved.**

---

## How to build / test
```sh
# Clone (public repo)
git clone https://github.com/ryanrudat/InkLab.git
cd InkLab

# Swift libraries
for p in Packages/*/; do ( cd "$p" && swift test ); done
# Backend proxy
( cd Server && npm test )
# iPad app — 24 app unit tests + UI tests; InkLabDoc package has 10
open InkLab/InkLab.xcodeproj                                  # Xcode 26; run on iPad/Sim (iPadOS 18+); all 12 engine packages are direct deps

# Cloud (Claude) — make-real + Claude-vision recognize
#   1. Paste your key into Server/.env  (ANTHROPIC_API_KEY=...; .env is gitignored)
#   2. Start the server:
cd Server && npm start                                        # auto-loads Server/.env (Simulator dev)
#   3. Run the app; if the server is down/unreachable, make-real now shows a clear error (no fake widget).
#      On a real iPad, deploy the proxy (Railway) and set Info.plist MakeRealBaseURL to its HTTPS URL.
```

## Suggested next-session priorities
1. **Consent/compliance surface** — replace the hardcoded session with a real age screen, §5.1.2(i) AI-permission prompt, and `NWPathMonitor`-fed `SessionContext` (required before minors touch the cloud).
2. **Persistence** — GRDB op-log + blob store so the journal (and generated widgets) survive relaunch; then write PencilKit ink into the journal (never-lose-ink).
3. **Run the app on a real iPad** → ADR-0005 device gates (zoom/overlay registration is the one decision-changing risk); point the proxy at the LAN IP.
4. **Make-real polish + §6 sandbox** — progress UI, place result near source ink, promote-in-UI; begin bundling the compute-sandbox JS engines.
