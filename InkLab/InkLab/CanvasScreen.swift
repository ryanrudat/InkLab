import SwiftUI
import UIKit
import InkLabKit

/// The page editor: the UIKit canvas + a floating SwiftUI toolbar and an "@" command bar that runs
/// the deterministic engines (brief §5, §5.3).
struct CanvasScreen: View {
    let notebook: Notebook
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var library: Library
    @StateObject private var model: CanvasModel
    @State private var command = ""
    @State private var showCommand = false
    @State private var status: String?
    @State private var persistenceWarning: String?
    @FocusState private var commandFocused: Bool

    init(notebook: Notebook) {
        self.notebook = notebook
        _model = StateObject(wrappedValue: CanvasModel(paper: notebook.paper))
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            CanvasRepresentable(model: model, notebookID: notebook.id,
                                onStatus: { showStatus($0) },
                                onPersistenceWarning: { warning in
                                    // JournalStore may replay a deferred init failure while UIKit is being
                                    // created inside a SwiftUI update. Assign on the next turn to avoid a
                                    // state mutation during view reconciliation.
                                    DispatchQueue.main.async { persistenceWarning = warning }
                                })
                .ignoresSafeArea()

            VStack(spacing: 0) {
                if showCommand { commandBar.transition(.move(edge: .top).combined(with: .opacity)) }
                Spacer()
            }

            if let status { statusToast(status) }
            if let persistenceWarning {
                VStack {
                    persistenceBanner(persistenceWarning)
                    Spacer()
                }
                .zIndex(20)
            }
            // The dock is its OWN view: its drag/collapse state stays local, so moving it never
            // re-renders this screen (which would re-run the canvas's updateUIViewController and stutter).
            FloatingDock(model: model)
        }
        .onAppear {
            model.fingerDrawing = settings.fingerDrawing
            model.autoCommands = settings.autoCommands
            model.snapShapesOnHold = settings.snapShapesOnHold
            model.makeRealSession = settings.makeRealSession
        }
        .onChange(of: settings.fingerDrawing) { _, newValue in model.fingerDrawing = newValue }
        .onChange(of: settings.autoCommands) { _, newValue in model.autoCommands = newValue }
        .onChange(of: settings.snapShapesOnHold) { _, newValue in model.snapShapesOnHold = newValue }
        .onChange(of: settings.makeRealSession) { _, newValue in model.makeRealSession = newValue }
        // Persist the live paper choice back to this notebook so closing/reopening the app restores it
        // (otherwise the canvas reseeds from the notebook's original paper and reverts to ruled).
        .onChange(of: model.paper) { _, newPaper in library.setPaper(notebook.id, newPaper) }
        .sheet(item: $model.pendingRecognition) { draft in
            RecognitionReviewView(draft: draft) { result in
                model.onInsertResult?(result, draft.pageID)
            }
        }
        .toolbar {
            ToolbarItem(placement: settings.leftHanded ? .topBarLeading : .topBarTrailing) {
                Button {
                    withAnimation { showCommand.toggle() }
                    commandFocused = showCommand
                } label: { Image(systemName: "at.circle\(showCommand ? ".fill" : "")") }
                .accessibilityIdentifier("atButton")
            }
        }
    }

    // MARK: Command bar

    private var commandBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "at").font(.body.weight(.bold)).foregroundStyle(Color.inkSun)
            TextField("@a clock  ·  @a pendulum  ·  @scientific calculator      (engines: @balance · @molar · @check)", text: $command)
                .font(.inkUI(16))
                .focused($commandFocused)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .onSubmit(runCmd)
            Button("Run", action: runCmd)
                .font(.inkUI(15, .semibold))
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .tint(Color.inkSun)
                .disabled(command.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(Color.inkCard, in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous).strokeBorder(Color.inkChrome, lineWidth: Theme.chromeWidth))
        .shadow(color: .black.opacity(0.08), radius: 8, y: 3)
        .padding(.horizontal, 12).padding(.top, 8)
    }

    private func runCmd() {
        let text = command.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        if isDeterministicEngineCommand(text) {
            // Correctness-critical work stays with the exact engines (READ vs COMPUTE), not generation.
            let result = runCommand(text)
            model.onInsertResult?(result, nil)
            showStatus(result)
        } else {
            // Everything else — "@a clock", "@a calculator", "@a pendulum sim", anything — is GENERATED
            // in real-time by Claude and rendered live (make-real).
            model.onMakeReal?(makeRealPrompt(text))
        }
        command = ""
        commandFocused = false   // dismiss the keyboard so the new object isn't covered
    }

    // MARK: Status toast

    private func statusToast(_ s: String) -> some View {
        Text(s)
            .font(.inkUI(15, .medium))
            .foregroundStyle(DockStyle.icon)
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(DockStyle.surface, in: Capsule())
            .overlay(Capsule().strokeBorder(DockStyle.rim, lineWidth: 1))
            .shadow(color: .black.opacity(0.2), radius: 6, y: 3)
            .padding(.bottom, 120)                    // clear of the dock at its default spot
            .transition(.opacity)
    }

    private func persistenceBanner(_ s: String) -> some View {
        Label(s, systemImage: "exclamationmark.triangle.fill")
            .font(.callout.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(Color.inkRust, in: RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous))
            .shadow(radius: 4)
            .padding(.horizontal, 16).padding(.top, 12)
            .accessibilityIdentifier("persistenceWarning")
    }

    private func showStatus(_ s: String) {
        guard !s.isEmpty else { withAnimation { status = nil }; return }
        withAnimation { status = s }
        Task {
            try? await Task.sleep(for: .seconds(2.8))
            withAnimation { if status == s { status = nil } }
        }
    }
}

