import Foundation
import InkLabKit

/// Cloud handwriting recognition via the InkLab proxy (`POST /recognize` → Claude vision). Claude reads
/// messy handwriting and math — and crucially the "@" symbol — far better than on-device Apple Vision,
/// which misreads a handwritten "@" as "a". Conforms to `InkRecognizer`, so it slots in behind the same
/// interface as Apple Vision (and later MyScript). The image leaves the device only through the proxy
/// (key off-device, consent-gated — ADR 0002).
struct ClaudeVisionRecognizer: InkRecognizer {
    let id: ProviderID = .claudeVision
    let isOnDevice = false
    let supportedFamilies: Set<DomainFamily> = [.text, .math, .chemistry, .diagram]

    var baseURL = InkLabProxy.baseURL
    /// The REAL consent session for this call — set by the host (`CanvasViewController`) from the user's
    /// settings before each cloud read. Defaults to NOT consented so nothing leaks if a caller forgets.
    /// The server re-checks it (`cloudEligible`), so this is the truth the gate sees — not a fabrication.
    var session = MakeRealSession(isOnline: true, userKind: "adult", aiConsentGranted: false, ageVerified: true)
    private struct Request: Codable { var session: MakeRealSession; var rasterPngBase64: String; var domain: String; var context: String? }
    private struct Response: Codable {
        struct Formal: Codable { var kind: String; var value: String }
        var formal: Formal; var confidence: Double; var readAs: String
    }

    enum CloudError: Error { case status(Int), badResponse }

    func recognize(_ input: RecognitionInput) async throws -> RecognitionResult {
        var req = URLRequest(url: baseURL.appendingPathComponent("recognize"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        InkLabProxy.authorize(&req)
        req.timeoutInterval = 30
        req.httpBody = try JSONEncoder().encode(Request(
            session: session,
            rasterPngBase64: input.raster.pngData.base64EncodedString(),
            domain: Self.domain(input.domainHint.family),
            context: input.context?.adjacentText))

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw CloudError.badResponse }
        guard http.statusCode == 200 else { throw CloudError.status(http.statusCode) }
        let r = try JSONDecoder().decode(Response.self, from: data)

        let formal: FormalStructure
        switch r.formal.kind {
        case "latex":  formal = .latex(r.formal.value)
        case "smiles": formal = .smiles(r.formal.value)
        case "plainText": formal = .plainText(r.formal.value)
        default:       formal = .unrecognized(reason: "cloud could not read it")
        }
        return RecognitionResult(formal: formal, confidence: r.confidence, readAs: r.readAs,
                                 provider: .claudeVision, isOnDevice: false)
    }

    private static func domain(_ f: DomainFamily) -> String {
        switch f {
        case .math: return "math"
        case .chemistry: return "chemistry"
        case .diagram: return "diagram"
        case .text: return "text"
        }
    }
}
