import Foundation
import InkLabKit

/// A deterministic best-fit result, ready for `FitGraphView` to draw. A freehand sketch has no axes, so
/// coordinates are in the sketch's own normalized space (x spans 0…10, y at the same scale). The
/// TRUSTWORTHY outputs — the model TYPE, the clean curve, and R² (goodness of fit) — come from the exact
/// least-squares in `InkLabFit`, never from a model.
struct FitGraphState: Codable, Equatable {
    var points: [[Double]]    // the sampled sketch points (x,y), normalized
    var curve: [[Double]]     // the fitted curve as a dense polyline (x,y)
    var equation: String      // e.g. "y = 2.01x² - 1.30x + 0.50"
    var rSquared: Double
    var model: String         // "Linear" / "Quadratic" / "Cubic" / "Exponential" / "Power"
}

/// Picks the best simple model for a set of sketch points using InkLabFit's exact least-squares.
enum CurveFitter {
    private struct Candidate { let model: String; let equation: String; let predict: (Double) -> Double; let params: Int }

    /// Fit sketch points (already in math space: y UP). Returns nil if there aren't enough distinct
    /// points to fit anything.
    static func fit(_ raw: [Point2D]) -> FitGraphState? {
        let cleaned = dedupByX(raw)
        guard cleaned.count >= 4 else { return nil }

        // Normalize to a friendly, UNIFORM scale (x → [floor, 10+floor], y by the same factor) so the
        // curve keeps the sketch's shape and the coefficients are readable rather than in raw pixels.
        // The min point maps to a small POSITIVE `floor`, NOT exactly 0: mapping it to 0 made the
        // exp/power positivity gates (x>0, y>0) ALWAYS fail, so the Exponential/Power models were dead
        // code (an exponential sketch was silently mislabeled). A small floor keeps both reachable and
        // lets R² pick among all five models fairly.
        let xs = cleaned.map(\.x), ys = cleaned.map(\.y)
        let minX = xs.min()!, maxX = xs.max()!, minY = ys.min()!
        let scale = 10.0 / max(maxX - minX, 1e-9)
        let floor = 0.5
        let pts = cleaned.map { Point2D(x: ($0.x - minX) * scale + floor, y: ($0.y - minY) * scale + floor) }

        var cands: [Candidate] = []
        if let f = linearFit(pts) { cands.append(.init(model: "Linear", equation: linearEq(f), predict: f.predict, params: 2)) }
        if let f = polynomialFit(pts, degree: 2) { cands.append(.init(model: "Quadratic", equation: polyEq(f), predict: f.predict, params: 3)) }
        if cleaned.count >= 5, let f = polynomialFit(pts, degree: 3) { cands.append(.init(model: "Cubic", equation: polyEq(f), predict: f.predict, params: 4)) }
        if pts.allSatisfy({ $0.y > 0.0001 }), let f = exponentialFit(pts) { cands.append(.init(model: "Exponential", equation: expEq(f), predict: f.predict, params: 2)) }
        if pts.allSatisfy({ $0.x > 0.0001 && $0.y > 0.0001 }), let f = powerFit(pts) { cands.append(.init(model: "Power", equation: powerEq(f), predict: f.predict, params: 2)) }

        // Score by R² (recomputed in DATA space for a fair comparison) minus a small complexity penalty,
        // so we prefer the simpler model unless a more complex one fits clearly better.
        let scored = cands.compactMap { c -> (Candidate, Double)? in
            let r2 = rSquared(pts, predict: c.predict)
            return r2.isFinite ? (c, r2) : nil
        }
        guard let best = scored.max(by: { ($0.1 - 0.02 * Double($0.0.params)) < ($1.1 - 0.02 * Double($1.0.params)) }) else { return nil }

        let lo = pts.map(\.x).min()!, hi = pts.map(\.x).max()!
        let step = max((hi - lo) / 80, 1e-6)
        let curve: [[Double]] = stride(from: lo, through: hi, by: step).compactMap {
            let y = best.0.predict($0); return y.isFinite ? [$0, y] : nil
        }
        return FitGraphState(points: pts.map { [$0.x, $0.y] }, curve: curve, equation: best.0.equation,
                             rSquared: max(0, min(1, best.1)), model: best.0.model)
    }

    /// Sort by x and collapse near-equal x (a vertical wiggle) by averaging y, so the input is a function.
    private static func dedupByX(_ p: [Point2D]) -> [Point2D] {
        var out: [Point2D] = []
        for pt in p.sorted(by: { $0.x < $1.x }) {
            if let last = out.last, abs(last.x - pt.x) < 1e-6 { out[out.count - 1] = Point2D(x: last.x, y: (last.y + pt.y) / 2) }
            else { out.append(pt) }
        }
        return out
    }

    // MARK: Equation formatting
    private static func num(_ x: Double) -> String {
        abs(x) < 1e-9 ? "0" : String(format: "%.3g", x)
    }
    private static func term(_ coef: Double, _ pow: String, leading: Bool) -> String {
        if leading { return "\(num(coef))\(pow)" }
        return "\(coef >= 0 ? "+ " : "- ")\(num(abs(coef)))\(pow)"
    }
    private static func linearEq(_ f: LinearFit) -> String {
        "y = " + term(f.slope, "x", leading: true) + " " + term(f.intercept, "", leading: false)
    }
    private static func polyEq(_ f: PolyFit) -> String {
        let c = f.coefficients   // c0 + c1·x + c2·x² + …
        var parts: [String] = []
        for d in stride(from: c.count - 1, through: 0, by: -1) {
            let pow = d == 0 ? "" : (d == 1 ? "x" : (d == 2 ? "x²" : (d == 3 ? "x³" : "x^\(d)")))
            parts.append(term(c[d], pow, leading: parts.isEmpty))
        }
        return "y = " + parts.joined(separator: " ")
    }
    private static func expEq(_ f: ExpFit) -> String { "y = \(num(f.a))·e^(\(num(f.b))x)" }
    private static func powerEq(_ f: PowerFit) -> String { "y = \(num(f.a))·x^\(num(f.b))" }
}
