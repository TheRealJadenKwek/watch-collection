import SwiftUI

// The box on screen, in layers (brief 5.6): the base (frame, lining, beds, dividers), one small canvas per watch so
// a move or a swap can glide, then the trial marks, the glass and the guides. Every number comes from BoxPainter.

/// A watch or a wishlist candidate as the boxes show it.
struct BoxPiece: Hashable, Identifiable {
    let itemID: String
    let wishlist: Bool
    var name: String
    var brand: String?
    var category: String?
    var diameter: Double?
    var dial: String?
    var photos: [String]
    var boxTiles: [String: String]?
    var boxCutout: BoxCutout?
    var focus: [String: PhotoFocus]?

    /// Stable across boxes and spaces, so a move glides: the watch id, or `trial:` and the candidate's id.
    var id: String { wishlist ? "trial:\(itemID)" : itemID }
    /// Its photo folder, which also names its cutouts and tiles.
    var directory: String { wishlist ? "wl-\(itemID)" : itemID }
    var source: CutoutSource {
        CutoutSource(itemID: itemID, wishlist: wishlist, photos: photos, setting: boxCutout, focus: focus)
    }
    /// The saved cutout settings that still apply.
    var setting: BoxCutout? { BoxModel.effectiveCutout(boxCutout, photos: photos) }
    /// The brand, or the category when there is none (the watch page's kicker).
    var kicker: String? { brand?.isEmpty == false ? brand : category }

    init(watch: Watch) {
        itemID = watch.id
        wishlist = false
        name = watch.name
        brand = watch.brand
        category = watch.category
        diameter = watch.diameter
        dial = watch.dialColor
        photos = watch.photos
        boxTiles = watch.boxTiles
        boxCutout = watch.boxCutout
        focus = watch.photoFocus
    }

    init(candidate: WishlistItem) {
        itemID = candidate.id
        wishlist = true
        name = candidate.name
        brand = candidate.brand.isEmpty ? nil : candidate.brand
        category = candidate.category
        diameter = candidate.diameter
        dial = candidate.dialColor
        photos = candidate.photos
        boxTiles = candidate.boxTiles
        boxCutout = candidate.boxCutout
        focus = candidate.photoFocus
    }
}

/// The pictures the boxes draw, loaded off the main actor (cutouts from `CutoutStore`, tiles from `BoxTileStore`)
/// and kept here for the views.
@MainActor @Observable
final class BoxArtwork {
    struct Cutout {
        var source: CutoutSource
        var result: CutoutResult?
        /// Bumped each time the picture changes, so the compartment cross-fades to it.
        var revision: Int
    }

    private(set) var cutouts: [String: Cutout] = [:]
    /// "<photo directory>/<file>", decoded at `tileSizes` on the long side.
    private(set) var tiles: [String: CGImage] = [:]
    /// The size each tile was decoded at. A tile stays on screen at its old size until the new size's decode arrives,
    /// so turning the box or resizing the window never blanks the compartments.
    @ObservationIgnored private var tileSizes: [String: Int] = [:]

    /// The cutout this piece shows now: the newest one made, even while a new setting is being worked out.
    func cutout(_ piece: BoxPiece) -> Cutout? { cutouts[piece.directory] }

    func tile(_ directory: String, _ file: String) -> CGImage? { tiles["\(directory)/\(file)"] }

    struct Request: Hashable {
        /// In the order their cutouts are made: the box on screen, then the tray, then the wishlist.
        var pieces: [BoxPiece]
        var tiles: [PhotoAsset]
        var pixels: Int
        /// A sync may have brought photos or tiles that were missing.
        var revision: Date?
    }

