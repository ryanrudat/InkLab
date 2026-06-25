# ADR 0005 — Canvas rendering over PencilKit

**Status:** Accepted (device-gate-validated) · June 2026 · geometry core built & tested
**Resolves:** Build brief §12 #2 (the last foundational decision)

## Context

The canvas must render a layer of live, interactive **objects** (recognized eqns, made-real widgets,
stickers, sticky notes, AI callouts, charts, 3D) over PencilKit **ink**, support the §5.2 paging
model (continuous capped auto-extend + finger paging + pencil-draws/finger-navigates), and let a
lasso select a **mixed** ink+object set for move/resize/rotate — with zero ink latency and crisp ink
at zoom. Four rival architectures were generated, fact-checked, and judged.

The single most-confirmed fact: **PencilKit ink blurs whenever an *outer* transform scales it, and
stays crisp only when PencilKit's own UIScrollView owns the zoom.** Refuted claims of note: PKStroke
has no stable public UUIDs and PKDrawing doesn't round-trip losslessly across content versions; the
tiled-CALayer "as crisp as PencilKit" and capture-probe-latency premises don't hold.

## Decision: a **PKCanvasView-hosted hybrid**

- **Ink:** one recycled live `PKCanvasView` per *visible* page (pool ~3); offscreen pages are cached
  `PKDrawing.image` raster snapshots (one live canvas avoids the confirmed multi-canvas GPU
  exhaustion). PencilKit's **native scroll/zoom is kept** — this is what guarantees crisp ink + zero
  latency. The page composites its per-ink-object PKDrawing blobs into one `canvasView.drawing`.
- **Objects:** one UIKit/CALayer host per object in a sibling overlay above the ink;
  `hitTest`→nil over empty space so **a Pencil touch falls through and draws**. SwiftUI is allowed
  only for *leaf* hosts (Swift Charts, RealityView) and the accessibility pattern — never as the
  per-frame transform driver (a single CALayer affine mirrors scroll/zoom).
- **Paging (§5.2):** vertical = PencilKit's scroll, auto-extended in screen-heights, capped ~4;
  horizontal = our finger paging; a new page is provisional until ink/an object lands.
- **Pencil/finger:** touch-**type** partition — `.pencilOnly` draws, `.direct` finger gestures
  navigate/lasso (disjoint touch sets, no `require(toFail:)` race). Palm rejection free.
- **Lasso (ours, not `PKLassoTool`):** finger **and** a Pencil-lasso *mode* (Pencil draws the
  selection when the lasso tool is active — the geometry is source-agnostic). Selects a mixed
  ink+object set; move/resize/rotate bakes to the journal as **one** undo transaction.
- **Model fit:** a pure function of the InkLabDoc journal (collab-ready). Uses **our** stroke IDs
  (`InkBody.strokeIDs`) — never PencilKit's — and the raster fallback (`BlobRef.fallbackRasterID`,
  ADR 0004) so a too-new ink blob is quarantined, not lost.

### Confirmed product choices
- **Objects always float above ink** (one flat ink plane per page) — accepted for v1; true
  interleaving would reopen the rejected multi-canvas tradeoff.
