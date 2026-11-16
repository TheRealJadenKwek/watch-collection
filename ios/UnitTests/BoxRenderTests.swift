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

    func testTheBoxIsDrawnFrontOnSixAcrossTwoDeep() {
        // Wider than tall, the drawer pull below the front wall.
        XCTAssertEqual(box.canvas, CGSize(width: 345, height: 218))
        // Slot 0 is back left, slot 5 back right, slot 6 front left (below slot 0), slot 11 front right.
        XCTAssertLessThan(box.slot(0).midX, box.slot(5).midX)
        XCTAssertEqual(box.slot(0).midX, box.slot(6).midX, accuracy: 0.001)
        XCTAssertLessThan(box.slot(0).midY, box.slot(6).midY)
        XCTAssertEqual(box.slot(6).midY, box.slot(11).midY, accuracy: 0.001)
        // Compartments stand upright: deeper than wide, so a dial sits at 12 up with the strap running up and down.
        XCTAssertGreaterThan(box.slot(0).height, box.slot(0).width)
        XCTAssertLessThanOrEqual(box.slot(11).maxY, box.outer.height)
    }

    func testSlotIndexRoundTripsEveryCentre() {
        for index in 0..<box.slotCount {
            let rect = box.slot(index)
            XCTAssertEqual(box.slotIndex(at: CGPoint(x: rect.midX, y: rect.midY)), index, "\(index)")
        }
    }

    func testSlotIndexIsNilOnTheFrameAndADividerResolvesToANeighbour() {
        XCTAssertNil(box.slotIndex(at: CGPoint(x: 5, y: 5)))
        XCTAssertNil(box.slotIndex(at: CGPoint(x: 172, y: 12)), "the back rail")
        XCTAssertNil(box.slotIndex(at: CGPoint(x: 172, y: 214)), "the drawer pull")
        // The divider between columns 0 and 1 runs from x 65 to 68.
        let onDivider = box.slotIndex(at: CGPoint(x: 66.5, y: 60))
        XCTAssertNotNil(onDivider)
        XCTAssertTrue([0, 1].contains(onDivider ?? -1))
        // The divider between the rows runs from y 111 to 114.
        let betweenRows = box.slotIndex(at: CGPoint(x: 40, y: 112.5))
        XCTAssertTrue([0, 6].contains(betweenRows ?? -1))
    }

    func testScaleFitsTheFrontView() {
        XCTAssertEqual(box.scale(fitting: CGSize(width: 370, height: 640)), 370 / 345, accuracy: 0.0001)
        XCTAssertEqual(box.scale(fitting: CGSize(width: 900, height: 109)), 0.5, accuracy: 0.0001)
    }

    func testPhoneScaleMatchesTheBrief() {
        // 370 pt wide front on: k is 1.07 and the box 234 pt tall.
        let k = 370 / box.canvas.width
        XCTAssertEqual(k, 1.07, accuracy: 0.01)
        XCTAssertEqual(box.canvas.height * k, 234, accuracy: 1)
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
        // A square of the same size (side twice the radius): its sides touch the ring, its corners stand outside it.
        // The rim test cannot push it under 0.3 (it scores about 0.57), but it stays under `roundEnough`, so a square
        // blob is questioned and searched for a better circle.
        let square = field(w, h) { x, y in abs(x - 100) <= radius && abs(y - 100) <= radius }
        let support = CutoutPipeline.circleSupport(gray: square, matte: nil, w: w, h: h, center: centre, radius: radius)
        XCTAssertLessThan(support, CutoutPipeline.roundEnough)
        XCTAssertLessThan(support, 0.9)
    }

    func testAnEmptyMatteHasNoInscribedCircle() {
        // What the skin test leaves when it clears the whole subject: radius 0, which `make` turns into the disc at
        // the usual size rather than an infinite scale.
        let (_, r) = CutoutPipeline.largestInscribedCircle([Float](repeating: 0, count: 64 * 48), w: 64, h: 48)
        XCTAssertEqual(r, 0)
    }

    func testHandRingIsKeptOnThePhoto() {
        var hint = CutoutHint()
        XCTAssertNil(CutoutPipeline.handRing(hint, w: 400, h: 300), "no ring")
        hint.centerX = 0.25; hint.centerY = 0.5; hint.radius = 0.2
        let ring = CutoutPipeline.handRing(hint, w: 400, h: 300)
        XCTAssertEqual(ring?.center.x ?? 0, 100, accuracy: 0.001)
        XCTAssertEqual(ring?.center.y ?? 0, 150, accuracy: 0.001)
        XCTAssertEqual(ring?.radius ?? 0, 60, accuracy: 0.001)
        hint.centerX = 1e300; hint.centerY = -4; hint.radius = 1e300
        let wild = CutoutPipeline.handRing(hint, w: 400, h: 300)
        XCTAssertEqual(wild?.center.x ?? 0, 400, accuracy: 0.001)
        XCTAssertEqual(wild?.center.y ?? -1, 0, accuracy: 0.001)
        XCTAssertEqual(wild?.radius ?? 0, 150, accuracy: 0.001)
        hint.radius = .nan
        XCTAssertNil(CutoutPipeline.handRing(hint, w: 400, h: 300), "not a number is no ring")
    }

    func testTheRingPicksTheSubjectUnderIt() {
        let (w, h) = (300, 200)
        // The watch in the middle and a second one at the edge, as in his Casio photo.
        let middle = field(w, h) { x, y in (x - 150) * (x - 150) + (y - 100) * (y - 100) <= 50 * 50 }
        let edge = field(w, h) { x, y in (x - 20) * (x - 20) + (y - 120) * (y - 120) <= 30 * 30 }
        let speck = field(w, h) { x, y in abs(x - 20) <= 2 && abs(y - 120) <= 2 }
        let onEdge = CGPoint(x: 20, y: 120)
        XCTAssertGreaterThan(CutoutPipeline.ringOverlap(edge, w: w, h: h, center: onEdge, radius: 30),
                             CutoutPipeline.ringOverlap(middle, w: w, h: h, center: onEdge, radius: 30))
        XCTAssertEqual(CutoutPipeline.ringOverlap(middle, w: w, h: h, center: onEdge, radius: 30), 0, "nothing of it under the ring")
        XCTAssertEqual(CutoutPipeline.ringOverlap(speck, w: w, h: h, center: onEdge, radius: 30), 0, "a speck counts for nothing")
    }

    func testCaseCover() {
        let side = 100, radius = 20.0
        let solid = [Float](repeating: 1, count: side * side)
        XCTAssertEqual(CutoutPipeline.caseCover(solid, side: side, radius: radius), 1, accuracy: 0.001)
        XCTAssertEqual(CutoutPipeline.caseCover([Float](repeating: 0, count: side * side), side: side, radius: radius), 0)
        var left = solid
        for y in 0..<side { for x in 50..<side { left[y * side + x] = 0 } }
        XCTAssertEqual(CutoutPipeline.caseCover(left, side: side, radius: radius), 0.5, accuracy: 0.03)
        XCTAssertLessThan(0.0, CutoutPipeline.emptyCase)
    }

    /// A grey photo with a dark disc at the left edge.
    private func photo(_ w: Int, _ h: Int) -> CGImage {
        let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.8, green: 0.8, blue: 0.75, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: w, height: h))
        context.setFillColor(CGColor(red: 0.1, green: 0.1, blue: 0.12, alpha: 1))
        context.fillEllipse(in: CGRect(x: -20, y: Double(h) / 2 - 40, width: 80, height: 80))
        return context.makeImage()!
    }

    /// Alpha of a premultiplied RGBA image, top row first.
    private func alpha(_ image: CGImage) -> [UInt8] {
        guard let pixels = Raster.rgba(image) else { return [] }
        return stride(from: 3, to: pixels.count, by: 4).map { pixels[$0] }
    }

    func testTheDiscIsClearPastThePhotosEdge() {
        let image = photo(300, 200)
        // Centre 6 pixels from the left edge, radius 40: most of the left half of the disc is off the photo.
        let side = 280, scale = 280 * Double(CutoutPipeline.caseFraction) / 40
        guard let cut = CutoutPipeline.discCut(image, side: side, center: CGPoint(x: 6, y: 100), angle: 0, scale: scale) else {
            return XCTFail("no cut")
        }
        let mid = side / 2, r = Int(Double(side) * Double(CutoutPipeline.caseFraction))
        // Inside the disc but left of the photo: clear. Inside the disc on the photo: solid.
        XCTAssertEqual(cut.alpha[mid * side + mid - r / 2], 0)
        XCTAssertEqual(cut.alpha[mid * side + mid + r / 2], 1, accuracy: 0.001)
        let coverage = Raster.coverage(width: 300, height: 200, side: side, center: CGPoint(x: 6, y: 100), angle: 0, scale: scale)
        XCTAssertEqual(coverage?[mid * side + 2], 0, "past the left edge")
        XCTAssertEqual(coverage?[mid * side + side - 3], 255, "on the photo")
    }

    func testCaseOnlyAtThePhotosEdgeLeavesNoGrey() {
        // End to end: the iOS Simulator cannot lift, so this is the disc path whatever Vision does.
        var hint = CutoutHint()
        hint.centerX = 0.02; hint.centerY = 0.5; hint.radius = 0.2
        hint.discOnly = true
        guard let cut = CutoutPipeline.make(photo: photo(300, 200), hint: hint) else { return XCTFail("no cutout") }
        XCTAssertEqual(cut.method, .disc)
        let a = alpha(cut.image), side = cut.image.width, mid = side / 2, r = Int(cut.caseRadius)
        XCTAssertEqual(a[mid * side + mid - r * 3 / 4], 0, "left of the photo, inside the case circle")
        XCTAssertEqual(a[mid * side + mid + r / 2], 255)
    }

    func testARingOfNoSizeGivesTheUsualDisc() {
        var hint = CutoutHint()
        hint.centerX = 0.5; hint.centerY = 0.5; hint.radius = 0
        guard let cut = CutoutPipeline.make(photo: photo(300, 200), hint: hint) else { return XCTFail("no cutout") }
        XCTAssertEqual(cut.method, .disc)
        XCTAssertEqual(cut.radius, CutoutPipeline.defaultCase, accuracy: 0.0001)
        XCTAssertEqual(cut.centerX, 0.5, accuracy: 0.0001, "the ring's centre is kept")
        XCTAssertGreaterThan(alpha(cut.image).filter { $0 > 127 }.count, 40_000, "a whole case disc, not grey or nothing")
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

    func testHintKeepsDocumentValuesInRange() {
        // A hand-edited or foreign document: the pipeline must never see these.
        let wild = CutoutStore.hint(for: BoxCutout(photo: "a.jpg", x: 1e300, y: -3, r: 1e300, turn: 1e9),
                                    focus: PhotoFocus(x: 7, y: -2, zoom: 1))
        XCTAssertEqual(wild.centerX, 1)
        XCTAssertEqual(wild.centerY, 0)
        XCTAssertEqual(wild.radius, BoxCutout.ringRadius.upperBound)
        XCTAssertEqual(wild.rotation, 180)
        XCTAssertEqual(wild.focusX, 1)
        XCTAssertEqual(wild.focusY, 0)
        let tiny = CutoutStore.hint(for: BoxCutout(photo: "a.jpg", x: 0.5, y: 0.5, r: 0), focus: nil)
        XCTAssertEqual(tiny.radius, BoxCutout.ringRadius.lowerBound)
        let nan = CutoutStore.hint(for: BoxCutout(photo: "a.jpg", x: .nan, y: 0.5, r: 0.2, turn: .infinity),
                                   focus: PhotoFocus(x: .nan, y: 0.3, zoom: 1))
        XCTAssertNil(nan.centerX, "not a number: no ring")
        XCTAssertEqual(nan.rotation, 0)
        XCTAssertEqual(nan.focusX, 0.5)
        XCTAssertEqual(nan.focusY, 0.5)
        // Values already in range are untouched, so the editor's hint and the saved one still share a cache key.
        let editor = CutoutStore.hint(for: BoxCutout(photo: "a.jpg", x: 0.4, y: 0.6, r: 0.2, turn: 0, caseOnly: false), focus: nil)
        let saved = CutoutStore.hint(for: BoxCutout(photo: "a.jpg", x: 0.4, y: 0.6, r: 0.2).normalized, focus: nil)
        XCTAssertEqual(CutoutStore.hintHash(editor), CutoutStore.hintHash(saved))
    }

    func testOnlyOtherVersionFoldersAreRemoved() {
        let names = ["v1", "v2", "v10", "v", "vx", "v-1", "v+3", "notes", ".DS_Store", "v3.tmp"]
        XCTAssertEqual(CutoutStore.staleVersionFolders(names, current: 2), ["v1", "v10"])
    }

    func testAHandSetRingClearsCheckTheCutout() {
        let image = CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!.makeImage()!
        var result = CutoutResult(image: image, caseRadius: 117.6, strap: [0.1, 0.1, 0.1], strapAbove: 0, strapBelow: 0, method: .disc,
                                  confidence: 0.3, photo: "a.jpg", centerX: 0.5, centerY: 0.5, radius: 0.2, rotation: 0)
        XCTAssertTrue(result.isDoubtful, "automatic disc")
        result.handSet = true
        XCTAssertFalse(result.isDoubtful, "the disc inside his own ring")
        result.method = .failed
        XCTAssertTrue(result.isDoubtful, "an empty cut is flagged even inside his ring")
        var hint = CutoutHint()
        XCTAssertFalse(CutoutStore.isHandSet(hint))
        hint.centerX = 0.5; hint.centerY = 0.5; hint.radius = 0.2
        XCTAssertTrue(CutoutStore.isHandSet(hint))
    }
}