    func load(_ request: Request) async {
        await CutoutStore.shared.removeOldVersions()
        await CutoutStore.shared.seedIfAsked()
        // Tiles first: they are what a compartment shows when they exist, and they decode quickly.
        let wanted = Set(request.tiles.map(Self.tileKey))
        if tiles.keys.contains(where: { !wanted.contains($0) }) {
            tiles = tiles.filter { wanted.contains($0.key) }
        }
        tileSizes = tileSizes.filter { tiles[$0.key] != nil }
        let decode = Set(Self.tilesToDecode(request.tiles.map(Self.tileKey), pixels: request.pixels, shown: tileSizes))
        for asset in request.tiles where decode.contains(Self.tileKey(asset)) {
            let key = Self.tileKey(asset)
            if Task.isCancelled { return }
            let image = await BoxTileStore.shared.tile(asset, maxPixel: request.pixels)
            // A newer request owns the tiles now.
            if Task.isCancelled { return }
            if let image {
                // A new tile fades in; a sharper or smaller copy of one on screen just takes its place.
                if tiles[key] == nil {
                    withAnimation(.easeInOut(duration: 0.25)) { tiles[key] = image }
                } else {
                    tiles[key] = image
                }
                tileSizes[key] = request.pixels
            } else if tiles[key] != nil {
                // Its file has gone from this device.
                withAnimation(.easeInOut(duration: 0.25)) { tiles[key] = nil }
                tileSizes[key] = nil
            }
        }
        // What is already on disk, at once; then whatever is missing or out of date, one Vision job at a time.
        let stale = request.pieces.filter { piece in
            guard let known = cutouts[piece.directory] else { return true }
            return known.source != piece.source || known.result == nil
        }
        for piece in stale {
            if Task.isCancelled { return }
            if let hit = await CutoutStore.shared.cached(piece.source) { set(hit, for: piece) }
        }
        for piece in stale {
            if Task.isCancelled { return }
            let result = await CutoutStore.shared.cutout(piece.source)
            if Task.isCancelled { return }
            set(result, for: piece)
        }
    }

    private func set(_ result: CutoutResult?, for piece: BoxPiece) {
        guard let next = Self.updated(cutouts[piece.directory], with: result, source: piece.source) else { return }
        withAnimation(.easeInOut(duration: 0.25)) {
            cutouts[piece.directory] = next
        }
    }

    /// What a piece's entry becomes when a load answers `result` for `source`; nil leaves it as it is. While a new
    /// cutout cannot be made (a photo still downloading) the last picture stays, filed under the source it was made
    /// for, so the next load asks again. A piece with no photos left goes back to the token.
    nonisolated static func updated(_ previous: Cutout?, with result: CutoutResult?, source: CutoutSource) -> Cutout? {
        if result == nil, previous?.result != nil, !source.photos.isEmpty { return nil }
        let same = previous?.result.map { old in result.map { $0.image === old.image } ?? false } ?? (result == nil)
        return Cutout(source: source, result: result, revision: (previous?.revision ?? 0) + (same ? 0 : 1))
    }

    nonisolated static func tileKey(_ asset: PhotoAsset) -> String { "\(asset.directory)/\(asset.filename)" }

    /// The tiles of a request to decode: those not on screen and those on screen at another size, in the request's
    /// order. Every other tile on screen stays as it is.
    nonisolated static func tilesToDecode(_ keys: [String], pixels: Int, shown: [String: Int]) -> [String] {
        keys.filter { shown[$0] != pixels }
    }
}

/// One watch in a compartment.
struct BoxStageItem: Identifiable {
    var piece: BoxPiece
    var slot: Int
    var content: BoxSlotContent
    /// Changes when the picture does (token, cutout, tile), for the cross-fade.
    var look: String

    var id: String { piece.id }
}

/// Outlines the screen draws over the box.
struct BoxGuideMarks: Equatable {
    /// The compartment selected: a 1.5 pt accent ring.
    var selected: Int?
    /// Where an armed chip can go: faint accent outlines.
    var targets: Set<Int> = []
    /// The first open space, when "Try in my box" brought the candidate here.
    var emphasized: Int?
}

