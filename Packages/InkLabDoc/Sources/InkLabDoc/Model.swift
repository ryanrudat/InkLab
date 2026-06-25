import Foundation
import InkLabRecognition

// MARK: - Identity & ordering

/// A CRDT "dot": which actor (device/user) produced an op, and its per-actor sequence number.
/// Globally unique, so merges dedup on it.
public struct OpID: Hashable, Codable, Sendable {
    public var actor: UUID
    public var counter: UInt64
    public init(actor: UUID, counter: UInt64) { self.actor = actor; self.counter = counter }
}

/// Hybrid logical clock — gives every op a deterministic TOTAL order across devices, so two clients
/// folding the same set of ops always reach an identical page (the heart of conflict-free merge).
public struct HLC: Comparable, Hashable, Codable, Sendable {
    public var wallMillis: UInt64
    public var counter: UInt16
    public var actor: UUID
    public init(wallMillis: UInt64, counter: UInt16, actor: UUID) {
        self.wallMillis = wallMillis; self.counter = counter; self.actor = actor
    }
    public static func < (a: HLC, b: HLC) -> Bool {
        if a.wallMillis != b.wallMillis { return a.wallMillis < b.wallMillis }
        if a.counter != b.counter { return a.counter < b.counter }
        return a.actor.uuidString < b.actor.uuidString   // final tiebreak: stable, deterministic
    }
}

/// LexoRank-style gap-free ordering key for z-order/paging — two devices can insert "between" the
/// same neighbors and still converge without renumbering (CloudKit forbids ordered relationships).
public struct FractionalIndex: Comparable, Hashable, Codable, Sendable {
    public var rank: String
    public init(_ rank: String) { self.rank = rank }
    public static func < (a: FractionalIndex, b: FractionalIndex) -> Bool { a.rank < b.rank }
    /// Minimal midpoint generator (sufficient for the prototype; production uses true LexoRank).
    public static func between(_ a: FractionalIndex?, _ b: FractionalIndex?) -> FractionalIndex {
        FractionalIndex(((a?.rank ?? "a") + (b?.rank ?? "z")) + "m")
    }
}

// MARK: - Object attributes

/// Decomposed transform SCALARS (not a matrix blob) so each field merges independently under LWW.
public struct Transform: Codable, Sendable, Equatable {
    public var x: Double, y: Double, width: Double, height: Double, rotation: Double
    public init(x: Double = 0, y: Double = 0, width: Double = 0, height: Double = 0, rotation: Double = 0) {
        self.x = x; self.y = y; self.width = width; self.height = height; self.rotation = rotation
    }
}

public enum BlobKind: String, Codable, Sendable { case inkPKDrawing, stickerPNG, widgetBundle, usdz, rasterFallback, vectorPDF }

/// A reference to heavy bytes stored outside the journal (ink PKDrawing, sticker PNG, USDZ, …).
/// Deliberately keyed by a freshly minted UUID, NOT a hash of PKDrawing bytes — those bytes are
/// versioned and carry timestamps, so they are not stable for content-addressing (fact-checked).
public struct BlobRef: Codable, Sendable, Hashable {
    public var id: UUID
    public var kind: BlobKind
    /// PKDrawing requiredContentVersion, persisted so a too-new ink blob is quarantined, not lost.
    public var inkContentVersion: Int?
    /// A rasterized PNG fallback so ink survives a forward-incompat decode failure.
    public var fallbackRasterID: UUID?
    public var byteCount: Int
    public init(id: UUID, kind: BlobKind, inkContentVersion: Int? = nil, fallbackRasterID: UUID? = nil, byteCount: Int = 0) {
        self.id = id; self.kind = kind; self.inkContentVersion = inkContentVersion
        self.fallbackRasterID = fallbackRasterID; self.byteCount = byteCount
    }
}

public enum ObjectKind: String, Codable, Sendable {
    case ink, recognized, widget, sticker, sticky, callout, chart, object3D, group
}

/// Ink object: PencilKit owns the bytes (BlobRef); we own identity, placement, and the per-stroke
/// UUIDs (minted at recognition time) that let a recognized equation link back to its source ink.
public struct InkBody: Codable, Sendable, Equatable {
    public var blob: BlobRef
    public var bounds: Rect
    public var strokeIDs: [UUID]
    public init(blob: BlobRef, bounds: Rect, strokeIDs: [UUID] = []) {
        self.blob = blob; self.bounds = bounds; self.strokeIDs = strokeIDs
    }
}