/// Where the dock rests. `.floating` is the free, horizontal capsule; `.left`/`.right` snap it flush to
/// a side wall and reflow it VERTICAL. Persisted as a raw string via `@AppStorage`.
enum DockPlacement: String { case floating, left, right }

/// The floating dock: repositionable, collapsible, and edge-aware. It glides freely while dragging — the
/// drag is tracked in GLOBAL coordinates, so the dock can't chase its own movement (a `.local`-space drag
/// fed each frame's offset back into the next frame's translation, which is what made the old drag
/// jitter/vibrate). Released near a side wall it snaps flush and reflows vertical; released anywhere else
/// it floats horizontally. It holds ONLY the drag/placement state + the grip; the heavy toolbar content
/// lives in `DockBar`, whose only inputs (`model`, `axis`) are unchanged during a drag, so SwiftUI skips
/// its body and the inline pickers/menus are never rebuilt mid-drag. Center + placement persist (the
/// center as a FRACTION of the container, so it survives rotation and split-view resizes).
private struct FloatingDock: View {
    @ObservedObject var model: CanvasModel
    @AppStorage("inklab.dock.fx") private var fx = 0.5          // committed center X, fraction of width
    @AppStorage("inklab.dock.fy") private var fy = 0.94         // committed center Y, fraction of height
    @AppStorage("inklab.dock.placement") private var placement: DockPlacement = .floating
    /// Live finger translation in GLOBAL space. `nil` ⇒ no drag in flight; non-nil ⇒ dragging — which lets
    /// an edge-docked dock be pulled FREELY off its wall instead of staying pinned. Auto-resets to `nil`.
    @GestureState private var dragTranslation: CGSize? = nil
    @State private var barSize: CGSize = .zero                  // measured, so the clamp keeps it on-screen

    private var axis: Axis { placement == .floating ? .horizontal : .vertical }
    private let edgeInset: CGFloat = 14                         // gap kept between the dock and any wall
    /// One spring drives BOTH the snap (placement/center) and the post-reflow re-measure, so the
    /// horizontal↔vertical transition reads as a single motion instead of two contending settles.
    private let settle: Animation = .spring(response: 0.34, dampingFraction: 0.82)

