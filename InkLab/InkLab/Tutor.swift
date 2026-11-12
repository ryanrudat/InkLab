import Foundation
import UIKit
import InkLabKit

// The Socratic tutor. READ → COMPUTE → TALK:
//  • READ    the selected problem + working with the same recognizer as Check work (`bestRead`).
//  • COMPUTE the verdict with the deterministic red pen (`checkChain`), and what must never be handed
//            over with `problemFacts` (InkLabMath). Every step the student writes back is re-checked
//            by the engine too (`checkAttempt`), so no model ever decides correctness.
//  • TALK    via the proxy (`POST /tutor`), which picks the hint-ladder rung, calls Claude, and guards
//            the reply against leaking the answer. The app checks the reply again with the exact engine
//            (`tutorReplyLeak`) before anything reaches the page.
//
// Each tutor message is a journaled callout next to the problem. The conversation state rides in the
// callout's provenance JSON, so the journal is the single source of truth: undoing a tutor message
// rewinds the thread, deleting the callouts ends the session, and a relaunch picks it back up.

// MARK: - Wire format (mirrors Server/src/tutor.ts)

enum StepCheck: String, Codable, Sendable, Equatable { case follows, doesNotFollow, cannotCheck }

struct TutorTurn: Codable, Sendable, Equatable {
    enum Role: String, Codable, Sendable { case tutor, student }
    var role: Role
    var text: String
    var check: StepCheck? = nil
    var wantsHint: Bool? = nil
    /// The student asked about the math ("so is x = 2?") instead of writing it as a step: checked, not
    /// added to the working.
    var question: Bool? = nil
}

/// A verified step the student wrote in a reply, folded into the working: from `line` (1-based, in the
/// working) the lines `from` were replaced by `to`; an empty `from` means steps added at the end.
struct TutorCorrection: Codable, Sendable, Equatable {
    var line: Int
    var from: [String]
    var to: [String]
}

struct TutorWireVerdict: Codable, Sendable, Equatable {
    var kind: String
    var steps: Int? = nil
    var line: Int? = nil
    var explanation: String? = nil
    var counterexample: String? = nil
    var reason: String? = nil

    init(_ v: TutorVerdict) {
        switch v {
        case .allValid(let steps): kind = "allValid"; self.steps = steps
        case .firstError(let line, _, let explanation, let counterexample):
            kind = "firstError"; self.line = line; self.explanation = explanation; self.counterexample = counterexample
        case .unsupported(let line, let reason): kind = "unsupported"; self.line = line; self.reason = reason
        }
    }
}

struct TutorWireTarget: Codable, Sendable, Equatable {
    var kind: String
    var value: String
    var variable: String? = nil
}

struct TutorRequest: Codable, Sendable {
    var session: MakeRealSession
    /// The working as written on the page ("line N" always means one of these).
    var lines: [String]
    /// The working as the engine now understands it, after the corrections.
    var working: [String]
    var corrections: [TutorCorrection]
    var chain: String
    var verdict: TutorWireVerdict
    var protected: [TutorWireTarget]
    var thread: [TutorTurn]
    var strict: Bool
}

struct TutorReply: Codable, Sendable, Equatable {
    var reply: String
    var rung: Int
    /// "clean" | "regenerated" | "fallback" — how the proxy's leak guard produced the reply.
    var guardOutcome: String
    enum CodingKeys: String, CodingKey { case reply, rung, guardOutcome = "guard" }
}

// MARK: - Session state

/// One tutoring conversation about one problem. `pageLines` is what the page shows (and never changes);
/// `lines` is the working as the engine currently understands it — a verified step the student writes in
/// a reply replaces the wrong line (recorded in `corrections`, so the tutor knows what changed). Verdict
/// and protected results are derived from `lines`.
struct TutorSession: Codable, Sendable, Equatable {
    var id = UUID()
    /// The selected problem's bounds in page content coordinates.
    var problem: CGRect
    /// The working as read from the page, one step per line.
    var pageLines: [String]
    /// Where each page line's ink is (content coordinates): the margin note points at one of them.
    var lineRects: [CGRect]
    /// The page line the note points at: the one the verdict was about when the session started.
    var anchorLine: Int
    var lines: [String]
    var corrections: [TutorCorrection] = []
    var thread: [TutorTurn] = []
    var rung = 1

