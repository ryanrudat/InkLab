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
        case .unfinished(let line): kind = "unfinished"; self.line = line
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
    /// "writing" for English / History (Server/src/writingTutor.ts); nil for math.
    var mode: String? = nil
    /// The working as written on the page ("line N" always means one of these), or the writing as read.
    var lines: [String]
    /// Math only: the working as the engine now understands it, after the corrections.
    var working: [String]? = nil
    var corrections: [TutorCorrection]? = nil
    var chain: String? = nil
    var verdict: TutorWireVerdict? = nil
    var protected: [TutorWireTarget]? = nil
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

/// What &Co is helping with. Math working is checked line by line by the red pen; writing (English,
/// History: a paragraph, an answer, notes) has no checker, so &Co only asks questions about it.
enum TutorMode: String, Codable, Sendable { case writing }

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
    /// nil = math (and every session saved before the tutor took writing).
    var mode: TutorMode? = nil
    /// What &Co's latest message points at on the page (the words it quotes, the line it names), in
    /// content coordinates. nil when it points at nothing in particular.
    var focus: [CGRect]? = nil

    static let maxRung = 4

    var isWriting: Bool { mode == .writing }
    /// The red pen's verdict. Math only: writing has no checker (never ask for it on a writing session).
    var verdict: TutorVerdict { checkChain(lines) }
    var facts: ProblemFacts? { isWriting ? nil : problemFacts(lines) }

    /// Prose, not math working: a few words, and no line that reads as a step of working. A history answer
    /// with a year in it ("taxes in 1861") is still writing; "2x + 3 = 7" or "1+3=" is math.
    static func looksLikeWriting(_ read: String) -> Bool {
        let words = read.split(whereSeparator: { !$0.isLetter && $0 != "'" }).filter { $0.count >= 2 }
        guard words.count >= 4 else { return false }
        return !steps(from: read).contains { step(in: $0) != nil }
    }

    /// Writing, one handwritten line each (only line breaks split it: a ";" is punctuation in prose). A
    /// typed paragraph is cut at word boundaries into lines the proxy accepts.
    static func writingLines(from read: String) -> [String] {
        read.split(whereSeparator: \.isNewline).flatMap { row -> [String] in
            var out: [String] = [], line = ""
            for word in row.split(whereSeparator: \.isWhitespace) {
                if !line.isEmpty, line.count + 1 + word.count > 200 { out.append(line); line = "" }
                line += line.isEmpty ? String(word.prefix(200)) : " \(word)"
            }
            return line.isEmpty ? out : out + [line]
        }
    }

    /// The page lines a reading becomes, as `start` would split it.
    static func pageLines(from read: String) -> [String] {
        looksLikeWriting(read) ? writingLines(from: read) : steps(from: read)
    }

    /// `text` reads the same as what's on the note already (so correcting it to that changes nothing).
    func readsTheSame(as text: String) -> Bool {
        guard Self.looksLikeWriting(text) == isWriting else { return false }
        guard isWriting else { return Self.steps(from: text) == pageLines }
        let words = { (s: String) in s.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }) }
        return words(text) == words(pageLines.joined(separator: " "))
    }

    /// Split a transcription into steps exactly as the red pen does (one step per line, or `;`).
    static func steps(from read: String) -> [String] {
        read.split(whereSeparator: { $0 == "\n" || $0 == ";" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Start a session on freshly read working, or say why not (nothing the engine can work with).
    /// `strokes` are the page's ink bounds, used to find each line on the page.
    static func start(read: String, problem: CGRect, strokes: [CGRect] = []) -> Result<TutorSession, TutorStartError> {
        let writing = looksLikeWriting(read)
        let lines = writing ? writingLines(from: read) : steps(from: read)
        guard !lines.isEmpty else { return .failure(.nothingRead) }
        guard lines.count <= 30, lines.allSatisfy({ $0.count <= 200 }) else { return .failure(.tooLong) }
        if writing {    // no verdict to point at: the note sits level with the first line
            return .success(TutorSession(problem: problem, pageLines: lines,
                                         lineRects: TutorLayout.lineRects(strokes: strokes, problem: problem, count: lines.count),
                                         anchorLine: 1, lines: lines, mode: .writing))
        }
        let anchor: Int
        switch checkChain(lines) {
        case .firstError(let line, _, _, _), .unsupported(let line, _), .unfinished(let line):
            anchor = min(max(1, line), lines.count)
        case .allValid: anchor = lines.count
        }
        return .success(TutorSession(problem: problem, pageLines: lines,
                                     lineRects: TutorLayout.lineRects(strokes: strokes, problem: problem, count: lines.count),
                                     anchorLine: anchor, lines: lines))
    }

    /// Nothing could be read from the page: the note says so and offers to rewrite or type the problem.
    /// No verdict and nothing for the proxy; the next reading (or typed problem) starts the session.
    var isUnread: Bool { pageLines.isEmpty }
    /// The tutor's name: on its notes ("&Co · hint 1 of 4"), beside its earlier messages, and in what the
    /// app says about it while you work with it.
    static let tutorName = "&Co"
    static let unreadMessage = "I couldn't read that. Can you write it again a little larger, or type it?"

    static func unread(problem: CGRect) -> TutorSession {
        var s = TutorSession(problem: problem, pageLines: [], lineRects: [], anchorLine: 0, lines: [])
        s.thread = [TutorTurn(role: .tutor, text: unreadMessage)]
        return s
    }

    /// The conversation started over on a new reading of the problem: the student corrected what was read,
    /// or rewrote or typed a problem that couldn't be read. A fresh verdict, no corrections (they didn't
    /// fix their work, only the reading), an empty thread and hint 1. The id stays, so the same note is
    /// updated, and one undo goes back to the old reading.
    func restarted(read: String, problem newProblem: CGRect? = nil, strokes: [CGRect]) -> Result<TutorSession, TutorStartError> {
        TutorSession.start(read: read, problem: newProblem ?? problem, strokes: strokes).map { fresh in
            var s = fresh
            s.id = id
            return s
        }
    }

    /// What the note shows as read ("I read: 2x + 3 = 7 · 2x = 10"), so a misreading can be caught.
    /// Writing reads as one passage (its line breaks are only where the handwriting wrapped).
    var readAs: String { pageLines.joined(separator: isWriting ? " " : "  ·  ") }

    /// Where the note points, in content coordinates: what the latest message is about, else the line the
    /// verdict was about.
    var anchorRect: CGRect {
        if let first = focus?.first { return first }
        return lineRects.indices.contains(anchorLine - 1) ? lineRects[anchorLine - 1] : problem
    }

    /// The request for the next tutor message (the proxy is stateless: the whole thread, every turn).
    func request(session consent: MakeRealSession, strict: Bool = false) -> TutorRequest {
        if isWriting {
            return TutorRequest(session: consent, mode: TutorMode.writing.rawValue, lines: pageLines, thread: thread, strict: strict)
        }
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

    /// Where a new step goes: in place of the first line that didn't follow (or couldn't be checked, or
    /// isn't finished), or after the last line when everything so far checks out.
    var replaceFrom: Int {
        switch verdict {
        case .firstError(let line, _, _, _), .unsupported(let line, _), .unfinished(let line): return max(0, line - 1)
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
        if attempt.isEmpty, case .unfinished = verdict,               // "is it 4?" answers "1 + 3 =" too
           let last = extractTutorMath(reply).last(where: { if case .expression = $0 { return true }; return false }) {
            attempt = [last.text]
        }
        guard !attempt.isEmpty else { return nil }
        let prefix = Array(lines.prefix(replaceFrom))
        // An answer to an unfinished line ("4" for "1 + 3 =") finishes that line, and is checked as such.
        if case .unfinished(let line) = verdict, lines.indices.contains(line - 1) {
            attempt[0] = completingUnfinished(lines[line - 1], with: attempt[0])
        }
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
        case .unsupported, .unfinished: return (.cannotCheck, lines)   // a reply that is itself unfinished: nothing to check yet
        }
    }

    /// Record the student's reply (any math in it checked by the engine) and return the updated session.
    /// A verified step replaces the wrong line and is recorded as a correction; a question is checked but
    /// never folded into the working — the page doesn't show it and the student hasn't written it.
    func addingStudentReply(_ text: String, wantsHint: Bool) -> TutorSession {
        var next = self
        let trimmed = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(1000))
        if isWriting {     // nothing to check: it's a message
            next.thread.append(TutorTurn(role: .student, text: trimmed.isEmpty ? "Another hint, please." : trimmed,
                                         wantsHint: wantsHint ? true : nil))
            return next
        }
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
        case .tooLong: return "That's a lot to read at once — lasso just one problem or one paragraph."
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
        if session.isWriting { return "What's the main point you want your reader to take away from this?" }
        switch session.verdict {
        case .firstError(let line, _, _, _) where line <= session.pageLines.count && session.corrections.isEmpty:
            return "Look again at line \(line): what did you do to get there from the line above?"
        case .unfinished(let line) where line <= session.pageLines.count:
            return "Line \(line) isn't finished yet. What goes on the other side of its equals sign?"
        case .firstError, .unsupported, .unfinished:
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

    /// The page's lines of ink inside the problem, top to bottom, one per transcribed line (see
    /// `InkGeometry.lines`). With no ink to go on (a typed problem), the problem is split evenly.
    static func lineRects(strokes: [CGRect], problem: CGRect, count: Int) -> [CGRect] {
        guard count > 0 else { return [] }
        if let lines = InkGeometry.lines(strokes.filter { !$0.isNull && $0.intersects(problem) }, count: count) { return lines }
        let h = problem.height / CGFloat(count)
        return (0..<count).map { CGRect(x: problem.minX, y: problem.minY + CGFloat($0) * h, width: problem.width, height: h) }
    }

    /// Where the margin note goes: level with the line it is about, to the right of everything in its band
    /// (leaving room for the note to grow as the conversation goes on), so it never covers the student's
    /// writing or another object (a widget's controls, a sticky). With no room in the margin, it goes under
    /// everything below the problem. `avoiding` = ink bounds + object frames (see `obstacles`).
    static func marginFrame(size: CGSize, anchor: CGRect, problem: CGRect, avoiding: [CGRect], canvasWidth: CGFloat,
                            growth: CGFloat = 160) -> CGRect {
        let y = max(8, anchor.midY - 22)
        func hits(_ rect: CGRect) -> [CGRect] { avoiding.filter { !$0.isNull && $0.insetBy(dx: -8, dy: -8).intersects(rect) } }
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

    /// What the note must not cover: the page's ink plus every other live object on it (widgets, stickies,
    /// callouts, other tutors' notes). `except` is the note itself when it is being updated.
    static func obstacles(ink: [CGRect], page: PageProjection, except: UUID?) -> [CGRect] {
        ink + page.objects.values.filter { !$0.isDeleted && $0.objectID != except }.map {
            CGRect(x: $0.transform.x, y: $0.transform.y, width: $0.transform.width, height: $0.transform.height)
        }
    }

    /// A z above every object on the page, so the note is always drawn on top (objects otherwise all share
    /// the default rank, which leaves their order to chance).
    static func topZ(on page: PageProjection) -> FractionalIndex {
        let top = page.objects.values.filter { !$0.isDeleted }.map(\.z.rank).max() ?? "m"
        return FractionalIndex(max(top, "y") + "m")
    }

    /// Where "Write on the page" asks for the reply: a free strip under the problem (moved down past any
    /// ink or object in the way), at least `minWidth` wide, inside the page.
    static func writeZone(problem: CGRect, avoiding: [CGRect], canvasWidth: CGFloat,
                          height: CGFloat = TutorNoteStyle.current.writeZoneHeight, minWidth: CGFloat = 300) -> CGRect {
        let width = min(max(problem.width, minWidth), max(120, canvasWidth - 32))
        let x = min(max(16, problem.minX), max(16, canvasWidth - 16 - width))
        var zone = CGRect(x: x, y: problem.maxY + 12, width: width, height: height)
        for _ in 0..<40 {
            let hits = avoiding.filter { !$0.isNull && $0.insetBy(dx: -8, dy: -8).intersects(zone) }
            guard let lowest = hits.map(\.maxY).max() else { break }
            zone.origin.y = lowest + 16
        }
        return zone
    }

    /// A tutor conversation new ink might be a reply to: its problem and the frames of its note(s).
    struct ReplyCandidate {
        var id: UUID
        var problem: CGRect
        var notes: [CGRect]
    }

    /// Which conversation new ink (written after a pause) is a reply to, if any. It counts when it is in
    /// the open write-here space (`writeZone`, the session it was opened for), or when it belongs to that
    /// conversation's writing: it lands on the problem, joins the problem's own ink as one piece of writing
    /// (`InkGeometry.blocks`), or sits right by the note (about 1.5 letter heights). Writing that starts a
    /// piece of its own — a new problem lower on the page — is no conversation's reply, and neither is a
    /// batch where part of the new ink does. `oldInk`: the page's other strokes; the problem's own ink is
    /// the part of it on the problem. With several matches, the nearest problem wins.
    static func replyTarget(newInk: [CGRect], oldInk: [CGRect], sessions: [ReplyCandidate],
                            writeZone: (session: UUID, rect: CGRect)?) -> UUID? {
        let new = newInk.filter { !$0.isNull }
        guard let first = new.first else { return nil }
        if let zone = writeZone, sessions.contains(where: { $0.id == zone.session }),
           new.contains(where: { $0.intersects(zone.rect) }) { return zone.session }
        let written = new.dropFirst().reduce(first) { $0.union($1) }
        func distance(_ a: CGRect, _ b: CGRect) -> CGFloat {
            hypot(max(0, b.minX - a.maxX, a.minX - b.maxX), max(0, b.minY - a.maxY, a.minY - b.maxY))
        }
        return sessions
            .filter { s in joins(new, problem: s.problem, problemInk: oldInk.filter { !$0.isNull && $0.intersects(s.problem) }, notes: s.notes) }
            .min { distance(written, $0.problem) < distance(written, $1.problem) }?.id
    }

    /// Whether ALL of `new` belongs to one conversation's writing (see `replyTarget`).
    static func joins(_ new: [CGRect], problem: CGRect, problemInk: [CGRect], notes: [CGRect]) -> Bool {
        let strokes = problemInk + new
        let reach = 1.5 * InkGeometry.letterHeight(strokes)
        let notes = notes.filter { !$0.isNull }.map { $0.insetBy(dx: -reach, dy: -reach) }
        for block in InkGeometry.blocks(strokes) {
            let fresh = block.filter { $0 >= problemInk.count }.map { strokes[$0] }
            guard !fresh.isEmpty else { continue }
            let joined = block.count > fresh.count                                    // with the problem's ink
                || fresh.contains { $0.intersects(problem) }                          // on the problem
                || fresh.contains { r in notes.contains { $0.intersects(r) } }        // right by the note
            if !joined { return false }
        }
        return true
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
