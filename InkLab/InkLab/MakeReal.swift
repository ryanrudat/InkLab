import Foundation

/// Generates a live widget's code from a natural-language request. The generator is swappable so the
/// canvas never depends on HOW the widget was produced — only that it returns sandbox-safe HTML/JS
/// (rendered by `WebWidgetView`). Generation is the headline "magic": "@a calculator" / "@anything" is
/// built on the spot by Claude, not pulled from a catalog of predefined widgets.
protocol MakeRealProvider: Sendable {
    func generate(prompt: String, session: MakeRealSession) async throws -> String
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
        if !aiConsentGranted { return "Turn on “Allow AI generation” in Settings to use “@” (it sends your prompt to Anthropic)." }
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

    func generate(prompt: String, session: MakeRealSession) async throws -> String {
        var req = URLRequest(url: baseURL.appendingPathComponent("make-real"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        InkLabProxy.authorize(&req)
        req.timeoutInterval = 90   // generous (multi-pass), but bounded so a hung server fails cleanly
        req.httpBody = try JSONEncoder().encode(Request(session: session, prompt: prompt))

        let data: Data, resp: URLResponse
        do {
            (data, resp) = try await URLSession.shared.data(for: req)
        } catch {
            // Connection refused / offline / timeout → the generator isn't reachable. Say so plainly.
            throw MakeRealError.notConfigured("InkLab’s AI generator isn’t reachable. Start the Server (see Server/README) and try again.")
        }

        guard let http = resp as? HTTPURLResponse else { throw MakeRealError.server("No response from the generator.") }
        guard http.statusCode == 200 else {
            // Surface the server's reason (e.g. 403 consent, 422 unsafe widget) instead of hiding it.
            let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let reason = body?["error"] as? String ?? String(data: data, encoding: .utf8) ?? ""
            throw MakeRealError.server(reason.isEmpty ? "Generator error (status \(http.statusCode))." : reason)
        }

        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let html = obj?["html"] as? String, !html.isEmpty else {
            throw MakeRealError.server("The generator returned no widget.")
        }
        return html
    }
}
