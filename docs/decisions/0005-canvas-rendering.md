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

`Packages/InkLabCanvasCore` — Foundation-only, **11 passing tests**: lasso hit-testing
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
