import SwiftUI

/// Where the Boxes tab should open, set by the watch page and the wishlist (`AppStore.openBoxes`).
enum BoxIntent: Equatable {
    /// An owned watch: its box with it selected, or armed for placing when it is in no box.
    case show(String)
    /// An owned watch armed for placing (selected instead when it already has a place).
    case place(String)
    /// A wishlist candidate armed for a trial, the first open space outlined.
    case tryOn(String)
}

/// A watch or candidate from the tray, picked for placing.
struct BoxChip: Equatable, Hashable {
    var itemID: String
    var wishlist: Bool
}

/// The drag in progress. Kept apart from the screen's state so following the finger redraws only the preview.
@MainActor @Observable
final class BoxDragModel {
    struct Lift {
        var piece: BoxPiece
        /// The compartment it came from; nil for a chip from the tray.
        var origin: Int?
        var content: BoxSlotContent
        /// The box it is drawn for, at the box's scale.
        var painter: BoxPainter
        /// From the finger to the middle of what it holds.
        var grab: CGSize
    }

    var lift: Lift?
    var location: CGPoint = .zero
    /// A drop has been sent and is waiting for the collection to change.
    @ObservationIgnored var dropping = false
    /// iPhone: counts presses held long enough to lift, and whether one is down, so a still hold can select its
    /// compartment once it has lasted half a second (`BoxesScreen.pressBegan`).
    @ObservationIgnored var press = 0
    @ObservationIgnored var pressing = false
}

#if os(iOS)
/// iPhone: press 0.22 s, then drag, as one UIKit long press. A SwiftUI `LongPressGesture` sequenced before a
/// `DragGesture` keeps the scroll view from scrolling when a swipe starts on it; this recognizer fails once the finger
/// moves 10 pt inside the 0.22 s, so a swipe that starts on a watch scrolls the page. Locations are in `space`.
struct LiftPress: UIGestureRecognizerRepresentable {
    enum Phase { case began, changed, ended, cancelled }

    var space: String
    var action: (_ phase: Phase, _ location: CGPoint, _ start: CGPoint) -> Void

    final class Coordinator {
        var start = CGPoint.zero
    }

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

    func makeUIGestureRecognizer(context: Context) -> UILongPressGestureRecognizer {
        let recognizer = UILongPressGestureRecognizer()
        recognizer.minimumPressDuration = 0.22
        recognizer.allowableMovement = 10
        return recognizer
    }

    func handleUIGestureRecognizerAction(_ recognizer: UILongPressGestureRecognizer, context: Context) {
        let location = context.converter.location(in: .named(space))
        switch recognizer.state {
        case .began:
            context.coordinator.start = location
            action(.began, location, location)
        case .changed:
            action(.changed, location, context.coordinator.start)
        case .ended:
            action(.ended, location, context.coordinator.start)
        case .cancelled, .failed:
            action(.cancelled, location, context.coordinator.start)
        default:
            break
        }
    }
}
#endif

/// Frames a drag needs, kept out of view state so scrolling does not redraw the screen.
final class BoxFrames {
    var stage: CGRect = .zero
    /// The scroll view's own frame. It already starts below the bar and ends above the tray (or the tab bar where
    /// there is no tray): its content insets for those bars are not added again.
    var scroll: CGRect = .zero
    var tray: CGRect = .zero
    /// The scroll view's offset from its top, and how far it can go.
    var offset: CGFloat = 0
    var maxOffset: CGFloat = 0
    /// The box is in the scroll view (a phone or a column); false where it stands in a fixed pane.
    var stageScrolls = true

    /// The top of what the scroll view shows of its content.
    var visibleTop: CGFloat { scroll.minY }
    /// The bottom of what the scroll view shows: the docked tray, or the end of its frame.
    var visibleBottom: CGFloat {
        let end = scroll.height > 0 ? scroll.maxY : .infinity
        return tray.height > 0 ? min(tray.minY, end) : end
    }

    /// True where the box is on screen: inside its frame and, when it scrolls, below the bar and above the tray.
    func showsBox(at point: CGPoint) -> Bool {
        guard stage.contains(point) else { return false }
        guard stageScrolls else { return true }
        if point.y >= visibleBottom { return false }
        if scroll.height > 0, point.y < visibleTop { return false }
        return true
    }

    /// While a watch is dragged: -8 (up) in the top 60 pt of what the scroll view shows or up to 40 pt above it, 8
    /// (down) in the bottom 60 pt above the tray or the tab bar, otherwise 0.
    func autoScrollStep(at y: CGFloat) -> CGFloat {
        let top = visibleTop, bottom = visibleBottom
        if y < top + 60, y > top - 40 { return -8 }
        if y > bottom - 60, y < bottom { return 8 }
        return 0
    }

    /// How far to scroll so `rect` (in the screen's space) shows with 12 pt to spare below the bar and above the tray;
    /// 0 when it already does.
    func revealDelta(for rect: CGRect) -> CGFloat {
        let top = visibleTop + 12, bottom = visibleBottom - 12
        if rect.maxY > bottom { return rect.maxY - bottom }
        if rect.minY < top { return rect.minY - top }
        return 0
    }
}

/// The Boxes tab (brief sections 8 and 9): the box on screen, its controls and info panel, and the watches that can
/// go in it, docked at the bottom on a phone so a drag can always reach them. One view tree in every posture: the
/// pieces (`header`, `stage`, `controls`, `infoPanel`, `tray`, `chipGrids`) go into the two panes of `BoxPanes`, a
/// fixed one and a scrolling one, and only where those panes stand changes with the posture.
struct BoxesScreen: View {
    @ObservedObject var store: AppStore
    let showSettings: () -> Void

