# ADR 0003 — iPadOS floor + the backend proxy

**Status:** Accepted · June 2026
**Resolves:** Build brief §12 #4 (on-device vs server boundary) and the deployment-target choice

## iPadOS floor: **iPadOS 18**

"iPadOS version" (software) and "device age" (hardware) are different axes — a chip gets 6–7 years of
OS updates, so the gate that matters for recognition performance is the **chip / Neural Engine**, not
the calendar.

- **iPadOS 18 captures ~83% of active iPads** (Apple App Store data, Feb 12 2026: ~57% on iPadOS 26 +
  ~26% on iPadOS 18; the sub-splits are third-party readings of Apple's chart, treat with mild
  caution; managed school fleets may skew older).
- Every iPadOS-18 device **except the lone iPad 7th-gen (A10, no Neural Engine)** has a Neural Engine.
- **Decision:** floor = iPadOS 18, and **gate on-device ML behind an actual Neural-Engine capability
  check** — route the A10 iPad 7th-gen to CPU/GPU or the cloud path rather than assuming a NE exists.
- Alternative: iPadOS 26 (A12+) guarantees a Neural Engine on 100% of devices and simplifies code, at
  ~17% reach cost — revisit if on-device ML/Pencil performance outweighs older-fleet reach. **Do not
  go below iPadOS 17** (A10/A9 devices have no NE and would over-rely on the cloud).
- Apple Pencil note: Pencil Pro needs iPadOS 17.5+ (newest M-series/A17 Pro); USB-C Pencil 17.1.1+
  (no pressure); 2nd-gen covers iPad Pro 2018–2022 / Air 4–5 / mini 6. Pressure/tilt feed stroke-
  quality heuristics for recognition.

## The backend proxy (consequence of ADR 0002)

All Anthropic calls route through a **thin InkLab backend**, never directly from the iPad. Reasons:
ZDR eligibility (Messages API, server-side), API-key security (no key on device), and the mandated
input/output **moderation** for minors. The boundary:

- **On the iPad (offline-capable):** ink capture (PencilKit), on-device recognition (MyScript / Apple
  Vision), and all deterministic compute engines (CAS, units, chemistry validation, etc.).
- **Through the proxy (online + consent only):** Claude vision recognition (math fallback, chemistry,
  diagrams) and generative features (make-real, explanations). The proxy enforces the consent gate
  server-side, applies moderation, strips/min­imizes data, and is where any negotiated ZDR applies.

Latency budget (initial targets, tune in the spike): on-device recognition median **< 500 ms**; cloud
round-trip **1–4 s**, only on demand/fallback, with the "Read as…" shown immediately from the
on-device pass so the UI never blocks on the network.

Re-validate the floor and Neural-Engine assumptions at each new iPadOS release (iPadOS 27 will likely
raise the chip floor), and re-check for any new Apple ink/math API after WWDC.
