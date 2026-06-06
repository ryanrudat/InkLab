import XCTest
@testable import InkLabRecognition

/// These tests pin down InkLab's recognition *decision* as executable behavior: on-device-first,
/// confidence-gated cloud escalation, the minors/consent gate, and "never auto-accept unvalidated
/// cloud output." They use configurable test doubles (no real SDKs) so the routing brain is
/// verifiable today, on the CLI.
final class RoutingRecognizerTests: XCTestCase {

    // MARK: - Test doubles

    /// A recognizer that returns a fixed result (or throws). Stateless => Sendable, no concurrency
    /// fuss. We assert on `result.provider` to know which path the router took.
    struct FixedRecognizer: InkRecognizer {
        let id: ProviderID
        let isOnDevice: Bool
        let supportedFamilies: Set<DomainFamily>
        let outcome: Result<RecognitionResult, RecognitionError>
        func recognize(_ input: RecognitionInput) async throws -> RecognitionResult {
            try outcome.get()
        }
    }

    func result(_ provider: ProviderID, onDevice: Bool, _ formal: FormalStructure,
                _ readAs: String, _ confidence: Double) -> RecognitionResult {
        RecognitionResult(formal: formal, confidence: confidence, readAs: readAs,
                          provider: provider, isOnDevice: onDevice)
    }

    func input(_ domain: RecognitionDomain, _ session: SessionContext) -> RecognitionInput {
        RecognitionInput(
            strokes: [],
            raster: RasterImage(pngData: Data(), width: 8, height: 8),
            region: Rect(x: 0, y: 0, width: 8, height: 8),
            domainHint: domain,
            session: session
        )
    }

    let adultOnline = SessionContext(isOnline: true, userKind: .adult, cloudAIConsentGranted: true)

    func router(onDevice: [DomainFamily: any InkRecognizer],
                cloud: [DomainFamily: any InkRecognizer],
                threshold: Double = 0.8) -> RoutingRecognizer {
        var registry: [ProviderID: any InkRecognizer] = [:]
        var onDeviceMap: [DomainFamily: ProviderID] = [:]
        var cloudMap: [DomainFamily: ProviderID] = [:]
        for (fam, rec) in onDevice { registry[rec.id] = rec; onDeviceMap[fam] = rec.id }
        for (fam, rec) in cloud { registry[rec.id] = rec; cloudMap[fam] = rec.id }
        return RoutingRecognizer(registry: registry, onDeviceByFamily: onDeviceMap,
                                 cloudByFamily: cloudMap, confidenceThreshold: threshold)
    }

    // MARK: - Tests

    /// High-confidence on-device math is accepted locally; cloud is never consulted.
    func test_math_highConfidence_staysOnDevice() async throws {
        let myscript = FixedRecognizer(id: .myscript, isOnDevice: true, supportedFamilies: [.math],
            outcome: .success(result(.myscript, onDevice: true, .latex("x^2+1"), "x²+1", 0.95)))
        let claude = FixedRecognizer(id: .claudeVision, isOnDevice: false, supportedFamilies: [.math],
            outcome: .failure(.providerUnavailable(.claudeVision))) // must NOT be called
        let r = try await router(onDevice: [.math: myscript], cloud: [.math: claude])
            .recognize(input(.math, adultOnline))
        XCTAssertEqual(r.provider, .myscript)
        XCTAssertTrue(r.isOnDevice)
        XCTAssertEqual(r.formal, .latex("x^2+1"))
    }

    /// Low-confidence on-device math escalates to cloud when the user is eligible.
    func test_math_lowConfidence_consented_escalatesToCloud() async throws {
        let myscript = FixedRecognizer(id: .myscript, isOnDevice: true, supportedFamilies: [.math],
            outcome: .success(result(.myscript, onDevice: true, .latex("x2+1"), "x2+1", 0.40)))
        let claude = FixedRecognizer(id: .claudeVision, isOnDevice: false, supportedFamilies: [.math],
            outcome: .success(result(.claudeVision, onDevice: false, .latex("x^2+1"), "x²+1", 0.90)))
        let r = try await router(onDevice: [.math: myscript], cloud: [.math: claude])
            .recognize(input(.math, adultOnline))
        XCTAssertEqual(r.provider, .claudeVision)
        XCTAssertEqual(r.formal, .latex("x^2+1"))
        // the on-device read survives as a ranked alternative for one-tap correction
        XCTAssertTrue(r.alternatives.contains { $0.readAs == "x2+1" })
    }

    /// An unconsented minor's low-confidence read does NOT go to the cloud; the best on-device read
    /// is returned with an explanatory note. No silent send.
    func test_math_lowConfidence_minorUnconsented_staysOnDevice() async throws {
        let session = SessionContext(isOnline: true, userKind: .minorUnconsented, cloudAIConsentGranted: true)
        let myscript = FixedRecognizer(id: .myscript, isOnDevice: true, supportedFamilies: [.math],
            outcome: .success(result(.myscript, onDevice: true, .latex("x2+1"), "x2+1", 0.40)))
        let claude = FixedRecognizer(id: .claudeVision, isOnDevice: false, supportedFamilies: [.math],
            outcome: .failure(.providerUnavailable(.claudeVision))) // must NOT be called
        let r = try await router(onDevice: [.math: myscript], cloud: [.math: claude])
            .recognize(input(.math, session))
        XCTAssertEqual(r.provider, .myscript)
        XCTAssertEqual(r.formal, .latex("x2+1"))
        XCTAssertNotNil(r.note)
    }