    static let maxRung = 4

    var verdict: TutorVerdict { checkChain(lines) }
    var facts: ProblemFacts? { problemFacts(lines) }

    /// Split a transcription into steps exactly as the red pen does (one step per line, or `;`).
    static func steps(from read: String) -> [String] {
        read.split(whereSeparator: { $0 == "\n" || $0 == ";" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Start a session on freshly read working, or say why not (nothing the engine can work with).
    /// `strokes` are the page's ink bounds, used to find each line on the page.
    static func start(read: String, problem: CGRect, strokes: [CGRect] = []) -> Result<TutorSession, TutorStartError> {
        let lines = steps(from: read)
        guard !lines.isEmpty else { return .failure(.nothingRead) }
        guard lines.count <= 30, lines.allSatisfy({ $0.count <= 200 }) else { return .failure(.tooLong) }
        let anchor: Int
        switch checkChain(lines) {
        case .firstError(let line, _, _, _), .unsupported(let line, _): anchor = min(max(1, line), lines.count)
        case .allValid: anchor = lines.count
        }
        return .success(TutorSession(problem: problem, pageLines: lines,
                                     lineRects: TutorLayout.lineRects(strokes: strokes, problem: problem, count: lines.count),
                                     anchorLine: anchor, lines: lines))
    }

    /// The page line the note points at, in content coordinates.
    var anchorRect: CGRect {
        lineRects.indices.contains(anchorLine - 1) ? lineRects[anchorLine - 1] : problem
    }

    /// The request for the next tutor message (the proxy is stateless: the whole thread, every turn).
    func request(session consent: MakeRealSession, strict: Bool = false) -> TutorRequest {
        let facts = self.facts
        return TutorRequest(session: consent, lines: pageLines, working: lines, corrections: corrections,
                            chain: (facts?.chain ?? .expression).rawValue,
                            verdict: TutorWireVerdict(verdict),
                            protected: facts.map { Self.wireTargets($0.protected) } ?? [],
                            thread: thread, strict: strict)
    }

    /// The engine's protected results in the proxy's ASCII grammar. A result the renderer can't express
    /// is left out; with nothing left, the proxy answers with a generic hint and never calls the model.
    static func wireTargets(_ results: [ProtectedResult]) -> [TutorWireTarget] {
        results.compactMap { r in
            switch r {
            case .expression(let e): return renderTutorASCII(e).map { TutorWireTarget(kind: "expression", value: $0) }
            case .equation(let l, let rr):
                guard let a = renderTutorASCII(l), let b = renderTutorASCII(rr) else { return nil }
                return TutorWireTarget(kind: "equation", value: "\(a) = \(b)")
            case .antiderivative(let f, let v):
                return renderTutorASCII(f).map { TutorWireTarget(kind: "antiderivative", value: $0, variable: v) }
            }
        }
    }

    /// Everything the student wrote (their page lines, their working, their replies) — quoting it back is
    /// never a leak.
    var studentWrote: Set<String> {
        studentMathKeys(pageLines + lines + thread.filter { $0.role == .student }.map(\.text))
    }

    /// A question is asked, not written as a step: it ends with "?" or opens like one.
    static func isQuestion(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if t.hasSuffix("?") { return true }
        let first = t.split(whereSeparator: { !$0.isLetter && $0 != "'" }).first.map(String.init) ?? ""
        return ["is", "isn't", "what", "why", "how", "can", "does", "do", "should", "could", "would", "will",
                "am", "are", "which", "where", "when"].contains(first)
    }

    // MARK: Checking a step the student writes back (deterministic)

    /// Where a new step goes: in place of the first line that didn't follow (or couldn't be checked),
    /// or after the last line when everything so far checks out.
    var replaceFrom: Int {
        switch verdict {
        case .firstError(let line, _, _, _), .unsupported(let line, _): return max(0, line - 1)
        case .allValid: return lines.count
        }
    }

    /// The math steps in a reply, if it is an attempt: a reply that is all math (one step per line), or
    /// failing that, the last equation inside a sentence ("is it 2x = 4?").
    static func attemptLines(in reply: String) -> [String] {
        let rows = steps(from: reply)
        let whole = rows.compactMap { step(in: $0) }
        if !rows.isEmpty, whole.count == rows.count { return whole }
        if let eq = extractTutorMath(reply).last(where: { if case .equation = $0 { return true }; return false }) {
            return [eq.text]
        }
        return []
    }

    /// The row as a step of working, or nil when it is prose. (The parser reads almost anything as a
    /// product of letters, so "is this math?" is decided by the reply extractor, which splits prose.)
    static func step(in row: String) -> String? {
        let n = normalizeTutorMath(row).trimmingCharacters(in: .whitespaces)
        if n.contains("∫") || n.contains("d/d") {          // a calculus claim: the engine's parser decides
            if case .unsupported(_, let reason) = checkChain([n]), reason.hasPrefix("couldn't read") { return nil }
            return n
        }
        let body = n.hasPrefix("=") ? String(n.dropFirst()).trimmingCharacters(in: .whitespaces) : n
        guard body.rangeOfCharacter(from: CharacterSet(charactersIn: "0123456789=+-*/^")) != nil else { return nil }
        let key = tutorMathKey(body)
        return extractTutorMath(body).contains(where: { tutorMathKey($0.text) == key }) ? n : nil
    }

    /// Run the red pen on the student's new step(s) in context. Returns nil when the reply has no math.
    func checkAttempt(_ reply: String) -> (check: StepCheck, lines: [String])? {
        var attempt = Self.attemptLines(in: reply)
        guard !attempt.isEmpty else { return nil }
        let prefix = Array(lines.prefix(replaceFrom))
        // A one-line calculus claim ("d/dx(x^2) = x") corrected with just a result ("2x"): keep the claim.
        if prefix.isEmpty, let first = lines.first, let eq = first.firstIndex(of: "="),
           first.contains("∫") || first.contains("d/d"),
           !attempt[0].contains("="), !attempt[0].contains("∫"), !attempt[0].contains("d/d") {
            attempt[0] = "\(first[..<eq].trimmingCharacters(in: .whitespaces)) = \(attempt[0])"
        }
        let candidate = prefix + attempt
        switch checkChain(candidate) {
        case .allValid: return (.follows, candidate)
        case .firstError: return (.doesNotFollow, lines)
        case .unsupported: return (.cannotCheck, lines)
        }
    }

    /// Record the student's reply (any math in it checked by the engine) and return the updated session.
    /// A verified step replaces the wrong line and is recorded as a correction; a question is checked but
    /// never folded into the working — the page doesn't show it and the student hasn't written it.
    func addingStudentReply(_ text: String, wantsHint: Bool) -> TutorSession {
        var next = self
        let trimmed = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(1000))
        let question = !wantsHint && Self.isQuestion(trimmed)
        let checked = wantsHint ? nil : checkAttempt(trimmed)
        next.thread.append(TutorTurn(role: .student, text: trimmed.isEmpty ? "Another hint, please." : trimmed,
                                     check: checked?.check, wantsHint: wantsHint ? true : nil,
                                     question: question ? true : nil))
        if let checked, checked.check == .follows, !question {
            let from = replaceFrom
            next.corrections.append(TutorCorrection(line: from + 1, from: Array(lines[from...]),
                                                    to: Array(checked.lines[from...])))
            next.lines = checked.lines
        }
        return next
    }
}

enum TutorStartError: Error, Equatable {
    case nothingRead, tooLong
    var message: String {
        switch self {
        case .nothingRead: return "Couldn't read your working — try writing larger and clearer."
        case .tooLong: return "That's a lot of working — lasso just one problem for the tutor."
        }
    }
}

// MARK: - The app's own answer-leak check (exact, after the proxy's numeric one)

enum TutorGuard {
    /// The first thing in `reply` that gives the answer away, by the engine's exact equivalence.
    static func leak(in reply: String, session: TutorSession) -> String? {
        guard let facts = session.facts else { return nil }
        return tutorReplyLeak(reply, protected: facts.protected, studentWrote: session.studentWrote)
    }

    /// Math-free last resort when even a strict regeneration leaks (fail closed).
    static func genericHint(for session: TutorSession) -> String {
        switch session.verdict {
        case .firstError(let line, _, _, _) where line <= session.pageLines.count && session.corrections.isEmpty:
            return "Look again at line \(line): what did you do to get there from the line above?"
        case .firstError, .unsupported:
            return "My checker can't confirm that step yet, so I won't guess. What did you do in it?"
        case .allValid:
            return session.corrections.isEmpty ? "Every step so far checks out. What do you think comes next?"
                                               : "Your working checks out now. What do you think comes next?"
        }
    }
}

// MARK: - Talking to the proxy

protocol TutorProvider: Sendable {
    func reply(to request: TutorRequest) async throws -> TutorReply
}

enum Tutor {
    static var provider: TutorProvider = ProxyTutorProvider()

    /// One guarded tutor turn: ask the proxy; if the app's exact check still finds a leak, ask once more
    /// with the strict instruction; if that leaks too, use a generic hint. Never returns leaked math.
    static func nextMessage(for session: TutorSession, consent: MakeRealSession,
                            provider custom: TutorProvider? = nil) async throws -> TutorReply {
        let provider = custom ?? Tutor.provider
        let first = try await provider.reply(to: session.request(session: consent))
        guard TutorGuard.leak(in: first.reply, session: session) != nil else { return first }
        if let second = try? await provider.reply(to: session.request(session: consent, strict: true)),
           TutorGuard.leak(in: second.reply, session: session) == nil {
            return second
        }
        return TutorReply(reply: TutorGuard.genericHint(for: session), rung: first.rung, guardOutcome: "fallback")
    }
}

struct ProxyTutorProvider: TutorProvider {
    var baseURL = InkLabProxy.baseURL
    /// Just over the proxy's 45 s whole-request budget (two drafts at most).
    static let requestTimeout: TimeInterval = 50

    func reply(to request: TutorRequest) async throws -> TutorReply {
        var req = URLRequest(url: baseURL.appendingPathComponent("tutor"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        InkLabProxy.authorize(&req)
        req.timeoutInterval = Self.requestTimeout
        req.httpBody = try JSONEncoder().encode(request)

        let data: Data, resp: URLResponse
        do {
            (data, resp) = try await URLSession.shared.data(for: req)
        } catch let error as URLError {
            throw MakeRealError.notConfigured(Self.message(for: error))
        } catch {
            throw MakeRealError.notConfigured(Self.unreachable)
        }
        guard let http = resp as? HTTPURLResponse else { throw MakeRealError.server("No answer from the tutor.") }
        guard http.statusCode == 200 else {
            let error = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["error"] as? String
            throw MakeRealError.server(Self.message(status: http.statusCode, error: error))
        }
        return try JSONDecoder().decode(TutorReply.self, from: data)
    }

    static let unreachable = "The tutor isn't reachable. Start the Server (see Server/README) and try again."
    static let tooSlow = "The tutor took too long to answer. Try again."

    static func message(for error: URLError) -> String {
        switch error.code {
        case .timedOut: return tooSlow
        case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .internationalRoamingOff:
            return "You're offline — the tutor needs a connection."
        default: return unreachable
        }
    }

    static func message(status: Int, error: String?) -> String {
        switch error {
        case "tutor timed out": return tooSlow
        case "upstream error": return "The tutor is unavailable right now. Try again in a moment."
        case "unauthorized": return "The tutor rejected this app (check MakeRealProxySecret)."
        case "invalid engine result", "invalid lines", "invalid verdict", "invalid protected", "invalid thread", "invalid chain":
            return "The tutor couldn't use that working. Lasso one problem and try again."
        case let reason? where !reason.isEmpty: return reason    // e.g. the consent gate's reason (403)
        default: return "Tutor error (status \(status))."
        }
    }
}

// MARK: - Callouts on the page

/// What the tutor note carries in its provenance JSON: the session as of its latest message.
struct TutorCalloutProvenance: Codable, Equatable {
    var tutor: TutorSession
    var turn: Int

    var json: String {
        (try? String(data: JSONEncoder().encode(self), encoding: .utf8)) ?? "{}"
    }

    static func decode(_ json: String) -> TutorCalloutProvenance? {
        guard json.contains("\"tutor\""), let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(TutorCalloutProvenance.self, from: data)
    }
}

/// A tutor note that is on the page right now.
struct TutorCallout: Equatable {
    var objectID: UUID
    var provenance: TutorCalloutProvenance
    var frame: CGRect
}

enum TutorLayout {
    /// How the engine's check of a student step reads in the thread.
    static func checkMark(_ check: StepCheck?) -> String {
        switch check {
        case .follows?: return "✓ checks out"
        case .doesNotFollow?: return "✗ doesn't follow yet"
        case .cannotCheck?: return "? can't check"
        case nil: return ""
        }
    }

    /// The page's lines of ink inside the problem, top to bottom: strokes grouped into rows by vertical
    /// overlap. When that doesn't give one row per transcribed line, the problem is split evenly instead.
    static func lineRects(strokes: [CGRect], problem: CGRect, count: Int) -> [CGRect] {
        guard count > 0 else { return [] }
        var rows: [CGRect] = []
        for r in strokes.filter({ $0.intersects(problem) && !$0.isNull }).sorted(by: { $0.midY < $1.midY }) {
            if let last = rows.last {
                let overlap = min(last.maxY, r.maxY) - max(last.minY, r.minY)
                if overlap > 0.3 * min(max(last.height, 1), max(r.height, 1)) { rows[rows.count - 1] = last.union(r); continue }
            }
            rows.append(r)
        }
        if rows.count == count { return rows }
        let h = problem.height / CGFloat(count)
        return (0..<count).map { CGRect(x: problem.minX, y: problem.minY + CGFloat($0) * h, width: problem.width, height: h) }
    }

    /// Where the margin note goes: level with the line it is about, to the right of all the ink in its band
    /// (leaving room for the note to grow as the conversation goes on), so it never covers the student's
    /// writing. With no room in the margin, it goes under the ink below the problem.
    static func marginFrame(size: CGSize, anchor: CGRect, problem: CGRect, ink: [CGRect], canvasWidth: CGFloat,
                            growth: CGFloat = 160) -> CGRect {
        let y = max(8, anchor.midY - 22)
        func hits(_ rect: CGRect) -> [CGRect] { ink.filter { !$0.isNull && $0.insetBy(dx: -8, dy: -8).intersects(rect) } }
        for room in [growth, 0] {
            var rect = CGRect(x: max(problem.maxX, anchor.maxX) + 28, y: y, width: size.width, height: size.height + room)
            for _ in 0..<50 {
                let blocking = hits(rect)
                if blocking.isEmpty { break }
                rect.origin.x = (blocking.map(\.maxX).max() ?? rect.minX) + 16
            }
            if rect.maxX <= canvasWidth - 8, hits(rect).isEmpty { return CGRect(origin: rect.origin, size: size) }
        }
        let x = max(8, min(problem.minX, canvasWidth - size.width - 8))
        let column = CGRect(x: x, y: problem.minY, width: size.width, height: .greatestFiniteMagnitude)
        let below = (hits(column).map(\.maxY) + [problem.maxY]).max()! + 16
        return CGRect(x: x, y: below, width: size.width, height: size.height)
    }

    /// Ink written here (after a pause) is a reply to the session: around the problem and its note.
    static func replyZone(problem: CGRect, callouts: [CGRect]) -> CGRect {
        callouts.reduce(problem) { $0.union($1) }.insetBy(dx: -100, dy: -100)
    }

    /// Every tutor session on a page. A session is ONE note object whose payload is replaced per message
    /// (`promote`), so this is normally one callout per session; the newest wins if there are more.
    static func sessions(on page: PageProjection) -> [(latest: TutorCallout, all: [TutorCallout])] {
        var bySession: [UUID: [TutorCallout]] = [:]
        for obj in page.objects.values where !obj.isDeleted {
            guard case .callout(_, _, let json) = obj.payload, let prov = TutorCalloutProvenance.decode(json) else { continue }
            let t = obj.transform
            bySession[prov.tutor.id, default: []].append(
                TutorCallout(objectID: obj.objectID, provenance: prov, frame: CGRect(x: t.x, y: t.y, width: t.width, height: t.height)))
        }
        return bySession.values.compactMap { all in
            all.max(by: { $0.provenance.turn < $1.provenance.turn }).map { (latest: $0, all: all) }
        }
    }
}

extension TutorSession {
    /// The proxy accepts 40 turns; stop a little before so the next reply always fits.
    static let maxThread = 36
}

extension MakeRealSession {
    /// The consent gate in the tutor's own words (the proxy re-checks it — `cloudEligible`).
    var tutorBlockReason: String? {
        if !isOnline { return "You're offline — the tutor needs a connection." }
        if !aiConsentGranted { return "Turn on “Allow AI generation” in Settings to use the tutor (it sends your working to Anthropic)." }
        return blockReason
    }
}
