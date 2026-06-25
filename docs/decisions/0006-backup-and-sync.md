# ADR 0006 — Backup & sync: serverless (Files export + CloudKit), not our server

**Status:** Proposed (recommended) · June 2026 · not yet built
**Resolves:** "Can we back up notebooks without a server, or should we use the Railway server for it?"
**Relates to:** [0002](0002-minors-cloud-compliance.md) (minors/cloud), [0003](0003-ipados-floor-and-backend-proxy.md) (backend proxy), [0004](0004-object-model.md) (object model — already names CloudKit as the sync target)

## Context

InkLab stores notebooks **only on the device** today: the notebook list (`library.json`) and each
notebook's journal/ink (`oplog.jsonl` + ink blobs) live in the app's Application Support container, with
**no backup and no sync** (ADR 0004's CloudKit step is deferred). A user deleting the app to reinstall it
**permanently lost their notebooks** — a dev-installed app's container is removed on delete, and with no
device backup there was no recoverable copy. This is unacceptable for a notes app; we need a backup/restore
path. The question is **where the backed-up data should live**: nowhere-but-the-device-plus-iCloud, or on
our own (Railway) server.

## Decision: back up **serverlessly** — keep notebook data on the device and in the user's own iCloud

**Do NOT store notebooks on our server (Railway or any other).** Use Apple's infrastructure so the data
never enters our custody:

1. **Immediate safety net — Files / iCloud Drive export+import.** A "Back up notebooks" action writes the
   notebook list + journals + ink to a single document the user controls (e.g. a `.inklab` bundle/zip) in the
   **Files app / iCloud Drive**, plus a matching import/restore. This **survives app deletion** (it's outside
   the app container), needs no account/auth, is trivial to build, and ships first.
2. **Real sync — CloudKit (`CKSyncEngine`), the user's own private database.** Notebooks live in the user's
   **iCloud** account and reappear automatically on reinstall or a new device. This is exactly the path ADR
   0004 already chose (one record per object, compacted snapshot + op-tail). It is **serverless from our
   side** (Apple runs it), free within generous per-user limits, and offline-first.

**The Railway proxy stays a stateless AI proxy.** It forwards `/make-real` and `/recognize` to Claude and
**never stores user content**; it must not become a notebook store.

### Why not our server (Railway)?

- **Compliance (the decisive reason).** Storing notebooks/ink on our server makes us a **custodian of user
  content, including minors' handwriting** — triggering COPPA/FERPA data-custody, retention, deletion-on-
  request, breach, and security obligations. ADR 0002's posture deliberately **minimizes** custody (ink never
  leaves the device; the proxy sends prompt *text*, not ink). Server-side notebook storage would blow that up.
- **Privacy.** CloudKit keeps data in the user's own iCloud (Apple as processor, end-to-end-ish, no InkLab
  data lake). Our server would mean users' handwriting flowing to, and sitting on, infrastructure we operate.
- **Auth.** Per-user server storage needs real per-user authentication; today's proxy has only an
  obfuscation-grade shared-secret Bearer (ADR 0003) — not user auth. CloudKit reuses the device's iCloud
  identity for free.
- **Cost & ops.** Storage, scaling, our-own-backups, and durability for every user's ink — all avoided.

## Consequences / sub-decisions

- **Export format** is self-contained and re-importable on another device; **re-validate any generated widget
  HTML on import** before loading it in the WKWebView (untrusted-origin rule — same as the cross-device sync
  caveat in ADR 0004).
- **Order of delivery:** ship the Files/iCloud Drive export+import first (days), then CloudKit sync.
- **No-iCloud users** still have the manual export; CloudKit degrades gracefully when iCloud is signed out.
- This ADR does **not** change ADR 0003's open *proxy-host* decision — that's about where the stateless AI
  proxy runs, which is independent of (and unaffected by) where notebooks are backed up.

## Risks

- CloudKit per-object upload cadence at notebook scale is unproven (already flagged in ADR 0004) → benchmark
  before broad build; the Files export is the de-risked fallback that ships regardless.
- A user with neither a device backup nor iCloud and who never exports can still lose data → make the first
  export prominent (onboarding nudge) once shipped.

## Status note

Recommended and documented in response to the data-loss incident (2026-06-17); **implementation pending.**
The prior loss is **not recoverable** (no pre-deletion backup existed).
