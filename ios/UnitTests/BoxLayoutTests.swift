import SwiftUI
import XCTest
@testable import WatchCollection

/// Where the Boxes tab puts the box in each posture (brief section 9): which arrangement a window gets, the box's view
/// and scale in the space it is given, and the two panes either side of the crease or the Mac's side column.
@MainActor final class BoxLayoutTests: XCTestCase {
    private let box = BoxGeometry(columns: 6, rows: 2)
    // Measured on the simulator, as in DuoTests.
    private let cover = CGSize(width: 466, height: 678)
    private let coverInsets = EdgeInsets(top: 0, leading: 0, bottom: 34, trailing: 84)
    private let inner = CGSize(width: 669, height: 951)
    private let book = CGSize(width: 951, height: 669)
    private let innerInsets = EdgeInsets(top: 24, leading: 0, bottom: 34, trailing: 0)

    private func layout(_ size: CGSize, _ insets: EdgeInsets, _ hinge: DuoLayout.Hinge) -> DuoLayout {
        DuoLayout(size: size, insets: insets, hinge: hinge)
    }

    // MARK: Arrangement

    func testEachPostureGetsItsArrangement() {
        XCTAssertEqual(BoxArrangement.of(.phone, mac: false, width: 402), .phone)
        // The cover is the phone layout.
        XCTAssertEqual(BoxArrangement.of(layout(cover, coverInsets, .closed), mac: false, width: 382), .phone)
        // Held like a book, open or half open.
        for hinge in [DuoLayout.Hinge.fullyOpen, .partiallyOpen] {
            XCTAssertEqual(BoxArrangement.of(layout(book, innerInsets, hinge), mac: false, width: 951), .book)
        }
        // The crease across: open is one column, half open is the table top.
        XCTAssertEqual(BoxArrangement.of(layout(inner, innerInsets, .fullyOpen), mac: false, width: 669), .column)
        XCTAssertEqual(BoxArrangement.of(layout(inner, innerInsets, .partiallyOpen), mac: false, width: 669), .table)
    }

    func testTheMacMovesItsSideColumnBelowTheBoxWhenNarrow() {
        XCTAssertEqual(BoxArrangement.of(.phone, mac: true, width: BoxArrangement.deskWidth), .desk)
        XCTAssertEqual(BoxArrangement.of(.phone, mac: true, width: 1200), .desk)
        XCTAssertEqual(BoxArrangement.of(.phone, mac: true, width: BoxArrangement.deskWidth - 1), .column)
        // Before the window is measured (width 0) it starts as a column.
        XCTAssertEqual(BoxArrangement.of(.phone, mac: true, width: 0), .column)
    }

    func testOnlyThePhoneDocksTheTrayAndTurnsTheBox() {
        let all: [BoxArrangement] = [.phone, .column, .book, .table, .desk]
        XCTAssertEqual(all.filter(\.docksTray), [.phone])
        XCTAssertEqual(all.filter(\.canTurn), [.phone])
        // Only where the box scrolls with the page does a drag near the edge scroll it.
        XCTAssertEqual(all.filter(\.stageScrolls), [.phone, .column])
        XCTAssertEqual(all.map(\.chipColumns), [1, 6, 4, 6, 2])
    }

    // MARK: The box in its space

    func testThePhoneShowsTheBoxEndOnAcrossTheWidthUnlessTurned() {
        let space = CGSize(width: 370, height: 0)
        let endOn = BoxArrangement.stage(box, .phone, space: space, turned: false, mac: false)
        XCTAssertEqual(endOn.orientation, .endOn)
        XCTAssertEqual(endOn.k * box.size(.endOn).width, 370, accuracy: 0.001)
        let turned = BoxArrangement.stage(box, .phone, space: space, turned: true, mac: false)
        XCTAssertEqual(turned.orientation, .front)
        XCTAssertEqual(turned.k * box.size(.front).width, 370, accuracy: 0.001)
    }

