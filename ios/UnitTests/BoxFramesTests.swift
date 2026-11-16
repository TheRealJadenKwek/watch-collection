import XCTest
@testable import WatchCollection

/// Where a drag lands with every box shown (the Both view): each box maps a point with its own geometry, the labels and
/// the gap between the boxes take a drop back, and the bar, the tray and a table's crease clip what scrolls.
final class BoxFramesTests: XCTestCase {
    private let box = BoxGeometry(columns: 6, rows: 2)
    /// Two boxes fitted between the bar and the tray of a 402 by 874 phone: (488 - 60) / 436.
    private let k: CGFloat = (488 - 60) / 436

    private var boxes: [(id: String, geometry: BoxGeometry)] { [(id: "black", geometry: box), (id: "brown", geometry: box)] }

    /// The phone: the scroll view from below the bar to the tray, the black box under its label at `top`, the brown
    /// one 16 pt below it under its own label. Both scroll.
    private func stacked(top: CGFloat = 22) -> BoxFrames {
        let frames = BoxFrames()
        frames.scroll = CGRect(x: 0, y: 0, width: 402, height: 545)
        frames.tray = CGRect(x: 0, y: 545, width: 402, height: 130)
        let width = box.canvas.width * k, height = box.canvas.height * k
        let x = (402 - width) / 2
        frames.order = ["black", "brown"]
        frames.stages["black"] = BoxFrames.Stage(rect: CGRect(x: x, y: top, width: width, height: height), scrolls: true)
        frames.stages["brown"] = BoxFrames.Stage(rect: CGRect(x: x, y: top + height + BoxStack.gap + BoxStack.label,
                                                              width: width, height: height), scrolls: true)
        return frames
    }

    private func middle(of slot: Int, in boxID: String, _ frames: BoxFrames, geometry: BoxGeometry? = nil, k: CGFloat? = nil) -> CGPoint {
        let rect = frames.stages[boxID]!.rect, scale = k ?? self.k
        let space = (geometry ?? box).slot(slot)
        return CGPoint(x: rect.minX + space.midX * scale, y: rect.minY + space.midY * scale)
    }

    func testEachBoxMapsItsOwnSpaces() {
        let frames = stacked()
        let top = middle(of: 3, in: "black", frames), lower = middle(of: 3, in: "brown", frames)
        XCTAssertEqual(frames.space(at: top, boxes: boxes, k: k), BoxSpace(boxID: "black", slot: 3))
        XCTAssertEqual(top.x, lower.x)
        XCTAssertEqual(frames.space(at: lower, boxes: boxes, k: k), BoxSpace(boxID: "brown", slot: 3))
        // Every space of both boxes.
        for boxID in ["black", "brown"] {
            for slot in 0..<box.slotCount {
                XCTAssertEqual(frames.space(at: middle(of: slot, in: boxID, frames), boxes: boxes, k: k), BoxSpace(boxID: boxID, slot: slot))
            }
        }
        XCTAssertNil(frames.space(at: top, boxes: boxes, k: 0), "no scale yet")
    }

    func testALabelTheGapAndTheFrameTakeADropBack() {
        let frames = stacked()
        let black = frames.stages["black"]!.rect, brown = frames.stages["brown"]!.rect
        let points: [(String, CGPoint)] = [
            ("the black box's label", CGPoint(x: black.midX, y: black.minY - 10)),
            ("the gap", CGPoint(x: black.midX, y: black.maxY + 8)),
            ("the brown box's label", CGPoint(x: brown.midX, y: brown.minY - 10)),
            ("the left rail", CGPoint(x: black.minX + 5, y: black.midY)),
            ("the drawer pull", CGPoint(x: brown.midX, y: brown.maxY - 2)),
        ]
        for (name, point) in points {
            XCTAssertNil(frames.space(at: point, boxes: boxes, k: k), name)
            XCTAssertTrue(frames.showsStack(at: point), name)
        }
        // Beside the stack and above its first label: off it.
        XCTAssertFalse(frames.showsStack(at: CGPoint(x: black.minX - 4, y: black.midY)))
        XCTAssertFalse(frames.showsStack(at: CGPoint(x: black.midX, y: black.minY - BoxStack.label - 2)))
    }

    func testTheTrayAndTheBarCoverWhatScrollsUnderThem() {
        // Scrolled down: the brown box runs on under the tray.
        let low = stacked(top: 120)
        let brown = low.stages["brown"]!.rect
        XCTAssertGreaterThan(brown.maxY, low.tray.minY)
        let onTray = CGPoint(x: brown.midX, y: low.tray.minY + 20)
        XCTAssertTrue(brown.contains(onTray))
        XCTAssertNil(low.space(at: onTray, boxes: boxes, k: k))
        XCTAssertFalse(low.showsStack(at: onTray), "on the tray: a drop takes the watch out")
        // Scrolled up: the black box's back row is under the bar.
        let high = stacked(top: -100)
        let black = high.stages["black"]!.rect
        let underBar = CGPoint(x: black.midX, y: -50)
        XCTAssertTrue(black.contains(underBar))
        XCTAssertNil(high.space(at: underBar, boxes: boxes, k: k))
        XCTAssertFalse(high.showsStack(at: underBar))
        XCTAssertEqual(high.space(at: middle(of: 8, in: "black", high), boxes: boxes, k: k), BoxSpace(boxID: "black", slot: 8))
    }