public enum BindingKind: String, Codable, Sendable { case knob, derived }

/// A reactive binding stub (a number that becomes a draggable knob; a derived value). The model
/// stores the binding + dependency edges; deterministic engines do the recompute (READ vs COMPUTE).
public struct ReactiveBinding: Codable, Sendable, Equatable {
    public var nodePath: String
    public var kind: BindingKind
    public var lower: Double?
    public var upper: Double?
    public init(nodePath: String, kind: BindingKind, lower: Double? = nil, upper: Double? = nil) {
        self.nodePath = nodePath; self.kind = kind; self.lower = lower; self.upper = upper
    }
}

/// A recognized object — reuses InkLabRecognition's vocabulary verbatim (now Codable) so the
/// recognition contract is the single source of truth for what "the formal structure" is.
public struct RecognizedBody: Codable, Sendable, Equatable {
    public var formal: FormalStructure
    public var readAs: String
    public var confidence: Double
    public var alternatives: [Candidate]
    public var sourceStrokeIDs: [UUID]
    public var bindings: [ReactiveBinding]
    public init(formal: FormalStructure, readAs: String, confidence: Double,
                alternatives: [Candidate] = [], sourceStrokeIDs: [UUID] = [], bindings: [ReactiveBinding] = []) {
        self.formal = formal; self.readAs = readAs; self.confidence = confidence
        self.alternatives = alternatives; self.sourceStrokeIDs = sourceStrokeIDs; self.bindings = bindings
    }
}

/// An edge in the reactive dependency graph (e.g. a knob's value drives a downstream cell).
public struct DependencyEdge: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var from: UUID, fromField: String
    public var to: UUID, toField: String
    public var fnID: String
    public init(id: UUID, from: UUID, fromField: String, to: UUID, toField: String, fnID: String) {
        self.id = id; self.from = from; self.fromField = fromField
        self.to = to; self.toField = toField; self.fnID = fnID
    }
}

// MARK: - The ONE object payload (discriminated; forward-compatible)

public indirect enum ObjectPayload: Sendable, Equatable {
    case ink(InkBody)
    case recognized(RecognizedBody)
    case widget(html: BlobRef, jsState: String, sandboxPolicy: String)
    case sticker(image: BlobRef, vectorPDF: BlobRef?)
    case sticky(text: String, colorHex: String)
    case callout(text: String, sourceObjectIDs: [UUID], provenanceJSON: String)
    case chart(specJSON: String, dataRef: UUID?)
    case object3D(scene: BlobRef, cameraJSON: String)
    case group(childIDs: [UUID])
    /// FORWARD-COMPAT: a newer object KIND authored by a newer client survives a decode/re-encode
    /// round-trip through an older client intact, instead of throwing or being dropped.
    case unknown(rawType: String, json: Data)
}

/// Full initial state of one object (the payload of addObject / aiInsert).
public struct ObjectSnapshot: Codable, Sendable, Equatable {
    public var objectID: UUID
    public var kind: ObjectKind
    public var transform: Transform
    public var z: FractionalIndex
    public var pageID: UUID
    public var createdBy: UUID
    public var lamport: UInt64
    public var payload: ObjectPayload
    public var isDeleted: Bool
    public var schemaVersion: UInt16
    public init(objectID: UUID, kind: ObjectKind, transform: Transform = .init(), z: FractionalIndex = .init("m"),
                pageID: UUID, createdBy: UUID, lamport: UInt64 = 0, payload: ObjectPayload,
                isDeleted: Bool = false, schemaVersion: UInt16 = 1) {
        self.objectID = objectID; self.kind = kind; self.transform = transform; self.z = z
        self.pageID = pageID; self.createdBy = createdBy; self.lamport = lamport
        self.payload = payload; self.isDeleted = isDeleted; self.schemaVersion = schemaVersion
    }
}

public struct PageMeta: Codable, Sendable, Equatable {
    public var pageID: UUID
    public var index: Int
    public var extentY: Double
    public init(pageID: UUID, index: Int, extentY: Double) {
        self.pageID = pageID; self.index = index; self.extentY = extentY
    }
}

