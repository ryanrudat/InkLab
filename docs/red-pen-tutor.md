# Red-pen tutor — the math wedge (`InkLabMath`)

The differentiated core (brief §6.4): read a student's handwritten working and find the **first wrong
line**, explaining why — understanding-first, not answer-delivery. Error localization is
**deterministic and correct by construction**: the model only READS ink into formal structure; this
engine COMPUTES the verdict by checking true mathematical equivalence between consecutive lines. No
LLM guess ever decides whether a step is right.

## How it works (exact, not numeric)
1. **Parse** each transcribed line into an expression AST (`Expr`): `+ − × ÷`, integer/parenthesised
   powers, parentheses, unary minus, implicit multiplication (`2x`, `2(x+1)`, `(x+1)(x-1)`), rational
   and decimal literals, and known function calls.
2. **Canonicalize** to an exact **rational function over multivariate polynomials with ℚ
   coefficients** (`RationalFunction`). Unknown/transcendental sub-expressions (`sin(x)`, `√2`) become
   **opaque atoms**, so algebra *around* them is still checked exactly while identities we don't know
   (e.g. `sin²+cos²=1`) are conservatively **not** assumed.
3. **Compare consecutive steps:**
   - *Expression-simplification chain* (`(x+1)^2` → `= x^2+2x+1` → …): each line must be **exactly
     equal** to the running value — tested by `num₁·den₂ − num₂·den₁ ≡ 0` (cross-multiply to zero).
   - *Equation-solving chain* (`2x+3=7` → `2x=4` → `x=2`): each step must **preserve the solution
     set** — tested by checking the `L−R` difference polynomials are nonzero **rational-scalar
     multiples** of one another (exactly the legal moves: add/subtract the same thing to both sides,
     scale both sides by a nonzero constant).
4. **Report the first failing line** with a plain-English reason and, where possible, a **concrete
   counterexample** ("At x = −5 the line above equals 16 but this line equals 26"; "x = −2 is a
   solution of the line above but no longer satisfies this line — a solution was lost").

## Calculus (also deterministic)
Differentiation is implemented exactly on the AST (power/product/quotient/chain rules +
sin/cos/tan/exp/ln/sqrt). A **derivative step** `d/dx(...) = result` is checked by differentiating
and comparing. An **integral step** `∫ ... dx = F (+C)` is checked by *differentiating the student's
answer* and requiring it to equal the integrand — which verifies integration without a full
integrator and makes the `+C` automatic (a constant differentiates to 0). Notation: `d/dx(...)` and
`∫ ... dx`, with the result on the same line or the next.

## What it catches today (all tested)
- The classic `(x+1)² = x²+1` expansion error.
- An arithmetic slip mid-solve, localized to the **first** offending line (not a downstream one).
- A **lost solution** when a student takes a square root (`x²=4 → x=2` drops `x=−2`).
- A wrong **derivative** (e.g. `d/dx(x²) = x`) or a wrong **integral** coefficient
  (`∫x² dx = x³/2 + C`), each with a numeric counterexample.
- Exact rational arithmetic (`1/3 ≠ 0.333`).

## Correct-or-silent (a trust guarantee, brief §3.5)
If a mismatch involves opaque atoms it can't verify (e.g. `√2·√2 = 2`), the tutor returns
**`unsupported`, never a confident error** — it would rather say less than accuse a correct step.

## Scope & current limitations (honest)
- **In scope:** polynomial/rational algebra over the rationals with opaque function/radical atoms;
  expression-equality and linear/polynomial equation-step validity; and **calculus** —
  differentiation and integral steps (as above).
- **Not yet:** transcendental identities (e.g. `sin²+cos²=1`), radical simplification, inequalities,
  actual equation *solving*, and multi-variable counterexamples (single real-variable only).
  Coefficients use `Int64` rationals — fine for student-scale steps; the exact core is now
  **overflow-safe by construction** (see Status 2026-06-09), so very large expansions degrade to
  `unsupported` rather than needing BigInt.

## Where it sits in the pipeline
Fed by the recognizer's `FormalStructure` (LaTeX / expression tree) once a student selects their
working; the verdict renders in place next to the ink (the "red pen"). Pure Swift, no iPad needed —
`( cd Packages/InkLabMath && swift test )` → 24 tests (algebra + calculus).

---

## Status (2026-06-08)
The red-pen tutor (`InkLabMath` `checkChain` — first-wrong-line detection) is **reachable in the app**:
via the **`@check`** command (typed or handwritten), the **engine chips on the recognition review
sheet**, and the toolbar **Check** button (`CanvasViewController.checkWork()`, which reads the lassoed
region — or the whole page's ink — then runs the tutor in place).

The **reading** step now uses `bestRead`: when the cloud-AI opt-in is granted it reads the lasso via
**Claude vision** through the backend proxy (it transcribes handwritten math and line breaks far better
than on-device Vision), otherwise it falls back to **Apple Vision** on-device. Either way the **tutor
judgment is unchanged** — `checkChain` runs the deterministic, exact-algebra red pen (correct-or-silent)
on the transcribed text (one step per line). Only the *reading* can touch the cloud; **no LLM ever
decides whether a step is right.**

## Status (2026-06-09)
The exact-arithmetic core (`Rational` / `Polynomial` + the `Expr` tokenizer) is now **overflow-safe**.
It previously used trapping `Int`, so an input like `@check 2^100` or a long decimal could SIGTRAP the
whole process. The core now uses **checked arithmetic with an absorbing overflow sentinel**: on `Int64`
overflow the tutor degrades to **`.unsupported`** ("numbers too large to verify exactly") instead of
crashing. This **strengthens correct-or-silent** — the earlier note ("swap to BigInt for very large
expansions") is superseded: the engine is overflow-safe by construction. (A latent `Rational` ÷0 trap
was fixed alongside it; regression tests added — `InkLabMath` is now **24 tests**.)

Surface naming/reach: the **`@check`** / **Check** verb is now labeled **"Check work"** everywhere it
appears, and it is reachable from the **lasso selection menu** (it acts on the lassoed selection).

## Status (2026-06-25)
No engine changes since 2026-06-09 — the red pen is stable. Verified current against the tree:
`InkLabMath` is still **24 tests** (algebra + calculus), and the engine remains reachable three ways —
the **`@check`** command (`CommandRunner` → `redPen`), the **"Check working"** chip on the recognition
review sheet (`EngineKit.EngineAction.check` → `runEngine`), and the toolbar / lasso-menu **Check work**
button (`CanvasViewController.checkWork()`). All three funnel transcribed text into the same
deterministic `checkChain`. `checkWork()` still reads the region via `bestRead` (Claude vision when the
cloud opt-in is granted, else on-device Apple Vision) and the **verdict is always the exact-algebra
tutor** — no LLM decides correctness.

(Unrelated to this engine: this session rewrote the canvas's floating dock — drag-jitter fix + side-wall
vertical snapping — in `CanvasScreen.swift`. It touches none of the red-pen path.) The repo is now public
at <https://github.com/ryanrudat/InkLab>.