    func testOnATableTheFirstBoxStandsAboveTheCreaseAndTheRestScroll() {
        let frames = BoxFrames()
        let tableK: CGFloat = 290 / 218
        let width = box.canvas.width * tableK, height = box.canvas.height * tableK
        // The scroll view starts below the crease band.
        frames.scroll = CGRect(x: 0, y: 420, width: 669, height: 400)
        frames.order = ["black", "brown"]
        frames.stages["black"] = BoxFrames.Stage(rect: CGRect(x: 104, y: 90, width: width, height: height), scrolls: false)
        frames.stages["brown"] = BoxFrames.Stage(rect: CGRect(x: 104, y: 380, width: width, height: height), scrolls: true)
        // The fixed box hits above the scroll view's top.
        let fixedPoint = middle(of: 2, in: "black", frames, k: tableK)
        XCTAssertLessThan(fixedPoint.y, frames.visibleTop)
        XCTAssertEqual(frames.space(at: fixedPoint, boxes: boxes, k: tableK), BoxSpace(boxID: "black", slot: 2))
        // The scrolling one is clipped at the scroll view's top: its back row runs under the crease band there.
        let clipped = CGPoint(x: 104 + width / 2, y: 400)
        XCTAssertTrue(frames.stages["brown"]!.rect.contains(clipped))
        XCTAssertNil(frames.space(at: clipped, boxes: boxes, k: tableK))
        XCTAssertEqual(frames.space(at: middle(of: 9, in: "brown", frames, k: tableK), boxes: boxes, k: tableK),
                       BoxSpace(boxID: "brown", slot: 9))
        // The band over the crease, between the two: a drop there goes back.
        XCTAssertTrue(frames.showsStack(at: CGPoint(x: 334, y: 410)))
        XCTAssertFalse(frames.showsStack(at: CGPoint(x: 334, y: frames.visibleBottom + 5)), "below what the scroll view shows")
    }

    /// The half-open table with the lower pane scrolled: the black box fixed above the crease (bottom 380), the scroll
    /// view from 420, the brown box's label 12 pt into it. However far it scrolls, the crease band takes a drop back;
    /// the brown box scrolled out of sight does not reach up over the tabs.
    func testOnATableTheCreaseBandStaysOnTheStackHoweverFarTheRestScrolls() {
        let tableK: CGFloat = 290 / 218
        let width = box.canvas.width * tableK, height = box.canvas.height * tableK
        func table(scrolled: CGFloat) -> BoxFrames {
            let frames = BoxFrames()
            frames.scroll = CGRect(x: 0, y: 420, width: 669, height: 400)
            frames.order = ["black", "brown"]
            frames.stages["black"] = BoxFrames.Stage(rect: CGRect(x: 104, y: 380 - height, width: width, height: height), scrolls: false)
            frames.stages["brown"] = BoxFrames.Stage(rect: CGRect(x: 104, y: 420 + 12 + BoxStack.label - scrolled, width: width, height: height),
                                                     scrolls: true)
            return frames
        }
        let band = CGPoint(x: 334, y: 405)
        for scrolled: CGFloat in [0, 100, 300, 340, 400, 600] {
            let frames = table(scrolled: scrolled)
            XCTAssertNil(frames.space(at: band, boxes: boxes, k: tableK), "scrolled \(scrolled)")
            XCTAssertTrue(frames.showsStack(at: band), "the crease band, scrolled \(scrolled)")
        }
        // Scrolled 400 pt the brown box is wholly above the scroll view, its raw rect reaching up over the tab row.
        let frames = table(scrolled: 400)
        let black = frames.stages["black"]!.rect, brown = frames.stages["brown"]!.rect
        XCTAssertLessThan(brown.maxY, frames.visibleTop)
        let tabs = CGPoint(x: black.midX, y: black.minY - BoxStack.label - 10)
        XCTAssertTrue(brown.insetBy(dx: 0, dy: -BoxStack.label).contains(tabs))
        XCTAssertFalse(frames.showsStack(at: tabs), "the tab row is not on the stack")
        XCTAssertFalse(table(scrolled: 600).showsStack(at: tabs), "nor scrolled 600")
        // The black box's own label still is.
        XCTAssertTrue(frames.showsStack(at: CGPoint(x: black.midX, y: black.minY - 10)))
    }

