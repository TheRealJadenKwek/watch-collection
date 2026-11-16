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
        var origin: BoxSpace?
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

/// A tab over the Boxes screen: one box, or every box at once.
enum BoxTab: Hashable {
    case box(String)
    case all
}

/// Which boxes the Boxes tab shows and what it calls them. Pure, for the tests.
enum BoxShowing {
    /// Every box in box order when all are asked for and there are two or more; otherwise the chosen box, or the
    /// first when it has gone. None without boxes.
    static func boxes(_ boxes: [WatchBox], selected: String, all: Bool) -> [WatchBox] {
        if all, boxes.count >= 2 { return boxes }
        guard let box = boxes.first(where: { $0.id == selected }) ?? boxes.first else { return [] }
        return [box]
    }

    /// The tab that shows every box: "Both" for two, "All" for more.
    static func tabWord(count: Int) -> String { count > 2 ? "All" : "Both" }

    /// The title over every box: "Both Boxes", "All Boxes".
    static func title(count: Int) -> String { count > 2 ? "All Boxes" : "Both Boxes" }

    /// The Mac header's line under "Boxes": "Both boxes, 14 watches, 10 spaces open".
    static func macSubtitle(count: Int, counts: String) -> String {
        (count > 2 ? "All boxes, " : "Both boxes, ") + counts
    }

    /// A box's tab: its name; on the cover the name without " Box" and its count ("Black 11"); the name without
    /// " Box" wherever there are four tabs or more.
    static func tabLabel(_ box: WatchBox, countsInTabs: Bool, tabCount: Int) -> String {
        let short = box.name.lowercased().hasSuffix(" box") ? String(box.name.dropLast(4)) : box.name
        if countsInTabs { return "\(short) \(box.slots.count)" }
        return tabCount >= 4 ? short : box.name
    }
}

/// The Boxes tab (brief sections 8 and 9): the box on screen, its controls and info panel, and the watches that can
/// go in it, docked at the bottom on a phone so a drag can always reach them. One view tree in every posture: the
/// pieces (`header`, `boxStack`, `controls`, `infoPanel`, `tray`, `chipGrids`) go into the two panes of `BoxPanes`, a
/// fixed one and a scrolling one, and only where those panes stand changes with the posture. The Both tab shows every
/// box at once, one under the other in box order, at one scale.
struct BoxesScreen: View {
    @ObservedObject var store: AppStore
    let showSettings: () -> Void

    /// The last single box shown; the box tabs return to it.
    @AppStorage("boxSelectedV1") private var selectedBoxID = "black"
    /// Every box at once (per device, never synced).
    @AppStorage("boxBothV1") private var showsBoth = false
    @State private var lidClosed = false
    @State private var selection: BoxSpace?
    /// A box an intent switched to together with its selection, so the switch does not clear what came with it.
    @State private var carriedBoxID: String?
    @State private var armed: BoxChip?
    @State private var emphasized: BoxSpace?
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
    @State private var lastHold: (space: BoxSpace?, at: Date) = (nil, .distantPast)
    @State private var liftTick = 0
    @State private var dropTick = 0
    /// Where the page is scrolled, kept across a fold as the other tabs keep theirs.
    @State private var fold = FoldScroll()
    /// How far down the scrolling pane the parts every posture shares (the controls row onward) start.
    @State private var sharedTop: CGFloat = 0
    @State private var autoScroll: Task<Void, Never>?
    @State private var pageWidth: CGFloat = 0
    /// What the scroll view shows of its page (bar to tray, or bar to tab bar where there is no tray), and where the
    /// boxes start on the page, so every box can be fitted between the bar and the tray.
    @State private var paneHeight: CGFloat = 0
    @State private var stackTop: CGFloat = 0
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
    /// The scrolling pane's content.
    private static let page = "boxes-page"

    // MARK: What is on screen

    /// One box as the screen shows it, worked out once per update.
    struct Scene {
        var arrangement: BoxArrangement
        var box: WatchBox
        /// Its place in the stack (0 at the top), and how many boxes the stack shows (1 in single view).
        var index: Int
        var count: Int
        var geometry: BoxGeometry
        var finish: BoxFinish
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
        /// It stands in the scroll view, where the bar and the tray can cover part of it.
        var scrolls: Bool
        /// Every box shown, top first, for finding the compartment under a finger.
        var stack: [(id: String, geometry: BoxGeometry)]

        var stageHeight: CGFloat { geometry.canvas.height * k }
        func piece(_ chip: BoxChip) -> BoxPiece? {
            chip.wishlist ? wishlist[chip.itemID].map(BoxPiece.init(candidate:)) : watches[chip.itemID].map(BoxPiece.init(watch:))
        }
    }

    /// Everything the screen shows: one scene per box shown, top first, at one scale.
    struct Board {
        var arrangement: BoxArrangement
        /// Box order; one scene in single view.
        var scenes: [Scene]
        var both: Bool
        var k: CGFloat
        /// What a change of view is keyed on: "both", or the box shown.
        var key: String

        var lead: Scene { scenes[0] }
        func scene(_ boxID: String) -> Scene? { scenes.first { $0.box.id == boxID } }
        var tab: BoxTab { both ? .all : .box(lead.box.id) }
        var hasTrial: Bool { scenes.contains { !$0.trial.isEmpty } }
        var steppingOut: [Watch] { scenes.flatMap(\.steppingOut) }
    }

    /// What a stage reports its frame under, so the frames follow the boxes shown.
    private struct StageKey: Equatable {
        var id: String
        var scrolls: Bool
    }

    private var boxes: [WatchBox] { store.data?.boxes ?? [] }

    /// Every box at once: chosen, and there are two or more. A stored choice waits while there is only one box.
    private var both: Bool { showsBoth && boxes.count >= 2 }

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

    /// The space every box at once is given. A column keeps its width and is given the height from the stack's top
    /// to the tray (or the tab bar), so the boxes fit there when they still read; on the Mac's desk the stack has the
    /// left side to itself, the panel having moved to the side column.
    private func stackSpace(_ arrangement: BoxArrangement) -> CGSize {
        switch arrangement {
        case .phone, .column:
            let width = stageSpace(arrangement, trial: false).width
            // Not measured yet: as wide as the column, as a single box is.
            guard paneHeight > 0, stackTop > 0 else { return CGSize(width: width, height: 0) }
            // 8 pt to spare: the both-view auto-scroll runs once the stack reaches within 6 pt of the edge, so a box
            // that fits never scrolls the page from under a watch held over its front row.
            return CGSize(width: width, height: max(1, paneHeight - stackTop - 8))
        case .book, .table:
            return stageSpace(arrangement, trial: false)
        case .desk:
            return CGSize(width: fixedSpace.width - 2 * margin, height: fixedSpace.height - 40)
        }
    }

