# ADR 0004 — Object model + persistence (the "journal")

**Status:** Accepted · June 2026 · core prototype built & tested
**Resolves:** Build brief §12 #3 (object/data model + persistence schema); answers the ink-storage half of §12 #2

## Context

One serializable, versioned representation must cover everything on a page (ink, recognized objects,
made-real widgets, stickers, sticky notes, AI callouts, charts, 3D) and support global undo/redo,
copy/paste across notebooks, z-order, transform, and offline-first CloudKit sync — with a rewrite-free
path to real-time collaboration later. It's the foundation everything sits on, so it's effectively
irreversible. Four rival architectures were generated, fact-checked, and scored by a 3-judge panel.

## Decision: an **event-sourced operation log** (package `InkLabDoc`)

The notebook is a deterministic **fold over an ordered log of `Op`s**. The page you see is the
journal replayed; nothing stores "current state" as the source of truth.

- **Undo = append the inverse op** (it never pops the log) → durable across relaunch and **composes
  with a concurrent remote merge** instead of going stale. AI insertions are ordinary ops grouped by
  a `transactionID`, so they're inside global undo *by construction*.
- **Never-lose-ink is structural**: a stroke is written to the append-only log + an immutable blob
  the instant the gesture ends, before any network step.
- **Merge = sort-union two logs by hybrid-logical-clock, re-fold** → conflict-free convergence;
  no op (hence no stroke) is dropped. LWW-per-field is the day-one resolution, as the brief allows.
- **Rewrite-free collab**: the v1 single-user store *is already a replicated op-log* (per-actor ids,
  HLC, tombstones, fractional z-index, UUID-only refs). Multi-user = more actors writing a shared
  CKShare zone — additive.
- **Recoverable**: the projection is disposable and rebuilt by replay, so a schema/logic bug is fixed
  by shipping corrected fold code and replaying — lowest blast radius for an "irreversible" choice.

Judges ranked this #1 on the correctness/undo and sync/collab lenses; the ship-speed judge preferred
SwiftData *only because collab is deferred*, while still recommending the op-log seams on day one.

### Key sub-decisions
1. **PencilKit owns the ink bytes; `InkLabDoc` owns identity/placement/refs.** One `PKDrawing` blob
   per ink-*object* (a lasso-committed cluster), referenced by `BlobRef`. Per-stroke UUIDs are minted
   only at recognition time, so a recognized equation links back to its source ink.
2. **Local store = GRDB/SQLite, not SwiftData.** Fact-checked: SwiftData exposes no custom
   `NSMergePolicy` (so its attribute-LWW would silently clobber concurrent ink with no fix), and
   `NSPersistentCloudKitContainer` is private-DB/single-Apple-ID (collab = transport rewrite).
3. **CloudKit = `CKSyncEngine`, one record *per object*** (compacted snapshot + small op-tail),
   mutated in place — *not* one record per raw op (which the fact-check flagged as throttle-prone).
4. **PKDrawing forward-incompat guard (CONFIRMED, live on the iPadOS 18 floor):** v4 ink from
   iPadOS 26 syncs down and fails to decode → every ink blob stores its `requiredContentVersion` + a
   **raster PNG fallback**, and a failed decode is **quarantined, never LWW-clobbered**.
5. **Reuse `InkLabRecognition`'s `FormalStructure`/`Candidate`** (now `Codable`) verbatim in
   recognized objects — the recognition contract stays the single source of truth.
6. **CRDT (automerge-swift) is deferred behind a `MergeStrategy` seam**, scoped to true concurrent
   free-text leaves only, and benchmark-gated (it's pre-1.0 with an open Swift-6 FFI issue).

## What was built & verified now

`Packages/InkLabDoc` — Foundation-only, CLI-tested, **7 passing tests**: Codable round-trip +
forward-compat fallthrough; exact undo round-trip; **AI-insert-undoes-as-one-step**; order-independent
fold + HLC last-writer-wins; **merge never loses a stroke** + commutativity; **compaction-equivalence
fuzz** (a bug resurrecting a deleted object fails the test); cross-notebook paste with ref remap.

The core functions are `fold` / `invert` / `merge` / `remap`, over value types `Op` / `OpPayload` /
`ObjectSnapshot` / `ObjectPayload`. The live projection uses a plain `Dictionary` in the prototype;
production swaps it for `swift-collections` `TreeDictionary` (CHAMP) for O(log N) structural sharing —
a performance change only, semantics unchanged.

## Deferred to the on-device phase (not blocking)
- GRDB schema (`ops` / `snapshots` / `blobs`), the `CKSyncEngine` delegate, and the PencilKit adapter.
- The automerge-swift collab benchmark (gated until collab is greenlit).
- `TreeDictionary` projection swap.

## Open product questions (defaults chosen; veto any)
- Undo/compaction window — default "≥ last 500 ops or 30 days".
- Cross-page/cross-notebook reactivity — default page-local in v1; cross-page deferred (model supports it).
- Ink raster-fallback cost — default ON (never-lose-ink > storage).
- Export — default high-DPI raster for v1; vector PDF later.
- Actor identity — default per-device actor ids (free collab-readiness).

## Risks
- Compaction correctness is the top systemic risk (mitigated: fuzz-tested with full replay as oracle).
- `CKSyncEngine` per-object upload cadence is unproven at notebook scale → on-device cadence benchmark before broad build.
- The PKDrawing quarantine + raster fallback MUST ship in the first ink-bearing build (data-loss path if skipped).
- automerge-swift is pre-1.0 → strictly behind the seam, swappable for a hand-rolled per-field RGA.
