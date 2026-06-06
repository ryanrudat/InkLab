import UIKit
import InkLabKit

/// The transparent overlay of live objects above the ink. In pen mode it lets a Pencil touch fall
/// THROUGH empty space (so PencilKit draws) while keeping objects finger-draggable; in lasso mode it
/// captures touches so the lasso can be drawn over anything.
final class ObjectOverlayView: UIView {
    var isLassoMode = false
    var onObjectMoved: ((UUID, Transform) -> Void)?

    private var hosts: [UUID: ObjectHostView] = [:]

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        if isLassoMode { return self }
        let hit = super.hitTest(point, with: event)
        return hit === self ? nil : hit
    }

    func apply(_ ops: [ViewOp], page: PageProjection) {
        for op in ops {
            switch op {
            case .add(let snapshot):
                let host = ObjectHostView(objectID: snapshot.objectID)
                host.onMoved = { [weak self] id, t in self?.onObjectMoved?(id, t) }
                addSubview(host)
                hosts[snapshot.objectID] = host
                host.apply(snapshot)
            case .updateTransform(let id, _), .updateZ(let id, _):
                if let snap = page.objects[id] { hosts[id]?.apply(snap) }
            case .updateProps(let snap):
                hosts[snap.objectID]?.apply(snap)
            case .remove(let id):
                hosts[id]?.removeFromSuperview()
                hosts[id] = nil
            }
        }
        let ordered = hosts.values.sorted {
            (page.objects[$0.objectID]?.z ?? FractionalIndex("m")) < (page.objects[$1.objectID]?.z ?? FractionalIndex("m"))
        }
        for (i, host) in ordered.enumerated() { host.layer.zPosition = CGFloat(i) }
    }
}

final class ObjectHostView: UIView {
    let objectID: UUID
    var onMoved: ((UUID, Transform) -> Void)?
    private let label = UILabel()
    private var current = Transform()

    init(objectID: UUID) {
        self.objectID = objectID
        super.init(frame: .zero)
        layer.cornerRadius = 8
        layer.shadowOpacity = 0.15
        layer.shadowRadius = 4
        layer.shadowOffset = CGSize(width: 0, height: 2)
        label.numberOfLines = 0
        label.font = .systemFont(ofSize: 16)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handleDrag(_:)))
        pan.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        addGestureRecognizer(pan)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func apply(_ snapshot: ObjectSnapshot) {
        current = snapshot.transform
        bounds = CGRect(x: 0, y: 0, width: max(8, snapshot.transform.width), height: max(8, snapshot.transform.height))
        center = CGPoint(x: snapshot.transform.x + snapshot.transform.width / 2,
                         y: snapshot.transform.y + snapshot.transform.height / 2)
        transform = CGAffineTransform(rotationAngle: CGFloat(snapshot.transform.rotation))
        switch snapshot.payload {
        case .sticky(let text, let colorHex):
            backgroundColor = UIColor(hex: colorHex) ?? .systemYellow
            label.textColor = .black
            label.text = text.isEmpty ? "Sticky" : text
        case .recognized(let body):
            backgroundColor = .secondarySystemBackground
            label.textColor = .label
            label.text = "Read as: \(body.readAs)"
        case .callout(let text, _, _):
            backgroundColor = UIColor.systemBlue.withAlphaComponent(0.12)
            layer.borderColor = UIColor.systemBlue.withAlphaComponent(0.4).cgColor
            layer.borderWidth = 1
            label.textColor = .label
            label.font = .systemFont(ofSize: 16, weight: .medium)
            label.text = text
        default:
            backgroundColor = .secondarySystemBackground
            label.textColor = .label
            label.text = String(describing: snapshot.kind)
        }
    }

    @objc private func handleDrag(_ g: UIPanGestureRecognizer) {
        guard let parent = superview else { return }
        switch g.state {
        case .changed:
            let d = g.translation(in: parent)
            center = CGPoint(x: center.x + d.x, y: center.y + d.y)
            g.setTranslation(.zero, in: parent)
        case .ended, .cancelled:
            let newTransform = Transform(x: Double(center.x) - current.width / 2,
                                         y: Double(center.y) - current.height / 2,
                                         width: current.width, height: current.height, rotation: current.rotation)
            onMoved?(objectID, newTransform)
        default:
            break
        }
    }
}
