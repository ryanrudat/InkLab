import Foundation

/// Generates a live widget's code from a natural-language request. The generator is swappable so the
/// canvas never depends on HOW the widget was produced — only that it returns sandbox-safe HTML/JS
/// (rendered by `WebWidgetView`). Generation is the headline "magic": "@a calculator" / "@anything" is
/// built on the spot by Claude, not pulled from a catalog of predefined widgets.
protocol MakeRealProvider: Sendable {
    func generate(prompt: String, session: MakeRealSession) async throws -> GeneratedWidget
}

/// A generated widget: its HTML plus the card shape it was designed for.
struct GeneratedWidget: Sendable, Equatable {
    var html: String
    var layout: WidgetLayout
}

/// The consent/session the Server re-checks (ADR 0002) before any Claude call. Built from `AppSettings`
/// so a real user's state — not a hardcoded "adult, consented" — gates every generation. Mirrors the
/// server's `Session` wire shape and `cloudEligible` policy.
struct MakeRealSession: Codable, Sendable, Equatable {
    var isOnline: Bool
    var userKind: String        // "adult" | "minorConsented" | "minorUnconsented" | "schoolManaged"
    var aiConsentGranted: Bool  // the App Store §5.1.2(i) third-party-AI permission
    var ageVerified: Bool

    /// Client-side mirror of the server gate — so an ineligible request shows a clear reason instantly
    /// instead of making a pointless network round-trip. The server re-enforces this (defence in depth).
    var blockReason: String? {
        if !isOnline { return "You’re offline — AI generation needs a connection." }
        if !aiConsentGranted { return "Turn on “Allow AI generation” in Settings to use “@” (it sends your prompt to OpenAI)." }
        if userKind == "minorUnconsented" { return "AI generation needs verifiable parental consent." }
        if (userKind == "minorConsented" || userKind == "schoolManaged") && !ageVerified {
            return "Age needs to be verified before AI generation."
        }
        return nil
    }
}

/// The single switch point. Default = `ProxyMakeRealProvider` (Server → Claude). Real generation needs
/// the Server running with an `ANTHROPIC_API_KEY`; when it isn't reachable the request fails with a
/// clear reason (no silent fake-widget fallback) so the user knows to start it.
enum MakeReal {
    static var provider: MakeRealProvider = ProxyMakeRealProvider()
}

enum MakeRealError: LocalizedError {
    case notConfigured(String), server(String)
    var errorDescription: String? {
        switch self {
        case .notConfigured(let m), .server(let m): return m
        }
    }
}

/// Shared configuration for talking to the InkLab proxy — used by both `ProxyMakeRealProvider`
/// (make-real) and `ClaudeVisionRecognizer` (recognize), so the base URL + auth live in one place.
enum InkLabProxy {
    /// Where the proxy lives. On device this must be a reachable HTTPS URL (the deployed Railway
    /// server) — `localhost` only works in the Simulator, which shares the Mac's network. Set the
    /// `MakeRealBaseURL` Info.plist key to the deployed URL; falls back to the local dev server.
    static var baseURL: URL {
        #if DEBUG
        // Test hook: point a Debug build at a local mock proxy without touching the plist, e.g.
        // `SIMCTL_CHILD_INKLAB_PROXY_URL=http://localhost:8799 xcrun simctl launch …`.
        if let s = ProcessInfo.processInfo.environment["INKLAB_PROXY_URL"], !s.isEmpty, let u = URL(string: s) { return u }
        #endif
        if let s = Bundle.main.object(forInfoDictionaryKey: "MakeRealBaseURL") as? String,
           !s.isEmpty, let u = URL(string: s) { return u }
        return URL(string: "http://localhost:8787")!
    }

    /// Add the shared-secret `Authorization` header (Info.plist `MakeRealProxySecret`) if configured.
    /// Obfuscation-grade — gates the public URL against casual abuse, not a determined attacker.
    static func authorize(_ req: inout URLRequest) {
        if let s = Bundle.main.object(forInfoDictionaryKey: "MakeRealProxySecret") as? String, !s.isEmpty {
            req.setValue("Bearer \(s)", forHTTPHeaderField: "Authorization")
        }
    }
}