    @AppStorage("boxSelectedV1") private var selectedBoxID = "black"
    @AppStorage("boxTurnedV1") private var turned = false
    @State private var lidClosed = false
    @State private var selection: Int?
    @State private var armed: BoxChip?
    @State private var emphasized: Int?
    @State private var trayShowsWishlist = false
    @State private var showsTrial = true
    @State private var art = BoxArtwork()
    @State private var drag = BoxDragModel()
    @State private var frames = BoxFrames()
    @State private var dragging: String?
    @State private var arriving: String?
    @State private var settles: [String: Int] = [:]
    @State private var lastDragEnd = Date.distantPast
    /// The compartment a still press last selected, and when, so the button's own tap at the release does not undo it.
    @State private var lastHold = (slot: -1, at: Date.distantPast)
    @State private var liftTick = 0
    @State private var dropTick = 0
    @State private var scroll = ScrollPosition(edge: .top)
    @State private var autoScroll: Task<Void, Never>?
    @State private var turnAngle = 0.0
    @State private var turnScale: CGFloat = 1
    @State private var turnHeight: CGFloat?
    @State private var turning = false
    @State private var pageWidth: CGFloat = 0
    /// The space the fixed pane gives the box (a book's left page, a table's top pane below its header, the Mac's
    /// left side).
    @State private var fixedSpace: CGSize = .zero
    /// Where the panes stand in the window, for the crease; and their width, for the Mac's side column.
    @State private var panesFrame: CGRect = .zero
    @State private var managing = false
    @State private var editing: BoxEditTarget?
    @State private var path = NavigationPath()
    @GestureState private var gesturing = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.pageMargin) private var margin
    @Environment(\.duo) private var duo
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.displayScale) private var displayScale
    @Environment(\.sectionIsActive) private var sectionIsActive
    @Environment(\.openPage) private var openPage

    static let space = "boxes"

    // MARK: What is on screen

    /// Everything the screen shows, worked out once per update.
    struct Scene {
        var arrangement: BoxArrangement
        var box: WatchBox
        var geometry: BoxGeometry
        var finish: BoxFinish
        var orientation: BoxOrientation
        /// What each compartment shows: the owned watch, or a candidate on trial while "Trying" is on.
        var occupants: [Int: BoxPiece]
        var items: [BoxStageItem]
        var emptyTile: CGImage?
        var trial: [Int: String]
        var showingTrial: Bool
        var steppingOut: [Watch]
        var loose: [Watch]
        var candidates: [WishlistItem]
        var watches: [String: Watch]
        var wishlist: [String: WishlistItem]
        var boxWidth: CGFloat
        var k: CGFloat

        var stageHeight: CGFloat { geometry.size(orientation).height * k }
        func piece(_ chip: BoxChip) -> BoxPiece? {
            chip.wishlist ? wishlist[chip.itemID].map(BoxPiece.init(candidate:)) : watches[chip.itemID].map(BoxPiece.init(watch:))
        }
    }

    private var boxes: [WatchBox] { store.data?.boxes ?? [] }

    /// How the screen stands in this posture (brief section 9).
    private var arrangement: BoxArrangement {
        BoxArrangement.of(duo, mac: Platform.isMac, width: panesFrame.width)
    }

    /// The space the box is given: a column's width, or what a fixed pane leaves it.
    private func stageSpace(_ arrangement: BoxArrangement, trial: Bool) -> CGSize {
        let pad = BoxArrangement.wellPadding
        switch arrangement {
        case .phone:
            return CGSize(width: max(200, pageWidth - 2 * WatchTheme.narrowMargin), height: 0)
        case .column:
            return CGSize(width: max(200, pageWidth - 2 * (Platform.isMac ? margin : 20)), height: 0)
        case .book:
            return CGSize(width: fixedSpace.width - 2 * pad, height: fixedSpace.height - 2 * pad)
        case .table:
            return CGSize(width: fixedSpace.width - 2 * max(margin, 20), height: fixedSpace.height - 2 * pad)
        case .desk:
            // Room under the box for the info panel, and for the trial switch while a trial is on.
            let panel: CGFloat = 230 + (trial ? 100 : 0)
            return CGSize(width: fixedSpace.width - 2 * margin, height: fixedSpace.height - 2 * 20 - 22 - panel)
        }
    }

    private func makeScene() -> Scene? {
        guard let data = store.data, let box = boxes.first(where: { $0.id == selectedBoxID }) ?? boxes.first else { return nil }
        let geometry = BoxGeometry(columns: box.columns, rows: box.rows)
        let finish = BoxFinish(name: box.finish)
        let arrangement = arrangement
        let trial = store.boxTrial.candidates(in: box.id)
        let fit = BoxArrangement.stage(geometry, arrangement, space: stageSpace(arrangement, trial: !trial.isEmpty),
                                       turned: turned, mac: Platform.isMac)
        let orientation = fit.orientation
        let watches = Dictionary(data.watches.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let wishlist = Dictionary(data.wishlist.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let showingTrial = showsTrial && !trial.isEmpty
        var occupants: [Int: BoxPiece] = [:]
        for slot in 0..<box.capacity {
            if showingTrial, let id = trial[slot], let candidate = wishlist[id] {
                occupants[slot] = BoxPiece(candidate: candidate)
            } else if let id = box.watchID(at: slot), let watch = watches[id] {
                occupants[slot] = BoxPiece(watch: watch)
            }
        }
        let emptyFile = data.emptyBoxTiles?[finish.rawValue]
        let emptyTile = emptyFile.flatMap { art.tile(PhotoStore.boxTileDirectory, $0) }
        let items = occupants.keys.sorted().compactMap { slot -> BoxStageItem? in
            guard let piece = occupants[slot] else { return nil }
            let drawn = content(piece, finish: finish, emptyBoxTiles: data.emptyBoxTiles)
            return BoxStageItem(piece: piece, slot: slot, content: drawn.content, look: drawn.look)
        }
        let k = fit.k
        let width = geometry.size(orientation).width * k
        return Scene(
            arrangement: arrangement, box: box, geometry: geometry, finish: finish, orientation: orientation, occupants: occupants, items: items,
            emptyTile: emptyTile, trial: trial, showingTrial: showingTrial,
            steppingOut: showingTrial ? store.boxTrial.steppingOut(of: box.id, in: data).compactMap { watches[$0] } : [],
            loose: BoxModel.tray(data),
            candidates: WishlistScreen.ranked(data.wishlist, scores: store.scores).filter { $0.status != "bought" },
            watches: watches, wishlist: wishlist, boxWidth: width, k: k
        )
    }

    /// What a piece's compartment shows in this finish (brief 5.3 step 5), and a key that changes with the picture.
    private func content(_ piece: BoxPiece, finish: BoxFinish, emptyBoxTiles: [String: String]?) -> (content: BoxSlotContent, look: String) {
        let cutout = art.cutout(piece)
        let picture = BoxModel.picture(
            finish: finish.rawValue, boxTiles: piece.boxTiles, cutout: piece.setting, emptyBoxTiles: emptyBoxTiles,
            hasTile: { art.tile(piece.directory, $0) != nil },
            hasEmptyTile: { art.tile(PhotoStore.boxTileDirectory, $0) != nil }
        )
        var tile: CGImage?
        if case .tile(let file) = picture { tile = art.tile(piece.directory, file) }
        let content = BoxSlotContent.make(picture: picture, tileImage: tile, cutout: cutout?.result, diameter: piece.diameter,
                                          dialName: piece.dial, isTrial: piece.wishlist)
        let look = tile != nil ? "tile" : cutout?.result != nil ? "cutout-\(cutout?.revision ?? 0)" : "token"
        return (content, look)
    }

    private func painter(_ scene: Scene) -> BoxPainter {
        BoxPainter(geometry: scene.geometry, palette: .of(scene.finish), orientation: scene.orientation, lidClosed: false,
                   slots: [:], trialTag: "TRYING", k: scene.k, emptyTile: scene.emptyTile)
    }

    // MARK: Body

    var body: some View {
        let scene = makeScene()
        SectionStack(path: $path) {
            page(scene)
                #if os(iOS)
                .navigationDestination(for: WatchRoute.self) { route in
                    WatchDossierView(store: store, watchID: route.id)
                }
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) { GearToolbarButton(action: showSettings) }
                    // Half open on a table the compact header stands in the bar, so the box above the crease keeps
                    // the height.
                    if let scene, scene.arrangement == .table {
                        ToolbarItem(placement: .principal) { compactHeader(scene) }
                    }
                }
                #else
                .desktopHeader("Boxes", subtitle: scene.map { "\($0.box.name), \(subtitle($0))" }) {
                    deskHeaderLeading(scene)
                } trailing: {
                    deskHeaderTrailing(scene)
                }
                #endif
        }
        .pageAppear()
        .sheet(isPresented: $managing) {
            BoxManageSheet(store: store, selectedBoxID: $selectedBoxID)
        }
        .sheet(item: $editing) { target in
            BoxCutoutEditor(store: store, piece: target.piece, finish: target.finish, emptyTile: target.emptyTile,
                            shownPhoto: target.shownPhoto)
        }
        .onChange(of: store.boxIntent, initial: true) { _, intent in
            guard let intent else { return }
            consume(intent)
            store.boxIntent = nil
        }
        .onChange(of: gesturing) { _, active in
            // A drag the system took away (a call, the app going to the background) ends without a drop: put the
            // watch back.
            if !active, drag.lift != nil, !drag.dropping { endDrag() }
        }
        .onDisappear {
            Task { await CutoutStore.shared.cancelPending() }
        }
        .sensoryFeedback(.impact(weight: .light), trigger: liftTick)
        .sensoryFeedback(.impact(weight: .light), trigger: dropTick)
        #if DEBUG
        .task { await runProbe() }
        #endif
    }

    @ViewBuilder
    private func page(_ scene: Scene?) -> some View {
        if store.data != nil, boxes.isEmpty {
            noBoxes
                .screenBackground()
        } else if let scene {
            ZStack(alignment: .topLeading) {
                BoxPanes(arrangement: scene.arrangement, crease: crease(scene.arrangement)) {
                    fixedPane(scene)
                    scrollPane(scene)
                }
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { panesFrame = $0 }
                BoxDragPreview(drag: drag)
                    .allowsHitTesting(false)
            }
            .coordinateSpace(.named(Self.space))
            .screenBackground()
            .task(id: artRequest(scene)) {
                guard sectionIsActive, scene.k > 0 else { return }
                await art.load(artRequest(scene))
            }
            .onChange(of: scene.box.id) { _, _ in
                withAnimation(.easeInOut(duration: 0.2)) {
                    selection = nil
                    armed = nil
                    emphasized = nil
                }
            }
            .onChange(of: scene.arrangement, initial: true) { _, arrangement in
                frames.stageScrolls = arrangement.stageScrolls
                if !arrangement.docksTray { frames.tray = .zero }
            }
        } else {
            Color.clear.screenBackground()
        }
    }

    /// The crease in the panes' own coordinates: an x on a book, a y on a table. nil anywhere else.
    private func crease(_ arrangement: BoxArrangement) -> CGFloat? {
        guard let crease = duo.crease else { return nil }
        switch arrangement {
        case .book: return crease - panesFrame.minX
        case .table: return crease - panesFrame.minY
        case .phone, .column, .desk: return nil
        }
    }

    /// The pane that stays put: a book's left page (the box alone, end on, fitted to the page), a table's top pane
    /// (the tabs and the box, under the compact header in the bar), the Mac's left side (the box with its panel under it). Empty in a
    /// column, where the box scrolls with everything else.
    private func fixedPane(_ scene: Scene) -> some View {
        ZStack {
            switch scene.arrangement {
            case .book:
                boxWell(scene)
            case .table:
                VStack(spacing: 0) {
                    boxTabs(scene)
                        .padding(.horizontal, margin)
                    boxWell(scene)
                }
            case .desk:
                Color.clear
                    .onGeometryChange(for: CGSize.self) { $0.size } action: { fixedSpace = $0 }
                    .overlay {
                        deskPanel(scene)
                    }
            case .phone, .column:
                EmptyView()
            }
        }
    }

    /// Whatever room is left, measured for the box and with the box centred in it.
    private func boxWell(_ scene: Scene) -> some View {
        Color.clear
            .onGeometryChange(for: CGSize.self) { $0.size } action: { fixedSpace = $0 }
            .overlay {
                stage(scene)
            }
    }

    /// The Mac's left side: the box front on, with the trial switch and the info panel under it, centred.
    private func deskPanel(_ scene: Scene) -> some View {
        VStack(spacing: 22) {
            stage(scene)
            VStack(spacing: 18) {
                if !scene.trial.isEmpty {
                    trialSwitch(scene)
                }
                infoPanel(scene)
                if !scene.steppingOut.isEmpty {
                    steppingOut(scene)
                }
            }
            .frame(maxWidth: min(max(scene.boxWidth, 420), 600))
            .padding(.horizontal, margin)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The pane that scrolls: on a phone the whole page over a docked tray; on a book's right page, below a table's
    /// crease and in a column everything but what the fixed pane holds, with chip grids in place of the tray; the
    /// Mac's side column holds only the chips. Always the same scroll view, so its offset survives a change of
    /// posture.
    private func scrollPane(_ scene: Scene) -> some View {
        let arrangement = scene.arrangement
        let mac = Platform.isMac
        return ScrollView {
            VStack(spacing: 0) {
                if !mac, arrangement == .phone || arrangement == .column || arrangement == .book {
                    header(scene)
                        .padding(.horizontal, margin)
                    boxTabs(scene)
                        .padding(.horizontal, margin)
                        .padding(.bottom, 22)
                }
                if arrangement.stageScrolls {
                    stage(scene)
                        .padding(.top, mac ? 20 : 0)
                        .padding(.bottom, 22)
                }
                if arrangement != .desk {
                    if !mac {
                        controls(scene)
                            .padding(.horizontal, margin)
                            .padding(.top, arrangement == .table ? 18 : 0)
                    }
                    if !scene.trial.isEmpty {
                        trialSwitch(scene)
                            .padding(.horizontal, margin)
                            .padding(.top, mac ? 0 : 18)
                    }
                    infoPanel(scene)
                        .padding(.horizontal, margin)
                        .padding(.top, mac && scene.trial.isEmpty ? 0 : 22)
                    if !scene.steppingOut.isEmpty {
                        steppingOut(scene)
                            .padding(.horizontal, margin)
                            .padding(.top, 22)
                    }
                }
                if !arrangement.docksTray {
                    chipGrids(scene, columns: arrangement.chipColumns)
                        .padding(.horizontal, margin)
                        .padding(.top, arrangement == .desk ? 20 : 34)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.bottom, 28)
        }
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { width in
            pageWidth = width
        }
        .scrollPosition($scroll)
        .scrollDisabled(dragging != nil)
        .onScrollGeometryChange(for: [CGFloat].self) { geometry in
            [geometry.contentOffset.y + geometry.contentInsets.top,
             max(0, geometry.contentSize.height + geometry.contentInsets.top + geometry.contentInsets.bottom - geometry.containerSize.height)]
        } action: { _, values in
            frames.offset = values[0]
            frames.maxOffset = values[1]
        }
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.space)) } action: { frames.scroll = $0 }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if arrangement.docksTray {
                tray(scene)
            }
        }
        #if os(iOS)
        // On the inner screen's panes the bar keeps no title: centred in the window it would sit on the crease, and a
        // table's top pane already shows the name.
        .mastheadTitle(arrangement == .book || arrangement == .table ? "" : scene.box.name)
        #endif
        .overlay(alignment: .leading) {
            if arrangement == .desk {
                Rectangle()
                    .fill(WatchTheme.separator)
                    .frame(width: WatchTheme.hairline)
                    .accessibilityHidden(true)
            }
        }
    }

    // MARK: Header

    private func header(_ scene: Scene) -> some View {
        Masthead(kicker: "Watch Boxes", title: scene.box.name, subtitle: countsInTabs ? nil : subtitle(scene))
    }

    /// On the cover screen the count moves into the box tabs ("Black 11") and the masthead keeps no subtitle. With
    /// one box there are no tabs, so the subtitle stays.
    private var countsInTabs: Bool { duo.posture == .folded && boxes.count > 1 }

    /// A box tab's label: the name, or on the cover the name without " Box" and its count of watches.
    private func tabLabel(_ box: WatchBox) -> String {
        guard countsInTabs else { return box.name }
        let short = box.name.lowercased().hasSuffix(" box") ? String(box.name.dropLast(4)) : box.name
        return "\(short) \(box.slots.count)"
    }

    /// Half open on a table: the kicker and the box's name on one centred line, in the bar above the tabs.
    private func compactHeader(_ scene: Scene) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Eyebrow("Watch Boxes")
            Text(scene.box.name)
                .font(AtelierType.title)
                .foregroundStyle(WatchTheme.ink)
                .contentTransition(.opacity)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    #if os(macOS)
    /// The Mac's header row: the boxes as a segmented control, then the lid.
    @ViewBuilder
    private func deskHeaderLeading(_ scene: Scene?) -> some View {
        if let scene {
            HStack(spacing: 12) {
                if boxes.count > 1 {
                    Picker("Box", selection: Binding(get: { scene.box.id }, set: { id in
                        withAnimation(.easeInOut(duration: 0.25)) { selectedBoxID = id }
                    })) {
                        ForEach(boxes) { box in
                            Text(box.name).tag(box.id)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
                Button(lidClosed ? "Open lid" : "Close lid") {
                    withAnimation(.easeInOut(duration: 0.35)) { lidClosed.toggle() }
                }
                .buttonStyle(.bordered)
            }
        }
    }

    /// Share and Edit, at the trailing end of the header row.
    @ViewBuilder
    private func deskHeaderTrailing(_ scene: Scene?) -> some View {
        if let scene {
            BoxShareMenu(store: store, card: shareCard(scene), product: productCard(scene))
                .labelStyle(.iconOnly)
                .fixedSize()
                .help("Share")
        }
        Button { managing = true } label: { Image(systemName: "pencil") }
            .help("Edit boxes")
            .accessibilityLabel("Edit boxes")
    }
    #endif

    /// "11 watches, 1 space open", "12 spaces open", or "Full".
    private func subtitle(_ scene: Scene) -> String {
        let placed = scene.box.slots.count
        let open = max(0, scene.box.capacity - placed)
        if open == 0 { return "Full" }
        let spaces = open == 1 ? "1 space open" : "\(open) spaces open"
        if placed == 0 { return spaces }
        return (placed == 1 ? "1 watch, " : "\(placed) watches, ") + spaces
    }

    /// One tab per box when there are two or more, and Edit for the manage sheet.
    private func boxTabs(_ scene: Scene) -> some View {
        HStack(alignment: .bottom, spacing: 14) {
            if boxes.count > 1 {
                UnderlineTabs(
                    selection: Binding(get: { scene.box.id }, set: { id in
                        withAnimation(.easeInOut(duration: 0.25)) { selectedBoxID = id }
                    }),
                    options: boxes.map { (value: $0.id, label: tabLabel($0)) }
                )
            } else {
                Spacer()
            }
            Button("Edit") { managing = true }
                .font(.system(.subheadline, weight: .bold))
                .foregroundStyle(WatchTheme.accent)
                .buttonStyle(.plain)
                .frame(minHeight: 44)
                .accessibilityLabel("Edit boxes")
        }
    }

    // MARK: The box

    private func stage(_ scene: Scene) -> some View {
        let width = scene.boxWidth, height = scene.stageHeight
        let marks = BoxGuideMarks(selected: selection, targets: targets(scene), emphasized: emphasized)
        let drag = drag, frames = frames
        return BoxStage(
            geometry: scene.geometry, finish: scene.finish, orientation: scene.orientation, lidClosed: lidClosed,
            items: scene.items, emptyTile: scene.emptyTile, hidden: dragging, arriving: arriving, settles: settles,
            marks: marks,
            hover: { drag.lift == nil ? nil : Self.slot(at: drag.location, frames: frames, scene) },
            outlined: colorScheme == .dark
        ) { slot in
            hit(slot, scene)
        }
        .frame(width: width, height: height)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.space)) } action: { frames.stage = $0 }
        .rotationEffect(.degrees(turnAngle))
        .scaleEffect(turnScale)
        .allowsHitTesting(!turning)
        .frame(width: width, height: turnHeight ?? height)
        .id(reduceMotion ? "\(scene.box.id)-\(scene.orientation.rawValue)" : scene.box.id)
        .transition(.opacity)
        .animation(.easeInOut(duration: 0.25), value: scene.box.id)
        .frame(maxWidth: .infinity)
    }

    /// Where an armed chip can go: the spaces with nothing in them (all of them when the box is full).
    private func targets(_ scene: Scene) -> Set<Int> {
        guard let armed else { return [] }
        let open = Set((0..<scene.box.capacity).filter { slot in
            armed.wishlist ? scene.occupants[slot] == nil : scene.box.watchID(at: slot) == nil
        })
        return open.isEmpty ? Set(0..<scene.box.capacity) : open
    }

    /// The compartment at a point in the screen's space, or nil off the compartments (the frame, outside the box, or
    /// a part of the box that is scrolled under the bar or the tray).
    static func slot(at point: CGPoint, frames: BoxFrames, _ scene: Scene) -> Int? {
        guard frames.showsBox(at: point), scene.k > 0 else { return nil }
        let local = CGPoint(x: (point.x - frames.stage.minX) / scene.k, y: (point.y - frames.stage.minY) / scene.k)
        return scene.geometry.slotIndex(at: local, scene.orientation)
    }

    /// One compartment's touch target: tap to select or place, press and drag to move, and everything VoiceOver needs.
    /// The Mac adds a context menu on a right click. The phone has none: its menu opened on the same press that lifts
    /// a watch and swallowed the drag, so a held watch never moved. Its actions are on the info panel of the selected
    /// compartment and in the VoiceOver actions.
    @ViewBuilder
    private func hit(_ slot: Int, _ scene: Scene) -> some View {
        let piece = scene.occupants[slot]
        let button = tapTarget(Color.clear.contentShape(Rectangle())) { tap(slot, scene) }
        let target = lifting(button, piece: piece, origin: slot, scene: scene) { tap(slot, scene) }
        .accessibilityLabel(spaceLabel(slot, scene))
        .accessibilityAddTraits(selection == slot ? .isSelected : [])
        .accessibilitySortPriority(Double(1000 - slot))
        .accessibilityActions {
            if let armed {
                Button("Place here") { place(armed, at: slot, scene) }
            }
            if let piece {
                actions(piece, slot: slot, scene)
            }
        }
        #if os(macOS)
        if let piece {
            target.contextMenu {
                actions(piece, slot: slot, scene)
            } preview: {
                BoxChipArt(piece: piece, cutout: art.cutout(piece)?.result)
                    .frame(width: 220, height: 220)
            }
        } else {
            target
        }
        #else
        target
        #endif
    }

    /// The menu for a watch in the box (VoiceOver actions, and the Mac's context menu).
    @ViewBuilder
    private func actions(_ piece: BoxPiece, slot: Int, _ scene: Scene) -> some View {
        if piece.wishlist {
            Button("Adjust cutout") { editing = editTarget(piece, scene) }
            Button("End trial") { endTrial(piece.itemID) }
        } else {
            Button("View watch") { viewWatch(piece.itemID) }
            Button("Adjust cutout") { editing = editTarget(piece, scene) }
            Button("Take out") { takeOut(piece.itemID) }
            ForEach(boxes.filter { $0.id != scene.box.id }) { other in
                if let open = firstOpenSpace(in: other) {
                    Button("Move to \(other.name)") { move(piece.itemID, to: other, slot: open) }
                }
            }
        }
    }

    /// Into the first open space of another box. The selection goes with it out of this box.
    private func move(_ watchID: String, to other: WatchBox, slot: Int) {
        if let scene = makeScene(), let selected = selection, scene.occupants[selected]?.itemID == watchID {
            withAnimation(.easeInOut(duration: 0.2)) { selection = nil }
        }
        Task { await store.placeWatch(id: watchID, boxID: other.id, slot: slot) }
    }

    private func editTarget(_ piece: BoxPiece, _ scene: Scene) -> BoxEditTarget {
        BoxEditTarget(piece: piece, finish: scene.finish, emptyTile: scene.emptyTile, shownPhoto: art.cutout(piece)?.result?.photo)
    }

    private func firstOpenSpace(in box: WatchBox) -> Int? {
        (0..<box.capacity).first { box.watchID(at: $0) == nil }
    }

    /// "Black Box, back row, space 2 of 6. Omega MoonSwatch Mission to Jupiter, 42 millimetres."
    private func spaceLabel(_ slot: Int, _ scene: Scene) -> String {
        let place = "\(scene.box.name), \(scene.box.spaceName(slot, outOf: true))."
        guard let piece = scene.occupants[slot] else { return "\(place) Empty." }
        let size = piece.diameter.map { ", \(compactNumber($0)) millimetres" } ?? ""
        let name = [piece.brand, piece.name].compactMap { $0 }.filter { !$0.isEmpty && !(piece.name.hasPrefix($0)) }.joined(separator: " ")
        return "\(place) \(name.isEmpty ? piece.name : name)\(size)." + (piece.wishlist ? " On trial from the wishlist." : "")
    }

    // MARK: Tapping

    private func tap(_ slot: Int, _ scene: Scene) {
        guard Date().timeIntervalSince(lastDragEnd) > 0.35 else { return }
        if lastHold.slot == slot, Date().timeIntervalSince(lastHold.at) < 1.5 { return }
        if let armed {
            place(armed, at: slot, scene)
            return
        }
        withAnimation(.easeInOut(duration: 0.2)) {
            selection = selection == slot ? nil : slot
        }
    }

    /// A press held still (iPhone): selects the compartment, or places an armed chip there, as a tap does, but never
    /// clears the selection. The selected compartment's info panel carries what a context menu would.
    private func held(_ slot: Int, _ scene: Scene) {
        guard drag.lift == nil, Date().timeIntervalSince(lastDragEnd) > 0.35 else { return }
        lastHold = (slot, Date())
        if let armed {
            place(armed, at: slot, scene)
            return
        }
        withAnimation(.easeInOut(duration: 0.2)) { selection = slot }
    }

    private func tapChip(_ chip: BoxChip, _ scene: Scene) {
        guard Date().timeIntervalSince(lastDragEnd) > 0.35 else { return }
        // A space chosen first: a candidate goes on trial there; an owned watch goes in when it is free.
        if let slot = selection, chip.wishlist || scene.box.watchID(at: slot) == nil {
            place(chip, at: slot, scene)
            return
        }
        withAnimation(.easeInOut(duration: 0.2)) {
            armed = armed == chip ? nil : chip
            selection = nil
            emphasized = nil
        }
    }

    /// Puts a chip's watch in a compartment: an owned watch by the place rules, a candidate on trial.
    private func place(_ chip: BoxChip, at slot: Int, _ scene: Scene) {
        let id = chip.wishlist ? "trial:\(chip.itemID)" : chip.itemID
        withAnimation(.easeInOut(duration: 0.2)) {
            armed = nil
            emphasized = nil
        }
        if chip.wishlist {
            store.tryOn(wishlistID: chip.itemID, boxID: scene.box.id, slot: slot)
            showsTrial = true
            land(id, at: slot)
        } else {
            Task {
                await store.placeWatch(id: chip.itemID, boxID: scene.box.id, slot: slot)
                land(id, at: slot)
            }
        }
    }

    private func land(_ id: String, at slot: Int) {
        arriving = id
        settles[id, default: 0] += 1
        selection = slot
        Task {
            try? await Task.sleep(for: .milliseconds(450))
            if arriving == id { arriving = nil }
        }
    }

    private func takeOut(_ watchID: String) {
        if let scene = makeScene(), let slot = selection, scene.occupants[slot]?.itemID == watchID { selection = nil }
        Task { await store.takeOut(watchID: watchID) }
    }

    private func endTrial(_ wishlistID: String) {
        if let scene = makeScene(), let slot = selection, scene.occupants[slot]?.itemID == wishlistID { selection = nil }
        withAnimation(.easeInOut(duration: 0.3)) { store.endTrial(wishlistID: wishlistID) }
    }

    private func viewWatch(_ id: String) {
        #if os(iOS)
        path.append(WatchRoute(id: id))
        #else
        openPage(WatchRoute(id: id))
        #endif
    }

    // MARK: Dragging

    /// A compartment's or a chip's tap. On iPhone a `Button` keeps the lift's UIKit recognizer from ever seeing the
    /// press, so it is a tap gesture with a button's trait and action for VoiceOver; the Mac keeps a plain button.
    @ViewBuilder
    private func tapTarget(_ label: some View, action: @escaping () -> Void) -> some View {
        #if os(iOS)
        label
            .onTapGesture(perform: action)
            .accessibilityElement(children: .ignore)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction(.default, action)
        #else
        Button(action: action) { label }
            .buttonStyle(.plain)
        #endif
    }

    /// Press and drag to move: a watch in a compartment (`origin`), a chip (`origin` nil), or on iPhone an empty
    /// compartment, where nothing lifts but a still hold selects it. `tap` is the button's own action, for a press the
    /// lift has taken from the button and let go without moving. Locations are in the screen's named space, which the
    /// box, the tray, the chip grids and the preview share, so a drag crosses the crease freely.
    @ViewBuilder
    private func lifting(_ content: some View, piece: BoxPiece?, origin: Int?, scene: Scene,
                         tap: @escaping () -> Void) -> some View {
        #if os(iOS)
        content.gesture(liftPress(piece: piece, origin: origin, scene: scene, tap: tap))
        #else
        content.simultaneousGesture(liftGesture(piece: piece, origin: origin, scene: scene), including: piece == nil ? .subviews : .all)
        #endif
    }

    #if os(iOS)
    /// iPhone: press 0.22 s, then drag; held as long as you like before moving, the watch still lifts. Moving within
    /// the 0.22 s scrolls the page instead. A compartment held still for half a second is selected while the finger is
    /// down, where the system menu used to open; let go before that, or a chip at any time, and it is a tap.
    private func liftPress(piece: BoxPiece?, origin: Int?, scene: Scene, tap: @escaping () -> Void) -> LiftPress {
        LiftPress(space: Self.space) { phase, location, start in
            switch phase {
            case .began:
                pressBegan(origin, scene)
            case .changed:
                guard let piece else { return }
                follow(location, start: start, piece: piece, origin: origin, scene: scene)
            case .ended:
                let held = !drag.pressing
                drag.pressing = false
                if drag.lift != nil {
                    drop(at: location, scene: scene)
                } else if !held {
                    // Let go without moving: the recognizer has cancelled the button's own tap by now.
                    tap()
                }
            case .cancelled:
                drag.pressing = false
                // A drag the system took away (a call, the app going to the background) ends without a drop: put
                // the watch back.
                if drag.lift != nil, !drag.dropping { endDrag() }
            }
        }
    }

    /// A press has lasted 0.22 s. If it is still down and has not lifted anything a further 0.28 s on, it selects its
    /// compartment (`held`); `pressing` false afterwards tells the release it has been dealt with.
    private func pressBegan(_ origin: Int?, _ scene: Scene) {
        drag.press += 1
        drag.pressing = true
        guard let origin else { return }
        let press = drag.press
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(280))
            guard drag.press == press, drag.pressing, drag.lift == nil else { return }
            drag.pressing = false
            held(origin, scene)
        }
    }
    #else
    /// Mac: a plain drag of 4 pt; a right click opens the context menu.
    private func liftGesture(piece: BoxPiece?, origin: Int?, scene: Scene) -> some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .named(Self.space))
            .updating($gesturing) { _, state, _ in state = true }
            .onChanged { value in
                guard let piece else { return }
                follow(value.location, start: value.startLocation, piece: piece, origin: origin, scene: scene)
            }
            .onEnded { value in
                guard drag.lift != nil else { return }
                drop(at: value.location, scene: scene)
            }
    }
    #endif

    private func follow(_ location: CGPoint, start: CGPoint, piece: BoxPiece, origin: Int?, scene: Scene) {
        if drag.lift == nil {
            // A watch in the box lifts once the finger has moved 4 pt, however long it was held first: a press that
            // never moves selects the compartment (`held`).
            if origin != nil, Platform.isMac == false, hypot(location.x - start.x, location.y - start.y) < 4 { return }
            lift(piece, origin: origin, start: start, scene: scene)
        }
        drag.location = location
    }

    private func lift(_ piece: BoxPiece, origin: Int?, start: CGPoint, scene: Scene) {
        let painter = painter(scene)
        let drawn = content(piece, finish: scene.finish, emptyBoxTiles: store.data?.emptyBoxTiles)
        var grab = CGSize.zero
        if let origin {
            let rect = painter.slotRect(origin)
            grab = CGSize(width: frames.stage.minX + rect.midX - start.x, height: frames.stage.minY + rect.midY - start.y)
        } else {
            // From the tray: held above the finger so the finger does not cover it.
            grab = CGSize(width: 0, height: -painter.slotRect(0).height * 0.35)
        }
        drag.dropping = false
        drag.lift = BoxDragModel.Lift(piece: piece, origin: origin, content: drawn.content, painter: painter, grab: grab)
        drag.location = start
        dragging = piece.id
        liftTick += 1
        if !piece.wishlist || origin == nil { armed = nil }
        startAutoScroll()
    }

    private func drop(at location: CGPoint, scene: Scene) {
        guard let lift = drag.lift else { return }
        drag.dropping = true
        dropTick += 1
        lastDragEnd = Date()
        let inBox = frames.showsBox(at: location)
        let target = Self.slot(at: location, frames: frames, scene)
        let piece = lift.piece
        if let target {
            if lift.origin == target {
                settles[piece.id, default: 0] += 1
                endDrag()
                return
            }
            arriving = piece.id
            if piece.wishlist {
                store.tryOn(wishlistID: piece.itemID, boxID: scene.box.id, slot: target)
                showsTrial = true
                endDrag()
                land(piece.id, at: target)
            } else {
                Task {
                    await store.placeWatch(id: piece.itemID, boxID: scene.box.id, slot: target)
                    endDrag()
                    land(piece.id, at: target)
                }
            }
        } else if inBox || lift.origin == nil {
            // On the frame, or a chip dropped anywhere but a compartment: back where it was.
            endDrag()
        } else {
            // Out of the box: back to the tray.
            if selection == lift.origin { selection = nil }
            if piece.wishlist {
                store.endTrial(wishlistID: piece.itemID)
                endDrag()
            } else {
                Task {
                    await store.takeOut(watchID: piece.itemID)
                    endDrag()
                }
            }
        }
    }

    private func endDrag() {
        autoScroll?.cancel()
        autoScroll = nil
        drag.lift = nil
        drag.dropping = false
        dragging = nil
        lastDragEnd = Date()
    }

    /// Near the top or bottom 60 pt of the scroll view, the page scrolls 8 pt a frame (the bottom edge is the tray, or
    /// the tab bar where there is no tray). Only where the box scrolls: in a fixed pane it is always in reach.
    private func startAutoScroll() {
        autoScroll?.cancel()
        guard frames.stageScrolls else { return }
        autoScroll = Task { @MainActor in
            while !Task.isCancelled, drag.lift != nil {
                try? await Task.sleep(for: .milliseconds(16))
                let step = frames.autoScrollStep(at: drag.location.y)
                guard step != 0 else { continue }
                let next = min(frames.maxOffset, max(0, frames.offset + step))
                guard next != frames.offset else { continue }
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) { scroll.scrollTo(y: next) }
            }
        }
    }

    // MARK: Controls

    private func controls(_ scene: Scene) -> some View {
        HStack(spacing: 8) {
            Button(lidClosed ? "Open lid" : "Close lid") {
                withAnimation(.easeInOut(duration: 0.35)) { lidClosed.toggle() }
            }
            // Only where the box is end on in a phone-wide column; elsewhere it takes the view that suits the space.
            if scene.arrangement.canTurn {
                Button {
                    turnBox(scene)
                } label: {
                    Label("Turn", systemImage: "rotate.right")
                }
                .disabled(turning)
            }
            BoxShareMenu(store: store, card: shareCard(scene), product: productCard(scene))
        }
        .quietButton()
        .controlSize(.small)
        .frame(maxWidth: .infinity)
    }

    /// 0.4 s: the whole box turns a quarter and scales to the new width, then redraws in the new orientation.
    /// With Reduce Motion it cross-fades.
    private func turnBox(_ scene: Scene) {
        guard !turning else { return }
        if reduceMotion {
            withAnimation(.easeInOut(duration: 0.25)) { turned.toggle() }
            return
        }
        let next: BoxOrientation = scene.orientation == .endOn ? .front : .endOn
        let nextSize = scene.geometry.size(next)
        let nextHeight = scene.boxWidth * nextSize.height / nextSize.width
        turning = true
        withAnimation(.easeInOut(duration: 0.4)) {
            turnAngle = scene.orientation == .endOn ? -90 : 90
            turnScale = scene.boxWidth / scene.stageHeight
            turnHeight = nextHeight
        } completion: {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                turned.toggle()
                turnAngle = 0
                turnScale = 1
                turnHeight = nil
                turning = false
            }
        }
    }

    /// "Trying" / "As it is" flips the same box in place; "Clear trial" ends every trial in this box.
    private func trialSwitch(_ scene: Scene) -> some View {
        VStack(spacing: 10) {
            UnderlineTabs(selection: Binding(get: { showsTrial }, set: { value in
                withAnimation(.easeInOut(duration: 0.3)) { showsTrial = value }
            }), options: [(value: true, label: "Trying"), (value: false, label: "As it is")])
            Button("Clear trial") {
                withAnimation(.easeInOut(duration: 0.3)) {
                    store.clearTrial(boxID: scene.box.id)
                    selection = nil
                }
            }
            .font(.system(.subheadline, weight: .bold))
            .foregroundStyle(WatchTheme.accent)
            .buttonStyle(.plain)
            .frame(minHeight: 44)
        }
    }

    // MARK: Info panel

    @ViewBuilder
    private func infoPanel(_ scene: Scene) -> some View {
        Group {
            if let slot = selection, slot < scene.box.capacity {
                if let piece = scene.occupants[slot] {
                    if piece.wishlist {
                        candidatePanel(piece, slot: slot, scene)
                    } else {
                        watchPanel(piece, slot: slot, scene)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        Eyebrow(scene.box.name)
                        Text("Empty space")
                            .font(AtelierType.title)
                            .foregroundStyle(WatchTheme.ink)
                        Text(scene.box.spaceName(slot).capitalizedFirst)
                            .font(AtelierType.detail)
                            .foregroundStyle(WatchTheme.muted)
                        Text(placeHint(scene.arrangement))
                            .font(AtelierType.caption)
                            .foregroundStyle(WatchTheme.muted)
                    }
                }
            } else if let armed, let piece = scene.piece(armed) {
                VStack(alignment: .leading, spacing: 8) {
                    if let kicker = piece.kicker { Eyebrow(kicker) }
                    Text(piece.name)
                        .font(AtelierType.title)
                        .foregroundStyle(WatchTheme.ink)
                    Text(armed.wishlist ? "Choose a space to try it in." : "Choose a space for it.")
                        .font(AtelierType.detail)
                        .foregroundStyle(WatchTheme.muted)
                    Button("Cancel") { withAnimation { self.armed = nil; emphasized = nil } }
                        .quietButton()
                        .padding(.top, 6)
                }
            } else {
                Text(Platform.isMac ? "Drag a watch to move it, or click a space." : "Drag a watch to move it, or tap a space.")
                    .font(AtelierType.detail)
                    .foregroundStyle(WatchTheme.muted)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .groupedCard()
        .animation(.easeInOut(duration: 0.2), value: selection)
    }

    /// Where the watches to place are: the docked tray, the grids below, or the Mac's side column.
    private func placeHint(_ arrangement: BoxArrangement) -> String {
        switch arrangement {
        case .phone: "Tap a watch in the tray to place it here."
        case .desk: "Click a watch on the right to place it here."
        case .column, .book, .table: Platform.isMac ? "Click a watch below to place it here." : "Tap a watch below to place it here."
        }
    }

    private func detailLine(_ piece: BoxPiece, slot: Int, _ scene: Scene) -> String {
        [piece.kicker == piece.category ? nil : piece.category,
         piece.diameter.map { "\(compactNumber($0)) mm" },
         scene.box.spaceName(slot)]
            .compactMap { $0 }
            .joined(separator: ", ")
    }

    private func watchPanel(_ piece: BoxPiece, slot: Int, _ scene: Scene) -> some View {
        let tileFile = piece.boxTiles?[scene.finish.rawValue]
        let tileOnDevice = tileFile.map { art.tile(piece.directory, $0) != nil } ?? false
        let useCutout = piece.setting?.useCutout == true
        let showsTile = tileOnDevice && !useCutout
        let doubtful = !showsTile && (art.cutout(piece)?.result?.isDoubtful ?? false)
        return VStack(alignment: .leading, spacing: 8) {
            if let kicker = piece.kicker { Eyebrow(kicker) }
            Text(piece.name)
                .font(AtelierType.title)
                .foregroundStyle(WatchTheme.ink)
                .fixedSize(horizontal: false, vertical: true)
            Text(detailLine(piece, slot: slot, scene))
                .font(AtelierType.detail)
                .foregroundStyle(WatchTheme.muted)
            if !showsTile && !(useCutout && tileFile != nil) {
                Text("Rendered picture not ready")
                    .font(AtelierType.caption)
                    .foregroundStyle(WatchTheme.muted)
            }
            if doubtful {
                Text("Check the cutout")
                    .font(AtelierType.caption)
                    .foregroundStyle(WatchTheme.muted)
            }
            ChipFlowLayout(spacing: 8) {
                Button("View watch") { viewWatch(piece.itemID) }
                    .prominentButton()
                if !showsTile {
                    Button("Adjust cutout") { editing = editTarget(piece, scene) }
                        .quietButton()
                }
                Button("Take out") { takeOut(piece.itemID) }
                    .quietButton()
                ForEach(boxes.filter { $0.id != scene.box.id }) { other in
                    if let open = firstOpenSpace(in: other) {
                        Button("Move to \(other.name)") { move(piece.itemID, to: other, slot: open) }
                            .quietButton()
                    }
                }
                if showsTile {
                    Button("Use my photo instead") { setUseCutout(piece, true) }
                        .quietButton()
                } else if useCutout, tileFile != nil {
                    Button("Use the rendered picture") { setUseCutout(piece, false) }
                        .quietButton()
                }
            }
            .padding(.top, 8)
        }
    }

    private func candidatePanel(_ piece: BoxPiece, slot: Int, _ scene: Scene) -> some View {
        let score = store.scores[piece.itemID]
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 8) {
                    Eyebrow("On trial" + (piece.kicker.map { ", \($0)" } ?? ""), color: WatchTheme.Box.trial)
                    Text(piece.name)
                        .font(AtelierType.title)
                        .foregroundStyle(WatchTheme.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(detailLine(piece, slot: slot, scene))
                        .font(AtelierType.detail)
                        .foregroundStyle(WatchTheme.muted)
                }
                Spacer(minLength: 0)
                if let score { ScoreRing(score: score.total, maximum: score.max) }
            }
            if art.cutout(piece)?.result?.isDoubtful == true {
                Text("Check the cutout")
                    .font(AtelierType.caption)
                    .foregroundStyle(WatchTheme.muted)
            }
            ChipFlowLayout(spacing: 8) {
                Button("Try another space") {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        armed = BoxChip(itemID: piece.itemID, wishlist: true)
                        selection = nil
                        trayShowsWishlist = true
                    }
                }
                .prominentButton()
                Button("End trial") { endTrial(piece.itemID) }
                    .quietButton()
                Button("Adjust cutout") { editing = editTarget(piece, scene) }
                    .quietButton()
            }
            .padding(.top, 8)
        }
    }

    private func setUseCutout(_ piece: BoxPiece, _ use: Bool) {
        var cutout = piece.setting ?? piece.photos.first.map { BoxCutout(photo: $0) }
        guard cutout != nil else { return }
        cutout?.useCutout = use ? true : nil
        let clean = cutout?.normalized
        // A setting that says nothing beyond the photo is the same as automatic.
        let value = clean.map { $0 == BoxCutout(photo: $0.photo) ? nil : $0 } ?? nil
        Task { await store.setBoxCutout(itemID: piece.itemID, wishlist: piece.wishlist, cutout: value) }
    }

    private func steppingOut(_ scene: Scene) -> some View {
        GroupedSection {
            GroupedRow("Stepping out", value: scene.steppingOut.map(\.name).joined(separator: ", "))
        }
    }

    // MARK: Tray

    private func tray(_ scene: Scene) -> some View {
        let chipSide: CGFloat = typeSize.isAccessibilitySize ? 84 : 64
        let shown: [BoxPiece] = trayShowsWishlist ? scene.candidates.map(BoxPiece.init(candidate:)) : scene.loose.map(BoxPiece.init(watch:))
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 20) {
                trayTab("Not in a box", count: scene.loose.count, wishlist: false)
                trayTab("Wishlist", count: scene.candidates.count, wishlist: true)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, margin)
            if shown.isEmpty {
                Text(trayShowsWishlist ? "Nothing on the wishlist yet." : "Every watch you own is in a box.")
                    .font(AtelierType.detail)
                    .foregroundStyle(WatchTheme.muted)
                    .frame(maxWidth: .infinity, minHeight: chipSide + 18, alignment: .leading)
                    .padding(.horizontal, margin)
            } else {
                ScrollViewReader { reader in
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(alignment: .top, spacing: 10) {
                            ForEach(shown) { piece in
                                chip(piece, side: chipSide, scene: scene)
                                    .id(piece.id)
                            }
                        }
                        .padding(.horizontal, margin)
                    }
                    // A horizontal scroll view takes every point of height it is offered; the tray is only its chips.
                    .fixedSize(horizontal: false, vertical: true)
                    .scrollClipDisabled()
                    // Clipped at the sides only, so on the cover the chips stop at the status strip instead of
                    // running on under the tab bar; an armed chip's outline still shows above and below.
                    .mask { Rectangle().padding(.vertical, -12) }
                    .onChange(of: armed) { _, chip in
                        guard let chip else { return }
                        withAnimation { reader.scrollTo(chip.wishlist ? "trial:\(chip.itemID)" : chip.itemID, anchor: .center) }
                    }
                }
            }
        }
        .padding(.top, 10)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity)
        .background(WatchTheme.background)
        .overlay(alignment: .top) { Hairline() }
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.space)) } action: { frames.tray = $0 }
    }

    private func trayTab(_ title: String, count: Int, wishlist: Bool) -> some View {
        let selected = trayShowsWishlist == wishlist
        return Button {
            withAnimation(.easeInOut(duration: 0.2)) { trayShowsWishlist = wishlist }
        } label: {
            Eyebrow("\(title) \(count)", color: selected ? WatchTheme.ink : WatchTheme.muted)
                .padding(.vertical, 4)
                .overlay(alignment: .bottom) {
                    if selected {
                        Rectangle().fill(WatchTheme.accent).frame(height: 1.5).offset(y: 2)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// A watch or candidate to place: `side` points square in the tray, or as wide as its column in a grid (nil).
    private func chip(_ piece: BoxPiece, side: CGFloat?, scene: Scene) -> some View {
        let chip = BoxChip(itemID: piece.itemID, wishlist: piece.wishlist)
        let isArmed = armed == chip
        let score = piece.wishlist ? store.scores[piece.itemID]?.total : nil
        let label = VStack(spacing: 3) {
            BoxChipArt(piece: piece, cutout: art.cutout(piece)?.result)
                .frame(width: side, height: side)
                .aspectRatio(1, contentMode: .fit)
                .overlay(alignment: .topTrailing) {
                    if let score {
                        Text("\(score)")
                            .font(AtelierType.kicker)
                            .foregroundStyle(WatchTheme.gold)
                            .padding(4)
                    }
                }
                .overlay {
                    if isArmed {
                        Rectangle().stroke(WatchTheme.accent, lineWidth: 2)
                    }
                }
                .opacity(dragging == piece.id ? 0.35 : 1)
            Text(piece.name)
                .font(AtelierType.caption)
                .foregroundStyle(WatchTheme.ink)
                .lineLimit(1)
                .frame(width: side.map { $0 + 8 })
                .frame(maxWidth: side == nil ? .infinity : nil)
        }
        .contentShape(Rectangle())
        let button = tapTarget(label) { tapChip(chip, scene) }
        return lifting(button, piece: piece, origin: nil, scene: scene) { tapChip(chip, scene) }
        .accessibilityLabel("\(piece.name), \(piece.wishlist ? "on the wishlist" : "not in a box")")
        .accessibilityHint("Double tap, then choose a space.")
        .accessibilityAddTraits(isArmed ? .isSelected : [])
    }

    // MARK: Chip grids

    /// In place of the docked tray where the page has room: "Not in a box" and "Wishlist" as grids, one above the
    /// other. A drop anywhere here takes a watch out, as a drop on the tray does.
    private func chipGrids(_ scene: Scene, columns: Int) -> some View {
        VStack(alignment: .leading, spacing: 30) {
            chipGrid("Not in a box", pieces: scene.loose.map(BoxPiece.init(watch:)),
                     empty: "Every watch you own is in a box.", columns: columns, scene: scene)
            chipGrid("Wishlist", pieces: scene.candidates.map(BoxPiece.init(candidate:)),
                     empty: "Nothing on the wishlist yet.", columns: columns, scene: scene)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func chipGrid(_ title: String, pieces: [BoxPiece], empty: String, columns: Int, scene: Scene) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Eyebrow("\(title) \(pieces.count)")
                .accessibilityAddTraits(.isHeader)
            if pieces.isEmpty {
                Text(empty)
                    .font(AtelierType.detail)
                    .foregroundStyle(WatchTheme.muted)
            } else {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10, alignment: .top), count: max(1, columns)),
                          spacing: 14) {
                    ForEach(pieces) { piece in
                        chip(piece, side: nil, scene: scene)
                    }
                }
            }
        }
    }

    // MARK: No boxes

    private var noBoxes: some View {
        VStack(spacing: 18) {
            EmptyCollectionView(title: "No boxes yet", detail: "Set up your watch boxes to see the collection in them.")
                .frame(maxHeight: 280)
            Button("Use the starting layout") { Task { await store.useStartingLayout() } }
                .prominentButton()
            Button("Add a box") { managing = true }
                .quietButton()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, margin)
    }

    // MARK: Share

    private func shareCard(_ scene: Scene) -> BoxShareCard {
        let onTrial = scene.showingTrial ? scene.items.filter { $0.piece.wishlist }.map(\.piece.name) : []
        return BoxShareCard(
            title: scene.box.name, subtitle: subtitle(scene), geometry: scene.geometry, finish: scene.finish,
            orientation: scene.orientation, lidClosed: lidClosed,
            slots: Dictionary(uniqueKeysWithValues: scene.items.map { ($0.slot, $0.content) }),
            emptyTile: scene.emptyTile, onTrial: onTrial, dark: colorScheme == .dark
        )
    }

    private func productCard(_ scene: Scene) -> BoxProductShareCard {
        BoxProductShareCard(
            title: scene.box.name, subtitle: subtitle(scene), geometry: scene.geometry, finish: scene.finish,
            slots: Dictionary(uniqueKeysWithValues: scene.items.map { ($0.slot, $0.content) }),
            emptyTile: scene.emptyTile, dark: colorScheme == .dark
        )
    }

    // MARK: Pictures to load

    private func artRequest(_ scene: Scene) -> BoxArtwork.Request {
        var seen: Set<String> = []
        var pieces: [BoxPiece] = []
        func add(_ piece: BoxPiece) {
            if seen.insert(piece.directory).inserted { pieces.append(piece) }
        }
        scene.occupants.keys.sorted().compactMap { scene.occupants[$0] }.forEach(add)
        scene.trial.keys.sorted().compactMap { scene.trial[$0].flatMap { scene.wishlist[$0] } }.map(BoxPiece.init(candidate:)).forEach(add)
        scene.loose.map(BoxPiece.init(watch:)).forEach(add)
        scene.candidates.map(BoxPiece.init(candidate:)).forEach(add)
        var tiles: [PhotoAsset] = []
        for piece in scene.occupants.keys.sorted().compactMap({ scene.occupants[$0] }) {
            if let file = piece.boxTiles?[scene.finish.rawValue],
               let asset = PhotoStore.asset(itemID: piece.itemID, filename: file, wishlist: piece.wishlist, baseURL: nil) {
                tiles.append(asset)
            }
        }
        if let file = store.data?.emptyBoxTiles?[scene.finish.rawValue], let asset = PhotoStore.emptyTileAsset(filename: file, baseURL: nil) {
            tiles.append(asset)
        }
        let compartment = BoxGeometry.compartment.height * scene.k
        return BoxArtwork.Request(
            pieces: pieces, tiles: tiles,
            pixels: BoxTileStore.pixelSize(compartmentPoints: compartment, scale: displayScale),
            revision: store.status.lastSync
        )
    }

    // MARK: Intents

    private func consume(_ intent: BoxIntent) {
        guard let data = store.data else { return }
        // From a watch page pushed on this tab: back to the box.
        path = NavigationPath()
        withAnimation(.easeInOut(duration: 0.25)) {
            switch intent {
            case .show(let id), .place(let id):
                if let space = BoxModel.location(of: id, in: data) {
                    selectedBoxID = space.boxID
                    selection = space.slot
                    armed = nil
                    revealSoon(space.slot)
                } else {
                    armed = BoxChip(itemID: id, wishlist: false)
                    trayShowsWishlist = false
                    selection = nil
                }
                emphasized = nil
            case .tryOn(let id):
                armed = BoxChip(itemID: id, wishlist: true)
                trayShowsWishlist = true
                selection = nil
                showsTrial = true
                if let box = data.boxes?.first(where: { $0.id == selectedBoxID }) ?? data.boxes?.first {
                    let trial = store.boxTrial.candidates(in: box.id)
                    emphasized = (0..<box.capacity).first { box.watchID(at: $0) == nil && trial[$0] == nil }
                    if let emphasized { revealSoon(emphasized) }
                }
            }
        }
    }

    /// Once the tab and the box are on screen, scrolls just far enough that a compartment shows between the bar and
    /// the tray.
    private func revealSoon(_ slot: Int) {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(400))
            guard frames.stageScrolls, let scene = makeScene(), slot < scene.box.capacity,
                  frames.stage.height > 0, frames.scroll.height > 0 else { return }
            let rect = painter(scene).slotRect(slot).offsetBy(dx: frames.stage.minX, dy: frames.stage.minY)
            let delta = frames.revealDelta(for: rect)
            guard delta != 0 else { return }
            let next = min(frames.maxOffset, max(0, frames.offset + delta))
            if reduceMotion {
                scroll.scrollTo(y: next)
            } else {
                withAnimation(.easeInOut(duration: 0.35)) { scroll.scrollTo(y: next) }
            }
        }
    }

    // MARK: Debug probe

    #if DEBUG
    /// Debug builds only, for pictures on a simulator that has no touch input:
    ///   -boxProbe "lid,select:3,arm:<watch-id>,try:<wishlist-id>,trial:<wishlist-id>@<slot>,notrial,wishlist,asis,
    ///              editor:3,manage,turn,brown,black,scroll:600,lift:2-5,wait:1,
    ///              card:<name>,product:<name>"
    private func runProbe() async {
        guard let probe = UserDefaults.standard.string(forKey: "boxProbe") else { return }
        try? await Task.sleep(for: .seconds(2.5))
        for token in probe.split(separator: ",").map(String.init) {
            // A screen the system built and dropped at launch (the Mac's window does) runs no probe.
            guard !Task.isCancelled else { return }
            let parts = token.split(separator: ":", maxSplits: 1).map(String.init)
            let value = parts.count > 1 ? parts[1] : ""
            switch parts[0] {
            case "lid": lidClosed = true
            case "select": selection = Int(value)
            case "arm": armed = BoxChip(itemID: value, wishlist: false)
            case "try": consume(.tryOn(value))
            case "notrial": for box in boxes { store.clearTrial(boxID: box.id) }
            case "trial":
                // A candidate on trial in a space of the box on screen: trial:<wishlist-id>@<slot>.
                let bits = value.split(separator: "@").map(String.init)
                if bits.count == 2, let slot = Int(bits[1]), let scene = makeScene() {
                    store.tryOn(wishlistID: bits[0], boxID: scene.box.id, slot: slot)
                    showsTrial = true
                }
            case "wishlist": trayShowsWishlist = true
            case "asis": showsTrial = false
            case "manage": managing = true
            case "turn": if let scene = makeScene() { turnBox(scene) }
            case "editor":
                if let scene = makeScene(), let slot = Int(value), let piece = scene.occupants[slot] {
                    editing = editTarget(piece, scene)
                }
            case "wait": try? await Task.sleep(for: .seconds(Double(value) ?? 1))
            case "card", "product":
                // The shared picture, written to the app's tmp/box-probe/<value>.png: card:<name>, product:<name>.
                if let scene = makeScene(),
                   let image = parts[0] == "card" ? BoxShare.image(shareCard(scene)) : BoxShare.image(productCard(scene)),
                   let png = BoxShare.png(image) {
                    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("box-probe", isDirectory: true)
                    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    try? png.write(to: folder.appendingPathComponent(value + ".png"), options: .atomic)
                }
            case "scroll": scroll.scrollTo(y: CGFloat(Double(value) ?? 0))
            case "brown", "black": selectedBoxID = parts[0]
            #if os(macOS)
            case "appearance": NSApp.appearance = NSAppearance(named: value == "dark" ? .darkAqua : .aqua)
            case "size":
                // The window's content size: size:<width>x<height>.
                let sides = value.split(separator: "x").compactMap { Double($0) }
                if sides.count == 2, let window = Self.mainWindow {
                    window.setContentSize(CGSize(width: sides[0], height: sides[1]))
                }
            case "window":
                // The Mac window as drawn, to the app's tmp/box-probe/<value>.png, and a sheet over it to
                // <value>-sheet.png with its offset from the window's top left in <value>-sheet.txt.
                let folder = FileManager.default.temporaryDirectory.appendingPathComponent("box-probe", isDirectory: true)
                try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                if let window = Self.mainWindow {
                    try? Self.picture(of: window)?.write(to: folder.appendingPathComponent(value + ".png"), options: .atomic)
                    if let sheet = window.attachedSheet, let png = Self.picture(of: sheet) {
                        try? png.write(to: folder.appendingPathComponent(value + "-sheet.png"), options: .atomic)
                        let offset = "\(sheet.frame.minX - window.frame.minX) \(window.frame.maxY - sheet.frame.maxY)"
                        try? offset.write(to: folder.appendingPathComponent(value + "-sheet.txt"), atomically: true, encoding: .utf8)
                    }
                }
            #endif
            case "lift":
                // A watch held over another compartment, as a drag shows it: lift:<from>-<over>.
                let ends = value.split(separator: "-").compactMap { Int($0) }
                if ends.count == 2, let scene = makeScene(), let piece = scene.occupants[ends[0]] {
                    let rect = painter(scene).slotRect(ends[1])
                    let point = CGPoint(x: frames.stage.minX + rect.midX + 10, y: frames.stage.minY + rect.midY + 6)
                    lift(piece, origin: ends[0], start: point, scene: scene)
                    drag.location = point
                }
            default: break
            }
        }
    }

    #if os(macOS)
    /// The app's window. A sheet's title becomes the window's while it is up, so it is found by size, not by title.
    private static var mainWindow: NSWindow? {
        NSApp.windows.filter { $0.isVisible && $0.sheetParent == nil }.max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
    }

    /// A window as its views draw it, title bar included, as a PNG. The app draws its own windows, so this needs no
    /// screen recording permission.
    private static func picture(of window: NSWindow) -> Data? {
        guard let view = window.contentView?.superview ?? window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep.representation(using: .png, properties: [:])
    }
    #endif
    #endif
}

