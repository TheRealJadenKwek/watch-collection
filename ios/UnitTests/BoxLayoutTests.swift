import SwiftUI
import XCTest
@testable import WatchCollection

/// Where the Boxes tab puts the box in each posture (brief section 9): which arrangement a window gets, the box's scale
/// in the space it is given (always front on), and the two panes either side of the crease or the Mac's side column.
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

    func testOnlyThePhoneDocksTheTray() {
        let all: [BoxArrangement] = [.phone, .column, .book, .table, .desk]
        XCTAssertEqual(all.filter(\.docksTray), [.phone])
        // Only where the box scrolls with the page does a drag near the edge scroll it.
        XCTAssertEqual(all.filter(\.stageScrolls), [.phone, .column])
        XCTAssertEqual(all.map(\.chipColumns), [1, 6, 4, 6, 2])
    }

    // MARK: The box in its space

    func testThePhoneAndTheCoverShowTheBoxFrontOnAcrossTheWidth() {
        // The phone's 370 pt column and the cover's 350: the box as wide as the column, about 234 pt tall at 370.
        for width: CGFloat in [370, 350] {
            let k = BoxArrangement.stage(box, .phone, space: CGSize(width: width, height: 0), mac: false)
            XCTAssertEqual(k, width / box.canvas.width, accuracy: 0.0001, "\(width)")
            XCTAssertEqual(k * box.canvas.width, width, accuracy: 0.001, "\(width)")
        }
        let phone = BoxArrangement.stage(box, .phone, space: CGSize(width: 370, height: 0), mac: false)
        XCTAssertEqual(phone * box.canvas.height, 234, accuracy: 1)
        // A compartment is still a finger's width: about 53 by 93 pt.
        XCTAssertEqual(phone * box.slot(0).width, 53.6, accuracy: 0.5)
        XCTAssertEqual(phone * box.slot(0).height, 93.3, accuracy: 0.5)
    }

    func testAColumnShowsTheBoxFrontOnAndTheMacCapsIt() {
        // The inner screen with the crease across: 669 less 20 a side.
        let inner = BoxArrangement.stage(box, .column, space: CGSize(width: 629, height: 0), mac: false)
        XCTAssertEqual(inner, 629 / 345, accuracy: 0.0001)
        XCTAssertEqual(inner * box.canvas.height, 397, accuracy: 1)
        // A narrow Mac window: as wide as the column, never wider than `widestBox`.
        let narrow = BoxArrangement.stage(box, .column, space: CGSize(width: 700, height: 0), mac: true)
        XCTAssertEqual(narrow * box.canvas.width, 700, accuracy: 0.001)
        let wide = BoxArrangement.stage(box, .column, space: CGSize(width: 1400, height: 0), mac: true)
        XCTAssertEqual(wide * box.canvas.width, BoxArrangement.widestBox, accuracy: 0.001)
    }

    func testAFixedPaneFitsTheBoxFrontOn() {
        // The left page of the book: taller than wide, so the box fills the page's width.
        let page = CGSize(width: 437.5, height: 535)
        let left = BoxArrangement.stage(box, .book, space: page, mac: false)
        assertFits(left, in: page)
        XCTAssertEqual(left * box.canvas.width, 437.5, accuracy: 0.001)
        // A page shorter than the box at that width: fitted to the height instead.
        let short = CGSize(width: 437.5, height: 200)
        let squat = BoxArrangement.stage(box, .book, space: short, mac: false)
        assertFits(squat, in: short)
        XCTAssertEqual(squat * box.canvas.height, 200, accuracy: 0.001)
        // Above the crease on the table top: wide and short, fitted to the height.
        let top = CGSize(width: 629, height: 330)
        let table = BoxArrangement.stage(box, .table, space: top, mac: false)
        assertFits(table, in: top)
        XCTAssertEqual(table * box.canvas.height, 330, accuracy: 0.001)
        // The Mac's desk: never wider than `widestBox` however big the window.
        let desk = BoxArrangement.stage(box, .desk, space: CGSize(width: 2000, height: 1500), mac: true)
        XCTAssertEqual(desk * box.canvas.width, BoxArrangement.widestBox, accuracy: 0.001)
        // Before the pane is measured there is no box to draw.
        for empty in [CGSize.zero, CGSize(width: 400, height: 0), CGSize(width: 0, height: 400)] {
            XCTAssertEqual(BoxArrangement.stage(box, .book, space: empty, mac: false), 0)
        }
    }

    func testEveryArrangementDrawsTheBoxFrontOnInEverySpace() {
        // There is no other view of the box: whatever the arrangement and the space, the drawing is the front
        // canvas (wider than tall, dials upright) at the scale the arrangement gives, and it fits the space it was
        // fitted to.
        XCTAssertGreaterThan(box.canvas.width, box.canvas.height)
        let spaces = [CGSize(width: 350, height: 0), CGSize(width: 370, height: 0), CGSize(width: 370, height: 640),
                      CGSize(width: 437.5, height: 535), CGSize(width: 629, height: 330), CGSize(width: 629, height: 900),
                      CGSize(width: 900, height: 600), CGSize(width: 2000, height: 1500)]
        for arrangement in [BoxArrangement.phone, .column, .book, .table, .desk] {
            for space in spaces {
                for mac in [false, true] {
                    let k = BoxArrangement.stage(box, arrangement, space: space, mac: mac)
                    let name = "\(arrangement) \(space) mac \(mac)"
                    switch arrangement {
                    case .phone:
                        XCTAssertEqual(k, space.width / box.canvas.width, accuracy: 0.0001, name)
                    case .column:
                        XCTAssertEqual(k, (mac ? min(space.width, BoxArrangement.widestBox) : space.width) / box.canvas.width,
                                       accuracy: 0.0001, name)
                    case .book, .table, .desk:
                        // A fixed pane is given a height; a column's (0) is no pane to fit.
                        guard space.height > 0 else { XCTAssertEqual(k, 0, name); continue }
                        XCTAssertGreaterThan(k, 0, name)
                        assertFits(k, in: space)
                    }
                }
            }
        }
    }

    private func assertFits(_ k: CGFloat, in space: CGSize, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertLessThanOrEqual(box.canvas.width * k, space.width + 0.001, file: file, line: line)
        XCTAssertLessThanOrEqual(box.canvas.height * k, space.height + 0.001, file: file, line: line)
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
    /// runs from there to the docked tray, and its content inset for the bar (116) is not part of that frame. The box
    /// is front on across the 370 pt column: 234 pt tall.
    private let phoneK: CGFloat = 370 / 345
    private func phoneFrames(boxTop: CGFloat) -> BoxFrames {
        let frames = BoxFrames()
        frames.scroll = CGRect(x: 0, y: 0, width: 402, height: 545)
        frames.tray = CGRect(x: 0, y: 545, width: 402, height: 130)
        frames.stage = CGRect(x: 16, y: boxTop, width: 370, height: box.canvas.height * phoneK)
        return frames
    }

    /// The compartment under a point in the screen's space, as `BoxesScreen.slot(at:)` finds it.
    private func slot(at point: CGPoint, _ frames: BoxFrames) -> Int? {
        guard frames.showsBox(at: point) else { return nil }
        return box.slotIndex(at: CGPoint(x: (point.x - frames.stage.minX) / phoneK, y: (point.y - frames.stage.minY) / phoneK))
    }

    func testTheTopOfThePageBelowTheBarIsOnTheBox() {
        // Scrolled so the top 116 pt of the box is under the bar: a watch let go at y 34 is in the front row.
        let frames = phoneFrames(boxTop: -116)
        for y: CGFloat in [1, 34, 60, 115] {
            XCTAssertTrue(frames.showsBox(at: CGPoint(x: 271, y: y)), "y \(y) is on screen, below the bar")
        }
        XCTAssertFalse(frames.showsBox(at: CGPoint(x: 271, y: -1)), "under the bar")
        XCTAssertFalse(frames.showsBox(at: CGPoint(x: 271, y: 200)), "below the box")
        let lower = phoneFrames(boxTop: 400)
        XCTAssertTrue(lower.showsBox(at: CGPoint(x: 271, y: 544)))
        XCTAssertFalse(lower.showsBox(at: CGPoint(x: 271, y: 545)), "under the tray")
        // So the compartment under the finger there is found, not taken for "outside the box".
        XCTAssertEqual(slot(at: CGPoint(x: 271, y: 34), frames), 10, "front row, space 5")
        XCTAssertNil(slot(at: CGPoint(x: 271, y: -1), frames), "the back row is under the bar")
        XCTAssertEqual(slot(at: CGPoint(x: 271, y: 530), lower), 10)
        XCTAssertNil(slot(at: CGPoint(x: 271, y: 560), lower), "the front row is under the tray")
    }

    func testADropLandsInTheCompartmentUnderTheFinger() {
        // The box front on at the top of the page: six across, two deep, slot 0 back left, slot 11 front right.
        let frames = phoneFrames(boxTop: 0)
        for index in 0..<box.slotCount {
            let rect = box.slot(index)
            let point = CGPoint(x: frames.stage.minX + rect.midX * phoneK, y: frames.stage.minY + rect.midY * phoneK)
            XCTAssertEqual(slot(at: point, frames), index, "the middle of space \(index)")
        }
        // Left to right along the back row, then the front row.
        let back = (0..<6).map { box.slot($0).midX }, front = (6..<12).map { box.slot($0).midX }
        XCTAssertEqual(back, back.sorted())
        XCTAssertEqual(back, front)
        XCTAssertLessThan(box.slot(0).midY, box.slot(6).midY)
        // The frame round the compartments, and the drawer pull below them, are no compartment.
        XCTAssertNil(slot(at: CGPoint(x: 16 + 5, y: 120), frames), "the left rail")
        XCTAssertNil(slot(at: CGPoint(x: 201, y: 228), frames), "the drawer pull")
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