    func testBoxesOfDifferentSizesMapWithTheirOwnGeometry() {
        let small = BoxGeometry(columns: 4, rows: 2)
        let frames = stacked()
        let width = small.canvas.width * k
        let top = frames.stages["brown"]!.rect.minY
        frames.stages["brown"]?.rect = CGRect(x: (402 - width) / 2, y: top, width: width, height: small.canvas.height * k)
        let mixed: [(id: String, geometry: BoxGeometry)] = [(id: "black", geometry: box), (id: "brown", geometry: small)]
        for slot in 0..<small.slotCount {
            XCTAssertEqual(frames.space(at: middle(of: slot, in: "brown", frames, geometry: small), boxes: mixed, k: k),
                           BoxSpace(boxID: "brown", slot: slot))
        }
        // A divider lands by the slack rule: up to half a divider either side goes to the nearer space.
        let rect = frames.stages["black"]!.rect
        let y = rect.minY + box.slot(0).midY * k
        let divider = box.slot(0).maxX
        XCTAssertEqual(frames.space(at: CGPoint(x: rect.minX + (divider + 0.5) * k, y: y), boxes: boxes, k: k)?.slot, 0)
        XCTAssertEqual(frames.space(at: CGPoint(x: rect.minX + (divider + 2.5) * k, y: y), boxes: boxes, k: k)?.slot, 1)
    }

    func testABoxNoLongerShownNoLongerTakesADrop() {
        let frames = stacked()
        let lower = middle(of: 4, in: "brown", frames)
        frames.stages["brown"] = nil
        XCTAssertNil(frames.space(at: lower, boxes: boxes, k: k))
        // Still in the frames but no longer in the order (its stage fading out): not hit either.
        let again = stacked()
        again.order = ["black"]
        XCTAssertNil(again.space(at: lower, boxes: boxes, k: k))
        XCTAssertFalse(again.shows("brown", at: lower))
        XCTAssertFalse(again.showsStack(at: lower), "a single box has no label around it")
    }

    func testOneBoxIsTheSingleViewAsBefore() {
        let frames = BoxFrames()
        frames.scroll = CGRect(x: 0, y: 0, width: 402, height: 545)
        frames.tray = CGRect(x: 0, y: 545, width: 402, height: 130)
        frames.order = ["black"]
        frames.stages["black"] = BoxFrames.Stage(rect: CGRect(x: 16, y: 300, width: 370, height: 234), scrolls: true)
        for point in [CGPoint(x: 200, y: 400), CGPoint(x: 200, y: 290), CGPoint(x: 200, y: 560), CGPoint(x: 10, y: 400),
                      CGPoint(x: 20, y: 320)] {
            XCTAssertEqual(frames.showsStack(at: point), frames.shows("black", at: point), "\(point)")
        }
    }

    func testAutoScrollInSingleViewIsAsBefore() {
        let frames = stacked()
        frames.order = ["black"]
        for y: CGFloat in [-39, -1, 0, 30, 59] { XCTAssertEqual(frames.autoScrollStep(at: y, both: false), -8, "y \(y)") }
        for y: CGFloat in [486, 520, 544] { XCTAssertEqual(frames.autoScrollStep(at: y, both: false), 8, "y \(y)") }
        for y: CGFloat in [-41, 61, 300, 484, 545, 600] { XCTAssertEqual(frames.autoScrollStep(at: y, both: false), 0, "y \(y)") }
        XCTAssertEqual(frames.autoScrollStep(at: 520), 8, "single view is the default")
    }

    func testWithBothBoxesAutoScrollRunsOnlyWhileTheStackRunsPastTheEdge() {
        // Fitted: the brown box ends just above the tray, so a watch held over its front row stays put.
        let fitted = stacked()
        XCTAssertLessThan(fitted.stages["brown"]!.rect.maxY, fitted.visibleBottom - 6)
        for y: CGFloat in [486, 520, 544] { XCTAssertEqual(fitted.autoScrollStep(at: y, both: true), 0, "y \(y)") }
        // The black box starts below the bar: no scrolling up either.
        for y: CGFloat in [-1, 30, 59] { XCTAssertEqual(fitted.autoScrollStep(at: y, both: true), 0, "y \(y)") }
        // The cover: the stack runs on under the tray, so the bottom band scrolls down to the hidden half.
        let long = stacked(top: 120)
        XCTAssertGreaterThan(long.stages["brown"]!.rect.maxY, long.visibleBottom - 6)
        for y: CGFloat in [486, 520, 544] { XCTAssertEqual(long.autoScrollStep(at: y, both: true), 8, "y \(y)") }
        XCTAssertEqual(long.autoScrollStep(at: 30, both: true), 0, "the top box starts below the bar")
        // Scrolled down so the black box starts under the bar: the top band scrolls back up.
        let scrolled = stacked(top: -60)
        for y: CGFloat in [-1, 30, 59] { XCTAssertEqual(scrolled.autoScrollStep(at: y, both: true), -8, "y \(y)") }
        XCTAssertEqual(scrolled.autoScrollStep(at: 300, both: true), 0)
        // Nothing scrolls (a book's page): no auto-scroll at all.
        let fixed = stacked(top: -60)
        for id in ["black", "brown"] { fixed.stages[id]?.scrolls = false }
        XCTAssertEqual(fixed.autoScrollStep(at: 30, both: true), 0)
        XCTAssertEqual(fixed.autoScrollStep(at: 520, both: true), 0)
    }
}
