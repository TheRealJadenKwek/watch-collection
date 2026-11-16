import SwiftUI
#if os(macOS)
import AppKit
#endif

/// The ring editor (brief section 7): fixes what the automatic cutout got wrong. The ring is the whole "move, size"
/// control: moving it moves the watch, resizing it rescales. Shaped like PhotoFramingSheet.
struct BoxCutoutEditor: View {
    @ObservedObject var store: AppStore
    let piece: BoxPiece
    let finish: BoxFinish
    var emptyTile: CGImage?
    @Environment(\.dismiss) private var dismiss

    /// The case ring as stored: centre as fractions of the photo's width and height, radius of its shorter side.
    struct Ring: Equatable {
        var x: Double
        var y: Double
        var r: Double
    }

    private struct Edit: Hashable {
        var photo: String
        var ring: Ring?
        var turn: Double
        var caseOnly: Bool

        static func == (a: Edit, b: Edit) -> Bool {
            a.photo == b.photo && a.ring == b.ring && a.turn == b.turn && a.caseOnly == b.caseOnly
        }

        func hash(into hasher: inout Hasher) {
            hasher.combine(photo)
            hasher.combine(ring?.x)
            hasher.combine(ring?.y)
            hasher.combine(ring?.r)
            hasher.combine(turn)
            hasher.combine(caseOnly)
        }
    }

    @State private var photo: String
    @State private var ring: Ring?
    @State private var turn: Double
    @State private var caseOnly: Bool
    @State private var image: CGImage?
    @State private var thumbnails: [String: CGImage] = [:]
    @State private var result: CutoutResult?
    @State private var gestureStart: (ring: Ring, turn: Double)?
    /// True while a ring gesture runs; it resets by itself when the gesture ends or is cancelled.
    @GestureState private var ringGestureActive = false
    @State private var saving = false
    private let initial: Edit

    init(store: AppStore, piece: BoxPiece, finish: BoxFinish, emptyTile: CGImage? = nil, shownPhoto: String? = nil) {
        self.store = store
        self.piece = piece
        self.finish = finish
        self.emptyTile = emptyTile
        let setting = piece.setting
        let photo = setting?.photo ?? shownPhoto.flatMap { piece.photos.contains($0) ? $0 : nil } ?? piece.photos.first ?? ""
        let ring = setting.flatMap { s in s.x.flatMap { x in s.y.flatMap { y in s.r.map { r in Ring(x: x, y: y, r: r) } } } }
        let edit = Edit(photo: photo, ring: ring, turn: setting?.turn ?? 0, caseOnly: setting?.caseOnly == true)
        initial = edit
        _photo = State(initialValue: edit.photo)
        _ring = State(initialValue: edit.ring)
        _turn = State(initialValue: edit.turn)
        _caseOnly = State(initialValue: edit.caseOnly)
    }

    private var edit: Edit { Edit(photo: photo, ring: ring, turn: turn, caseOnly: caseOnly) }