/// A typed field patch for setProps (sticky text, recognized "read as", a knob value).
public struct PropPatch: Codable, Sendable, Equatable {
    public var stickyText: String?
    public var colorHex: String?
    public var readAs: String?
    public var knobValue: Double?
    public init(stickyText: String? = nil, colorHex: String? = nil, readAs: String? = nil, knobValue: Double? = nil) {
        self.stickyText = stickyText; self.colorHex = colorHex; self.readAs = readAs; self.knobValue = knobValue
    }
}

// MARK: - The universal operation (everything that happens is one of these)

public enum OpPayload: Sendable, Equatable, Codable {
    case addObject(snapshot: ObjectSnapshot)
    case aiInsert(snapshot: ObjectSnapshot, provenanceJSON: String)
    case delete(objectID: UUID)
    case restore(objectID: UUID)
    case setTransform(objectID: UUID, old: Transform, new: Transform)
    case setZ(objectID: UUID, old: FractionalIndex, new: FractionalIndex)
    case setInk(objectID: UUID, old: BlobRef?, new: BlobRef)
    case setProps(objectID: UUID, old: PropPatch, new: PropPatch)
    case addEdge(edge: DependencyEdge)
    case removeEdge(edge: DependencyEdge)
    case addPage(meta: PageMeta)
    case setPageExtent(pageID: UUID, old: Double, new: Double)
    /// Edit a live object's inline state string — `jsState` for `.widget`, `specJSON` for `.chart`,
    /// `cameraJSON` for `.object3D`. Invertible by swapping old/new, so a widget edit undoes in one step.
    case setObjectState(objectID: UUID, old: String, new: String)
    /// Replace an object's payload in place (the §6 energy-level "promote": sticker ↔ interactive ↔ 3D),
    /// preserving its identity/transform/z. Invertible by swapping old/new.
    case promote(objectID: UUID, old: ObjectPayload, new: ObjectPayload)
}

public struct Op: Codable, Sendable, Equatable, Identifiable {
    public var id: OpID
    public var hlc: HLC
    public var schemaVersion: UInt16
    public var notebookID: UUID
    /// Groups several ops into ONE user-visible undo step (a 12-object lasso drag; an AI insertion
    /// that drops a callout + a widget + 2 dependency edges).
    public var transactionID: UUID?
    /// Set when this op is itself an undo of a prior op (undo appends; it never pops the log).
    public var undoesOpID: OpID?
    public var payload: OpPayload
    public init(id: OpID, hlc: HLC, schemaVersion: UInt16 = 1, notebookID: UUID,
                transactionID: UUID? = nil, undoesOpID: OpID? = nil, payload: OpPayload) {
        self.id = id; self.hlc = hlc; self.schemaVersion = schemaVersion; self.notebookID = notebookID
        self.transactionID = transactionID; self.undoesOpID = undoesOpID; self.payload = payload
    }
}

// MARK: - The live projection the fold produces (prod: TreeDictionary for structural sharing)

public struct PageProjection: Sendable, Equatable {
    public var id: UUID
    public var extentY: Double
    public var objects: [UUID: ObjectSnapshot]
    public init(id: UUID, extentY: Double = 0, objects: [UUID: ObjectSnapshot] = [:]) {
        self.id = id; self.extentY = extentY; self.objects = objects
    }
}

public struct NotebookProjection: Sendable, Equatable {
    public var id: UUID
    public var pageOrder: [UUID]
    public var pages: [UUID: PageProjection]
    public var edges: [UUID: DependencyEdge]
    public var highWaterHLC: HLC?
    public init(id: UUID, pageOrder: [UUID] = [], pages: [UUID: PageProjection] = [:],
                edges: [UUID: DependencyEdge] = [:], highWaterHLC: HLC? = nil) {
        self.id = id; self.pageOrder = pageOrder; self.pages = pages; self.edges = edges; self.highWaterHLC = highWaterHLC
    }
}

// MARK: - Forward-compatible Codable for ObjectPayload