/// The cutout editor's subject.
struct BoxEditTarget: Identifiable {
    var piece: BoxPiece
    var finish: BoxFinish
    var emptyTile: CGImage?
    /// The photo its cutout is made from now, where the editor opens.
    var shownPhoto: String?
    var id: String { piece.id }
}

/// The lifted watch under the finger, 1.1 times its size with a deeper shadow.
struct BoxDragPreview: View {
    let drag: BoxDragModel

    var body: some View {
        if let lift = drag.lift {
            let slot = lift.origin ?? 0
            let rect = lift.painter.slotRect(slot)
            BoxWatchCanvas(painter: lift.painter, slot: slot, content: lift.content, lift: 1, lifted: true)
                .frame(width: rect.width, height: rect.height)
                .scaleEffect(1.1)
                .shadow(color: .black.opacity(0.35), radius: 18, x: 6, y: 16)
                .position(x: drag.location.x + lift.grab.width, y: drag.location.y + lift.grab.height)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .transition(.opacity)
        }
    }
}

extension WatchBox {
    /// "back row, space 3" (the third from the left end seen from the front), "front row, space 1", "row 2, space 4";
    /// a one-row box has no row phrase. `outOf` adds the row's length: "space 2 of 6".
    func spaceName(_ slot: Int, outOf: Bool = false) -> String {
        guard columns > 0 else { return "space \(slot + 1)" }
        let row = slot / columns, column = slot % columns
        let space = "space \(column + 1)" + (outOf ? " of \(columns)" : "")
        guard rows > 1 else { return space }
        let rowName = row == 0 ? "back row" : row == rows - 1 ? "front row" : "row \(row + 1)"
        return "\(rowName), \(space)"
    }

    /// "Black Box, back row, space 3": where a watch sits, as the watch page shows it.
    func placeName(_ slot: Int) -> String { "\(name), \(spaceName(slot))" }
}

extension String {
    /// The first letter in capitals: "Back row, space 3".
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