    /// Where the ring is drawn: as set by hand, else where the pipeline found the case.
    private var shownRing: Ring {
        if let ring { return ring }
        if let result, result.photo == photo { return Ring(x: result.centerX, y: result.centerY, r: result.radius) }
        return Ring(x: 0.5, y: 0.5, r: 0.25)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 22) {
                    preview
                    photoWithRing
                    turnControl
                    if piece.photos.count > 1 { photoStrip }
                    caseOnlyToggle
                    HStack(spacing: 10) {
                        Button("Reset") { reset() }
                            .quietButton()
                            .disabled(piece.setting == nil && edit == initial)
                        Button("Done") { save() }
                            .prominentButton()
                            .disabled(saving || photo.isEmpty)
                    }
                    .padding(.top, 4)
                }
                .padding(16)
            }
            .background(WatchTheme.background)
            .navigationTitle("Adjust Cutout")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(role: .cancel) { dismiss() }
                }
            }
            .task(id: photo) { await loadPhoto() }
            .task { await loadThumbnails() }
            .task(id: edit) {
                // 150 ms after the last change; the previous cutout stays until the new one lands.
                if result != nil { try? await Task.sleep(for: .milliseconds(150)) }
                guard !Task.isCancelled, !photo.isEmpty else { return }
                let setting = BoxCutout(photo: photo, x: ring?.x, y: ring?.y, r: ring?.r, turn: turn, caseOnly: caseOnly)
                let hint = CutoutStore.hint(for: setting, focus: piece.focus?[photo])
                let made = await CutoutStore.shared.cutout(directory: piece.directory, photo: photo, hint: hint,
                                                           wishlist: piece.wishlist, itemID: piece.itemID)
                guard !Task.isCancelled, let made else { return }
                withAnimation(.easeInOut(duration: 0.25)) { result = made }
            }
        }
        .desktopSheet(width: 520, height: 820)
    }

    // MARK: Preview

    /// One compartment of this finish, drawn by the box's own painter.
    private var preview: some View {
        let content = BoxSlotContent.make(
            picture: emptyTile == nil ? .pillow : .emptyTile(""), tileImage: nil, cutout: result,
            diameter: piece.diameter, dialName: piece.dial
        )
        return BoxSceneView(geometry: BoxGeometry(columns: 1, rows: 1), finish: finish, orientation: .front, lidClosed: false,
                            slots: [0: content], emptyTile: emptyTile)
            .frame(height: 200)
            .frame(maxWidth: .infinity)
    }

    // MARK: Photo and ring

    private var photoWithRing: some View {
        VStack(spacing: 8) {
            GeometryReader { proxy in
                let frame = fitted(in: proxy.size)
                ZStack(alignment: .topLeading) {
                    if let image {
                        Image(decorative: image, scale: 1)
                            .resizable()
                            .frame(width: frame.width, height: frame.height)
                            .offset(x: frame.minX, y: frame.minY)
                        ringOverlay(frame: frame, size: proxy.size)
                    } else {
                        ProgressView()
                            .frame(width: proxy.size.width, height: proxy.size.height)
                    }
                }
                .frame(width: proxy.size.width, height: proxy.size.height)
                .contentShape(Rectangle())
                .gesture(ringGesture(frame: frame))
            }
            .frame(height: 320)
            .background(Color.black)
            #if os(macOS)
            .background(ScrollWheelReader { points in scrollResize(points) })
            #endif
            .clipped()
            .onChange(of: ringGestureActive) { _, active in
                // A cancelled gesture never reaches onEnded: start the next one from where the ring is.
                if !active { gestureStart = nil }
            }
            .accessibilityElement()
            .accessibilityLabel("Photo with the case ring")
            .accessibilityAdjustableAction { direction in
                var next = shownRing
                next.r = clampRadius(next.r + (direction == .increment ? 0.01 : -0.01))
                ring = next
            }
            Text(Platform.isMac ? "Drag the ring onto the case. Pinch or scroll to size it." : "Drag the ring onto the case. Pinch to size it, twist to turn it.")
                .font(AtelierType.caption)
                .foregroundStyle(WatchTheme.muted)
        }
    }

    /// The photo's rectangle, aspect fit, in the view.
    private func fitted(in size: CGSize) -> CGRect {
        guard let image, image.width > 0, image.height > 0, size.width > 0, size.height > 0 else { return .zero }
        let scale = min(size.width / CGFloat(image.width), size.height / CGFloat(image.height))
        let w = CGFloat(image.width) * scale, h = CGFloat(image.height) * scale
        return CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h)
    }

    /// The ring in accent, 2 pt, a tick at 12 o'clock (the way the cutout will stand), and the outside dimmed.
    private func ringOverlay(frame: CGRect, size: CGSize) -> some View {
        let shown = shownRing
        let center = CGPoint(x: frame.minX + shown.x * frame.width, y: frame.minY + shown.y * frame.height)
        let radius = shown.r * min(frame.width, frame.height)
        let angle = (result?.photo == photo ? result?.rotation : nil) ?? turn
        return Canvas { context, canvasSize in
            var outside = Path(CGRect(origin: .zero, size: canvasSize))
            outside.addEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
            context.fill(outside, with: .color(.black.opacity(0.45)), style: FillStyle(eoFill: true))
            let circle = Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
            context.stroke(circle, with: .color(WatchTheme.accent), lineWidth: 2)
            let radians = angle * .pi / 180
            let direction = CGPoint(x: sin(radians), y: -cos(radians))
            let tick = Path { path in
                path.move(to: CGPoint(x: center.x + direction.x * radius, y: center.y + direction.y * radius))
                path.addLine(to: CGPoint(x: center.x + direction.x * (radius + 12), y: center.y + direction.y * (radius + 12)))
            }
            context.stroke(tick, with: .color(WatchTheme.accent), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
        }
        .frame(width: size.width, height: size.height)
        .allowsHitTesting(false)
    }

    private func ringGesture(frame: CGRect) -> some Gesture {
        SimultaneousGesture(SimultaneousGesture(DragGesture(minimumDistance: 1), MagnifyGesture()), RotateGesture())
            .updating($ringGestureActive) { _, active, _ in active = true }
            .onChanged { value in
                guard frame.width > 0, frame.height > 0 else { return }
                let start = gestureStart ?? (shownRing, turn)
                if gestureStart == nil { gestureStart = start }
                let translation = value.first?.first?.translation ?? .zero
                let magnification = Double(value.first?.second?.magnification ?? 1)
                ring = Ring(
                    x: min(1, max(0, start.ring.x + Double(translation.width / frame.width))),
                    y: min(1, max(0, start.ring.y + Double(translation.height / frame.height))),
                    r: clampRadius(start.ring.r * magnification)
                )
                if let rotation = value.second?.rotation.degrees, rotation != 0 {
                    turn = snapped(min(180, max(-180, start.turn + rotation)))
                }
            }
            .onEnded { _ in gestureStart = nil }
    }

    private func clampRadius(_ r: Double) -> Double {
        min(BoxCutout.ringRadius.upperBound, max(BoxCutout.ringRadius.lowerBound, r))
    }

    /// The Mac's scroll wheel or two-finger scroll over the photo sizes the ring (brief 7.2): 100 points of scroll
    /// make it about half as big again.
    private func scrollResize(_ points: Double) {
        guard image != nil, points != 0 else { return }
        var next = shownRing
        next.r = clampRadius(next.r * Self.scrollFactor(points))
        ring = next
    }

    /// How much a scroll of `points` (up positive) scales the ring.
    static func scrollFactor(_ points: Double) -> Double {
        exp(points * 0.004)
    }

    // MARK: Turn

    private var turnControl: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Turn")
                    .font(.system(.body, weight: .bold))
                    .foregroundStyle(WatchTheme.ink)
                Spacer()
                Text("\(Int(turn.rounded()))°")
                    .font(AtelierType.detail)
                    .monospacedDigit()
                    .foregroundStyle(WatchTheme.muted)
            }
            Slider(value: Binding(get: { turn }, set: { turn = snapped($0) }), in: -180...180)
                .accessibilityValue("\(Int(turn.rounded())) degrees")
        }
    }

    /// Detents at 0 and a quarter either way.
    private func snapped(_ value: Double) -> Double {
        for detent in [-90.0, 0, 90] where abs(value - detent) < 4 { return detent }
        return value
    }

    // MARK: Photos

    private var photoStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(piece.photos, id: \.self) { file in
                    Button {
                        guard file != photo else { return }
                        // Another photo starts automatic again.
                        photo = file
                        ring = nil
                        turn = 0
                        result = nil
                    } label: {
                        Group {
                            if let thumbnail = thumbnails[file] {
                                Image(decorative: thumbnail, scale: 1)
                                    .resizable()
                                    .scaledToFill()
                            } else {
                                WatchTheme.card
                            }
                        }
                        .frame(width: 56, height: 56)
                        .clipped()
                        .overlay {
                            if file == photo { Rectangle().stroke(WatchTheme.accent, lineWidth: 2) }
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Photo \((piece.photos.firstIndex(of: file) ?? 0) + 1)")
                    .accessibilityAddTraits(file == photo ? .isSelected : [])
                }
            }
        }
    }

    private var caseOnlyToggle: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle("Case only", isOn: $caseOnly)
                .font(.system(.body, weight: .bold))
                .tint(.green)
            Text("Use when a hand or the background came along.")
                .font(AtelierType.caption)
                .foregroundStyle(WatchTheme.muted)
        }
    }

    private func localURL(_ file: String) -> URL? {
        PhotoStore.asset(itemID: piece.itemID, filename: file, wishlist: piece.wishlist, baseURL: nil)
            .flatMap(PhotoStore.existingLocalURL)
    }

    private func loadPhoto() async {
        guard let url = localURL(photo) else {
            image = nil
            return
        }
        let loaded = await Task.detached(priority: .userInitiated) { CutoutPipeline.load(url) }.value
        image = loaded
    }

    private func loadThumbnails() async {
        for file in piece.photos where thumbnails[file] == nil {
            guard let url = localURL(file) else { continue }
            if let thumbnail = await Task.detached(priority: .utility, operation: { CutoutPipeline.load(url, maxSide: 168) }).value {
                thumbnails[file] = thumbnail
            }
        }
    }

    // MARK: Saving

    private func save() {
        saving = true
        var value: BoxCutout? = BoxCutout(photo: photo, x: ring?.x, y: ring?.y, r: ring?.r, turn: turn, caseOnly: caseOnly,
                                          useCutout: piece.setting?.useCutout).normalized
        // Nothing changed on an automatic watch: it stays automatic.
        if piece.setting == nil, edit == initial { value = nil }
        Task {
            await store.setBoxCutout(itemID: piece.itemID, wishlist: piece.wishlist, cutout: value)
            saving = false
            dismiss()
        }
    }

    /// Back to automatic. A refused tile stays refused: `useCutout` is kept, on the photo automatic picks (brief 6.2),
    /// so the box shows the automatic cutout and not his photo's tile.
    private func reset() {
        saving = true
        Task {
            var value: BoxCutout?
            if piece.setting?.useCutout == true {
                let automatic = CutoutSource(itemID: piece.itemID, wishlist: piece.wishlist, photos: piece.photos, setting: nil, focus: piece.focus)
                let picked = await CutoutStore.shared.cutout(automatic)?.photo
                if let photo = picked.flatMap({ piece.photos.contains($0) ? $0 : nil }) ?? piece.photos.first {
                    value = BoxCutout(photo: photo, useCutout: true)
                }
            }
            await store.setBoxCutout(itemID: piece.itemID, wishlist: piece.wishlist, cutout: value)
            saving = false
            dismiss()
        }
    }
}