/// The box in layers. `hits` gives each compartment's touch target (tap, drag, menu, accessibility); it is laid over
/// the compartment and scales with the box.
struct BoxStage<Hits: View>: View {
    var geometry: BoxGeometry
    var finish: BoxFinish
    var orientation: BoxOrientation
    var lidClosed: Bool
    var items: [BoxStageItem]
    var emptyTile: CGImage?
    /// The watch being dragged: its place shows the bare bed.
    var hidden: String?
    /// A watch that was just dropped appears where it landed instead of gliding there.
    var arriving: String?
    var settles: [String: Int] = [:]
    var marks = BoxGuideMarks()
    /// The compartment under a dragged watch. Called from its own small view, so following the finger redraws
    /// only that ring.
    var hover: (() -> Int?)? = nil
    var outlined = false
    @ViewBuilder var hits: (Int) -> Hits

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let mm = geometry.size(orientation)
        GeometryReader { proxy in
            let painter = painter(k: proxy.size.width / mm.width)
            // Increase Contrast: the selection and trial rings 2.5 pt (brief 11).
            let trialRing = contrast == .increased ? 2.5 : BoxPainter.trialRingWidth
            ZStack(alignment: .topLeading) {
                Canvas(opaque: false, rendersAsynchronously: false) { context, _ in
                    painter.drawBase(&context)
                }
                watches(painter)
                Canvas(opaque: false, rendersAsynchronously: false) { context, _ in
                    painter.drawMarks(&context, ringWidth: trialRing)
                }
                .allowsHitTesting(false)
                BoxGlassLayer(painter: painter, progress: lidClosed ? 1 : 0, slides: !reduceMotion)
                    .allowsHitTesting(false)
                BoxGuides(painter: painter, marks: marks, lineWidth: contrast == .increased ? 2.5 : 1.5, trialWidth: trialRing)
                    .allowsHitTesting(false)
                if let hover {
                    BoxHoverRing(painter: painter, slot: hover, lineWidth: contrast == .increased ? 3 : 2)
                        .allowsHitTesting(false)
                }
                ForEach(0..<geometry.slotCount, id: \.self) { slot in
                    let rect = painter.slotRect(slot)
                    hits(slot)
                        .frame(width: rect.width, height: rect.height)
                        .position(x: rect.midX, y: rect.midY)
                }
            }
        }
        .aspectRatio(mm.width / mm.height, contentMode: .fit)
        .overlay {
            if outlined {
                GeometryReader { proxy in
                    let rect = painter(k: proxy.size.width / mm.width).outerRect
                    RoundedRectangle(cornerRadius: BoxGeometry.frameCorner * proxy.size.width / mm.width, style: .continuous)
                        .stroke(WatchTheme.separator, lineWidth: WatchTheme.hairline)
                        .frame(width: rect.width, height: rect.height)
                        .offset(x: rect.minX, y: rect.minY)
                }
                .allowsHitTesting(false)
            }
        }
        .modifier(BoxSceneShadow())
    }

    private func painter(k: CGFloat) -> BoxPainter {
        var marked: [Int: BoxSlotContent] = [:]
        for item in items where item.content.isTrial && item.id != hidden { marked[item.slot] = item.content }
        return BoxPainter(geometry: geometry, palette: .of(finish), orientation: orientation, lidClosed: lidClosed,
                          slots: marked, trialTag: "TRYING", k: k, emptyTile: emptyTile)
    }

    /// One canvas per watch. Keyed by the watch, so a move or a swap glides (0.3 s); with Reduce Motion keyed by the
    /// watch and its space, so it cross-fades instead.
    private func watches(_ painter: BoxPainter) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(items.map { KeyedItem(item: $0, reduceMotion: reduceMotion) }) { keyed in
                let item = keyed.item
                let rect = painter.slotRect(item.slot)
                BoxWatchItem(painter: painter, item: item, settle: settles[item.id] ?? 0)
                    .frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: rect.midY)
                    .opacity(item.id == hidden ? 0 : 1)
                    .transaction { transaction in
                        if item.id == arriving || item.id == hidden { transaction.animation = nil }
                    }
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.92)))
                    .allowsHitTesting(false)
            }
        }
        .animation(.easeInOut(duration: reduceMotion ? 0.25 : 0.3), value: items.map { "\($0.id)@\($0.slot)" })
    }
}

private struct KeyedItem: Identifiable {
    var item: BoxStageItem
    var reduceMotion: Bool
    var id: String { reduceMotion ? "\(item.id)@\(item.slot)" : item.id }
}

/// One compartment's watch. A drop settles it from 1.06 with a spring while its contact shadow tightens; a new
/// picture (token to cutout to tile) cross-fades in 0.25 s.
struct BoxWatchItem: View {
    var painter: BoxPainter
    var item: BoxStageItem
    var settle: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Group {
                if reduceMotion {
                    BoxWatchCanvas(painter: painter, slot: item.slot, content: item.content)
                } else {
                    KeyframeAnimator(initialValue: 0.0, trigger: settle) { rise in
                        BoxWatchCanvas(painter: painter, slot: item.slot, content: item.content, lift: rise)
                            .scaleEffect(1 + 0.06 * rise)
                    } keyframes: { _ in
                        KeyframeTrack {
                            MoveKeyframe(1.0)
                            SpringKeyframe(0.0, duration: 0.6, spring: Spring(response: 0.32, dampingRatio: 0.82))
                        }
                    }
                }
            }
            .id(item.look)
            .transition(.opacity)
        }
        .animation(.easeInOut(duration: 0.25), value: item.look)
    }
}

