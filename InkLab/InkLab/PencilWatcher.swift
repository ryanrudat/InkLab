import UIKit
import UIKit.UIGestureRecognizerSubclass

/// Notices when Apple Pencil is on the glass without taking part in touch handling, so the canvas can stop
/// a resting hand from drawing, scrolling or turning the page while someone writes. It never recognizes,
/// never delays or cancels a touch, and never blocks another recognizer: it only counts Pencil touches.
final class PencilWatcher: UIGestureRecognizer, UIGestureRecognizerDelegate {
    /// The first Pencil touch of a sequence landed (the count went 0 → 1).
    var onPencilDown: (() -> Void)?
    /// The last Pencil touch lifted or was cancelled (the count went back to 0).
    var onPencilUp: (() -> Void)?

    private var active: Set<ObjectIdentifier> = []   // every touch we're watching, identity only (not retained)
    private var pencils: Set<ObjectIdentifier> = []

    init() {
        super.init(target: nil, action: nil)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
        // A palm usually lands before the Pencil; the default (exclusive) would then ignore the Pencil.
        requiresExclusiveTouchType = false
        delegate = self
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        let wasDown = !pencils.isEmpty
        for touch in touches {
            active.insert(ObjectIdentifier(touch))
            if touch.type == .pencil { pencils.insert(ObjectIdentifier(touch)) }
        }
        if !wasDown, !pencils.isEmpty { onPencilDown?() }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) { lift(touches) }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) { lift(touches) }

    private func lift(_ touches: Set<UITouch>) {
        let wasDown = !pencils.isEmpty
        for touch in touches {
            active.remove(ObjectIdentifier(touch))
            pencils.remove(ObjectIdentifier(touch))
        }
        if wasDown, pencils.isEmpty { onPencilUp?() }
        if active.isEmpty { state = .failed }   // done with this sequence; UIKit resets us for the next
    }

    override func reset() {
        super.reset()
        active.removeAll()
        if !pencils.isEmpty {
            pencils.removeAll()
            onPencilUp?()
        }
    }

    override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool { false }
    override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool { false }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
}

/// Whether this iPad is used with Apple Pencil. Remembered once a Pencil touches the page, and assumed when
/// the iPad's own "Only Draw with Apple Pencil" setting is on.
enum PencilPresence {
    static let key = "inklab.pencilDetected.v1"

    static var detected: Bool {
        UserDefaults.standard.bool(forKey: key) || UIPencilInteraction.prefersPencilOnlyDrawing
    }

    static func noteDetected() { UserDefaults.standard.set(true, forKey: key) }
}