    var body: some View {
        GeometryReader { geo in
            content(geo)
                .onGeometryChange(for: CGSize.self) { $0.size } action: { newSize in
                    guard newSize != barSize else { return }
                    // First measure: snap. Later changes (tool toggles, horizontal↔vertical reflow): animate
                    // so the re-clamp into its resting/pinned spot slides instead of popping.
                    if barSize == .zero { barSize = newSize }
                    else { withAnimation(settle) { barSize = newSize } }
                }
                // Hide the first, un-measured frame so a persisted edge placement can't flash mid-screen
                // before the real size pins it flush.
                .opacity(barSize == .zero ? 0 : 1)
                .position(livePosition(in: geo.size))
        }
        .ignoresSafeArea(.keyboard)
    }

    @ViewBuilder private func content(_ geo: GeometryProxy) -> some View {
        if model.dockCollapsed {
            puck(geo)
        } else {
            let layout = axis == .vertical ? AnyLayout(VStackLayout(spacing: 12))
                                           : AnyLayout(HStackLayout(spacing: 12))
            layout {
                grip(geo)
                DockBar(model: model, axis: axis)   // stable input → NOT rebuilt while dragging
            }
            .font(.title3)
            .foregroundStyle(DockStyle.icon)
            .padding(.horizontal, 16).padding(.vertical, 12)
            .dockSurface()
        }
    }

    /// Collapsed state: a small puck showing the active tool. Tap to expand; drag to move.
    private func puck(_ geo: GeometryProxy) -> some View {
        HStack(spacing: 6) {
            Image(systemName: model.tool.systemImage)
            Image(systemName: "chevron.up").font(.caption2).foregroundStyle(DockStyle.dim)
        }
        .font(.title3).foregroundStyle(DockStyle.icon)
        .padding(.horizontal, 16).padding(.vertical, 12)
        .dockSurface()
        .contentShape(Capsule())
        .onTapGesture { withAnimation(.spring(duration: 0.3)) { model.dockCollapsed = false } }
        // Larger slop on the puck: it ALSO taps-to-expand, so only a deliberate move should start a drag —
        // otherwise a slightly-wobbly tap gets swallowed as a micro-drag.
        .gesture(dockDrag(geo, minDistance: 10))
        .accessibilityIdentifier("expandToolbar")
    }

    /// The drag handle (only this moves the dock, so the tool buttons stay tappable). A generous hit area
    /// makes it easy to grab; small slop so it starts dragging immediately (the grip has no competing tap).
    private func grip(_ geo: GeometryProxy) -> some View {
        Image(systemName: "line.3.horizontal")
            .font(.body).foregroundStyle(DockStyle.dim)
            .padding(6)
            .contentShape(Rectangle())
            .gesture(dockDrag(geo, minDistance: 2))
            .accessibilityIdentifier("dockGrip")
    }

    private func dockDrag(_ geo: GeometryProxy, minDistance: CGFloat) -> some Gesture {
        // `.global` decouples the reported translation from the dock's own movement (no feedback loop → no
        // jitter). `minDistance` is small on the grip (instant) and larger on the tap-also puck.
        DragGesture(minimumDistance: minDistance, coordinateSpace: .global)
            .updating($dragTranslation) { value, state, _ in state = value.translation }
            .onEnded { value in endDrag(value.translation, in: geo.size) }
    }

    // MARK: Positioning

    private func committedCenter(in c: CGSize) -> CGPoint { CGPoint(x: fx * c.width, y: fy * c.height) }

    /// Where the dock ACTUALLY sits at rest right now — the persisted fraction run through the placement
    /// pin. The drag must start from HERE, not from the raw fraction: an edge-docked dock's stored `fx` is
    /// a stale horizontal value the pin overrides, so following the finger from it would jump on grab.
    private func currentRestingCenter(in c: CGSize) -> CGPoint { restingCenter(committedCenter(in: c), in: c) }

    /// The dock center this frame: free-following the finger mid-drag (edge pin released, so it can be
    /// pulled off a wall), otherwise resting at its committed/pinned spot.
    private func livePosition(in c: CGSize) -> CGPoint {
        let base = currentRestingCenter(in: c)
        if let t = dragTranslation {
            return clampToBounds(CGPoint(x: base.x + t.width, y: base.y + t.height), in: c)
        }
        return base
    }