    func testAColumnShowsTheBoxFrontOnAndTheMacCapsIt() {
        // The inner screen with the crease across: 669 less 20 a side.
        let inner = BoxArrangement.stage(box, .column, space: CGSize(width: 629, height: 0), turned: true, mac: false)
        XCTAssertEqual(inner.orientation, .front)
        XCTAssertEqual(inner.k, 629 / 345, accuracy: 0.0001)
        XCTAssertEqual(inner.k * box.size(.front).height, 397, accuracy: 1)
        // A narrow Mac window: as wide as the column, never wider than `widestBox`.
        let narrow = BoxArrangement.stage(box, .column, space: CGSize(width: 700, height: 0), turned: false, mac: true)
        XCTAssertEqual(narrow.k * box.size(.front).width, 700, accuracy: 0.001)
        let wide = BoxArrangement.stage(box, .column, space: CGSize(width: 1400, height: 0), turned: false, mac: true)
        XCTAssertEqual(wide.k * box.size(.front).width, BoxArrangement.widestBox, accuracy: 0.001)
    }

    func testAFixedPaneTakesTheViewWithTheBiggerWatchesAndFitsIt() {
        // The left page of the book: taller than wide, so end on, fitted to the height.
        let page = CGSize(width: 437.5, height: 535)
        let left = BoxArrangement.stage(box, .book, space: page, turned: true, mac: false)
        XCTAssertEqual(left.orientation, .endOn)
        assertFits(left, in: page)
        XCTAssertEqual(left.k * box.size(.endOn).height, 535, accuracy: 0.001)
        // Above the crease on the table top: wide and short, so front on.
        let top = CGSize(width: 629, height: 330)
        let table = BoxArrangement.stage(box, .table, space: top, turned: false, mac: false)
        XCTAssertEqual(table.orientation, .front)
        assertFits(table, in: top)
        // The Mac's desk: front on, and never wider than `widestBox` however big the window.
        let desk = BoxArrangement.stage(box, .desk, space: CGSize(width: 2000, height: 1500), turned: false, mac: true)
        XCTAssertEqual(desk.orientation, .front)
        XCTAssertEqual(desk.k * box.size(.front).width, BoxArrangement.widestBox, accuracy: 0.001)
        // Before the pane is measured there is no box to draw.
        for empty in [CGSize.zero, CGSize(width: 400, height: 0), CGSize(width: 0, height: 400)] {
            XCTAssertEqual(BoxArrangement.stage(box, .book, space: empty, turned: false, mac: false).k, 0)
        }
    }

    private func assertFits(_ stage: (orientation: BoxOrientation, k: CGFloat), in space: CGSize,
                            file: StaticString = #filePath, line: UInt = #line) {
        let drawn = box.size(stage.orientation)
        XCTAssertLessThanOrEqual(drawn.width * stage.k, space.width + 0.001, file: file, line: line)
        XCTAssertLessThanOrEqual(drawn.height * stage.k, space.height + 0.001, file: file, line: line)
    }

    // MARK: Panes

    func testAColumnGivesEverythingToTheScrollingPane() {
        let bounds = CGRect(x: 0, y: 10, width: 402, height: 700)
        for arrangement in [BoxArrangement.phone, .column] {
            let panes = BoxPanes.panes(in: bounds, arrangement, crease: nil)
            XCTAssertEqual(panes.fixed.size, .zero)
            XCTAssertEqual(panes.fixed.origin, bounds.origin)
            XCTAssertEqual(panes.scrolling, bounds)
        }
    }

    func testTheBookAndTheTableSplitAtTheCreaseWithItsClearance() {
        let spread = CGRect(x: 0, y: 0, width: 951, height: 560)
        let book = BoxPanes.panes(in: spread, .book, crease: nil)
        XCTAssertEqual(book.fixed, CGRect(x: 0, y: 0, width: 461.5, height: 560))
        XCTAssertEqual(book.scrolling, CGRect(x: 489.5, y: 0, width: 461.5, height: 560))
        // The table top: the box above, the rest below, nothing in the 28 pt band.
        let page = CGRect(x: 0, y: 0, width: 669, height: 951 - 68 - 34)
        let crease = 951 / 2 - 68.0
        let table = BoxPanes.panes(in: page, .table, crease: crease)
        XCTAssertEqual(table.fixed.maxY, crease - DuoLayout.creaseClearance)
        XCTAssertEqual(table.scrolling.minY, crease + DuoLayout.creaseClearance)
        XCTAssertEqual(table.scrolling.maxY, page.maxY)
        XCTAssertEqual(table.fixed.width, 669)
    }