/// Calls InkLab's Server proxy `/make-real` (which runs the multi-pass assembler against Claude and
/// re-checks consent + sandbox-safety). Returns a full HTML document for `WebWidgetView` to render.
struct ProxyMakeRealProvider: MakeRealProvider {
    private struct Request: Codable { var session: MakeRealSession; var prompt: String }

    var baseURL = InkLabProxy.baseURL

    /// Just over the proxy's 170 s whole-request deadline (`DEFAULT_MAKE_REAL_DEADLINE_MS`), so a slow
    /// generation ends with the server's clear "timed out" answer rather than a client-side timeout.
    static let requestTimeout: TimeInterval = 185

    func generate(prompt: String, session: MakeRealSession) async throws -> GeneratedWidget {
        var req = URLRequest(url: baseURL.appendingPathComponent("make-real"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        InkLabProxy.authorize(&req)
        req.timeoutInterval = Self.requestTimeout
        req.httpBody = try JSONEncoder().encode(Request(session: session, prompt: prompt))

        let data: Data, resp: URLResponse
        do {
            (data, resp) = try await URLSession.shared.data(for: req)
        } catch let error as URLError {
            throw MakeRealError.notConfigured(Self.message(for: error))
        } catch {
            throw MakeRealError.notConfigured(Self.unreachable)
        }

        guard let http = resp as? HTTPURLResponse else { throw MakeRealError.server("No response from the generator.") }
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard http.statusCode == 200 else {
            throw MakeRealError.server(Self.message(status: http.statusCode, error: obj?["error"] as? String))
        }
        guard let html = obj?["html"] as? String, !html.isEmpty else {
            throw MakeRealError.server("The generator returned no widget.")
        }
        let layout = (obj?["layout"] as? String).flatMap(WidgetLayout.init(rawValue:)) ?? .portrait
        return GeneratedWidget(html: html, layout: layout)
    }

    static let unreachable = "InkLab’s AI generator isn’t reachable. Start the Server (see Server/README) and try again."
    static let tooSlow = "That took too long to design. Try again, or ask for something simpler."

    /// A transport failure, in words that say what actually happened (a timeout is not "server down").
    static func message(for error: URLError) -> String {
        switch error.code {
        case .timedOut:
            return tooSlow
        case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .internationalRoamingOff:
            return "You’re offline — AI generation needs a connection."
        default:
            return unreachable
        }
    }

    /// The proxy's error code (Server/src/makeReal.ts, server.ts) as a message for the status toast.
    static func message(status: Int, error: String?) -> String {
        switch error {
        case "declined":              return "Claude declined to build that. Try rephrasing the request."
        case "no widget":             return "Claude answered without building a widget. Try rephrasing the request."
        case "incomplete generation": return "The design came back unfinished. Try again."
        case "unsafe widget":         return "That design tried to load something from the internet, so it was blocked. Try again."
        case "generation timed out":  return tooSlow
        case "empty prompt":          return "Write what you’d like after the “@”."
        case "prompt too long":       return "That request is too long. Describe the widget in a sentence or two."
        case "upstream error":        return "Claude is unavailable right now. Try again in a moment."
        case "unauthorized":          return "The AI generator rejected this app (check MakeRealProxySecret)."
        case let reason? where !reason.isEmpty:
            return reason   // e.g. the consent gate's reason (403)
        default:
            return "Generator error (status \(status))."
        }
    }
}

/// The request to send when a generated widget failed its render check: the original ask plus what broke, so
/// the model fixes the actual bug (most often an unescaped quote that stops the whole script from running).
/// Kept well under the proxy's 2000-character prompt cap.
func makeRealRetryPrompt(_ prompt: String, after health: RenderHealth) -> String {
    let problem = String(health.problem.prefix(240))
    return String(prompt.prefix(1500)) + "\n\n(A previous version of this widget failed in the browser: \(problem). "
        + "Rebuild it so the JavaScript is valid and runs without errors; watch for unescaped quotes or apostrophes inside strings.)"
}
