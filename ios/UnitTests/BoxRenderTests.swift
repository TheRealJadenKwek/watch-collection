import CoreGraphics
import SwiftUI
import XCTest
@testable import WatchCollection

/// Brief section 14: the millimetre geometry, the cutout pipeline's pure parts on synthetic bitmaps, the cutout
/// cache key, and what a compartment draws (13.8).
final class BoxGeometryTests: XCTestCase {
    let box = BoxGeometry(columns: 6, rows: 2)

    func testOuterSizeAndCanvasOfASixByTwo() {
        XCTAssertEqual(box.outer.width, 345, accuracy: 0.001)
        XCTAssertEqual(box.outer.height, 210, accuracy: 0.001)
        XCTAssertEqual(box.canvas.width, 345, accuracy: 0.001)
        XCTAssertEqual(box.canvas.height, 218, accuracy: 0.001)
    }

    func testCompartmentsAreFiftyByEightySeven() {
        for index in [0, 11] {
            XCTAssertEqual(box.slot(index).width, 50, accuracy: 0.001)
            XCTAssertEqual(box.slot(index).height, 87, accuracy: 0.001)
        }
    }

    func testPlaceInBothOrientations() {
        XCTAssertEqual(box.size(.front), CGSize(width: 345, height: 218))
        XCTAssertEqual(box.size(.endOn), CGSize(width: 218, height: 345))
        XCTAssertEqual(box.place(box.slot(0), .front), box.slot(0))
        // End on: slot 0 (back left) lands top right, slot 6 (front left) top left.
        let first = box.place(box.slot(0), .endOn), sixth = box.place(box.slot(6), .endOn)
        XCTAssertGreaterThan(first.midX, 218 / 2)
        XCTAssertLessThan(first.midY, 345 / 4)
        XCTAssertLessThan(sixth.midX, 218 / 2)
        XCTAssertLessThan(sixth.midY, 345 / 4)
        XCTAssertEqual(first.width, 87, accuracy: 0.001)
        XCTAssertEqual(first.height, 50, accuracy: 0.001)
    }

    func testSlotIndexRoundTripsEveryCentre() {
        for orientation in [BoxOrientation.front, .endOn] {
            for index in 0..<box.slotCount {
                let rect = box.place(box.slot(index), orientation)
                XCTAssertEqual(box.slotIndex(at: CGPoint(x: rect.midX, y: rect.midY), orientation), index, "\(orientation) \(index)")
            }
        }
    }

    func testSlotIndexIsNilOnTheFrameAndADividerResolvesToANeighbour() {
        XCTAssertNil(box.slotIndex(at: CGPoint(x: 5, y: 5), .front))
        XCTAssertNil(box.slotIndex(at: CGPoint(x: 172, y: 12), .front), "the back rail")
        XCTAssertNil(box.slotIndex(at: CGPoint(x: 5, y: 5), .endOn))
        // The divider between columns 0 and 1 runs from x 65 to 68.
        let onDivider = box.slotIndex(at: CGPoint(x: 66.5, y: 60), .front)
        XCTAssertNotNil(onDivider)
        XCTAssertTrue([0, 1].contains(onDivider ?? -1))
        // The divider between the rows runs from y 111 to 114.
        let betweenRows = box.slotIndex(at: CGPoint(x: 40, y: 112.5), .front)
        XCTAssertTrue([0, 6].contains(betweenRows ?? -1))
    }

    func testOrientationForTheSpaceOnOffer() {
        XCTAssertEqual(BoxGeometry.orientation(for: CGSize(width: 370, height: 640), columns: 6, rows: 2), .endOn)
        XCTAssertEqual(BoxGeometry.orientation(for: CGSize(width: 629, height: 450), columns: 6, rows: 2), .front)
        XCTAssertEqual(BoxGeometry.orientation(for: CGSize(width: 900, height: 600), columns: 6, rows: 2), .front)
    }