    /// Resting position for the current placement: edge placements pin flush to the wall (x fixed by the
    /// CURRENT measured size, so the vertical bar sits snug after it reflows); floating just stays in bounds.
    private func restingCenter(_ p: CGPoint, in c: CGSize) -> CGPoint {
        let halfW = barSize.width / 2, halfH = barSize.height / 2
        let y = clamped(p.y, half: halfH, span: c.height)
        switch placement {
        case .left:     return CGPoint(x: halfW + edgeInset, y: y)
        case .right:    return CGPoint(x: c.width - halfW - edgeInset, y: y)
        case .floating: return CGPoint(x: clamped(p.x, half: halfW, span: c.width), y: y)
        }
    }

    private func clampToBounds(_ p: CGPoint, in c: CGSize) -> CGPoint {
        CGPoint(x: clamped(p.x, half: barSize.width / 2, span: c.width),
                y: clamped(p.y, half: barSize.height / 2, span: c.height))
    }

    /// Keep a center coordinate so the whole dock (± its half-extent + inset) stays within `span`.
    private func clamped(_ v: CGFloat, half: CGFloat, span: CGFloat) -> CGFloat {
        guard span > 0 else { return v }
        let lo = half + edgeInset, hi = span - half - edgeInset
        guard lo <= hi else { return span / 2 }                 // dock larger than the axis → center it
        return min(hi, max(lo, v))
    }

    /// On release: pick the placement from where it was dropped (push a wall ⇒ dock to it; drop in the
    /// middle ⇒ float), then spring into the resting/reflowed form. Persist the center as a fraction.
    private func endDrag(_ translation: CGSize, in c: CGSize) {
        guard c.width > 0, c.height > 0 else { return }
        let base = currentRestingCenter(in: c)                   // start from where it really sits (not raw fx)
        let rawX = base.x + translation.width
        let rawY = base.y + translation.height
        let halfW = barSize.width / 2
        let snapZone: CGFloat = 48                               // how close to a wall counts as "docked"
        let newPlacement: DockPlacement =
            (rawX - halfW) < snapZone        ? .left :
            (c.width - (rawX + halfW)) < snapZone ? .right : .floating
        let drop = clampToBounds(CGPoint(x: rawX, y: rawY), in: c)
        withAnimation(settle) {
            placement = newPlacement
            fx = drop.x / c.width
            fy = drop.y / c.height
        }
    }
}

/// The toolbar CONTENT — tools, contextual color/size, pen favorites, insert menu, undo/redo, page nav,
/// and the collapse button. A SEPARATE view with a single `@ObservedObject` input, so SwiftUI skips
/// re-rendering it while the dock is being dragged (the parent's offset changes, not this view's input).
private struct DockBar: View {
    @ObservedObject var model: CanvasModel
    /// Set by the dock: `.horizontal` for the floating capsule, `.vertical` when snapped to a side wall.
    /// Changing it reflows the whole bar via `AnyLayout` (preserving child identity, so it animates). It
    /// only changes on a snap — never mid-drag — so the drag-perf isolation still holds.
    var axis: Axis
    @State private var showColorPopover = false

    private static let quickColors = ["#1E2530", "#3D6FA3", "#C2452A", "#4E8A5E", "#E8742F", "#7E5AA6", "#2E8C86", "#FFFFFF"]

