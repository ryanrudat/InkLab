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

---

## Implementation status (2026-06-07)

The decision stands. Amendments from this session:

- **Two additive ops** were added to the journal, both **one-step-undoable** with fold/invert/remap arms + tests:
  - `setObjectState` — edits a live widget/chart/3D object's inline state.
  - `promote` — energy-level swap (e.g. sticker ↔ interactive ↔ 3D).
  Existing case serialization is unchanged; `InkLabDoc` now has **9 passing tests** (the two new ops included).
- **Live widgets render via a polymorphic host** that rebuilds in place when an object's payload kind changes (text cards, native widgets, and a locked-down `WKWebView` for generated HTML).
- **Still IN-MEMORY only.** The GRDB local op-log + blob store and CloudKit/`CKSyncEngine` sync remain deferred (see "Deferred to the on-device phase") — nothing survives relaunch yet.
- **PencilKit ink is NOT yet written into the journal** — strokes currently live only in the live `PKCanvasView`. The never-lose-ink guarantee in §"Decision" is therefore not yet realized; wiring the PencilKit adapter into the append-only log is outstanding.

## Implementation status (2026-06-08)

The journal now **persists across relaunch** — closing the two outstanding gaps from 2026-06-07 ("still in-memory only", "ink not written into the journal"). A new swappable **`JournalStorage`** protocol (`InkLab/InkLab/JournalStorage.swift`) sits behind `JournalStore`, with a file-backed `FileJournalStorage` impl scoped per notebook under Application Support:

- **Op log** = `oplog.jsonl`, append-only, one compact-JSON `Op` per line — append is O(1) via `FileHandle.seekToEnd` + `synchronize()` (fsync) to shrink the torn-tail window; a torn/forward-incompatible line is skipped, never fatal (matches the "recoverable projection" intent). **Ink blobs** = one `PKDrawing` `Data` per page (`ink/<page>.drawing`), passed as `Data` so the storage layer stays PencilKit-free.
- **On launch**: `JournalStore` replays the persisted op log via `fold`. Because `fold` orders by HLC (not append order), the **`Clock` is reseeded past the loaded ops** (`advance(toWall: maxLoadedWall + 1)`) so new edits sort after everything on disk.
- **Stable notebook ids**: the notebook **LIST persists** too (`Library` → `library.json`; `Notebook` is now `Codable` with a stable `id`), required so each notebook's storage dir is stable across launches. Deleting a notebook also removes its on-disk store.
- **Never-lose-ink, as-built**: ink flushes on a debounce, and a **background/suspend flush** (`willResignActive` / `didEnterBackground` → `flushInkNow`) writes the current page synchronously; FileProtection `completeUntilFirstUserAuthentication` keeps locked-device background writes from silently failing.
- **Relaunch reopens the LAST-VIEWED page** (per-notebook `UserDefaults` key), not always page 1 — so later-page work isn't perceived as lost.
- **Undo/redo stacks are session-only by design** (not persisted) — the *inverse* ops are still written to the log, so an undone edit stays undone across relaunch; only the back/forward history resets.

Tests (`InkLab/InkLabTests`): `journalPersistsAndReloads`, `reloadReopensLastViewedPage`, `persistedUndoSurvivesReloadHistoryResets`.

**Deviation from the decision:** the local store is an **interim file-backed JSONL/blob store, not the GRDB/SQLite schema** (`ops`/`snapshots`/`blobs`) named in §"Decision" sub-decision #2 and §"Deferred". GRDB is the eventual target and drops in behind this same `JournalStorage` protocol; **op-log compaction, the GRDB impl, and CloudKit/`CKSyncEngine` sync remain deferred.**

## Implementation status (2026-06-09)

Correctness/integrity hardening of the journal and its persistence, plus direct-manipulation edits that route through the object model. The decision stands.

- **HLC total order is now strictly monotonic (A5).** `Clock.tick()` used a **wrapping `UInt16` counter** that never advanced the wall within a session, so after 65,536 ops the total order corrupted. `tick()` now **advances the wall on counter overflow** — the invariant the whole sort-union merge and reseed-on-load logic depends on. Regression test.
- **Op-log replay distinguishes a torn tail from interior corruption (A6).** `FileJournalStorage.loadOps` previously silently dropped **any** unreadable line, so an interior corrupt/forward-incompatible op left a replay **hole**; it now treats only a **benign torn tail** as recoverable and logs **interior corruption loudly**. `JournalStorage.append` (and `JournalStore`) are now **throwing**, so a real persistence failure is **surfaced** (an `onPersistenceError` hook) instead of being swallowed while the live session shows the op as saved — tightening the never-lose-ink path.
- **Async results are tagged to their originating page (A7).** Async make-real / Check / Recognize results and the auto-"@" scan could land on the **wrong page** after a page switch; the originating page is now captured and guarded, and a pending auto-scan is cancelled on a page switch — so a result is never journaled onto the wrong page.
- **Lasso move + cut/copy/paste journal through the object model (B1/B2).** A lasso **move** of a mixed handwriting+object selection commits its object ops as **one journal transaction** (`setTransform × n`); **delete/cut/copy/paste** reuse one **generalized combined history step** (`HistoryStep.compound` + `commitCompound`), so each is **one undo step** (objects = one journal transaction, ink = before→after drawing, reversed together) — i.e. these edits are inside global undo *by construction*, as §"Decision" intends. Copy/paste use a **static session clipboard**, so paste works **across pages and across notebooks** (object refs remapped on paste, matching the cross-notebook-paste guarantee already tested in `InkLabDoc`).
- **Still open:** the uncertain `fold(_:from:)` incremental-compaction **high-water trap** is **unreachable today** (no compaction store is wired) but should be fixed **before GRDB/compaction lands** — it sits on the compaction-correctness risk already flagged in §"Risks".

## Backup & sync direction (2026-06-17)

The §"Decision" CloudKit (`CKSyncEngine`) sync target is now captured as its own decision —
**[ADR 0006](0006-backup-and-sync.md)** — prompted by a real on-device data loss (a user deleted the app;
on-device-only storage + no backup = unrecoverable). It reaffirms **serverless** backup: a **Files /
iCloud-Drive export** ships first as an immediate safety net, then CloudKit (the user's own iCloud). It
also rules out storing notebooks on our proxy (data-custody/COPPA-FERPA). No change to the op-log model
here — CloudKit remains one record per object (compacted snapshot + op-tail), and widget HTML received from
another device must be re-validated before loading.