#if os(macOS)
/// Hands the scroll wheel over this view's area to `onScroll` (points, up positive) instead of the scroll view around
/// it. It takes no clicks, so the drag and pinch on the photo work as before.
private struct ScrollWheelReader: NSViewRepresentable {
    var onScroll: (Double) -> Void

    func makeNSView(context: Context) -> WheelView {
        let view = WheelView()
        view.onScroll = onScroll
        return view
    }

    func updateNSView(_ view: WheelView, context: Context) {
        view.onScroll = onScroll
    }

    static func dismantleNSView(_ view: WheelView, coordinator: ()) {
        view.stopListening()
    }

    final class WheelView: NSView {
        var onScroll: ((Double) -> Void)?
        private var monitor: Any?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopListening()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self, let window = self.window, event.window === window, !self.isHiddenOrHasHiddenAncestor,
                      self.visibleRect.contains(self.convert(event.locationInWindow, from: nil)) else { return event }
                // A mouse wheel reports lines, a trackpad points. The glide after a trackpad flick is swallowed too,
                // so the sheet does not scroll under the pointer, but it does not keep resizing the ring.
                if event.momentumPhase.isEmpty {
                    let points = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * 10
                    self.onScroll?(Double(points))
                }
                return nil
            }
        }

        func stopListening() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
    }
}
#endif