final class BoxArtworkTests: XCTestCase {
    private func cutout(_ photo: String) -> CutoutResult {
        let image = CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!.makeImage()!
        return CutoutResult(image: image, caseRadius: 117.6, strap: [0.1, 0.1, 0.1], strapAbove: 1, strapBelow: 1, method: .lift,
                            confidence: 0.9, photo: photo, centerX: 0.5, centerY: 0.5, radius: 0.2, rotation: 0)
    }

    private func source(_ photos: [String]) -> CutoutSource {
        CutoutSource(itemID: "zenith-220s", wishlist: false, photos: photos, setting: nil, focus: nil)
    }

    func testAPhotoNotHereYetKeepsThePictureAndAsksAgain() {
        let old = BoxArtwork.Cutout(source: source(["a.jpg"]), result: cutout("a.jpg"), revision: 1)
        // A new cover that has not downloaded: nothing to make yet.
        XCTAssertNil(BoxArtwork.updated(old, with: nil, source: source(["b.jpg", "a.jpg"])),
                     "the old picture stays, under its old source, so the next load is not skipped")
        let arrived = cutout("b.jpg")
        let next = BoxArtwork.updated(old, with: arrived, source: source(["b.jpg", "a.jpg"]))
        XCTAssertTrue(next?.result?.image === arrived.image)
        XCTAssertEqual(next?.revision, 2)
        XCTAssertEqual(next?.source, source(["b.jpg", "a.jpg"]))
    }

