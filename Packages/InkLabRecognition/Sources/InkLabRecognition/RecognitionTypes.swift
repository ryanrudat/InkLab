import Foundation

// MARK: - Geometry & ink (value types; the iOS adapter maps PencilKit into these)

/// A point in canvas coordinates.
public struct Point: Sendable, Equatable {
    public var x: Double
    public var y: Double
    public init(x: Double, y: Double) { self.x = x; self.y = y }
}

/// A rectangle in canvas/image coordinates (selection bounds, etc.).
public struct Rect: Sendable, Equatable, Codable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
}

/// One sampled point of an Apple Pencil stroke. `force/altitude/azimuth` are optional because
/// not every Pencil/finger sample carries them — online recognizers (MyScript/ML Kit) use the
/// time-ordering of these points, which raster OCR (Vision/Claude) discards.
public struct InkPoint: Sendable, Equatable {
    public var x: Double
    public var y: Double
    public var t: TimeInterval
    public var force: Double?
    public var altitude: Double?
    public var azimuth: Double?
    public init(x: Double, y: Double, t: TimeInterval,
                force: Double? = nil, altitude: Double? = nil, azimuth: Double? = nil) {
        self.x = x; self.y = y; self.t = t
        self.force = force; self.altitude = altitude; self.azimuth = azimuth
    }
}

/// A single time-ordered stroke.
public struct InkStroke: Sendable, Equatable {
    public var points: [InkPoint]
    public init(points: [InkPoint]) { self.points = points }
}

/// A rasterized render of a selection. Encoded bytes (e.g. PNG) so this package stays free of
/// CoreGraphics; the iOS adapter produces it via `PKDrawing.image(from:scale:)` -> PNG.
public struct RasterImage: Sendable, Equatable {
    public var pngData: Data
    public var width: Int
    public var height: Int
    public init(pngData: Data, width: Int, height: Int) {
        self.pngData = pngData; self.width = width; self.height = height
    }
}

// MARK: - Domains

/// Coarse routing family. Providers advertise which families they handle.
public enum DomainFamily: String, Sendable, Hashable, CaseIterable {
    case math, text, chemistry, diagram
}

public enum DiagramKind: Sendable, Hashable {
    case generic, circuit, freeBody, biology
}

/// The caller's expectation for a selection. Carries the diagram subtype so a cloud recognizer
/// can be prompted specifically (circuit vs free-body), while routing keys off `.family`.
public enum RecognitionDomain: Sendable, Hashable {
    case math
    case text
    case chemistry
    case diagram(DiagramKind)

    public var family: DomainFamily {
        switch self {
        case .math: return .math
        case .text: return .text
        case .chemistry: return .chemistry
        case .diagram: return .diagram
        }
    }
}

/// Optional surrounding context that helps disambiguate (used by cloud recognizers; on-device
/// engines typically ignore it).
public struct RecognitionContext: Sendable, Equatable {
    public var adjacentText: String?
    public var problemStatement: String?
    public init(adjacentText: String? = nil, problemStatement: String? = nil) {
        self.adjacentText = adjacentText; self.problemStatement = problemStatement
    }
}

// MARK: - Input

/// Everything a recognizer needs. Every provider receives BOTH strokes and a raster so that
/// swapping an online (stroke) provider for an offline (raster) one needs no caller change.
public struct RecognitionInput: Sendable {
    public var strokes: [InkStroke]
    public var raster: RasterImage
    public var region: Rect
    public var domainHint: RecognitionDomain
    public var context: RecognitionContext?
    /// Session/consent state — read by the cloud-eligibility policy in `RoutingRecognizer`.
    public var session: SessionContext
    public var localeIdentifier: String

    public init(strokes: [InkStroke],
                raster: RasterImage,
                region: Rect,
                domainHint: RecognitionDomain,
                context: RecognitionContext? = nil,
                session: SessionContext,
                localeIdentifier: String = "en_US") {
        self.strokes = strokes
        self.raster = raster
        self.region = region
        self.domainHint = domainHint
        self.context = context
        self.session = session
        self.localeIdentifier = localeIdentifier
    }
}

// MARK: - Formal structure (the READ-vs-COMPUTE payload)

/// A minimal math expression tree. The deterministic compute engines consume this (or LaTeX/MathML
/// they parse into it); they NEVER depend on which provider produced it.
public indirect enum MathNode: Sendable, Equatable, Codable {
    case number(Double)
    case symbol(String)
    case unary(op: String, MathNode)
    case binary(op: String, lhs: MathNode, rhs: MathNode)
    case call(name: String, args: [MathNode])
}

/// A circuit/diagram netlist (experimental, post-MVP — see docs/decisions/0001).
public struct NetlistDoc: Sendable, Equatable, Codable {
    public struct Component: Sendable, Equatable, Codable {
        public var kind: String     // "R", "C", "V", ...
        public var id: String       // "R1"
        public var nodes: [String]  // ["n1", "n2"]
        public var value: String?   // "10k"
        public init(kind: String, id: String, nodes: [String], value: String? = nil) {
            self.kind = kind; self.id = id; self.nodes = nodes; self.value = value
        }
    }
    public var components: [Component]
    public init(components: [Component]) { self.components = components }
}

/// The contract between recognition and compute. Strongly typed so the compute layer can switch
/// exhaustively over what it was handed.
public enum FormalStructure: Sendable, Equatable, Codable {
    case latex(String)
    case mathML(String)
    case expressionTree(MathNode)
    case plainText(String)
    case smiles(String)
    case netlist(NetlistDoc)
    case unrecognized(reason: String)
}

// MARK: - Result

public enum ProviderID: String, Sendable, Equatable {
    case myscript
    case appleVision
    case mlkit
    case claudeVision
    case mathpix
    case routing
    case none
}

/// A ranked alternative interpretation, enabling one-tap correction / disagreement UI.
public struct Candidate: Sendable, Equatable, Codable {
    public var formal: FormalStructure
    public var readAs: String
    public var confidence: Double
    public init(formal: FormalStructure, readAs: String, confidence: Double) {
        self.formal = formal; self.readAs = readAs; self.confidence = confidence
    }
}

/// The output contract. `formal` is the payload; `readAs` is the human-confirmable transcription
/// the UI shows ("Read as f(x) = x² + 3x"); `provider`/`isOnDevice` are for telemetry and the
/// consent gate — never for branching compute logic.
public struct RecognitionResult: Sendable, Equatable {
    public var formal: FormalStructure
    public var confidence: Double
    public var readAs: String
    public var alternatives: [Candidate]
    public var provider: ProviderID
    public var isOnDevice: Bool
    public var latency: Duration
    /// Optional human-readable note (e.g. "cloud unavailable (offline); returned best on-device read").
    public var note: String?

    public init(formal: FormalStructure,
                confidence: Double,
                readAs: String,
                alternatives: [Candidate] = [],
                provider: ProviderID,
                isOnDevice: Bool,
                latency: Duration = .zero,
                note: String? = nil) {
        self.formal = formal
        self.confidence = confidence
        self.readAs = readAs
        self.alternatives = alternatives
        self.provider = provider
        self.isOnDevice = isOnDevice
        self.latency = latency
        self.note = note
    }
}

// MARK: - Errors

public enum RecognitionError: Error, Sendable, Equatable {
    /// A concrete provider stub that hasn't been wired to its SDK yet.
    case notImplemented(ProviderID)
    case providerUnavailable(ProviderID)
    case unsupportedDomain(DomainFamily)
}