/// One compartment's contents in its own small canvas, drawn by the box's painter in the compartment's place.
struct BoxWatchCanvas: View, Animatable {
    var painter: BoxPainter
    var slot: Int
    var content: BoxSlotContent
    var lift: Double = 0
    /// Picked up out of the box: a tile travels without its walls, a cutout without its pillow.
    var lifted = false

    var animatableData: Double {
        get { lift }
        set { lift = newValue }
    }

    var body: some View {
        Canvas(opaque: false, rendersAsynchronously: false) { context, _ in
            let rect = painter.slotRect(slot)
            context.translateBy(x: -rect.minX, y: -rect.minY)
            painter.drawContents(&context, slot: slot, content: content, lift: lift, lifted: lifted)
        }
    }
}

/// The clear lid. It fades in over 0.35 s while the ceiling light's reflection slides 12 pt; with Reduce Motion it
/// only fades.
struct BoxGlassLayer: View, Animatable {
    var painter: BoxPainter
    var progress: Double
    var slides: Bool

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    var body: some View {
        Canvas(opaque: false, rendersAsynchronously: false) { context, _ in
            guard progress > 0.001 else { return }
            context.opacity = min(1, progress)
            painter.glass(&context, lampShift: slides ? CGFloat(1 - progress) * 12 : 0)
        }
    }
}

/// Selection, armed targets and the drop target, as outlines inside the compartments. A selected candidate on trial
/// keeps its trial ring: the selection goes round the outside of the compartment instead.
struct BoxGuides: View {
    var painter: BoxPainter
    var marks: BoxGuideMarks
    var lineWidth: CGFloat
    /// The trial ring's width, to keep clear of it.
    var trialWidth: CGFloat = BoxPainter.trialRingWidth

    var body: some View {
        Canvas(opaque: false, rendersAsynchronously: false) { context, _ in
            func ring(_ slot: Int, _ color: Color, _ width: CGFloat, inset: CGFloat) {
                let rect = painter.slotRect(slot).insetBy(dx: inset, dy: inset)
                context.stroke(Path(roundedRect: rect, cornerRadius: 2), with: .color(color), lineWidth: width)
            }
            for slot in marks.targets.sorted() where slot != marks.emphasized {
                ring(slot, WatchTheme.accent.opacity(0.55), 1, inset: 3)
            }
            if let slot = marks.emphasized { ring(slot, WatchTheme.accent, lineWidth, inset: 3) }
            if let slot = marks.selected {
                let overTrial = painter.slots[slot]?.isTrial == true
                ring(slot, WatchTheme.accent, lineWidth,
                     inset: BoxPainter.selectionInset(lineWidth: lineWidth, overTrial: overTrial, trialWidth: trialWidth))
            }
        }
    }
}

/// The accent outline on the compartment a dragged watch would land in.
struct BoxHoverRing: View {
    var painter: BoxPainter
    var slot: () -> Int?
    var lineWidth: CGFloat

    var body: some View {
        let target = slot()
        Canvas(opaque: false, rendersAsynchronously: false) { context, _ in
            guard let target else { return }
            let rect = painter.slotRect(target).insetBy(dx: 1.5, dy: 1.5)
            context.stroke(Path(roundedRect: rect, cornerRadius: 2), with: .color(WatchTheme.accent), lineWidth: lineWidth)
        }
    }
}

/// A tray chip's picture: the cutout on the card colour, or the token while it is being made.
struct BoxChipArt: View {
    var piece: BoxPiece
    var cutout: CutoutResult?

    var body: some View {
        Canvas(opaque: false, rendersAsynchronously: false) { context, size in
            let side = min(size.width, size.height)
            // The case fills a little over half the chip, so a 34 mm and a 49 mm watch both read at this size.
            let radius = side * 0.3
            context.translateBy(x: size.width / 2, y: size.height / 2)
            if let cutout {
                let drawn = CGFloat(cutout.image.width) * radius / max(1, cutout.caseRadius)
                context.draw(Image(decorative: cutout.image, scale: 1),
                             in: CGRect(x: -drawn / 2, y: -drawn / 2, width: drawn, height: drawn))
            } else {
                BoxPainter.token(&context, dial: BoxPainter.tokenDial(piece.dial), radius: radius)
            }
        }
        .background(WatchTheme.card)
        .clipShape(Rectangle())
    }
}