    private func makeBoard() -> Board? {
        guard let data = store.data else { return nil }
        let both = both
        let shown = BoxShowing.boxes(boxes, selected: selectedBoxID, all: both)
        guard !shown.isEmpty else { return nil }
        let arrangement = arrangement
        let mac = Platform.isMac
        let geometries = shown.map { BoxGeometry(columns: $0.columns, rows: $0.rows) }
        let trials = shown.map { store.boxTrial.candidates(in: $0.id) }
        let k = both
            ? BoxStack.scale(geometries, arrangement, space: stackSpace(arrangement), mac: mac)
            : BoxArrangement.stage(geometries[0], arrangement, space: stageSpace(arrangement, trial: !trials[0].isEmpty), mac: mac)
        let watches = Dictionary(data.watches.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let wishlist = Dictionary(data.wishlist.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let loose = BoxModel.tray(data)
        let candidates = WishlistScreen.ranked(data.wishlist, scores: store.scores).filter { $0.status != "bought" }
        let stack = zip(shown, geometries).map { (id: $0.id, geometry: $1) }
        let scenes = shown.indices.map { index -> Scene in
            let box = shown[index], geometry = geometries[index], trial = trials[index]
            let finish = BoxFinish(name: box.finish)
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
            // A table keeps the first box above the crease; the rest of the stack scrolls below it.
            let scrolls = arrangement.stageScrolls || (both && arrangement == .table && index > 0)
            return Scene(
                arrangement: arrangement, box: box, index: index, count: shown.count, geometry: geometry, finish: finish,
                occupants: occupants, items: items, emptyTile: emptyTile, trial: trial, showingTrial: showingTrial,
                steppingOut: showingTrial ? store.boxTrial.steppingOut(of: box.id, in: data).compactMap { watches[$0] } : [],
                loose: loose, candidates: candidates, watches: watches, wishlist: wishlist,
                boxWidth: geometry.canvas.width * k, k: k, scrolls: scrolls, stack: stack
            )
        }
        return Board(arrangement: arrangement, scenes: scenes, both: both, k: k, key: both ? "both" : shown[0].id)
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
        BoxPainter(geometry: scene.geometry, palette: .of(scene.finish), lidClosed: false,
                   slots: [:], trialTag: "TRYING", k: scene.k, emptyTile: scene.emptyTile)
    }

    // MARK: Body

    var body: some View {
        let board = makeBoard()
        SectionStack(path: $path) {
            page(board)
                .keepsScrollAcrossFolds($fold)
                #if os(iOS)
                .navigationDestination(for: WatchRoute.self) { route in
                    WatchDossierView(store: store, watchID: route.id)
                }
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) { GearToolbarButton(action: showSettings) }
                    // Half open on a table the compact header stands in the bar, so the box above the crease keeps
                    // the height; with every box shown in a column it stands there too, so the boxes fit.
                    if let board, headerInBar(board) {
                        ToolbarItem(placement: .principal) { compactHeader(board) }
                    }
                }
                #else
                .desktopHeader("Boxes", subtitle: board.map(deskSubtitle)) {
                    deskHeaderLeading(board)
                } trailing: {
                    deskHeaderTrailing(board)
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
    private func page(_ board: Board?) -> some View {
        if store.data != nil, boxes.isEmpty {
            noBoxes
                .screenBackground()
        } else if let board {
            ZStack(alignment: .topLeading) {
                BoxPanes(arrangement: board.arrangement, crease: crease(board.arrangement)) {
                    fixedPane(board)
                    scrollPane(board)
                }
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { panesFrame = $0 }
                BoxDragPreview(drag: drag)
                    .allowsHitTesting(false)
            }
            .coordinateSpace(.named(Self.space))
            .screenBackground()
            // Keyed by whether the section is showing too: on the Mac every section is built at launch, so the art
            // loads when Boxes is chosen, and leaving it cancels the task and the cutout jobs it queued.
            .task(id: ArtTask(request: artRequest(board), active: sectionIsActive)) {
                guard sectionIsActive, board.k > 0 else { return }
                await art.load(artRequest(board))
            }
            .onChange(of: sectionIsActive) { _, active in
                if !active { Task { await CutoutStore.shared.cancelPending() } }
            }
            .onChange(of: board.key) { _, key in
                // A box switched to with its own selection (the watch page's Box row) keeps it. Every box at once
                // keeps a selection in any box; a single box keeps only its own.
                if key != "both" {
                    let carried = carriedBoxID == key
                    carriedBoxID = nil
                    guard !carried else { return }
                } else {
                    carriedBoxID = nil
                }
                let shown = key == "both" ? Set(boxes.map(\.id)) : [key]
                withAnimation(.easeInOut(duration: 0.2)) {
                    if let selection, !shown.contains(selection.boxID) { self.selection = nil }
                    armed = nil
                    emphasized = nil
                }
            }
            .onChange(of: board.scenes.map { StageKey(id: $0.box.id, scrolls: $0.scrolls) }, initial: true) { _, stages in
                // The frames follow the boxes shown: a box no longer shown no longer takes a drop.
                let ids = stages.map(\.id)
                frames.order = ids
                frames.stages = frames.stages.filter { ids.contains($0.key) }
                for stage in stages { frames.stages[stage.id]?.scrolls = stage.scrolls }
            }
            .onChange(of: board.arrangement, initial: true) { _, arrangement in
                if !arrangement.docksTray { frames.tray = .zero }
                // A fold mid-drag can take down the stage under the finger with no cancel from UIKit: let go of the
                // watch where it was (nothing moved), so it shows again and scrolling comes back.
                if drag.lift != nil, !drag.dropping { endDrag() }
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

    /// The pane that stays put: a book's left page (the boxes alone, front on, fitted to the page), a table's top pane
    /// (the tabs and the first box, under the compact header in the bar), the Mac's left side (the box with its panel
    /// under it, or every box alone). Empty in a column, where the boxes scroll with everything else.
    private func fixedPane(_ board: Board) -> some View {
        ZStack {
            switch board.arrangement {
            case .book:
                boxWell(board, board.scenes[...])
            case .table:
                VStack(spacing: 0) {
                    boxTabs(board)
                        .padding(.horizontal, margin)
                    boxWell(board, board.scenes.prefix(1))
                }
            case .desk:
                Color.clear
                    .onGeometryChange(for: CGSize.self) { $0.size } action: { fixedSpace = $0 }
                    .overlay {
                        deskPanel(board)
                    }
            case .phone, .column:
                EmptyView()
            }
        }
    }

    /// Whatever room is left, measured for the boxes and with them centred in it.
    private func boxWell(_ board: Board, _ scenes: ArraySlice<Scene>) -> some View {
        Color.clear
            .onGeometryChange(for: CGSize.self) { $0.size } action: { fixedSpace = $0 }
            .overlay {
                boxStack(board, scenes)
            }
    }

    /// The Mac's left side: the box front on, with the trial switch and the info panel under it, centred. With every
    /// box shown, the boxes alone: the panel moves to the head of the side column.
    private func deskPanel(_ board: Board) -> some View {
        VStack(spacing: 22) {
            boxStack(board, board.scenes[...])
            if !board.both {
                VStack(spacing: 18) {
                    if board.hasTrial {
                        trialSwitch(board)
                    }
                    infoPanel(board)
                    if !board.steppingOut.isEmpty {
                        steppingOut(board)
                    }
                }
                .frame(maxWidth: min(max(board.lead.boxWidth, 420), 600))
                .padding(.horizontal, margin)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The pane that scrolls: on a phone the whole page over a docked tray; on a book's right page, below a table's
    /// crease and in a column everything but what the fixed pane holds, with chip grids in place of the tray; the
    /// Mac's side column holds only the chips (and, with every box shown, the panel above them). Always the same
    /// scroll view; what stands above the shared parts changes with the posture, so `FoldScroll` puts the reader back
    /// on the same lines after a fold.
    private func scrollPane(_ board: Board) -> some View {
        let arrangement = board.arrangement
        let mac = Platform.isMac
        let both = board.both
        let barHeader = both && (arrangement == .phone || arrangement == .column)
        let desk = arrangement == .desk
        return ScrollView {
            VStack(spacing: 0) {
                if !mac, arrangement == .phone || arrangement == .column || arrangement == .book {
                    if !barHeader {
                        header(board)
                            .padding(.horizontal, margin)
                    }
                    boxTabs(board)
                        .padding(.horizontal, margin)
                        .padding(.bottom, barHeader ? 12 : 22)
                }
                if arrangement.stageScrolls {
                    boxStack(board, board.scenes[...])
                        .onGeometryChange(for: CGFloat.self) { $0.frame(in: .named(Self.page)).minY } action: { stackTop = $0 }
                        .padding(.top, mac ? 20 : 0)
                        .padding(.bottom, 22)
                }
                if arrangement == .table, board.scenes.count > 1 {
                    // Half open on a table: the boxes after the first, below the crease at the same scale.
                    boxStack(board, board.scenes.dropFirst())
                        .padding(.top, 12)
                        .padding(.bottom, 22)
                }
                if !desk || both {
                    if !mac {
                        controls(board)
                            .padding(.horizontal, margin)
                            .padding(.top, arrangement == .table ? 18 : 0)
                            .onGeometryChange(for: CGFloat.self) { $0.frame(in: .named(Self.page)).minY } action: { sharedTop = $0 }
                    }
                    if board.hasTrial {
                        trialSwitch(board)
                            .padding(.horizontal, margin)
                            .padding(.top, mac ? (desk ? 20 : 0) : 18)
                    }
                    infoPanel(board)
                        .padding(.horizontal, margin)
                        .padding(.top, mac && !board.hasTrial ? (desk ? 20 : 0) : 22)
                    if !board.steppingOut.isEmpty {
                        steppingOut(board)
                            .padding(.horizontal, margin)
                            .padding(.top, 22)
                    }
                }
                if !arrangement.docksTray {
                    chipGrids(board, columns: arrangement.chipColumns)
                        .padding(.horizontal, margin)
                        .padding(.top, desk && !both ? 20 : 34)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.bottom, 28)
            .coordinateSpace(.named(Self.page))
        }
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { width in
            pageWidth = width
        }
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.height
        } action: { height in
            paneHeight = height
        }
        // Across a fold the reader comes back to the same lines from the controls row on; what each posture puts above
        // them (the box on a phone, only the masthead on a book's right page) differs.
        #if os(iOS)
        .foldScroll($fold, lead: sharedTop)
        #else
        .scrollPosition($fold.position)
        #endif
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
                tray(board)
            }
        }
        #if os(iOS)
        // On the inner screen's panes the bar keeps no title: centred in the window it would sit on the crease, and a
        // table's top pane already shows the name. Where the compact header stands in the bar it is the title.
        .mastheadTitle(arrangement == .book || arrangement == .table || barHeader ? "" : board.lead.box.name)
        #endif
        .overlay(alignment: .leading) {
            if desk {
                Rectangle()
                    .fill(WatchTheme.separator)
                    .frame(width: WatchTheme.hairline)
                    .accessibilityHidden(true)
            }
        }
    }

    // MARK: Header

    private func header(_ board: Board) -> some View {
        Masthead(kicker: "Watch Boxes", title: title(board), subtitle: countsInTabs ? nil : subtitle(board))
    }

    /// The box's name, or "Both Boxes" ("All Boxes") with every box shown.
    private func title(_ board: Board) -> String {
        board.both ? BoxShowing.title(count: board.scenes.count) : board.lead.box.name
    }

    /// On the cover screen the count moves into the box tabs ("Black 11") and the masthead keeps no subtitle. With
    /// one box there are no tabs, so the subtitle stays.
    private var countsInTabs: Bool { duo.posture == .folded && boxes.count > 1 }

    /// The tabs: one per box, then the one for every box at once.
    private var tabOptions: [(value: BoxTab, label: String)] {
        let count = boxes.count + 1
        let options = boxes.map { (value: BoxTab.box($0.id), label: BoxShowing.tabLabel($0, countsInTabs: countsInTabs, tabCount: count)) }
        return options + [(value: .all, label: BoxShowing.tabWord(count: boxes.count))]
    }

    /// A tab chosen: a box, the last single box changing with it, or every box at once.
    private func choose(_ tab: BoxTab) {
        switch tab {
        case .box(let id):
            withAnimation(.easeInOut(duration: both ? 0.3 : 0.25)) {
                showsBoth = false
                selectedBoxID = id
            }
        case .all:
            withAnimation(.easeInOut(duration: 0.3)) { showsBoth = true }
        }
    }

    /// The compact header stands in the bar half open on a table, and with every box shown on a phone or in a column.
    private func headerInBar(_ board: Board) -> Bool {
        board.arrangement == .table || (board.both && (board.arrangement == .phone || board.arrangement == .column))
    }

    /// The kicker and the title on one centred line, in the bar above the tabs. A bar too narrow for both keeps the
    /// title.
    private func compactHeader(_ board: Board) -> some View {
        let title = title(board)
        return ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Eyebrow("Watch Boxes")
                compactTitle(title)
            }
            compactTitle(title)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    private func compactTitle(_ title: String) -> some View {
        Text(title)
            .font(AtelierType.title)
            .foregroundStyle(WatchTheme.ink)
            .contentTransition(.opacity)
            .lineLimit(1)
    }

    #if os(macOS)
    /// "Black Box, 11 watches, 1 space open"; "Both boxes, 14 watches, 10 spaces open".
    private func deskSubtitle(_ board: Board) -> String {
        board.both ? BoxShowing.macSubtitle(count: board.scenes.count, counts: subtitle(board))
            : "\(board.lead.box.name), \(subtitle(board))"
    }

    /// The Mac's header row: the boxes (and every box at once) as a segmented control, then the lid.
    @ViewBuilder
    private func deskHeaderLeading(_ board: Board?) -> some View {
        if let board {
            HStack(spacing: 12) {
                if boxes.count > 1 {
                    Picker("Box", selection: Binding(get: { board.tab }, set: { choose($0) })) {
                        ForEach(tabOptions, id: \.value) { option in
                            Text(option.label).tag(option.value)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
                Button(lidLabel(board)) {
                    withAnimation(.easeInOut(duration: 0.35)) { lidClosed.toggle() }
                }
                .buttonStyle(.bordered)
            }
        }
    }

    /// Share and Edit, at the trailing end of the header row.
    @ViewBuilder
    private func deskHeaderTrailing(_ board: Board?) -> some View {
        if let board {
            shareMenu(board)
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
        BoxShare.counts(watches: scene.box.slots.count, capacity: scene.box.capacity)
    }

    /// The box's count, or every shown box's added up: "14 watches, 10 spaces open".
    private func subtitle(_ board: Board) -> String {
        guard board.both else { return subtitle(board.lead) }
        return BoxShare.counts(of: board.scenes.map { (watches: $0.box.slots.count, onTrial: 0, capacity: $0.box.capacity) })
    }

    /// One tab per box when there are two or more, then the tab for every box at once, and Edit for the manage sheet.
    private func boxTabs(_ board: Board) -> some View {
        HStack(alignment: .bottom, spacing: 14) {
            if boxes.count > 1 {
                UnderlineTabs(
                    selection: Binding(get: { board.tab }, set: { choose($0) }),
                    options: tabOptions
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

    // MARK: The boxes

    /// The boxes shown, one under the other at one scale, each under its name and count when there is more than one.
    /// Single view runs through the same `ForEach` with no label, so the box on screen keeps its identity when every
    /// box is shown and resizes into place while the others fade in. With Reduce Motion the whole stack cross-fades.
    private func boxStack(_ board: Board, _ scenes: ArraySlice<Scene>) -> some View {
        VStack(spacing: BoxStack.gap) {
            ForEach(scenes, id: \.box.id) { scene in
                VStack(spacing: 8) {
                    if board.both {
                        stageLabel(scene)
                    }
                    stage(scene)
                }
                .transition(.opacity)
            }
        }
        .id(reduceMotion ? board.key : "stack")
        .transition(.opacity)
    }

    /// A box's name and count over it, as wide as the box: "BLACK BOX ... 11 watches, 1 space open". The row keeps
    /// its 14 pt: its type stops growing at xxLarge, and at accessibility sizes the count goes (the tabs and the header
    /// already say it) so the name keeps the width.
    private func stageLabel(_ scene: Scene) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Eyebrow(scene.box.name)
                .lineLimit(1)
                .layoutPriority(1)
            Spacer(minLength: 0)
            if !typeSize.isAccessibilitySize {
                Text(subtitle(scene))
                    .font(AtelierType.caption)
                    .foregroundStyle(WatchTheme.muted)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
        .frame(width: scene.boxWidth, height: BoxStack.label - 8)
        .accessibilityElement(children: .combine)
        // The count still read aloud where it is not drawn.
        .accessibilityValue(typeSize.isAccessibilitySize ? subtitle(scene) : "")
        .accessibilityAddTraits(.isHeader)
        .accessibilitySortPriority(Double((scene.count - scene.index) * 1000 + 1))
        .frame(maxWidth: .infinity)
    }

    private func stage(_ scene: Scene) -> some View {
        let width = scene.boxWidth, height = scene.stageHeight
        let id = scene.box.id
        let marks = BoxGuideMarks(selected: selection?.boxID == id ? selection?.slot : nil, targets: targets(scene),
                                  emphasized: emphasized?.boxID == id ? emphasized?.slot : nil)
        let drag = drag, frames = frames, stack = scene.stack, k = scene.k, scrolls = scene.scrolls
        return BoxStage(
            geometry: scene.geometry, finish: scene.finish, lidClosed: lidClosed,
            items: scene.items, emptyTile: scene.emptyTile, hidden: dragging, arriving: arriving, settles: settles,
            marks: marks,
            // The ring shows in whichever box is under the finger.
            hover: {
                guard drag.lift != nil, let space = frames.space(at: drag.location, boxes: stack, k: k), space.boxID == id else { return nil }
                return space.slot
            },
            outlined: colorScheme == .dark
        ) { slot in
            hit(slot, scene)
        }
        .frame(width: width, height: height)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.space)) } action: {
            frames.stages[id] = BoxFrames.Stage(rect: $0, scrolls: scrolls)
        }
        .id(scene.box.id)
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

    /// One compartment's touch target: tap to select or place, press and drag to move, and everything VoiceOver needs.
    /// The Mac adds a context menu on a right click. The phone has none: its menu opened on the same press that lifts
    /// a watch and swallowed the drag, so a held watch never moved. Its actions are on the info panel of the selected
    /// compartment and in the VoiceOver actions.
    @ViewBuilder
    private func hit(_ slot: Int, _ scene: Scene) -> some View {
        let piece = scene.occupants[slot]
        let space = BoxSpace(boxID: scene.box.id, slot: slot)
        let button = tapTarget(Color.clear.contentShape(Rectangle())) { tap(slot, scene) }
        let target = lifting(button, piece: piece, origin: space, scene: scene) { tap(slot, scene) }
        .accessibilityLabel(spaceLabel(slot, scene))
        .accessibilityAddTraits(selection == space ? .isSelected : [])
        // The top box reads first, each box's label just before its spaces.
        .accessibilitySortPriority(Double((scene.count - scene.index) * 1000 - slot))
        .accessibilityActions {
            if let armed {
                Button("Place here") { place(armed, at: space) }
            }
            if let piece {
                // What a finger does by dragging, in two steps: pick the watch up here, then "Place here" on another
                // space moves it there or swaps the two.
                if armed?.itemID != piece.itemID {
                    Button(piece.wishlist ? "Try another space" : "Move") { pickUp(piece) }
                }
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

    /// Arms a watch or candidate that is already in the box, as a chip from the tray is armed, so the next space chosen
    /// takes it (a move, or a swap with what is there).
    private func pickUp(_ piece: BoxPiece) {
        withAnimation(.easeInOut(duration: 0.2)) {
            armed = BoxChip(itemID: piece.itemID, wishlist: piece.wishlist)
            selection = nil
            emphasized = nil
            if piece.wishlist { trayShowsWishlist = true }
        }
    }

    /// Into the first open space of another box. In single view the selection goes with it out of this box; with
    /// that box on screen too, the watch settles in its new space as a drop does and the selection follows it.
    private func move(_ watchID: String, to other: WatchBox, slot: Int) {
        let board = makeBoard()
        if board?.scene(other.id) != nil {
            let target = BoxSpace(boxID: other.id, slot: slot)
            Task {
                await store.placeWatch(id: watchID, boxID: other.id, slot: slot)
                land(watchID, at: target)
            }
            return
        }
        if let board, let selected = selection, board.scene(selected.boxID)?.occupants[selected.slot]?.itemID == watchID {
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
        let space = BoxSpace(boxID: scene.box.id, slot: slot)
        guard Date().timeIntervalSince(lastDragEnd) > 0.35 else { return }
        if lastHold.space == space, Date().timeIntervalSince(lastHold.at) < 1.5 { return }
        if let armed {
            place(armed, at: space)
            return
        }
        withAnimation(.easeInOut(duration: 0.2)) {
            selection = selection == space ? nil : space
        }
    }

    /// A press held still (iPhone): selects the compartment, or places an armed chip there, as a tap does, but never
    /// clears the selection. The selected compartment's info panel carries what a context menu would.
    private func held(_ slot: Int, _ scene: Scene) {
        guard drag.lift == nil, Date().timeIntervalSince(lastDragEnd) > 0.35 else { return }
        let space = BoxSpace(boxID: scene.box.id, slot: slot)
        lastHold = (space, Date())
        if let armed {
            place(armed, at: space)
            return
        }
        withAnimation(.easeInOut(duration: 0.2)) { selection = space }
    }

    private func tapChip(_ chip: BoxChip, _ board: Board) {
        guard Date().timeIntervalSince(lastDragEnd) > 0.35 else { return }
        // A space chosen first: a candidate goes on trial there; an owned watch goes in when it is free. Either goes
        // to that space's box.
        if let space = selection, let scene = board.scene(space.boxID), chip.wishlist || scene.box.watchID(at: space.slot) == nil {
            place(chip, at: space)
            return
        }
        withAnimation(.easeInOut(duration: 0.2)) {
            armed = armed == chip ? nil : chip
            selection = nil
            emphasized = nil
        }
    }

    /// Puts a chip's watch in a compartment: an owned watch by the place rules, a candidate on trial.
    private func place(_ chip: BoxChip, at space: BoxSpace) {
        let id = chip.wishlist ? "trial:\(chip.itemID)" : chip.itemID
        withAnimation(.easeInOut(duration: 0.2)) {
            armed = nil
            emphasized = nil
        }
        if chip.wishlist {
            store.tryOn(wishlistID: chip.itemID, boxID: space.boxID, slot: space.slot)
            showsTrial = true
            land(id, at: space)
        } else {
            Task {
                await store.placeWatch(id: chip.itemID, boxID: space.boxID, slot: space.slot)
                land(id, at: space)
            }
        }
    }

    private func land(_ id: String, at space: BoxSpace) {
        arriving = id
        settles[id, default: 0] += 1
        selection = space
        Task {
            try? await Task.sleep(for: .milliseconds(450))
            if arriving == id { arriving = nil }
        }
    }

    /// The selected compartment's piece, wherever it is shown.
    private func selectedItemID(_ board: Board?) -> String? {
        guard let board, let space = selection else { return nil }
        return board.scene(space.boxID)?.occupants[space.slot]?.itemID
    }

    private func takeOut(_ watchID: String) {
        if selectedItemID(makeBoard()) == watchID { selection = nil }
        Task { await store.takeOut(watchID: watchID) }
    }

    private func endTrial(_ wishlistID: String) {
        if selectedItemID(makeBoard()) == wishlistID { selection = nil }
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
    /// lift has taken from the button and let go without moving. `scene` is the box it is drawn for: the box it came
    /// from, or the top box for a chip. Locations are in the screen's named space, which every box, the tray, the chip
    /// grids and the preview share, so a drag crosses from one box to another and over the crease freely.
    @ViewBuilder
    private func lifting(_ content: some View, piece: BoxPiece?, origin: BoxSpace?, scene: Scene,
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
    private func liftPress(piece: BoxPiece?, origin: BoxSpace?, scene: Scene, tap: @escaping () -> Void) -> LiftPress {
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
                    drop(at: location)
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
    private func pressBegan(_ origin: BoxSpace?, _ scene: Scene) {
        drag.press += 1
        drag.pressing = true
        guard let origin else { return }
        let press = drag.press
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(280))
            guard drag.press == press, drag.pressing, drag.lift == nil else { return }
            drag.pressing = false
            held(origin.slot, scene)
        }
    }
    #else
    /// Mac: a plain drag of 4 pt; a right click opens the context menu.
    private func liftGesture(piece: BoxPiece?, origin: BoxSpace?, scene: Scene) -> some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .named(Self.space))
            .updating($gesturing) { _, state, _ in state = true }
            .onChanged { value in
                guard let piece else { return }
                follow(value.location, start: value.startLocation, piece: piece, origin: origin, scene: scene)
            }
            .onEnded { value in
                guard drag.lift != nil else { return }
                drop(at: value.location)
            }
    }
    #endif

    private func follow(_ location: CGPoint, start: CGPoint, piece: BoxPiece, origin: BoxSpace?, scene: Scene) {
        if drag.lift == nil {
            // A watch in the box or a chip lifts once the finger has moved 4 pt, however long it was held first: a
            // press that never moves selects the compartment (`held`) or, on a chip, is a tap that arms it.
            if Platform.isMac == false, hypot(location.x - start.x, location.y - start.y) < 4 { return }
            lift(piece, origin: origin, start: start, scene: scene)
        }
        drag.location = location
    }

    /// Lifts a piece. It keeps the look of the box it came from (tiles are per finish) until it lands; a chip from the
    /// tray lifts with the top box's look.
    private func lift(_ piece: BoxPiece, origin: BoxSpace?, start: CGPoint, scene: Scene) {
        let painter = painter(scene)
        let drawn = content(piece, finish: scene.finish, emptyBoxTiles: store.data?.emptyBoxTiles)
        var grab = CGSize.zero
        if let origin {
            let rect = painter.slotRect(origin.slot)
            let stage = frames.stages[origin.boxID]?.rect ?? .zero
            grab = CGSize(width: stage.minX + rect.midX - start.x, height: stage.minY + rect.midY - start.y)
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
        startAutoScroll(both: scene.count > 1)
    }

    /// Lets go: on a compartment of any box shown, it goes there (a swap with what is there, across boxes too); on
    /// its own space it settles back; anywhere else on the stack (a frame, a label, the gap between two boxes, the
    /// band over a table's crease), or a chip let go off a compartment, back where it was; anywhere else, out to the
    /// tray.
    private func drop(at location: CGPoint) {
        guard let lift = drag.lift else { return }
        drag.dropping = true
        dropTick += 1
        lastDragEnd = Date()
        guard let board = makeBoard() else {
            endDrag()
            return
        }
        let onStack = frames.showsStack(at: location)
        let target = frames.space(at: location, boxes: board.lead.stack, k: board.k)
        let piece = lift.piece
        if let target {
            if lift.origin == target {
                settles[piece.id, default: 0] += 1
                endDrag()
                return
            }
            arriving = piece.id
            if piece.wishlist {
                store.tryOn(wishlistID: piece.itemID, boxID: target.boxID, slot: target.slot)
                showsTrial = true
                endDrag()
                land(piece.id, at: target)
            } else {
                Task {
                    await store.placeWatch(id: piece.itemID, boxID: target.boxID, slot: target.slot)
                    endDrag()
                    land(piece.id, at: target)
                }
            }
        } else if onStack || lift.origin == nil {
            // On a frame, a label or between the boxes, or a chip dropped anywhere but a compartment: back where it was.
            endDrag()
        } else {
            // Out of the boxes: back to the tray.
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
    /// the tab bar where there is no tray). Only where a box scrolls: in a fixed pane it is always in reach. With every
    /// box shown, only while the stack runs on past that edge (`BoxFrames.autoScrollStep`).
    private func startAutoScroll(both: Bool) {
        autoScroll?.cancel()
        guard frames.order.contains(where: { frames.stages[$0]?.scrolls == true }) else { return }
        autoScroll = Task { @MainActor in
            while !Task.isCancelled, drag.lift != nil {
                try? await Task.sleep(for: .milliseconds(16))
                let step = frames.autoScrollStep(at: drag.location.y, both: both)
                guard step != 0 else { continue }
                let next = min(frames.maxOffset, max(0, frames.offset + step))
                guard next != frames.offset else { continue }
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) { fold.position.scrollTo(y: next) }
            }
        }
    }

    // MARK: Controls

    /// "Close lid" / "Open lid"; "Close lids" / "Open lids" with every box shown. One control drives every box.
    private func lidLabel(_ board: Board) -> String {
        board.both ? (lidClosed ? "Open lids" : "Close lids") : (lidClosed ? "Open lid" : "Close lid")
    }

    private func controls(_ board: Board) -> some View {
        HStack(spacing: 8) {
            Button(lidLabel(board)) {
                withAnimation(.easeInOut(duration: 0.35)) { lidClosed.toggle() }
            }
            shareMenu(board)
        }
        .quietButton()
        .controlSize(.small)
        .frame(maxWidth: .infinity)
    }

    /// "Trying" / "As it is" flips every box shown in place; "Clear trial" ends every trial in them ("Clear trials"
    /// when two or more have one).
    private func trialSwitch(_ board: Board) -> some View {
        let withTrial = board.scenes.filter { !$0.trial.isEmpty }.count
        return VStack(spacing: 10) {
            UnderlineTabs(selection: Binding(get: { showsTrial }, set: { value in
                withAnimation(.easeInOut(duration: 0.3)) { showsTrial = value }
            }), options: [(value: true, label: "Trying"), (value: false, label: "As it is")])
            Button(withTrial > 1 ? "Clear trials" : "Clear trial") {
                withAnimation(.easeInOut(duration: 0.3)) {
                    for scene in board.scenes { store.clearTrial(boxID: scene.box.id) }
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

    /// One panel, for the selected space in whichever box it is.
    @ViewBuilder
    private func infoPanel(_ board: Board) -> some View {
        Group {
            if let space = selection, let scene = board.scene(space.boxID), space.slot < scene.box.capacity {
                let slot = space.slot
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
                        Text(placeHint(board))
                            .font(AtelierType.caption)
                            .foregroundStyle(WatchTheme.muted)
                    }
                }
            } else if let armed, let piece = board.lead.piece(armed) {
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

    /// Where the watches to place are: the docked tray, the grids below, or the Mac's side column (under the panel
    /// when every box is shown).
    private func placeHint(_ board: Board) -> String {
        switch board.arrangement {
        case .phone: "Tap a watch in the tray to place it here."
        case .desk: board.both ? "Click a watch below to place it here." : "Click a watch on the right to place it here."
        case .column, .book, .table: Platform.isMac ? "Click a watch below to place it here." : "Tap a watch below to place it here."
        }
    }

    /// "Dive, 42 mm, back row, space 3"; with every box shown, the box too: "Dive, 42 mm, Black Box, back row, space 3".
    private func detailLine(_ piece: BoxPiece, slot: Int, _ scene: Scene) -> String {
        [piece.kicker == piece.category ? nil : piece.category,
         piece.diameter.map { "\(compactNumber($0)) mm" },
         scene.count > 1 ? scene.box.placeName(slot) : scene.box.spaceName(slot)]
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
                // With every box shown: pick it up, then choose a space in any box.
                if scene.count > 1 {
                    Button("Move") { pickUp(piece) }
                        .quietButton()
                }
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
                Button("Try another space") { pickUp(piece) }
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
        // With no setting yet, the photo the cutout comes from now (automatic's pick, brief 6.2), not the cover: the
        // box then shows the cutout automatic chose.
        let shown = (art.cutout(piece)?.result?.photo).flatMap { piece.photos.contains($0) ? $0 : nil }
        var cutout = piece.setting ?? (shown ?? piece.photos.first).map { BoxCutout(photo: $0) }
        guard cutout != nil else { return }
        cutout?.useCutout = use ? true : nil
        let clean = cutout?.normalized
        // A setting that says nothing beyond the photo is the same as automatic.
        let value = clean.map { $0 == BoxCutout(photo: $0.photo) ? nil : $0 } ?? nil
        Task { await store.setBoxCutout(itemID: piece.itemID, wishlist: piece.wishlist, cutout: value) }
    }

    /// The watches that stepped out for a trial, in every box shown, box order.
    private func steppingOut(_ board: Board) -> some View {
        GroupedSection {
            GroupedRow("Stepping out", value: board.steppingOut.map(\.name).joined(separator: ", "))
        }
    }

    // MARK: Tray

    private func tray(_ board: Board) -> some View {
        let chipSide: CGFloat = typeSize.isAccessibilitySize ? 84 : 64
        let lead = board.lead
        let shown: [BoxPiece] = trayShowsWishlist ? lead.candidates.map(BoxPiece.init(candidate:)) : lead.loose.map(BoxPiece.init(watch:))
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 20) {
                trayTab("Not in a box", count: lead.loose.count, wishlist: false)
                trayTab("Wishlist", count: lead.candidates.count, wishlist: true)
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
                                chip(piece, side: chipSide, board: board)
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
    private func chip(_ piece: BoxPiece, side: CGFloat?, board: Board) -> some View {
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
        let button = tapTarget(label) { tapChip(chip, board) }
        return lifting(button, piece: piece, origin: nil, scene: board.lead) { tapChip(chip, board) }
        .accessibilityLabel("\(piece.name), \(piece.wishlist ? "on the wishlist" : "not in a box")")
        .accessibilityHint("Double tap, then choose a space.")
        .accessibilityAddTraits(isArmed ? .isSelected : [])
        .onDisappear {
            // A grid dropped the chip being dragged (autoscroll took it far off screen) and its press with it: no
            // drop will come, so the drag ends here and the chip goes back.
            if let lift = drag.lift, lift.origin == nil, lift.piece.id == piece.id, !drag.dropping {
                drag.pressing = false
                endDrag()
            }
        }
    }

    // MARK: Chip grids

    /// In place of the docked tray where the page has room: "Not in a box" and "Wishlist" as grids, one above the
    /// other. A drop anywhere here takes a watch out, as a drop on the tray does.
    private func chipGrids(_ board: Board, columns: Int) -> some View {
        VStack(alignment: .leading, spacing: 30) {
            chipGrid("Not in a box", pieces: board.lead.loose.map(BoxPiece.init(watch:)),
                     empty: "Every watch you own is in a box.", columns: columns, board: board)
            chipGrid("Wishlist", pieces: board.lead.candidates.map(BoxPiece.init(candidate:)),
                     empty: "Nothing on the wishlist yet.", columns: columns, board: board)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func chipGrid(_ title: String, pieces: [BoxPiece], empty: String, columns: Int, board: Board) -> some View {
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
                        chip(piece, side: nil, board: board)
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
            if store.canOfferStartingLayout {
                Button("Use the starting layout") { Task { await store.useStartingLayout() } }
                    .prominentButton()
            }
            Button("Add a box") { managing = true }
                .quietButton()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, margin)
    }

    // MARK: Share

    /// The Share pill: the box's two pictures, or with every box shown the stacked ones ("both-boxes.png").
    @ViewBuilder
    private func shareMenu(_ board: Board) -> some View {
        if board.both {
            BoxShareMenu(store: store, title: title(board), card: stackCard(board), product: stackProductCard(board))
        } else {
            BoxShareMenu(store: store, title: board.lead.box.name, card: shareCard(board.lead), product: productCard(board.lead))
        }
    }

    private func shareCard(_ scene: Scene) -> BoxShareCard {
        let trial = pictureTrial(scene)
        return BoxShareCard(
            title: scene.box.name, subtitle: trial.subtitle, geometry: scene.geometry, finish: scene.finish,
            lidClosed: lidClosed,
            slots: Dictionary(uniqueKeysWithValues: scene.items.map { ($0.slot, $0.content) }),
            emptyTile: scene.emptyTile, onTrial: trial.onTrial, steppingOut: trial.steppingOut, dark: colorScheme == .dark
        )
    }

    private func productCard(_ scene: Scene) -> BoxProductShareCard {
        let trial = pictureTrial(scene)
        return BoxProductShareCard(
            title: scene.box.name, subtitle: trial.subtitle, geometry: scene.geometry, finish: scene.finish,
            slots: Dictionary(uniqueKeysWithValues: scene.items.map { ($0.slot, $0.content) }),
            emptyTile: scene.emptyTile, onTrial: trial.onTrial, steppingOut: trial.steppingOut, dark: colorScheme == .dark
        )
    }

    /// Every box shown, top down, in one card: each box's own card is its label row and picture.
    private func stackCard(_ board: Board) -> BoxStackShareCard {
        BoxStackShareCard(title: title(board), subtitle: stackSubtitle(board), boxes: board.scenes.map(shareCard),
                          dark: colorScheme == .dark)
    }

    private func stackProductCard(_ board: Board) -> BoxStackProductShareCard {
        BoxStackProductShareCard(title: title(board), subtitle: stackSubtitle(board), boxes: board.scenes.map(productCard),
                                 dark: colorScheme == .dark)
    }

    /// What the stacked picture shows, added up over its boxes: "14 watches, 10 spaces open".
    private func stackSubtitle(_ board: Board) -> String {
        BoxShare.counts(of: board.scenes.map { scene in
            let onTrial = scene.showingTrial ? scene.items.filter { $0.piece.wishlist }.count : 0
            let owned = scene.showingTrial ? scene.items.count - onTrial : scene.box.slots.count
            return (watches: owned, onTrial: onTrial, capacity: scene.box.capacity)
        })
    }

    /// What a shared picture says about the trial in it: its subtitle counts what the picture shows (candidates on
    /// trial included), and the line under it names the candidates and the watches that stepped out for them.
    private func pictureTrial(_ scene: Scene) -> (subtitle: String, onTrial: [String], steppingOut: [String]) {
        guard scene.showingTrial else { return (subtitle(scene), [], []) }
        let onTrial = scene.items.filter { $0.piece.wishlist }.map(\.piece.name)
        let owned = scene.items.count - onTrial.count
        return (BoxShare.counts(watches: owned, onTrial: onTrial.count, capacity: scene.box.capacity), onTrial,
                scene.steppingOut.map(\.name))
    }

    // MARK: Pictures to load

    /// What the art task runs for: the pictures wanted, and whether the section is the one showing.
    private struct ArtTask: Hashable {
        var request: BoxArtwork.Request
        var active: Bool
    }

    /// Every box shown loads together, each with its own finish's tiles, so no box's tiles push out another's.
    private func artRequest(_ board: Board) -> BoxArtwork.Request {
        var seen: Set<String> = []
        var pieces: [BoxPiece] = []
        func add(_ piece: BoxPiece) {
            if seen.insert(piece.directory).inserted { pieces.append(piece) }
        }
        for scene in board.scenes {
            scene.occupants.keys.sorted().compactMap { scene.occupants[$0] }.forEach(add)
        }
        for scene in board.scenes {
            scene.trial.keys.sorted().compactMap { scene.trial[$0].flatMap { scene.wishlist[$0] } }.map(BoxPiece.init(candidate:)).forEach(add)
        }
        board.lead.loose.map(BoxPiece.init(watch:)).forEach(add)
        board.lead.candidates.map(BoxPiece.init(candidate:)).forEach(add)
        var tiles: [PhotoAsset] = []
        var tileKeys: Set<String> = []
        func addTile(_ asset: PhotoAsset) {
            if tileKeys.insert(BoxArtwork.tileKey(asset)).inserted { tiles.append(asset) }
        }
        for scene in board.scenes {
            for piece in scene.occupants.keys.sorted().compactMap({ scene.occupants[$0] }) {
                if let file = piece.boxTiles?[scene.finish.rawValue],
                   let asset = PhotoStore.asset(itemID: piece.itemID, filename: file, wishlist: piece.wishlist, baseURL: nil) {
                    addTile(asset)
                }
            }
        }
        for scene in board.scenes {
            if let file = store.data?.emptyBoxTiles?[scene.finish.rawValue], let asset = PhotoStore.emptyTileAsset(filename: file, baseURL: nil) {
                addTile(asset)
            }
        }
        let compartment = BoxGeometry.compartment.height * board.k
        return BoxArtwork.Request(
            pieces: pieces, tiles: tiles,
            pixels: BoxTileStore.pixelSize(compartmentPoints: compartment, scale: displayScale),
            revision: store.status.lastSync
        )
    }

    // MARK: Intents

    private func consume(_ intent: BoxIntent) {
        guard let data = store.data else { return }
        let both = both
        // From a watch page pushed on this tab: back to the box.
        path = NavigationPath()
        withAnimation(.easeInOut(duration: 0.25)) {
            switch intent {
            case .show(let id), .place(let id):
                if let space = BoxModel.location(of: id, in: data) {
                    // Every box shown stays so: only the remembered single box follows the watch.
                    if !both, space.boxID != makeBoard()?.lead.box.id { carriedBoxID = space.boxID }
                    selectedBoxID = space.boxID
                    selection = space
                    armed = nil
                    revealSoon(space)
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
                // The first open space across the boxes shown, in box order.
                emphasized = nil
                for box in BoxShowing.boxes(data.boxes ?? [], selected: selectedBoxID, all: both) {
                    let trial = store.boxTrial.candidates(in: box.id)
                    if let slot = (0..<box.capacity).first(where: { box.watchID(at: $0) == nil && trial[$0] == nil }) {
                        emphasized = BoxSpace(boxID: box.id, slot: slot)
                        break
                    }
                }
                if let emphasized { revealSoon(emphasized) }
            }
        }
    }

    /// Once the tab and the box are on screen, scrolls just far enough that a compartment shows between the bar and
    /// the tray.
    private func revealSoon(_ space: BoxSpace) {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(400))
            guard let board = makeBoard(), let scene = board.scene(space.boxID), space.slot < scene.box.capacity,
                  let stage = frames.stages[space.boxID], stage.scrolls, stage.rect.height > 0, frames.scroll.height > 0 else { return }
            let rect = painter(scene).slotRect(space.slot).offsetBy(dx: stage.rect.minX, dy: stage.rect.minY)
            let delta = frames.revealDelta(for: rect)
            guard delta != 0 else { return }
            let next = min(frames.maxOffset, max(0, frames.offset + delta))
            if reduceMotion {
                fold.position.scrollTo(y: next)
            } else {
                withAnimation(.easeInOut(duration: 0.35)) { fold.position.scrollTo(y: next) }
            }
        }
    }

    // MARK: Debug probe

    #if DEBUG
    /// Debug builds only, for pictures on a simulator that has no touch input:
    ///   -boxProbe "lid,select:3,arm:<watch-id>,try:<wishlist-id>,trial:<wishlist-id>@<slot>,notrial,wishlist,asis,
    ///              editor:3,manage,brown,black,both,single,scroll:600,lift:2-5,liftchip:<watch-id>,show:<watch-id>,
    ///              pickup:3,place:5,wait:1,card:<name>,product:<name>"
    /// A slot is a space of the top box, or `<box-id>@<slot>` for any box shown: select:brown@3, lift:black@2-brown@5,
    /// trial:<wishlist-id>@brown@3.
    private func runProbe() async {
        guard let probe = UserDefaults.standard.string(forKey: "boxProbe") else { return }
        try? await Task.sleep(for: .seconds(2.5))
        for token in probe.split(separator: ",").map(String.init) {
            // A screen the system built and dropped at launch (the Mac's window does) runs no probe.
            guard !Task.isCancelled else { return }
            let parts = token.split(separator: ":", maxSplits: 1).map(String.init)
            let value = parts.count > 1 ? parts[1] : ""
            let board = makeBoard()
            switch parts[0] {
            case "lid": lidClosed = true
            case "select": selection = board.flatMap { Self.probeSpace(value, $0) }
            case "arm": armed = BoxChip(itemID: value, wishlist: false)
            case "try": consume(.tryOn(value))
            case "notrial": for box in boxes { store.clearTrial(boxID: box.id) }
            case "trial":
                // A candidate on trial in a space shown: trial:<wishlist-id>@<slot> or trial:<wishlist-id>@<box-id>@<slot>.
                let bits = value.split(separator: "@", maxSplits: 1).map(String.init)
                if bits.count == 2, let board, let space = Self.probeSpace(bits[1], board) {
                    store.tryOn(wishlistID: bits[0], boxID: space.boxID, slot: space.slot)
                    showsTrial = true
                }
            case "wishlist": trayShowsWishlist = true
            case "asis": showsTrial = false
            case "manage": managing = true
            case "editor":
                if let board, let space = Self.probeSpace(value, board), let scene = board.scene(space.boxID),
                   let piece = scene.occupants[space.slot] {
                    editing = editTarget(piece, scene)
                }
            case "wait": try? await Task.sleep(for: .seconds(Double(value) ?? 1))
            case "card", "product":
                // The shared picture, written to the app's tmp/box-probe/<value>.png: card:<name>, product:<name>.
                // With every box shown, the stacked one.
                if let board, let png = probePicture(parts[0] == "card", board).flatMap(BoxShare.png) {
                    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("box-probe", isDirectory: true)
                    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    try? png.write(to: folder.appendingPathComponent(value + ".png"), options: .atomic)
                }
            case "scroll": fold.position.scrollTo(y: CGFloat(Double(value) ?? 0))
            case "brown", "black": selectedBoxID = parts[0]
            case "both": showsBoth = true
            case "single": showsBoth = false
            // The watch page's Box row: show:<watch-id>.
            case "show": store.openBoxes(.show(value))
            // VoiceOver's two steps: pickup:<slot> ("Move"), then place:<slot> ("Place here").
            case "pickup":
                if let board, let space = Self.probeSpace(value, board), let piece = board.scene(space.boxID)?.occupants[space.slot] {
                    pickUp(piece)
                }
            case "place": if let board, let armed, let space = Self.probeSpace(value, board) { place(armed, at: space) }
            case "liftchip":
                // A tray chip held up, as a drag from the tray shows it: liftchip:<watch-id>.
                if let board, let watch = board.lead.watches[value] {
                    let point = CGPoint(x: frames.tray.midX, y: frames.tray.minY - 80)
                    lift(BoxPiece(watch: watch), origin: nil, start: point, scene: board.lead)
                    drag.location = point
                }
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
                if let board, let ends = Self.probeSpaces(value, board),
                   let scene = board.scene(ends.from.boxID), let piece = scene.occupants[ends.from.slot],
                   let over = board.scene(ends.over.boxID), let stage = frames.stages[ends.over.boxID],
                   let home = frames.stages[ends.from.boxID] {
                    // Touched down on the watch, then moved over the other compartment, as a finger does.
                    let start = painter(scene).slotRect(ends.from.slot)
                    let rect = painter(over).slotRect(ends.over.slot)
                    let point = CGPoint(x: stage.rect.minX + rect.midX + 10, y: stage.rect.minY + rect.midY + 6)
                    lift(piece, origin: ends.from, start: CGPoint(x: home.rect.minX + start.midX, y: home.rect.minY + start.midY), scene: scene)
                    drag.location = point
                }
            default: break
            }
        }
    }

    /// The share picture a probe writes: the box's, or with every box shown the stacked one.
    private func probePicture(_ card: Bool, _ board: Board) -> CGImage? {
        if board.both {
            return card ? BoxShare.image(stackCard(board)) : BoxShare.image(stackProductCard(board))
        }
        return card ? BoxShare.image(shareCard(board.lead)) : BoxShare.image(productCard(board.lead))
    }

    /// "3" is space 3 of the top box; "brown@3" space 3 of the brown box.
    private static func probeSpace(_ text: String, _ board: Board) -> BoxSpace? {
        let bits = text.split(separator: "@", maxSplits: 1).map(String.init)
        if bits.count == 2, let slot = Int(bits[1]) { return BoxSpace(boxID: bits[0], slot: slot) }
        guard let slot = Int(text) else { return nil }
        return BoxSpace(boxID: board.lead.box.id, slot: slot)
    }

    /// "2-5", "black@2-brown@5": cut at the first "-" after a slot number (box ids can hold a "-").
    private static func probeSpaces(_ text: String, _ board: Board) -> (from: BoxSpace, over: BoxSpace)? {
        let characters = Array(text)
        guard let cut = characters.indices.first(where: { $0 > 0 && characters[$0] == "-" && characters[$0 - 1].isNumber }),
              let from = probeSpace(String(characters[..<cut]), board),
              let over = probeSpace(String(characters[(cut + 1)...]), board) else { return nil }
        return (from, over)
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
            let slot = lift.origin?.slot ?? 0
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