    func testPhoneScaleMatchesTheBrief() {
        // 370 pt wide end on: k is 1.70 and the box 586 pt tall.
        let k = 370 / box.size(.endOn).width
        XCTAssertEqual(k, 1.70, accuracy: 0.01)
        XCTAssertEqual(box.size(.endOn).height * k, 586, accuracy: 1)
    }
}

final class CutoutPipelinePureTests: XCTestCase {
    /// A w by h field, 1 inside the shapes and 0 outside.
    private func field(_ w: Int, _ h: Int, _ inside: (Double, Double) -> Bool) -> [Float] {
        var values = [Float](repeating: 0, count: w * h)
        for y in 0..<h {
            for x in 0..<w where inside(Double(x) + 0.5, Double(y) + 0.5) { values[y * w + x] = 1 }
        }
        return values
    }

    func testLargestInscribedCircleFindsTheDiscUnderABar() {
        let (w, h) = (240, 200)
        let centre = CGPoint(x: 110, y: 96), radius = 40.0
        let matte = field(w, h) { x, y in
            let disc = (x - centre.x) * (x - centre.x) + (y - centre.y) * (y - centre.y) <= radius * radius
            let bar = abs(y - centre.y) <= 10    // a strap straight through, edge to edge
            return disc || bar
        }
        let (found, r) = CutoutPipeline.largestInscribedCircle(matte, w: w, h: h)
        XCTAssertEqual(found.x, centre.x, accuracy: 2)
        XCTAssertEqual(found.y, centre.y, accuracy: 2)
        XCTAssertEqual(r, radius, accuracy: radius * 0.1)
    }

    func testCircleSupportIsHighOnACircleAndLowOnASquare() {
        let (w, h) = (200, 200)
        let centre = CGPoint(x: 100, y: 100), radius = 50.0
        let circle = field(w, h) { x, y in (x - 100) * (x - 100) + (y - 100) * (y - 100) <= radius * radius }
        XCTAssertGreaterThan(CutoutPipeline.circleSupport(gray: circle, matte: nil, w: w, h: h, center: centre, radius: radius), 0.9)
        // A square of the same size: its corners on the ring.
        let half = radius / 2.0.squareRoot()
        let square = field(w, h) { x, y in abs(x - 100) <= half && abs(y - 100) <= half }
        XCTAssertLessThan(CutoutPipeline.circleSupport(gray: square, matte: nil, w: w, h: h, center: centre, radius: radius), 0.3)
    }

    func testStrapAxisReturnsTheTiltAndNilOnABareDisc() {
        let (w, h) = (300, 300)
        let centre = CGPoint(x: 150, y: 150), radius = 30.0
        let tilt = 20.0 * .pi / 180
        // Up the strap, clockwise from straight up: x grows as y falls.
        let along = (x: sin(tilt), y: -cos(tilt))
        let strapped = field(w, h) { x, y in
            let dx = x - centre.x, dy = y - centre.y
            if dx * dx + dy * dy <= radius * radius { return true }
            let length = dx * along.x + dy * along.y
            let across = abs(dx * along.y - dy * along.x)
            return abs(length) <= radius * 2.6 && across <= radius * 0.4
        }
        guard let axis = CutoutPipeline.strapAxis(strapped, w: w, h: h, center: centre, radius: radius) else {
            return XCTFail("no strap axis")
        }
        XCTAssertEqual(axis * 180 / .pi, 20, accuracy: 3)
        let disc = field(w, h) { x, y in (x - 150) * (x - 150) + (y - 150) * (y - 150) <= radius * radius }
        XCTAssertNil(CutoutPipeline.strapAxis(disc, w: w, h: h, center: centre, radius: radius))
    }

    func testSkinTest() {
        XCTAssertTrue(CutoutPipeline.isSkin(200, 150, 120))
        XCTAssertFalse(CutoutPipeline.isSkin(235, 225, 205), "cream")
        XCTAssertFalse(CutoutPipeline.isSkin(150, 152, 158), "steel grey")
    }
}