    var body: some View {
        let layout = axis == .vertical ? AnyLayout(VStackLayout(spacing: 11))
                                       : AnyLayout(HStackLayout(spacing: 11))
        layout {
            ForEach(CanvasTool.allCases) { tool in
                // The active tool sits on a small sun disc; the rest are quiet steel.
                Button { model.tool = tool } label: {
                    // The disc is a background, so it doesn't widen the dock (it spills into the spacing).
                    Image(systemName: tool.systemImage)
                        .foregroundStyle(model.tool == tool ? Color.white : DockStyle.dim)
                        .background(Circle().fill(model.tool == tool ? Color.inkSun : Color.clear).frame(width: 36, height: 36))
                }
            }
            // Color + thickness appear ONLY for the drawing tools (contextual — like GoodNotes/Notability).
            // Colors (scrollable strip + current/custom picker) are grouped together and kept SEPARATE
            // from thickness, so changing color never disturbs the chosen stroke width.
            if model.tool == .pen || model.tool == .highlighter {
                divider
                colorStrip
                customColorPicker
                divider
                sizeDots
            }
            divider
            Button { model.onAddSticky?() } label: { Image(systemName: "note.text.badge.plus") }
                .accessibilityIdentifier("addSticky")
            // The Socratic tutor gets its own button: lasso a problem (or not, for the whole page) and tap.
            Button { model.onTutor?() } label: { Image(systemName: "graduationcap") }
                .accessibilityIdentifier("tutor")
                .accessibilityLabel("Tutor")
            insertMenu
            divider
            Button { model.onUndo?() } label: { Image(systemName: "arrow.uturn.backward") }
                .accessibilityIdentifier("undo")
            Button { model.onRedo?() } label: { Image(systemName: "arrow.uturn.forward") }
                .accessibilityIdentifier("redo")
            divider
            Button { model.onPrevPage?() } label: { Image(systemName: axis == .vertical ? "chevron.up" : "chevron.left") }
                .accessibilityIdentifier("prevPage")
            Text(model.pageIndicator).font(.inkUI(15, .medium).monospacedDigit()).foregroundStyle(DockStyle.dim).frame(minWidth: 22)
            Button { model.onNextPage?() } label: { Image(systemName: axis == .vertical ? "chevron.down" : "chevron.right") }
                .accessibilityIdentifier("nextPage")
            divider
            Button { withAnimation(.spring(duration: 0.3)) { model.dockCollapsed = true } } label: {
                Image(systemName: axis == .vertical ? "chevron.compact.down" : "chevron.compact.right")
            }
            .accessibilityIdentifier("collapseToolbar")
        }
        .animation(.easeInOut(duration: 0.15), value: model.tool)
    }

    /// The active tool's saved colors in a FIXED-WIDTH horizontal scroller, so saving lots of colors
    /// scrolls sideways instead of widening the dock off the iPad screen. Tap to apply (color ONLY —
    /// the thickness is left alone), long-press to delete, and the dashed ＋ saves the current color.
    /// Persisted across launches.
    private var colorStrip: some View {
        // The strip scrolls along the dock's axis: a horizontal window when floating, a vertical one when
        // wall-docked — so the dock never grows past a fixed extent in either orientation.
        let vertical = axis == .vertical
        // Three swatches at a time (the rest scroll): with the Tutor button the dock must still fit a
        // portrait iPad (820 pt) while the pen's colors and sizes are showing.
        let window = min(CGFloat(max(model.currentColors.count, 1)) * 32, 92)
        let outer = vertical ? AnyLayout(VStackLayout(spacing: 8)) : AnyLayout(HStackLayout(spacing: 8))
        let inner = vertical ? AnyLayout(VStackLayout(spacing: 8)) : AnyLayout(HStackLayout(spacing: 8))
        return outer {
            ScrollView(vertical ? .vertical : .horizontal, showsIndicators: false) {
                inner {
                    ForEach(model.currentColors, id: \.self) { hex in
                        Button { model.useColor(hex) } label: { colorDot(hex) }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button(role: .destructive) { model.deleteColor(hex) } label: {
                                    Label("Delete color", systemImage: "trash")
                                }
                            }
                    }
                }
                .padding(vertical ? .horizontal : .vertical, 2)
            }
            .frame(width: vertical ? nil : window, height: vertical ? window : nil)
            Button { model.addCurrentColor() } label: {
                Image(systemName: "plus.circle.dashed").foregroundStyle(DockStyle.dim)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("addColor")
        }
    }

    /// A saved-color swatch: a fixed-size dot (its size no longer encodes stroke width — color and
    /// thickness are now independent) with an accent ring when it's the live pen color.
    private func colorDot(_ hex: String) -> some View {
        Circle()
            .fill(Color(hex: hex) ?? .gray)
            .frame(width: 24, height: 24)
            .overlay(Circle().strokeBorder(.white.opacity(0.6), lineWidth: 0.5))
            .overlay(Circle().strokeBorder(Color.inkSun, lineWidth: model.isActiveColor(hex) ? 2.5 : 0))
    }

