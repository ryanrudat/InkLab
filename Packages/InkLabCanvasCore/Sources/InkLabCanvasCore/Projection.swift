import Foundation
import InkLabRecognition   // Point, Rect
import InkLabDoc           // Transform, FractionalIndex, ObjectSnapshot, PageProjection

// MARK: - Selecting objects on a page with a lasso

public struct Selection: Equatable, Sendable {
    public var objectIDs: Set<UUID>
    public var inkObjectIDs: Set<UUID>
    public var unionBounds: Rect?
    public init(objectIDs: Set<UUID> = [], inkObjectIDs: Set<UUID> = [], unionBounds: Rect? = nil) {
        self.objectIDs = objectIDs; self.inkObjectIDs = inkObjectIDs; self.unionBounds = unionBounds
    }
    public var isEmpty: Bool { objectIDs.isEmpty && inkObjectIDs.isEmpty }
}

/// Which (non-deleted) overlay objects on a page does a lasso select? Ink selection additionally
/// needs decoded stroke points on-device (via `strokeHitTest`); this covers the object world.
public func selectObjects(in page: PageProjection, lasso: [Point]) -> Set<UUID> {
    var selected = Set<UUID>()
    for (id, obj) in page.objects where !obj.isDeleted {
        if rotatedRectIntersectsPolygon(obj.transform, lasso) { selected.insert(id) }
    }
    return selected
}

/// Union AABB of several objects' rotated boxes — the selection's bounding rect.
public func unionBounds(of transforms: [Transform]) -> Rect? {
    let pts = transforms.flatMap { corners(of: $0) }
    return boundingRect(pts)
}

// MARK: - Projection → view diff (drive the overlay from the journal's fold output)

public enum ViewOp: Equatable, Sendable {
    case add(ObjectSnapshot)
    case updateTransform(UUID, Transform)
    case updateZ(UUID, FractionalIndex)
    case updateProps(ObjectSnapshot)
    case remove(UUID)
}

/// Minimal set of view operations to turn `old` into `new` for one page. A tombstoned (isDeleted)
/// object is treated as a removal. Output order is not significant (apply as a batch).
public func projectionDiff(old: PageProjection?, new: PageProjection) -> [ViewOp] {
    var ops: [ViewOp] = []
    let oldObjects = old?.objects ?? [:]

    for (id, n) in new.objects {
        let existed = (oldObjects[id].map { !$0.isDeleted }) ?? false
        if n.isDeleted {
            if existed { ops.append(.remove(id)) }
            continue
        }
        guard let o = oldObjects[id], !o.isDeleted else { ops.append(.add(n)); continue }
        if o.transform != n.transform { ops.append(.updateTransform(id, n.transform)) }
        if o.z != n.z { ops.append(.updateZ(id, n.z)) }
        if o.payload != n.payload { ops.append(.updateProps(n)) }
    }
    for (id, o) in oldObjects where new.objects[id] == nil && !o.isDeleted {
        ops.append(.remove(id))
    }
    return ops
}
