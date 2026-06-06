import Foundation
import InkLabMath

public enum ReactiveError: Error, Equatable, Sendable {
    case parse(cell: String, message: String)
    case cycle([String])           // the names involved in a dependency cycle
    case undefined(String)         // a referenced cell that doesn't exist (or can't evaluate)
}

/// A spreadsheet-like dependency graph. Inputs are "knobs" you set; formula cells are expressions
/// over other cells (parsed by InkLabMath). `evaluate()` recomputes everything in dependency order
/// — change one input and all downstream values update — and detects cycles.
public final class ReactiveGraph {
    private enum Def {
        case input(Double)
        case formula(Expr, deps: Set<String>)
    }
    private var cells: [String: Def] = [:]

    public init() {}

    /// Set (or replace) an input "knob".
    public func setInput(_ name: String, _ value: Double) {
        cells[name] = .input(value)
    }

    /// Set (or replace) a formula cell, e.g. setFormula("area", "3.14159 * r^2").
    public func setFormula(_ name: String, _ formula: String) throws {
        do {
            let expr = try parseExpr(formula, multiLetterVariables: true)   // "price", "taxRate", …
            cells[name] = .formula(expr, deps: variables(in: expr))
        } catch {
            throw ReactiveError.parse(cell: name, message: "\(error)")
        }
    }

    public func remove(_ name: String) { cells[name] = nil }
    public var cellNames: Set<String> { Set(cells.keys) }

    /// Recompute every cell in dependency order. Returns all values, or the first error (a cycle, or
    /// a reference to a missing/undefined cell).
    public func evaluate() -> Result<[String: Double], ReactiveError> {
        // Topological sort via DFS, detecting cycles.
        var state: [String: Int] = [:]   // 0 unvisited, 1 visiting, 2 done
        var order: [String] = []
        var cycle: [String]? = nil

        func visit(_ n: String, _ stack: [String]) {
            if cycle != nil { return }
            switch state[n] ?? 0 {
            case 2: return
            case 1:
                // back-edge: the cycle is from n's earlier appearance to here
                if let i = stack.firstIndex(of: n) { cycle = Array(stack[i...]) } else { cycle = stack + [n] }
                return
            default: break
            }
            state[n] = 1
            if case .formula(_, let deps) = cells[n] {
                for d in deps where cells[d] != nil { visit(d, stack + [n]) }
            }
            state[n] = 2
            order.append(n)
        }

        for name in cells.keys.sorted() { visit(name, []) }   // sorted: deterministic cycle reporting
        if let cycle { return .failure(.cycle(cycle)) }

        // Evaluate in dependency order (deps before dependents).
        var env: [String: Double] = [:]
        for name in order {
            switch cells[name]! {
            case .input(let v):
                env[name] = v
            case .formula(let expr, let deps):
                for d in deps where cells[d] == nil { return .failure(.undefined(d)) }
                guard let value = numericValue(expr, env) else { return .failure(.undefined(name)) }
                env[name] = value
            }
        }
        return .success(env)
    }
}