    func testTheDeskKeepsAColumnAtTheRight() {
        let bounds = CGRect(x: 0, y: 0, width: 1100, height: 800)
        let desk = BoxPanes.panes(in: bounds, .desk, crease: nil)
        XCTAssertEqual(desk.fixed, CGRect(x: 0, y: 0, width: 800, height: 800))
        XCTAssertEqual(desk.scrolling, CGRect(x: 800, y: 0, width: BoxArrangement.sideColumn, height: 800))
        // Narrower than the column itself: the column takes it all, the box pane nothing, never negative.
        let tiny = BoxPanes.panes(in: CGRect(x: 0, y: 0, width: 200, height: 300), .desk, crease: nil)
        XCTAssertEqual(tiny.fixed.width, 0)
        XCTAssertEqual(tiny.scrolling, CGRect(x: 0, y: 0, width: 200, height: 300))
    }

    // MARK: Where a drag sees the box (the scroll view's frame, the bar and the tray)

    /// An iPhone 17 Pro as measured: the screen's space starts below the bar (screen y 116), the scroll view's frame
    /// runs from there to the docked tray, and its content inset for the bar (116) is not part of that frame.
    private func phoneFrames(boxTop: CGFloat) -> BoxFrames {
        let frames = BoxFrames()
        frames.scroll = CGRect(x: 0, y: 0, width: 402, height: 545)
        frames.tray = CGRect(x: 0, y: 545, width: 402, height: 130)
        frames.stage = CGRect(x: 16, y: boxTop, width: 370, height: 586)
        return frames
    }

    func testTheTopOfThePageBelowTheBarIsOnTheBox() {
        // The review's drop: scrolled 250, a watch let go at y 34, inside back row space 1 (85 pt rows).
        let frames = phoneFrames(boxTop: -116)
        for y: CGFloat in [1, 34, 60, 115, 200, 469] {
            XCTAssertTrue(frames.showsBox(at: CGPoint(x: 271, y: y)), "y \(y) is on screen, below the bar")
        }
        XCTAssertFalse(frames.showsBox(at: CGPoint(x: 271, y: -1)), "under the bar")
        let lower = phoneFrames(boxTop: 0)
        XCTAssertTrue(lower.showsBox(at: CGPoint(x: 271, y: 544)))
        XCTAssertFalse(lower.showsBox(at: CGPoint(x: 271, y: 545)), "under the tray")
        // So the compartment under the finger there is found, not taken for "outside the box".
        let k = 370 / box.size(.endOn).width
        let local = CGPoint(x: (271 - frames.stage.minX) / k, y: (34 - frames.stage.minY) / k)
        XCTAssertNotNil(box.slotIndex(at: local, .endOn))
    }

    func testAutoScrollRunsInTheBandsAtTheBarAndTheTray() {
        let frames = phoneFrames(boxTop: 0)
        // Up: the top 60 pt of the page, and up to 40 pt above it (over the bar).
        for y: CGFloat in [-39, -1, 0, 30, 59] { XCTAssertEqual(frames.autoScrollStep(at: y), -8, "y \(y)") }
        // Down: the 60 pt above the tray; over the tray itself it is a drop to take the watch out, so no scrolling.
        for y: CGFloat in [486, 520, 544] { XCTAssertEqual(frames.autoScrollStep(at: y), 8, "y \(y)") }
        for y: CGFloat in [-41, 61, 300, 484, 545, 600] { XCTAssertEqual(frames.autoScrollStep(at: y), 0, "y \(y)") }
        // Where the review saw it run, 76 to 176 pt below the bar, the finger is over the page, not its edge.
        XCTAssertEqual(frames.autoScrollStep(at: 100), 0)
    }