final class CutoutCacheKeyTests: XCTestCase {
    func testKeyChangesWithEachHintFieldAndTheVersion() {
        var base = CutoutHint()
        base.centerX = 0.5
        base.centerY = 0.5
        base.radius = 0.2
        let key = CutoutStore.cacheKey(directory: "zenith-220s", photo: "a.jpg", hint: base)
        var changes: [CutoutHint] = []
        var hint = base; hint.centerX = 0.51; changes.append(hint)
        hint = base; hint.centerY = 0.49; changes.append(hint)
        hint = base; hint.radius = 0.21; changes.append(hint)
        hint = base; hint.rotation = 4; changes.append(hint)
        hint = base; hint.discOnly = true; changes.append(hint)
        for changed in changes {
            XCTAssertNotEqual(CutoutStore.cacheKey(directory: "zenith-220s", photo: "a.jpg", hint: changed), key)
        }
        XCTAssertNotEqual(CutoutStore.cacheKey(directory: "zenith-220s", photo: "a.jpg", hint: base, version: CutoutPipeline.version + 1), key)
        XCTAssertTrue(key.hasPrefix("v\(CutoutPipeline.version)/zenith-220s/a-"))
        // The framing focus only guides which subject to keep; it is not part of the key.
        hint = base; hint.focusX = 0.2; hint.focusY = 0.8
        XCTAssertEqual(CutoutStore.cacheKey(directory: "zenith-220s", photo: "a.jpg", hint: hint), key)
    }

    func testHintFromASavedSetting() {
        let full = CutoutStore.hint(for: BoxCutout(photo: "a.jpg", x: 0.4, y: 0.6, r: 0.2, turn: -4, caseOnly: true), focus: nil)
        XCTAssertEqual(full.centerX, 0.4)
        XCTAssertEqual(full.radius, 0.2)
        XCTAssertEqual(full.rotation, -4)
        XCTAssertTrue(full.discOnly)
        // A partial ring is no ring.
        let partial = CutoutStore.hint(for: BoxCutout(photo: "a.jpg", x: 0.4), focus: nil)
        XCTAssertNil(partial.centerX)
        XCTAssertEqual(CutoutStore.hintHash(partial), CutoutStore.hintHash(CutoutHint()))
    }
}

final class BoxSlotContentTests: XCTestCase {
    private func image(_ side: Int) -> CGImage {
        let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        return context.makeImage()!
    }

    private func cutout(_ image: CGImage) -> CutoutResult {
        CutoutResult(image: image, caseRadius: 117.6, strap: [0.2, 0.3, 0.4], strapAbove: 0.9, strapBelow: 0.1, method: .lift,
                     confidence: 0.8, photo: "a.jpg", centerX: 0.5, centerY: 0.5, radius: 0.2, rotation: 0)
    }

    func testTileThenEmptyTileThenPillow() {
        let tile = image(4), cut = cutout(image(8))
        let withTile = BoxSlotContent.make(picture: .tile("box-black-1.jpg"), tileImage: tile, cutout: cut, diameter: 42, dialName: "Blue")
        XCTAssertTrue(withTile.tile === tile)

        let onEmpty = BoxSlotContent.make(picture: .emptyTile("empty-black-1.jpg"), tileImage: tile, cutout: cut, diameter: 42, dialName: "Blue")
        XCTAssertNil(onEmpty.tile, "an empty tile is the bed, not the watch")
        XCTAssertTrue(onEmpty.cutout === cut.image)

        let onPillow = BoxSlotContent.make(picture: .pillow, tileImage: nil, cutout: cut, diameter: 42, dialName: "Blue", isTrial: true)
        XCTAssertNil(onPillow.tile)
        XCTAssertTrue(onPillow.cutout === cut.image)
        XCTAssertEqual(onPillow.caseRadiusPx, 117.6, accuracy: 0.001)
        XCTAssertEqual(onPillow.strap.g, 0.3, accuracy: 0.001)
        XCTAssertEqual(onPillow.strapAbove, 0.9, accuracy: 0.001)
        XCTAssertEqual(onPillow.diameter, 42, accuracy: 0.001)
        XCTAssertTrue(onPillow.isTrial)

        // A tile the rule picked but that has not loaded yet: the cutout until it does.
        let notLoaded = BoxSlotContent.make(picture: .tile("box-black-1.jpg"), tileImage: nil, cutout: cut, diameter: nil, dialName: nil)
        XCTAssertNil(notLoaded.tile)
        XCTAssertEqual(notLoaded.diameter, BoxGeometry.defaultDiameter, accuracy: 0.001)
    }