    func testNoPhotosLeftShowsTheToken() {
        let old = BoxArtwork.Cutout(source: source(["a.jpg"]), result: cutout("a.jpg"), revision: 3)
        let next = BoxArtwork.updated(old, with: nil, source: source([]))
        XCTAssertNotNil(next)
        XCTAssertNil(next?.result)
        XCTAssertEqual(next?.revision, 4)
    }

    func testTheSamePictureKeepsItsRevision() {
        let made = cutout("a.jpg")
        let old = BoxArtwork.Cutout(source: source(["a.jpg"]), result: made, revision: 5)
        XCTAssertEqual(BoxArtwork.updated(old, with: made, source: source(["a.jpg"]))?.revision, 5)
        XCTAssertEqual(BoxArtwork.updated(nil, with: nil, source: source(["a.jpg"]))?.revision, 0)
    }

    func testTilesAtAnotherSizeStayUntilTheirReplacementDecodes() {
        // Turning the phone: every tile on screen is at the old size. Each is decoded again, and none is dropped first.
        let shown = ["w1/box-black-1.jpg": 640, "w2/box-black-1.jpg": 896]
        XCTAssertEqual(BoxArtwork.tilesToDecode(["w1/box-black-1.jpg", "w2/box-black-1.jpg", "w3/box-black-1.jpg"], pixels: 896, shown: shown),
                       ["w1/box-black-1.jpg", "w3/box-black-1.jpg"])
        XCTAssertEqual(BoxArtwork.tilesToDecode(["w2/box-black-1.jpg"], pixels: 896, shown: shown), [])
    }
}