    /// Live pen color — a LIGHTWEIGHT button (not an always-rendered `ColorPicker`/`UIColorWell`, which is
    /// expensive to reconcile every frame and made the dock drag stutter). Opens a popover with quick
    /// swatches + the system color picker; the heavy picker only exists while the popover is open.
    private var customColorPicker: some View {
        Button { showColorPopover = true } label: {
            Circle()
                .fill(model.penColor)
                .frame(width: 24, height: 24)
                .overlay(Circle().strokeBorder(.white.opacity(0.7), lineWidth: 1))
                .overlay(Circle().strokeBorder(.secondary.opacity(0.4), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showColorPopover) { penColorPopover.presentationCompactAdaptation(.popover) }
    }

    private var penColorPopover: some View {
        let cols = [GridItem(.adaptive(minimum: 38), spacing: 12)]
        return VStack(alignment: .leading, spacing: 14) {
            LazyVGrid(columns: cols, spacing: 12) {
                ForEach(DockBar.quickColors, id: \.self) { hex in
                    Button { if let c = Color(hex: hex) { model.penColor = c } } label: {
                        Circle().fill(Color(hex: hex) ?? .gray).frame(width: 34, height: 34)
                            .overlay(Circle().strokeBorder(.secondary.opacity(0.35), lineWidth: 0.5))
                            .overlay(Circle().strokeBorder(Color.inkSun,
                                lineWidth: model.penColor.hexString?.caseInsensitiveCompare(hex) == .orderedSame ? 3 : 0))
                    }
                    .buttonStyle(.plain)
                }
            }
            ColorPicker("Custom color", selection: $model.penColor, supportsOpacity: false)
        }
        .padding()
        .frame(width: 260)
        .foregroundStyle(.primary)          // the dock's light-on-slate foreground doesn't belong in the popover
    }

    /// Three thickness presets shown as graduated dots (tap to select).
    private var sizeDots: some View {
        let layout = axis == .vertical ? AnyLayout(VStackLayout(spacing: 10))
                                       : AnyLayout(HStackLayout(spacing: 10))
        return layout {
            ForEach(model.widthPresets, id: \.self) { w in
                Button { model.penWidth = w } label: {
                    Circle()
                        .fill(model.penWidth == w ? Color.inkSun : DockStyle.dim)
                        .frame(width: 6 + w, height: 6 + w)
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// "Insert / Actions" — the decluttered home for the less-frequent actions (was loose in the bar).
    private var insertMenu: some View {
        Menu {
            Button { model.onRecognize?() } label: { Label("Recognize", systemImage: "text.viewfinder") }
            Button { model.onCheckWork?() } label: { Label("Check work", systemImage: "checkmark.seal") }
                .accessibilityIdentifier("checkWork")
            Button { model.onFitCurve?() } label: { Label("Fit graph", systemImage: "chart.xyaxis.line") }
                .accessibilityIdentifier("fitCurve")
            // The native, engine-backed calculator (correct by construction, on-device, no cloud).
            Button { model.onInsertWidget?("scientificCalculator") } label: {
                Label("Calculator", systemImage: "plus.forwardslash.minus")
            }
            .accessibilityIdentifier("insertCalculator")
            Divider()
            Menu {
                ForEach(PaperType.allCases) { p in
                    Button { model.paper = p } label: { Label(p.label, systemImage: p.systemImage) }
                }
            } label: { Label("Paper", systemImage: "doc") }
        } label: { Image(systemName: "plus.circle") }
        .accessibilityIdentifier("insertMenu")
    }

    /// A thin separator that runs ACROSS the dock — a vertical hairline in the horizontal bar, a
    /// horizontal one when the bar is wall-docked vertical. (An explicit rect is predictable across the
    /// `AnyLayout` axis switch, where a plain `Divider` doesn't reliably pick up the new orientation.)
    private var divider: some View {
        Rectangle()
            .fill(DockStyle.divider)
            .frame(width: axis == .vertical ? 24 : 1, height: axis == .vertical ? 1 : 22)
    }
}

/// The dock's look: a slate capsule (the poster city's steel) with dome-white icons, a steel rim, and a
/// sun disc behind the active tool. The status toast wears the same surface.
enum DockStyle {
    static let surface = Color(uiColor: Theme.dynamic(0x2E3542, 0x2B3447))
    static let rim = Color(uiColor: Theme.dynamic(0x4B5464, 0x48536B))
    static let icon = Color(rgb: 0xEFEAE6)
    static let dim = Color(rgb: 0xA6AFBA)
    static let divider = Color.white.opacity(0.16)
}

private extension View {
    func dockSurface() -> some View {
        background(DockStyle.surface, in: Capsule())
            .overlay(Capsule().strokeBorder(DockStyle.rim, lineWidth: 1))
            .shadow(color: .black.opacity(0.22), radius: 8, y: 4)
    }
}

/// Bridges the SwiftUI tool state to the UIKit canvas.
private struct CanvasRepresentable: UIViewControllerRepresentable {
    @ObservedObject var model: CanvasModel
    let notebookID: UUID
    var onStatus: (String) -> Void
    var onPersistenceWarning: (String) -> Void

    func makeUIViewController(context: Context) -> CanvasViewController {
        let vc = CanvasViewController()
        vc.notebookID = notebookID   // set BEFORE the view loads so the lazy store/storage key off it
        vc.onStatus = onStatus
        vc.onPersistenceWarning = onPersistenceWarning
        vc.onRecognized = { [weak model] draft in model?.pendingRecognition = draft }
        vc.onSelectTool = { [weak model] tool in model?.tool = tool }
        model.onUndo = { [weak vc] in vc?.performUndo() }
        model.onRedo = { [weak vc] in vc?.performRedo() }
        model.onAddSticky = { [weak vc] in vc?.addSticky() }
        model.onInsertResult = { [weak vc] text, pageID in vc?.insertResult(text, onPage: pageID) }
        model.onRecognize = { [weak vc] in vc?.recognizeSelectionOrPage() }
        model.onCheckWork = { [weak vc] in vc?.checkWork() }
        model.onTutor = { [weak vc] in vc?.startTutor() }
        model.onFitCurve = { [weak vc] in vc?.fitLassoedSketch() }
        model.onInsertWidget = { [weak vc] kind in vc?.insertWidget(kind: kind) }
        model.onMakeReal = { [weak vc] prompt in vc?.makeReal(prompt: prompt) }
        model.onNextPage = { [weak vc] in vc?.goToNextPage() }
        model.onPrevPage = { [weak vc] in vc?.goToPreviousPage() }
        vc.onPageChanged = { [weak model] idx, count in
            // Defer out of the SwiftUI update cycle — the canvas reports the initial page during its
            // own layout, and publishing to `model` mid-update triggers the "Publishing changes from
            // within view updates" warning.
            DispatchQueue.main.async { model?.pageIndicator = count > 1 ? "\(idx)/\(count)" : "\(idx)" }
        }
        vc.apply(paper: model.paper, penColor: UIColor(model.penColor), penWidth: model.penWidth,
                 tool: model.tool, fingerDrawing: model.fingerDrawing, autoCommands: model.autoCommands,
                 snapShapesOnHold: model.snapShapesOnHold, makeRealSession: model.makeRealSession)
        return vc
    }

    static func dismantleUIViewController(_ uiViewController: CanvasViewController, coordinator: ()) {
        uiViewController.prepareForDismissal()
    }

    func updateUIViewController(_ vc: CanvasViewController, context: Context) {
        // `apply` is idempotent (early-returns when nothing changed), so the occasional extra call from a
        // SwiftUI re-render is cheap.
        vc.apply(paper: model.paper, penColor: UIColor(model.penColor), penWidth: model.penWidth,
                 tool: model.tool, fingerDrawing: model.fingerDrawing, autoCommands: model.autoCommands,
                 snapShapesOnHold: model.snapShapesOnHold, makeRealSession: model.makeRealSession)
    }
}