    func testUseCutoutRefusesTheTile() {
        let tiles = ["black": "box-black-1.jpg"], empties = ["black": "empty-black-1.jpg"]
        let refuse = BoxCutout(photo: "a.jpg", useCutout: true)
        let picture = BoxModel.picture(finish: "black", boxTiles: tiles, cutout: refuse, emptyBoxTiles: empties,
                                       hasTile: { _ in true }, hasEmptyTile: { _ in true })
        XCTAssertEqual(picture, .emptyTile("empty-black-1.jpg"))
        let content = BoxSlotContent.make(picture: picture, tileImage: image(4), cutout: nil, diameter: 40, dialName: nil)
        XCTAssertNil(content.tile)
        XCTAssertNil(content.cutout, "no cutout yet: the token")
    }

    func testSpaceNames() {
        let box = WatchBox(id: "black", name: "Black Box", finish: "black", columns: 6, rows: 2, slots: [:])
        XCTAssertEqual(box.spaceName(2), "back row, space 3")
        XCTAssertEqual(box.spaceName(6), "front row, space 1")
        XCTAssertEqual(box.spaceName(1, outOf: true), "back row, space 2 of 6")
        XCTAssertEqual(box.placeName(2), "Black Box, back row, space 3")
        let tall = WatchBox(id: "x", name: "X", finish: "black", columns: 3, rows: 3, slots: [:])
        XCTAssertEqual(tall.spaceName(4), "row 2, space 2")
        let single = WatchBox(id: "y", name: "Y", finish: "black", columns: 4, rows: 1, slots: [:])
        XCTAssertEqual(single.spaceName(3), "space 4")
    }
}

/// Where a drag counts as over the box, and the shared picture's names.
final class BoxScreenPureTests: XCTestCase {
    func testDropsUnderTheTrayOrTheBarAreOffTheBox() {
        // As measured on an iPhone 17 Pro: the scroll view's frame starts below the bar (screen y 116 is y 0 here)
        // and ends at the tray.
        let frames = BoxFrames()
        frames.stage = CGRect(x: 16, y: 300, width: 370, height: 900)
        frames.scroll = CGRect(x: 0, y: 0, width: 402, height: 545)
        frames.tray = CGRect(x: 0, y: 545, width: 402, height: 130)
        XCTAssertTrue(frames.showsBox(at: CGPoint(x: 200, y: 400)))
        XCTAssertFalse(frames.showsBox(at: CGPoint(x: 200, y: 560)), "the box runs on under the tray")
        XCTAssertFalse(frames.showsBox(at: CGPoint(x: 10, y: 400)), "beside the box")
        frames.stage.origin.y = -200
        XCTAssertFalse(frames.showsBox(at: CGPoint(x: 200, y: -10)), "scrolled under the bar")
        XCTAssertTrue(frames.showsBox(at: CGPoint(x: 200, y: 150)))
        // Before the tray and the scroll view have reported a frame, only the stage counts.
        let early = BoxFrames()
        early.stage = CGRect(x: 0, y: 0, width: 100, height: 100)
        XCTAssertTrue(early.showsBox(at: CGPoint(x: 50, y: 90)))
    }

