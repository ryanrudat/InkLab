import Foundation

/// Exact symbolic differentiation on the `Expr` AST (structure-preserving, so known functions get
/// their real derivatives). The result is canonicalized and compared exactly — this is how the tutor
/// verifies a derivative step, and (by differentiating the student's antiderivative) an integral step.
///
/// Other variables are treated as constants. Unknown/unsupported forms differentiate to an opaque
/// marker, which the tutor's correct-or-silent guard turns into "unsupported" rather than a false
/// accusation.
public func differentiate(_ e: Expr, _ x: String) -> Expr {
    func d(_ e: Expr) -> Expr { differentiate(e, x) }
    switch e {
    case .num:
        return .num(.zero)
    case .variable(let v):
        return .num(v == x ? .one : .zero)
    case .neg(let a):
        return .neg(d(a))
    case .add(let a, let b):
        return .add(d(a), d(b))
    case .sub(let a, let b):
        return .sub(d(a), d(b))
    case .mul(let a, let b):                              // product rule
        return .add(.mul(d(a), b), .mul(a, d(b)))
    case .div(let a, let b):                              // quotient rule
        return .div(.sub(.mul(d(a), b), .mul(a, d(b))), .pow(b, .num(Rational(2))))
    case .pow(let base, let exp):
        if let n = constantRational(exp) {               // power rule + chain: d(u^n) = n·u^(n-1)·u'
            return .mul(.mul(.num(n), .pow(base, .num(n - .one))), d(base))
        }
        if constantRational(base) != nil {               // exponential rule: d(a^u) = a^u·ln(a)·u'
            return .mul(.mul(e, .funcApp("ln", [base])), d(exp))
        }
        return opaque(e)
    case .funcApp(let name, let args) where args.count == 1:
        let u = args[0], du = d(u)                        // chain rule on known functions
        switch name {
        case "sin":  return .mul(.funcApp("cos", [u]), du)
        case "cos":  return .mul(.neg(.funcApp("sin", [u])), du)
        case "tan":  return .mul(.div(.num(.one), .pow(.funcApp("cos", [u]), .num(Rational(2)))), du)
        case "exp":  return .mul(.funcApp("exp", [u]), du)
        case "ln":   return .mul(.div(.num(.one), u), du)
        case "sqrt": return .mul(.div(.num(.one), .mul(.num(Rational(2)), .funcApp("sqrt", [u]))), du)
        default:     return opaque(e)
        }
    case .deriv(let inner, let v):                        // higher-order: d/dx(d/dv(inner))
        return differentiate(differentiate(inner, v), x)
    default:
        return opaque(e)
    }
}

private func opaque(_ e: Expr) -> Expr { .funcApp("∂", [e]) }

/// The exact rational value of `e` if it is a constant, else nil.
func constantRational(_ e: Expr) -> Rational? {
    let rf = canonicalize(e)
    guard let n = rf.num.constantValue, let d = rf.den.constantValue, !d.isZero else { return nil }
    return n / d
}