- **~10× max zoom** (PencilKit's cap) is sufficient — keeps the crisp native-scroll spine.
- **Lasso: finger + a Pencil-lasso mode.**

## What was built & verified now

`Packages/InkLabCanvasCore` — Foundation-only, **25 passing tests** (11 core + 14 draw-and-hold shape
recognition added 2026-06-16): lasso hit-testing
(point-in-polygon, stroke contains/intersects, rotated-rect∩polygon), transform math (resize keeps
the opposite corner fixed, rotate inverse), canvas↔view coordinate round-trip, page auto-extend
(grow + cap), the page-turn-vs-scroll classifier, object selection, and the projection→view diff
(incl. tombstone-as-removal). Depends on InkLabDoc (Transform/projection) + InkLabRecognition
(Point/Rect) so its output feeds `RecognitionInput`.

## On-device gate plan (needs an iPad; can't be CLI-verified)
A single UIKit prototype, each gate a hard go/no-go before the spine is locked:
- **Gate A (highest risk):** native zoom crispness + overlay↔ink pixel registration under fast pinch.
  Fail → fall back to the "own-the-transform" approach (the only spine-changing failure).
- **Gate B:** the pencil-draws/finger-navigates touch-type partition feel (edge draws vs edge pages).
- **Gate C:** multi-canvas GPU memory bounded across ~20 pages (pool of 3 + raster snapshots).
- **Gate D:** ink round-trip + recognition contract (blob → strokes+raster → recognizer; quarantine).
- **Gate E:** lasso-drag perf at 120 Hz + off-main `PKDrawing.image` (thread-safety undocumented).

## Risks
- Overlay↔ink registration under fast pinch is "uncertain" — degrades gracefully (drift snaps back,
  never corrupts strokes); measured at Gate A.
- Stroke→object attribution after composite+transform+partial-lasso is the data-integrity hot spot —
  mitigated by our own stroke IDs + the raster fallback + fuzz-testing the side-table.
- `PKDrawing.image` thread-safety undocumented → Gate E; fallback is a main-thread bake.

## Implementation status (2026-06-07)
The `PKCanvasView` + UIKit object-overlay hybrid is built and runs in the app.
- **Object overlay:** the polymorphic host renders text cards, native widgets, and a locked-down
  WKWebView; objects carry editing chrome — delete (✕), a resize grip, and inline sticky-note edit —
  all undoable via the journal.
- **Generated widgets** render inside the locked-down WKWebView host.
- **Drawing input:** `PKCanvasView.drawingPolicy` is set to `.anyInput` so the canvas is drawable in
  the Simulator (finger/mouse), behind a Settings toggle.
- **Crash fix:** a pre-existing crash (apply(…) running from `makeUIViewController` before
  `viewDidLoad` and touching a nil lasso gesture) was fixed — the canvas could not open before this.

Still requires a physical iPad — the ADR-0005 device gates remain open: zoom crispness / overlay
registration (Gate A), palm rejection / touch-type partition (Gate B), GPU memory across pages
(Gate C), and the ink round-trip (Gate D). **Per-object rotate and lasso transform are pending.**

## Implementation status (2026-06-08)
The hybrid spine matured; the lasso and the overlay are now navigation-safe and carry live geometry.
- **Lasso ↔ navigation coexist.** `lassoGesture.maximumNumberOfTouches = 1` and
  `ObjectOverlayView.hitTest` only captures the overlay when `event.allTouches.count <= 1`, so a
  **two-finger scroll and the page-swipe still work while the lasso tool is active** — one finger
  draws the loop, two fingers navigate.
- **Persistent marquee.** The dashed selection now closes into a loop (`UIBezierPath.close()`) and
  stays drawn after the finger lifts until the next lasso / new ink / tool switch / page change,
  so a selection looks like one.
- **Honest ink hit-testing.** Lassoing handwriting runs `strokeHitTest` per stroke (pre-filtered by
  `renderBounds`) and reports whether real ink was caught. No coordinate conversion is needed: lasso
  points and stroke points already share content coords (`overlay.bounds.origin == contentOffset`),
  so the ADR's canvas↔view ruling holds with no `adjustedContentInset` math.
- **Write on a widget.** A per-object `WidgetAnnotationView` ink layer sits **above** each generated
  WKWebView host: **Pencil draws, finger operates the widget** (its `hitTest` falls through finger
  touches unless the ✏️ toggle is on, for the Simulator), strokes persist per object, and a ƒ header
  button recognizes the writing and feeds the widget via `setWidgetInput` (handwrite → plot). **Erasing
  it** mirrors the page (see the 2026-06-22 note): a 🧽 toggle for finger/Pencil, plus the global Eraser
  tool driving the Pencil.
- **Native deterministic fit graph.** A new `native:fitGraph` widget (`FitGraphView`) draws the
  sampled points + best-fit curve + equation + R² with no OCR/cloud — the toolbar Fit button calls
  `fitLassoedSketch()`, which samples the lassoed strokes and runs `CurveFitter` (InkLabFit's exact
  least-squares). See `docs/ARCHITECTURE.md`'s fit note for the trust caveat (axisless sketch → normalized units).
- **"Designing…" animation.** A transient, non-journal `DesigningPlaceholderView` (shimmer + breathing
  sparkle) shows on the canvas exactly where a make-real widget will land during the ~20s generation,
  then is swapped for the real widget (or removed on failure).

Device gates A–E and per-object rotate / full lasso transform remain open.

## Implementation status (2026-06-09)
Lasso became direct manipulation (ADR's "move a mixed selection" — move + edit shipped), and the
toolbar/dock was redesigned.
- **Lasso move (mixed ink+object).** Drag from inside the selection to move a mix of handwriting +
  objects as **one undo step**: objects move as one journal transaction (`setTransform × n`), ink
  translates via `PKStroke.transform` (rebuilt `PKDrawing`), reversed together via a combined
  journal/ink history step.
- **Lasso delete / cut / copy / paste.** A native edit menu (tap inside the selection) plus
  ⌘C/⌘X/⌘V, each **one undo step** through a generalized combined history step
  (`HistoryStep.compound` + `commitCompound`: objects = one journal transaction, ink = before→after
  drawing). Copy/paste use a **static session clipboard**, so paste works across pages **and**
  notebooks; it lands at the visible center preserving the copied set's relative layout and is
  auto-selected so it can be dragged immediately. Recognize / Check / Fit were also added to the
  lasso selection menu (they act on the selection).
- **✕ delete works in lasso mode.** A tap on an object's ✕ now passes through even when the lasso
  tool is active (the overlay used to swallow it).
- **Geometry-only widget updates.** Moving/resizing a **native** widget now uses a geometry-only
  path (`applyGeometry`) instead of a content reload, so a transform no longer reloads journaled
  state and wipe uncommitted input (e.g. calculator entry).
- **Toolbar / dock redesign.** Inline color + thickness are shown **contextually** (only for
  pen/highlighter); less-frequent actions (Recognize / Check / Fit / Paper) moved into a "＋"
  Insert/Actions menu. **Pen favorites/presets** save (color + width) per tool, persisted
  (UserDefaults) — tap a chip to apply both, long-press to edit, a dashed ＋ to save the live pen.
  The dock is **repositionable** (drag a grip; clamped on-screen; position persisted) and
  **collapsible** (a chevron folds it to a puck); the "@" command button honors `leftHanded`. A
  drag-fluidity rework removed the stutter (idempotent `vc.apply`, the toolbar content isolated in a
  child `DockBar`, a bar-measuring clamp, and the heavy inline `UIColorWell` replaced by a
  lightweight color-dot popover); final feel is best confirmed on a physical iPad. "Check working"
  was renamed to "Check work".

Per-object rotate and group resize/rotate remain deferred; device gates A–E remain open.

## Implementation status (2026-06-16 → 18)
Writing-experience polish + three correctness fixes, plus a new shape-recognition capability. The
**draw-and-hold** fix was **confirmed on a real iPad + Pencil** (a partial Gate-B/Gate-E touch of the live
ink path); the **undo** fix is build- + regression-test-verified (device pass still recommended). Each
change went through a multi-agent adversarial review.
- **Lasso DRAG perf (Gate E, partial).** `updateMove` no longer rebuilt + re-rendered the whole
  `PKDrawing` every touch-move (the lag). The selected strokes are now lifted onto a **snapshot
  `CALayer`** translated per frame; the real drawing is rebuilt **once on release**. All per-frame layer
  mutations are wrapped in a `CATransaction` with implicit animations disabled so the marquee tracks the
  finger instead of easing behind it.
- **Lasso SELECTION correctness.** Hit-testing now (a) **applies `PKStroke.transform`** — a stroke moved
  earlier carried its offset in `transform`, so it was tested at its stale pre-move location and left
  behind; and (b) samples the **dense interpolated path** (`PencilKitAdapters.hitTestPoints`) not the
  sparse B-spline control points, so a small stroke whose curve is inside the loop isn't missed.
  `fitLassoedSketch` is likewise transform-aware now.
- **Draw-and-hold SHAPE SNAPPING (new).** Hold the pencil still ~0.5s after a stroke and it snaps to a
  clean line/arrow/circle/ellipse/rectangle/triangle. The recogniser is deterministic + correct-or-silent
  (`InkLabCanvasCore.ShapeRecognition`, +14 tests); the snap is **one undo step** (undo → freehand). Hold
  detection observes PencilKit's **own** `drawingGestureRecognizer` **and** reads the finished stroke's
  end-dwell samples — **a separate `UIGestureRecognizer` cannot be added to a `PKCanvasView` to run
  alongside drawing on iOS 18** (devforums 766925; the first attempt silently never fired).
- **Undo no longer resurrects ink (real fix 2026-06-18).** Assigning `canvasView.drawing` commits through
  PencilKit's **async render pipeline** (devforums 702903/719944), so for a window the canvas's live stroke
  base is still the pre-swap drawing and the next stroke is composited onto it — re-introducing the removed
  stroke. A 06-17 attempt (gate input + clear `canvasView.undoManager` + re-enable one runloop later) did
  **not** hold, because the settle window isn't a fixed duration. **Fix:** `setCanvasDrawing` records the
  **content-signature** of every stroke a swap REMOVES; `canvasViewDrawingDidChange` **strips any of those
  exact strokes if they reappear** and writes the corrected drawing back — structurally race-proof, while
  bitmap-eraser edits (new signatures) and redo (signatures cleared on a legitimate restore) are untouched.
  **`PKDrawing.dataRepresentation()` is not byte-stable for identical content**, so it can't be a stroke
  identity — signatures hash the stroke's geometry+ink via a process-stable `Hasher`. Test
  `resurrectedStrokesAreStrippedByIdentity` (pure `strippingResurrectedStrokes` helper). Closes the latent
  `isRestoringDrawing` item flagged on 2026-06-08.
- **Writing UX.** Bolder pen widths (3/6/10); **colour and thickness decoupled** (a colour tap no longer
  resets the width — the old `(colour,width)` presets became a colour-only palette); saved colours sit in a
  **fixed-width horizontal scroller** so the dock can't overflow.

**General PencilKit rule reaffirmed here:** don't fight `PKCanvasView` — observe *its* gestures rather than
adding competing ones, and **never trust the drawing after a programmatic `.drawing` swap**: it commits
asynchronously, so reconcile new strokes against a known baseline **by content identity** (and note that
`PKDrawing.dataRepresentation()` is **not** a stable identity — hash the stroke's geometry). Per-object
rotate / group resize/rotate and device gates A–E remain open.

## Implementation status (2026-06-22)
Two reported bugs in the AI-generated (`@`) widgets, fixed at the root and put through a multi-agent
adversarial review (which broke its own first fix — see the erase regression below). Build-verified on an
iPadOS 18 Simulator; Pencil-vs-finger routing still wants a device pass.
- **Generated widgets no longer blur on reopen (Gate-A-adjacent — WKWebView raster, not the PencilKit
  zoom-blur of §"single most-confirmed fact").** `CanvasViewController.viewDidLoad` rebuilds every object
  via `overlay.apply(...)` **before the canvas is in a window or laid out**, so each `WebWidgetView` called
  `loadHTMLString` while off-screen at a zero frame / 1× `contentScaleFactor` — WebKit's single paint
  rasterized at the wrong size/scale and never refreshed until a drag re-composited it (which is why the
  widget the user *dragged* sharpened up). **Fix:** `WebWidgetView` holds `pendingHTML` and defers the paint
  to `loadIfReady()`, gated on `window != nil && bounds > 1` and driven by `didMoveToWindow` +
  `layoutSubviews`, so the one-and-only paint lands on the real screen at full resolution. Freshly-generated
  widgets (created post-layout, already in-window) stay immediate. **Lesson:** a `WKWebView` must never be
  asked to paint while off-screen or at a zero frame — the first raster sticks.
- **Erase widget annotations.** `WidgetAnnotationView` only ever *added* strokes. Added whole-stroke erase
  (point-to-segment distance) via a per-widget 🧽 toggle (finger or Pencil; mutually exclusive with ✏️;
  header tints red) **and** a Pencil that erases whenever the app's global **Eraser** tool is active
  (`pencilErases`, propagated `apply → ObjectOverlayView.setPencilErasesAnnotations → ObjectHostView →
  WidgetAnnotationView`). This also fixed a latent bug: the Eraser tool used to make a Pencil *draw* red ink
  on a widget. A finger still operates the widget when no finger-mode is active.
- **Erase persistence (regression caught in review — same family as the undo-resurrection bug).** Whole-stroke
  erase mutates `strokes` live during the gesture, but persistence only fired in `touchesEnded` via
  `onChanged`. A **cancelled** erase — a two-finger scroll claiming the touch mid-rub, or the app
  backgrounding — left the erase applied in memory but unsaved, so the rubbed-out strokes resurrected from the
  stale on-disk blob on reload. **Fix:** `touchesCancelled` now fires `onChanged` when an erase was in flight
  (a cancelled *draw* stays a no-op — it only discards `active`, never touching `strokes`).