    func testShareNames() {
        XCTAssertEqual(BoxShare.fileName("Black Box", ""), "black-box")
        XCTAssertEqual(BoxShare.fileName("Brown Box", "-product"), "brown-box-product")
        XCTAssertEqual(BoxShare.fileName("!!!", ""), "watch-box")
        XCTAssertEqual(BoxShareCard.list(["A"]), "A")
        XCTAssertEqual(BoxShareCard.list(["A", "B"]), "A and B")
        XCTAssertEqual(BoxShareCard.list(["A", "B", "C"]), "A, B and C")
    }
}

/// The trial mark and the selection ring beside it (review of 2026-11-16, drawing 5 to 7).
@MainActor final class BoxMarkTests: XCTestCase {
    private let box = BoxGeometry(columns: 6, rows: 2)

    /// Every width the box is drawn at: the phone end on and turned, the cover, a book's page, the inner screen's
    /// column, the share card, the Mac.
    private let views: [(name: String, orientation: BoxOrientation, width: CGFloat)] = [
        ("phone", .endOn, 370), ("phone turned", .front, 370), ("cover", .endOn, 350), ("cover turned", .front, 350),
        ("book", .endOn, 408), ("column", .front, 629), ("share", .front, 728), ("mac", .front, 900),
    ]

    private func painter(_ orientation: BoxOrientation, width: CGFloat, trials: [Int]) -> BoxPainter {
        var slots: [Int: BoxSlotContent] = [:]
        for slot in trials {
            var content = BoxSlotContent()
            content.isTrial = true
            slots[slot] = content
        }
        return BoxPainter(geometry: box, palette: .of(.black), orientation: orientation, lidClosed: false, slots: slots,
                          trialTag: BoxPainter.trialWord, k: width / box.size(orientation).width)
    }

    /// The marks alone, on a clear canvas, at 2x.
    private func marks(_ painter: BoxPainter, ringWidth: CGFloat = BoxPainter.trialRingWidth) -> CGImage? {
        let size = box.size(painter.orientation)
        let view = Canvas { context, _ in painter.drawMarks(&context, ringWidth: ringWidth) }
            .frame(width: size.width * painter.k, height: size.height * painter.k)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        return renderer.cgImage
    }