/// Wire format: { "type": <caseName>, "bodyData": <Data of the case body's JSON> }. An unknown
/// `type` is captured verbatim into `.unknown`, so newer object kinds round-trip through older
/// clients without loss. (Equatable/Sendable are still synthesized; only Codable is custom.)
extension ObjectPayload: Codable {
    private enum CodingKeys: String, CodingKey { case type, bodyData }
    private struct Widget: Codable { var html: BlobRef; var jsState: String; var sandboxPolicy: String }
    private struct Sticker: Codable { var image: BlobRef; var vectorPDF: BlobRef? }
    private struct Sticky: Codable { var text: String; var colorHex: String }
    private struct Callout: Codable { var text: String; var sourceObjectIDs: [UUID]; var provenanceJSON: String }
    private struct Chart: Codable { var specJSON: String; var dataRef: UUID? }
    private struct Object3D: Codable { var scene: BlobRef; var cameraJSON: String }
    private struct Group: Codable { var childIDs: [UUID] }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        let (type, data): (String, Data)
        switch self {
        case .ink(let b):                       (type, data) = ("ink", try Canonical.encode(b))
        case .recognized(let b):                (type, data) = ("recognized", try Canonical.encode(b))
        case .widget(let h, let j, let s):      (type, data) = ("widget", try Canonical.encode(Widget(html: h, jsState: j, sandboxPolicy: s)))
        case .sticker(let i, let v):            (type, data) = ("sticker", try Canonical.encode(Sticker(image: i, vectorPDF: v)))
        case .sticky(let t, let col):           (type, data) = ("sticky", try Canonical.encode(Sticky(text: t, colorHex: col)))
        case .callout(let t, let src, let p):   (type, data) = ("callout", try Canonical.encode(Callout(text: t, sourceObjectIDs: src, provenanceJSON: p)))
        case .chart(let spec, let ref):         (type, data) = ("chart", try Canonical.encode(Chart(specJSON: spec, dataRef: ref)))
        case .object3D(let scene, let cam):     (type, data) = ("object3D", try Canonical.encode(Object3D(scene: scene, cameraJSON: cam)))
        case .group(let ids):                   (type, data) = ("group", try Canonical.encode(Group(childIDs: ids)))
        case .unknown(let rawType, let json):   (type, data) = (rawType, json)
        }
        try c.encode(type, forKey: .type)
        try c.encode(data, forKey: .bodyData)
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(String.self, forKey: .type)
        let data = try c.decode(Data.self, forKey: .bodyData)
        switch type {
        case "ink":        self = .ink(try Canonical.decode(InkBody.self, data))
        case "recognized": self = .recognized(try Canonical.decode(RecognizedBody.self, data))
        case "widget":     let b = try Canonical.decode(Widget.self, data);   self = .widget(html: b.html, jsState: b.jsState, sandboxPolicy: b.sandboxPolicy)
        case "sticker":    let b = try Canonical.decode(Sticker.self, data);  self = .sticker(image: b.image, vectorPDF: b.vectorPDF)
        case "sticky":     let b = try Canonical.decode(Sticky.self, data);   self = .sticky(text: b.text, colorHex: b.colorHex)
        case "callout":    let b = try Canonical.decode(Callout.self, data);  self = .callout(text: b.text, sourceObjectIDs: b.sourceObjectIDs, provenanceJSON: b.provenanceJSON)
        case "chart":      let b = try Canonical.decode(Chart.self, data);    self = .chart(specJSON: b.specJSON, dataRef: b.dataRef)
        case "object3D":   let b = try Canonical.decode(Object3D.self, data); self = .object3D(scene: b.scene, cameraJSON: b.cameraJSON)
        case "group":      let b = try Canonical.decode(Group.self, data);    self = .group(childIDs: b.childIDs)
        default:           self = .unknown(rawType: type, json: data)   // <-- the forward-compat fallthrough
        }
    }
}

/// One deterministic JSON coder (sorted keys) so re-encoding is byte-stable — needed for the
/// round-trip equality tests and for content stability.
public enum Canonical {
    public static let encoder: JSONEncoder = {
        let e = JSONEncoder(); e.outputFormatting = [.sortedKeys]; return e
    }()
    public static let decoder = JSONDecoder()
    public static func encode<T: Encodable>(_ v: T) throws -> Data { try encoder.encode(v) }
    public static func decode<T: Decodable>(_ t: T.Type, _ data: Data) throws -> T { try decoder.decode(t, from: data) }
}