    func testWithoutATrayTheBottomEdgeIsTheScrollViewsEnd() {
        // The inner screen with the crease across: one column, no tray; the scroll view's frame ends at the tab bar.
        let frames = BoxFrames()
        frames.scroll = CGRect(x: 0, y: 0, width: 669, height: 812)
        frames.stage = CGRect(x: 20, y: 150, width: 629, height: 397)
        XCTAssertEqual(frames.visibleBottom, 812)
        XCTAssertEqual(frames.autoScrollStep(at: 790), 8)
        XCTAssertEqual(frames.autoScrollStep(at: 700), 0)
        frames.stage.origin.y = 500
        XCTAssertTrue(frames.showsBox(at: CGPoint(x: 200, y: 800)))
        XCTAssertFalse(frames.showsBox(at: CGPoint(x: 200, y: 820)), "under the tab bar")
    }

    func testRevealScrollsJustEnoughToShowACompartment() {
        let frames = phoneFrames(boxTop: 0)
        // Already between the bar and the tray, with 12 pt to spare.
        XCTAssertEqual(frames.revealDelta(for: CGRect(x: 20, y: 12, width: 148, height: 85)), 0)
        XCTAssertEqual(frames.revealDelta(for: CGRect(x: 20, y: 448, width: 148, height: 85)), 0)
        // Under the tray: scroll down until its bottom is 12 pt above the tray.
        XCTAssertEqual(frames.revealDelta(for: CGRect(x: 20, y: 500, width: 148, height: 85)), 52)
        // Under the bar: scroll up until its top is 12 pt below the bar, not 12 pt below the bar's height again.
        XCTAssertEqual(frames.revealDelta(for: CGRect(x: 20, y: -50, width: 148, height: 85)), -62)
        XCTAssertEqual(frames.revealDelta(for: CGRect(x: 20, y: 40, width: 148, height: 85)), 0)
    }

    // MARK: What a shared picture says

    func testCountsAreWhatThePictureShows() {
        XCTAssertEqual(BoxShare.counts(watches: 11, capacity: 12), "11 watches, 1 space open")
        XCTAssertEqual(BoxShare.counts(watches: 0, capacity: 12), "12 spaces open")
        XCTAssertEqual(BoxShare.counts(watches: 1, capacity: 12), "1 watch, 11 spaces open")
        XCTAssertEqual(BoxShare.counts(watches: 12, capacity: 12), "Full")
        // A candidate in the open space fills the picture; one over an owned watch takes that watch's place.
        XCTAssertEqual(BoxShare.counts(watches: 11, onTrial: 1, capacity: 12), "11 watches, 1 on trial")
        XCTAssertEqual(BoxShare.counts(watches: 10, onTrial: 1, capacity: 12), "10 watches, 1 on trial, 1 space open")
        XCTAssertEqual(BoxShare.counts(watches: 0, onTrial: 2, capacity: 12), "2 on trial, 10 spaces open")
        XCTAssertEqual(BoxShare.counts(watches: 1, onTrial: 1, capacity: 3), "1 watch, 1 on trial, 1 space open")
    }

    func testTheTrialLineNamesWhatSteppedOut() {
        XCTAssertNil(BoxShare.trialLine(onTrial: [], steppingOut: ["G-Steel"]))
        XCTAssertEqual(BoxShare.trialLine(onTrial: ["Commander 1959"], steppingOut: []), "On trial: Commander 1959.")
        XCTAssertEqual(BoxShare.trialLine(onTrial: ["Commander 1959", "Ricochet"], steppingOut: ["G-Steel"]),
                       "On trial: Commander 1959 and Ricochet. G-Steel steps out to make room.")
        XCTAssertEqual(BoxShare.trialLine(onTrial: ["A"], steppingOut: ["B", "C"]), "On trial: A. B and C step out to make room.")
    }
}