    /// Points (at 1x) of every pixel drawn, in RGBA.
    private func drawn(_ image: CGImage) -> [(point: CGPoint, rgba: [UInt8])] {
        let w = image.width, h = image.height
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        let context = CGContext(data: &pixels, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        var out: [(CGPoint, [UInt8])] = []
        for y in 0..<h {
            for x in 0..<w where pixels[(y * w + x) * 4 + 3] > 8 {
                let i = (y * w + x) * 4
                out.append((CGPoint(x: (CGFloat(x) + 0.5) / 2, y: (CGFloat(y) + 0.5) / 2), Array(pixels[i..<(i + 4)])))
            }
        }
        return out
    }

    func testTheTrialMarkStaysInsideItsSpaceInEveryView() throws {
        for view in views {
            // A space at each corner of the box, so the tag meets a divider and the frame in every direction.
            let trials = [0, 5, 6, 11]
            let painter = painter(view.orientation, width: view.width, trials: trials)
            let image = try XCTUnwrap(marks(painter), view.name)
            let rects = trials.map { painter.slotRect($0).insetBy(dx: -0.5, dy: -0.5) }
            let stray = drawn(image).filter { pixel in !rects.contains { $0.contains(pixel.point) } }
            XCTAssertTrue(stray.isEmpty, "\(view.name): \(stray.count) pixels of a trial mark outside its space, first at \(stray.first?.point ?? .zero)")
        }
    }

    func testTheTagIsNeverCutByItsSpace() throws {
        // The setting chosen fits between the walls in every view (it is clipped only as a last resort).
        for view in views {
            let painter = painter(view.orientation, width: view.width, trials: [0])
            let rect = painter.slotRect(0)
            var chosen: (style: BoxPainter.TrialTagStyle, frame: CGRect)?
            let size = max(7, 4.6 * painter.k)
            let probe = Canvas { context, _ in
                chosen = BoxPainter.trialTag(in: rect, styles: BoxPainter.trialTagStyles(BoxPainter.trialWord)) { style in
                    context.resolve(Text(style.word).font(.system(size: size, weight: .bold).width(style.expanded ? .expanded : .standard))
                        .tracking(style.tracking)).measure(in: CGSize(width: 400, height: 100))
                }
            }
            .frame(width: 10, height: 10)
            _ = ImageRenderer(content: probe).cgImage
            let tag = try XCTUnwrap(chosen, view.name)
            XCTAssertLessThanOrEqual(tag.frame.maxX, rect.maxX - BoxPainter.tagMargin + 0.01, view.name)
            XCTAssertLessThanOrEqual(tag.frame.maxY, rect.maxY - BoxPainter.tagMargin + 0.01, view.name)
            // The full word wherever there is room for it: end on everywhere, and the front view off the phone.
            if view.orientation == .endOn || view.width >= 600 {
                XCTAssertEqual(tag.style, BoxPainter.trialTagStyles(BoxPainter.trialWord)[0], view.name)
            }
        }
    }

    func testTheTagTakesTheFirstSettingThatFits() {
        let styles = BoxPainter.trialTagStyles("TRYING")
        XCTAssertEqual(styles.map(\.word), ["TRYING", "TRYING", "TRY"])
        let rect = CGRect(x: 100, y: 0, width: 50, height: 85)
        // 40 pt between the walls: 30 + 12 does not fit, 30 + 8 does.
        let widths: [CGFloat] = [30, 30, 14]
        let second = BoxPainter.trialTag(in: rect, styles: styles) { style in
            CGSize(width: widths[styles.firstIndex(of: style) ?? 0], height: 9)
        }
        XCTAssertEqual(second.style, styles[1])
        XCTAssertEqual(second.frame, CGRect(x: 105, y: 5, width: 38, height: 14))
        // Nothing fits: the last, smallest one.
        let last = BoxPainter.trialTag(in: rect, styles: styles) { _ in CGSize(width: 60, height: 9) }
        XCTAssertEqual(last.style.word, "TRY")
    }

    func testIncreaseContrastThickensTheTrialRing() throws {
        let painter = painter(.endOn, width: 370, trials: [3])
        // The ring along the compartment's left wall, below the tag: how many pixels across it covers.
        let rect = painter.slotRect(3)
        func across(_ width: CGFloat) throws -> Int {
            let image = try XCTUnwrap(marks(painter, ringWidth: width))
            let row = rect.midY + 20
            return drawn(image).filter { abs($0.point.y - row) < 0.3 && $0.point.x < rect.minX + 6 }.count
        }
        XCTAssertGreaterThan(try across(2.5), try across(BoxPainter.trialRingWidth))
    }

    func testSelectionAndTrialRingsKeepApart() {
        for (selection, trial) in [(CGFloat(1.5), BoxPainter.trialRingWidth), (2.5, 2.5)] {
            let inset = BoxPainter.selectionInset(lineWidth: selection, overTrial: true, trialWidth: trial)
            let selectionBand = (inset - selection / 2)...(inset + selection / 2)
            let trialBand = (BoxPainter.trialRingInset - trial / 2)...(BoxPainter.trialRingInset + trial / 2)
            XCTAssertGreaterThanOrEqual(trialBand.lowerBound - selectionBand.upperBound, BoxPainter.selectionGap - 0.001)
            // Outside the compartment, on its half of the divider at the scales the phone draws end on.
            XCTAssertLessThanOrEqual(selectionBand.upperBound, 0)
        }
        // Without a trial the selection ring stays where it was, just inside the walls.
        XCTAssertEqual(BoxPainter.selectionInset(lineWidth: 1.5, overTrial: false), 1.25)
    }
}