final class BoxCutoutEditorTests: XCTestCase {
    func testScrollSizesTheRing() {
        XCTAssertEqual(BoxCutoutEditor.scrollFactor(0), 1)
        XCTAssertGreaterThan(BoxCutoutEditor.scrollFactor(10), 1)
        XCTAssertLessThan(BoxCutoutEditor.scrollFactor(-10), 1)
        XCTAssertEqual(BoxCutoutEditor.scrollFactor(100) * BoxCutoutEditor.scrollFactor(-100), 1, accuracy: 1e-9, "up then down comes back")
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

/// The trial mark, the selection ring beside it, and the product view's frame (review of 2026-11-16, drawing 2 and
/// 4 to 7).
@MainActor final class BoxMarkTests: XCTestCase {
    private let box = BoxGeometry(columns: 6, rows: 2)

    /// Every width the box is drawn at, always front on: the phone, the cover, a book's page, the inner screen's
    /// column, the share card, the Mac.
    private let views: [(name: String, width: CGFloat)] = [
        ("phone", 370), ("cover", 350), ("book", 437), ("column", 629), ("share", 728), ("mac", 900),
    ]

    private func painter(width: CGFloat, trials: [Int]) -> BoxPainter {
        var slots: [Int: BoxSlotContent] = [:]
        for slot in trials {
            var content = BoxSlotContent()
            content.isTrial = true
            slots[slot] = content
        }
        return BoxPainter(geometry: box, palette: .of(.black), lidClosed: false, slots: slots,
                          trialTag: BoxPainter.trialWord, k: width / box.canvas.width)
    }

    /// The marks alone, on a clear canvas, at 2x.
    private func marks(_ painter: BoxPainter, ringWidth: CGFloat = BoxPainter.trialRingWidth) -> CGImage? {
        let size = box.canvas
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
            let painter = painter(width: view.width, trials: trials)
            let image = try XCTUnwrap(marks(painter), view.name)
            let rects = trials.map { painter.slotRect($0).insetBy(dx: -0.5, dy: -0.5) }
            let stray = drawn(image).filter { pixel in !rects.contains { $0.contains(pixel.point) } }
            XCTAssertTrue(stray.isEmpty, "\(view.name): \(stray.count) pixels of a trial mark outside its space, first at \(stray.first?.point ?? .zero)")
        }
    }

    func testTheTagIsNeverCutByItsSpace() throws {
        // The setting chosen fits between the walls in every view (it is clipped only as a last resort).
        for view in views {
            let painter = painter(width: view.width, trials: [0])
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
            // The full word wherever there is room for it: the front view off the phone.
            if view.width >= 600 {
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
        let painter = painter(width: 370, trials: [3])
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
            // Outside the compartment, on its half of the divider.
            XCTAssertLessThanOrEqual(selectionBand.upperBound, 0)
        }
        // Without a trial the selection ring stays where it was, just inside the walls.
        XCTAssertEqual(BoxPainter.selectionInset(lineWidth: 1.5, overTrial: false), 1.25)
    }

    // MARK: The product view

    func testTheProductViewFitsEveryRowCount() {
        // Two rows keep the prototype's frame.
        XCTAssertEqual(BoxProductPainter.aspect(box), 345 / 262, accuracy: 0.0005)
        for rows in 1...4 {
            for columns in 1...8 {
                let geometry = BoxGeometry(columns: columns, rows: rows)
                for width: CGFloat in [370, 402, 728] {
                    let size = CGSize(width: width, height: width / BoxProductPainter.aspect(geometry))
                    let painter = BoxProductPainter(geometry: geometry, palette: .of(.black), slots: [:], size: size)
                    XCTAssertGreaterThanOrEqual(painter.top, 4, "\(columns) x \(rows) at \(width): the back rail is cut off")
                }
            }
        }
        // More rows, a taller picture.
        let heights = (1...4).map { BoxProductPainter.height(BoxGeometry(columns: 6, rows: $0)) }
        XCTAssertEqual(heights, heights.sorted())
    }

    func testTheProductViewMarksATrialWithItsTag() throws {
        /// Pixels of the trial green (#2FB877) well inside the box the green spans: none for the ring alone (it is
        /// that box's edge), the capsule of the TRYING tag when there is one.
        func greenInsideTheRing(trial: Bool) throws -> Int {
            var content = BoxSlotContent()
            content.isTrial = trial
            let view = BoxProductView(geometry: box, finish: .black, slots: [6: content]).frame(width: 370)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 1
            let image = try XCTUnwrap(renderer.cgImage)
            let green = drawn(image).filter { pixel in
                let c = pixel.rgba
                return abs(Int(c[0]) - 0x2F) < 30 && abs(Int(c[1]) - 0xB8) < 30 && abs(Int(c[2]) - 0x77) < 30
            }.map(\.point)
            guard let first = green.first else { return 0 }
            let span = green.reduce(CGRect(origin: first, size: .zero)) { $0.union(CGRect(origin: $1, size: .zero)) }
            return green.filter { span.insetBy(dx: 3, dy: 3).contains($0) }.count
        }
        XCTAssertEqual(try greenInsideTheRing(trial: false), 0)
        XCTAssertGreaterThan(try greenInsideTheRing(trial: true), 100)
    }

    func testABackRowTrialGoesUnderTheFrontRow() throws {
        /// The rows of the trial green in the picture with a candidate in one space.
        func greenRows(_ slot: Int) throws -> ClosedRange<CGFloat> {
            var content = BoxSlotContent()
            content.isTrial = true
            let view = BoxProductView(geometry: box, finish: .black, slots: [slot: content]).frame(width: 370)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 3
            let image = try XCTUnwrap(renderer.cgImage)
            let ys = drawn(image).filter { pixel in
                let c = pixel.rgba
                return abs(Int(c[0]) - 0x2F) < 30 && abs(Int(c[1]) - 0xB8) < 30 && abs(Int(c[2]) - 0x77) < 30
            }.map(\.point.y)
            let top = try XCTUnwrap(ys.min()), bottom = try XCTUnwrap(ys.max())
            return top...bottom
        }
        // Space 0 is at the back on the left, space 6 in front of it.
        let back = try greenRows(0), front = try greenRows(6)
        XCTAssertLessThan(back.lowerBound, front.lowerBound)
        XCTAssertLessThanOrEqual(back.upperBound, front.lowerBound + 1.5, "the back ring runs over the front row")
    }
}