    /// A consented minor CAN use the cloud fallback.
    func test_math_lowConfidence_minorConsented_escalatesToCloud() async throws {
        let session = SessionContext(isOnline: true, userKind: .minorConsented, cloudAIConsentGranted: true)
        let myscript = FixedRecognizer(id: .myscript, isOnDevice: true, supportedFamilies: [.math],
            outcome: .success(result(.myscript, onDevice: true, .latex("x2"), "x2", 0.30)))
        let claude = FixedRecognizer(id: .claudeVision, isOnDevice: false, supportedFamilies: [.math],
            outcome: .success(result(.claudeVision, onDevice: false, .latex("x^2"), "x²", 0.92)))
        let r = try await router(onDevice: [.math: myscript], cloud: [.math: claude])
            .recognize(input(.math, session))
        XCTAssertEqual(r.provider, .claudeVision)
    }

    /// Chemistry has no on-device path; with consent + online it goes straight to cloud.
    func test_chemistry_cloudOnly_consented_usesCloud() async throws {
        let claude = FixedRecognizer(id: .claudeVision, isOnDevice: false, supportedFamilies: [.chemistry],
            outcome: .success(result(.claudeVision, onDevice: false, .smiles("CCO"), "ethanol", 0.85)))
        let r = try await router(onDevice: [:], cloud: [.chemistry: claude])
            .recognize(input(.chemistry, adultOnline))
        XCTAssertEqual(r.provider, .claudeVision)
        XCTAssertEqual(r.formal, .smiles("CCO"))
    }

    /// Cloud-only chemistry while offline returns an explicit unrecognized result — never a silent
    /// send and never a fabricated answer.
    func test_chemistry_offline_returnsUnrecognized() async throws {
        let offline = SessionContext(isOnline: false, userKind: .adult, cloudAIConsentGranted: true)
        let claude = FixedRecognizer(id: .claudeVision, isOnDevice: false, supportedFamilies: [.chemistry],
            outcome: .failure(.providerUnavailable(.claudeVision)))
        let r = try await router(onDevice: [:], cloud: [.chemistry: claude])
            .recognize(input(.chemistry, offline))
        XCTAssertEqual(r.provider, .routing)
        if case .unrecognized = r.formal {} else { XCTFail("expected .unrecognized, got \(r.formal)") }
        XCTAssertNotNil(r.note)
    }

    /// Cloud output that fails the deterministic validator is NOT accepted; routing falls back to
    /// the best on-device read.
    func test_cloud_parseFailure_notAccepted() async throws {
        let myscript = FixedRecognizer(id: .myscript, isOnDevice: true, supportedFamilies: [.math],
            outcome: .success(result(.myscript, onDevice: true, .latex("x2+1"), "x2+1", 0.40)))
        let claude = FixedRecognizer(id: .claudeVision, isOnDevice: false, supportedFamilies: [.math],
            outcome: .success(result(.claudeVision, onDevice: false, .latex("   "), "(garbage)", 0.99)))
        let r = try await router(onDevice: [.math: myscript], cloud: [.math: claude])
            .recognize(input(.math, adultOnline))
        XCTAssertEqual(r.provider, .myscript, "unvalidated cloud output must not win even at 0.99")
        XCTAssertEqual(r.formal, .latex("x2+1"))
    }

    /// Text routes to the on-device text provider (Apple Vision).
    func test_text_usesOnDeviceVision() async throws {
        let vision = FixedRecognizer(id: .appleVision, isOnDevice: true, supportedFamilies: [.text],
            outcome: .success(result(.appleVision, onDevice: true, .plainText("hello"), "hello", 0.9)))
        let r = try await router(onDevice: [.text: vision], cloud: [:])
            .recognize(input(.text, adultOnline))
        XCTAssertEqual(r.provider, .appleVision)
        XCTAssertEqual(r.formal, .plainText("hello"))
    }

    /// The DefaultCloudPolicy rules, directly.
    func test_defaultCloudPolicy() {
        let p = DefaultCloudPolicy()
        XCTAssertEqual(p.cloudEligible(.init(isOnline: true,  userKind: .adult,            cloudAIConsentGranted: true)),  .allowed)
        XCTAssertEqual(p.cloudEligible(.init(isOnline: true,  userKind: .schoolManaged,    cloudAIConsentGranted: true)),  .allowed)
        XCTAssertEqual(p.cloudEligible(.init(isOnline: false, userKind: .adult,            cloudAIConsentGranted: true)),  .blocked(reason: "offline"))
        if case .blocked = p.cloudEligible(.init(isOnline: true, userKind: .adult,         cloudAIConsentGranted: false)) {} else { XCTFail() }
        if case .blocked = p.cloudEligible(.init(isOnline: true, userKind: .minorUnconsented, cloudAIConsentGranted: true)) {} else { XCTFail() }
    }
}
