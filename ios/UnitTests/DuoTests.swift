import SwiftUI
import UIKit
import XCTest
@testable import WatchCollection

/// The folding iPhone's layout engine: which posture a window gets, how the hinge is read, which way the app may turn,
/// and how many columns each posture lays out.
@MainActor final class DuoTests: XCTestCase {
    // Measured on the simulator and on the real phone.
    private let cover = CGSize(width: 466, height: 678)
    private let coverInsets = EdgeInsets(top: 0, leading: 0, bottom: 34, trailing: 84)
    private let inner = CGSize(width: 669, height: 951)
    private let book = CGSize(width: 951, height: 669)
    private let innerInsets = EdgeInsets(top: 24, leading: 0, bottom: 34, trailing: 0)
    // iPhone 17 Pro and Pro Max.
    private let pro = CGSize(width: 402, height: 874)
    private let proMax = CGSize(width: 440, height: 956)

    private func layout(_ size: CGSize, _ insets: EdgeInsets, _ hinge: DuoLayout.Hinge = .unknown) -> DuoLayout {
        DuoLayout(size: size, insets: insets, hinge: hinge)
    }

    private func turned(_ size: CGSize) -> CGSize { CGSize(width: size.height, height: size.width) }

    private let hinges: [DuoLayout.Hinge] = [.unknown, .closed, .partiallyOpen, .fullyOpen]

    // MARK: Posture

    func testOrdinaryIPhonesAreAlwaysPhones() {
        let phones = [CGSize(width: 320, height: 568), CGSize(width: 375, height: 667), CGSize(width: 375, height: 812), CGSize(width: 390, height: 844),
                      CGSize(width: 393, height: 852), pro, CGSize(width: 414, height: 736), CGSize(width: 414, height: 896),
                      CGSize(width: 420, height: 912), CGSize(width: 428, height: 926), CGSize(width: 430, height: 932), proMax]
        for size in phones + phones.map(turned) {
            for hinge in hinges {
                XCTAssertEqual(DuoLayout.posture(size: size, hinge: hinge), .phone, "\(size) \(hinge)")
            }
        }
        XCTAssertEqual(DuoLayout.posture(size: .zero, hinge: .fullyOpen), .phone)
    }

    func testTheProAndProMaxArePhonesBothWaysRound() {
        for size in [pro, turned(pro), proMax, turned(proMax)] {
            let duo = layout(size, EdgeInsets(top: 62, leading: 0, bottom: 34, trailing: 0), .fullyOpen)
            XCTAssertEqual(duo.posture, .phone, "\(size)")
            XCTAssertFalse(duo.isWide)
            XCTAssertNil(duo.crease)
            XCTAssertEqual(duo.statusStrip, 0)
        }
    }

    func testCoverScreenIsFoldedWhateverTheHingeSays() {
        for hinge in hinges {
            XCTAssertEqual(DuoLayout.posture(size: cover, hinge: hinge), .folded)
        }
        // Beside another app on the open phone the window is the same shape as the cover.
        XCTAssertEqual(DuoLayout.posture(size: CGSize(width: 469, height: 669), hinge: .fullyOpen), .folded)
        XCTAssertEqual(DuoLayout.posture(size: CGSize(width: 469, height: 669), hinge: .partiallyOpen), .folded)
    }

    func testPostureBoundaries() {
        // The inner screen's shortest side: 600 is open, 599 is not.
        XCTAssertEqual(DuoLayout.posture(size: CGSize(width: 600, height: 900), hinge: .fullyOpen), .open)
        XCTAssertEqual(DuoLayout.posture(size: CGSize(width: 900, height: 600), hinge: .fullyOpen), .open)
        XCTAssertEqual(DuoLayout.posture(size: CGSize(width: 600, height: 900), hinge: .partiallyOpen), .half)
        XCTAssertEqual(DuoLayout.posture(size: CGSize(width: 599, height: 900), hinge: .fullyOpen), .folded)
        XCTAssertEqual(DuoLayout.posture(size: CGSize(width: 900, height: 599), hinge: .fullyOpen), .phone)
        // The cover's narrowest: 420 is folded, 419 is a phone.
        XCTAssertEqual(DuoLayout.posture(size: CGSize(width: 420, height: 600), hinge: .unknown), .folded)
        XCTAssertEqual(DuoLayout.posture(size: CGSize(width: 419, height: 600), hinge: .unknown), .phone)
        // Squat below 1.62 tall to wide; at 1.62 it is a phone.
        XCTAssertEqual(DuoLayout.posture(size: CGSize(width: 500, height: 809), hinge: .unknown), .folded)
        XCTAssertEqual(DuoLayout.posture(size: CGSize(width: 500, height: 810), hinge: .unknown), .phone)
        // Taller than wide: a square or wider window is never a cover.
        XCTAssertEqual(DuoLayout.posture(size: CGSize(width: 500, height: 501), hinge: .unknown), .folded)
        XCTAssertEqual(DuoLayout.posture(size: CGSize(width: 500, height: 500), hinge: .unknown), .phone)
        XCTAssertEqual(DuoLayout.posture(size: turned(cover), hinge: .unknown), .phone)
    }

    func testInnerScreenIsOpenUnlessTheHingeIsPartOpen() {
        for size in [inner, book] {
            XCTAssertEqual(DuoLayout.posture(size: size, hinge: .fullyOpen), .open)
            XCTAssertEqual(DuoLayout.posture(size: size, hinge: .unknown), .open)
            XCTAssertEqual(DuoLayout.posture(size: size, hinge: .closed), .open)
            XCTAssertEqual(DuoLayout.posture(size: size, hinge: .partiallyOpen), .half)
        }
    }

    func testFoldRunsAcrossATallWindowAndDownAWideOne() {
        XCTAssertEqual(layout(inner, innerInsets, .partiallyOpen).fold, .across)
        XCTAssertEqual(layout(book, innerInsets, .partiallyOpen).fold, .down)
        XCTAssertNil(layout(inner, innerInsets, .fullyOpen).fold)
        XCTAssertNil(layout(cover, coverInsets, .partiallyOpen).fold)
    }

    func testBookAcrossAndTableTop() {
        // Held like a book, open or half open: two pages either side of an upright crease.
        for hinge in [DuoLayout.Hinge.fullyOpen, .partiallyOpen] {
            let duo = layout(book, innerInsets, hinge)
            XCTAssertTrue(duo.isBook)
            XCTAssertFalse(duo.isAcross)
            XCTAssertFalse(duo.isTableTop)
            XCTAssertEqual(duo.crease, 475.5)
        }
        // The crease across: open is one tall page, half open is the table top.
        let open = layout(inner, innerInsets, .fullyOpen)
        XCTAssertTrue(open.isAcross)
        XCTAssertFalse(open.isBook)
        XCTAssertFalse(open.isTableTop)
        XCTAssertEqual(open.crease, 475.5)
        let table = layout(inner, innerInsets, .partiallyOpen)
        XCTAssertTrue(table.isAcross)
        XCTAssertTrue(table.isTableTop)
        // The cover and phones have no crease.
        for duo in [layout(cover, coverInsets, .partiallyOpen), layout(pro, EdgeInsets()), DuoLayout.phone] {
            XCTAssertFalse(duo.isBook)
            XCTAssertFalse(duo.isAcross)
            XCTAssertFalse(duo.isTableTop)
            XCTAssertNil(duo.crease)
        }
    }

    func testOnlyACoverScreenHasAStatusStrip() {
        let folded = layout(cover, coverInsets)
        XCTAssertEqual(folded.statusStrip, 84)
        XCTAssertEqual(folded.statusCorner, CGSize(width: 84, height: DuoLayout.statusDepth))
        // The same shape of window with no clock down its side keeps nothing clear.
        let beside = layout(CGSize(width: 469, height: 669), innerInsets, .fullyOpen)
        XCTAssertEqual(beside.posture, .folded)
        XCTAssertEqual(beside.statusStrip, 0)
        XCTAssertEqual(beside.statusCorner, .zero)
        XCTAssertEqual(layout(inner, innerInsets, .fullyOpen).statusStrip, 0)
        XCTAssertEqual(DuoLayout.phone.statusStrip, 0)
    }

    // MARK: Columns and margins

    func testColumnsPerPosture() {
        let phone = DuoLayout(posture: .phone, size: pro, insets: EdgeInsets())
        // Cards, then Photos, for each posture.
        XCTAssertEqual(phone.tileColumns, 2)
        XCTAssertEqual(phone.photoColumns, 3)
        XCTAssertEqual(DuoLayout.phone.tileColumns, 2)
        XCTAssertEqual(DuoLayout.phone.photoColumns, 3)
        XCTAssertEqual(layout(cover, coverInsets).tileColumns, 2)
        XCTAssertEqual(layout(cover, coverInsets).photoColumns, 4)
        for hinge in [DuoLayout.Hinge.fullyOpen, .partiallyOpen] {
            // A book's grid fills its right page.
            XCTAssertEqual(layout(book, innerInsets, hinge).tileColumns, 2)
            XCTAssertEqual(layout(book, innerInsets, hinge).photoColumns, 3)
            // The crease across, open or on a table.
            XCTAssertEqual(layout(inner, innerInsets, hinge).tileColumns, 3)
            XCTAssertEqual(layout(inner, innerInsets, hinge).photoColumns, 5)
        }
        // Cards in columns: one on a phone and the cover, two on the inner screen.
        XCTAssertEqual(phone.cardColumns, 1)
        XCTAssertEqual(layout(cover, coverInsets).cardColumns, 1)
        XCTAssertEqual(layout(inner, innerInsets, .fullyOpen).cardColumns, 2)
        XCTAssertEqual(layout(book, innerInsets, .partiallyOpen).cardColumns, 2)
    }

    func testPageMarginIsThePhonesOwnOnAPhone() {
        XCTAssertEqual(DuoLayout.phone.pageMargin(phone: 20), 20)
        XCTAssertEqual(DuoLayout.phone.pageMargin(phone: 16), 16)
        XCTAssertEqual(layout(cover, coverInsets).pageMargin(phone: 20), 16)
        XCTAssertEqual(layout(inner, innerInsets, .fullyOpen).pageMargin(phone: 20), 22)
        XCTAssertEqual(layout(book, innerInsets, .partiallyOpen).pageMargin(phone: 20), 22)
    }

    func testTheCreaseGapKeepsBothPagesClear() {
        XCTAssertEqual(DuoLayout.creaseGap(inset: 0), 28)
        XCTAssertEqual(DuoLayout.creaseGap(inset: 16), 60)
        // Two equal columns with that gap and the same outer inset end and start clear of the crease.
        let inset: CGFloat = 16, gap = DuoLayout.creaseGap(inset: inset)
        let column = (book.width - 2 * inset - gap) / 2
        XCTAssertEqual(inset + column, book.width / 2 - DuoLayout.creaseClearance - inset)
        XCTAssertEqual(inset + column + gap, book.width / 2 + DuoLayout.creaseClearance + inset)
    }

    func testBalanceFillsTheShortestColumn() {
        XCTAssertEqual(DuoLayout.balance([3, 1, 1, 1, 1], columns: 2), [0, 1, 1, 1, 0])
        XCTAssertEqual(DuoLayout.balance([1, 1, 1, 1], columns: 2), [0, 1, 0, 1])
        XCTAssertEqual(DuoLayout.balance([1, 1, 1], columns: 1), [0, 0, 0])
        XCTAssertEqual(DuoLayout.balance([1, 1], columns: 0), [0, 0])
        XCTAssertEqual(DuoLayout.balance([], columns: 2), [])
    }

    // MARK: Panes either side of the crease

    func testPanesStopShortOfTheCrease() {
        let bounds = CGRect(x: 0, y: 0, width: 951, height: 560)
        let side = CreaseSplit.panes(in: bounds, axis: .horizontal, crease: nil)
        XCTAssertEqual(side.first, CGRect(x: 0, y: 0, width: 461.5, height: 560))
        XCTAssertEqual(side.second, CGRect(x: 489.5, y: 0, width: 461.5, height: 560))
        // The crease where the window's is: a table-top page that starts under a 68 pt bar.
        let page = CGRect(x: 0, y: 0, width: 669, height: 951 - 68 - 34)
        let table = CreaseSplit.panes(in: page, axis: .vertical, crease: 951 / 2 - 68)
        XCTAssertEqual(table.first.maxY, 951 / 2 - 68 - DuoLayout.creaseClearance)
        XCTAssertEqual(table.second.minY, 951 / 2 - 68 + DuoLayout.creaseClearance)
        XCTAssertEqual(table.second.maxY, page.maxY)
        XCTAssertEqual(table.first.width, 669)
        // Offset bounds keep their origin.
        let offset = CreaseSplit.panes(in: CGRect(x: 10, y: 20, width: 100, height: 50), axis: .horizontal, crease: 40)
        XCTAssertEqual(offset.first, CGRect(x: 10, y: 20, width: 26, height: 50))
        XCTAssertEqual(offset.second, CGRect(x: 64, y: 20, width: 46, height: 50))
        // A crease beyond the bounds leaves the pane past it empty, never negative.
        let beyond = CreaseSplit.panes(in: CGRect(x: 0, y: 0, width: 100, height: 50), axis: .vertical, crease: 400)
        XCTAssertEqual(beyond.first.height, 50)
        XCTAssertEqual(beyond.second.height, 0)
    }

    // MARK: The keyboard

    func testAKeyboardIsNotMistakenForTheHomeIndicator() {
        let monitor = DuoMonitor()
        XCTAssertEqual(monitor.layout(size: cover, insets: coverInsets).insets.bottom, 34)
        var typing = coverInsets
        typing.bottom = 320
        XCTAssertEqual(monitor.layout(size: cover, insets: typing).insets.bottom, 34)
        // A keyboard dragged away passes through every height on its way down: none of them is the home indicator.
        for bottom in [CGFloat(41), 60, 80, 119, 120, 121] {
            typing.bottom = bottom
            XCTAssertEqual(monitor.layout(size: cover, insets: typing).insets.bottom, 34, "\(bottom)")
        }
        XCTAssertEqual(monitor.layout(size: cover, insets: coverInsets).insets.bottom, 34)
        // A phone with no home indicator keeps none.
        var flat = coverInsets
        flat.bottom = 0
        XCTAssertEqual(monitor.layout(size: cover, insets: flat).insets.bottom, 0)
        typing.bottom = 300
        XCTAssertEqual(monitor.layout(size: cover, insets: typing).insets.bottom, 0)
        // At the line itself it is taken as the home indicator.
        flat.bottom = DuoLayout.tallestHomeInset
        XCTAssertEqual(monitor.layout(size: cover, insets: flat).insets.bottom, DuoLayout.tallestHomeInset)
    }

    // MARK: The hinge

    func testHalfOpenWaitsThenShows() {
        var gate = HingeGate(shown: .fullyOpen)
        XCTAssertEqual(gate.update(.partiallyOpen), .startWait)
        XCTAssertEqual(gate.shown, .fullyOpen, "nothing changes until the wait ends")
        XCTAssertEqual(gate.waitEnded(), .show)
        XCTAssertEqual(gate.shown, .partiallyOpen)
        XCTAssertNil(gate.waiting)
        // A wait that was already stopped shows nothing when its timer fires late.
        XCTAssertEqual(gate.waitEnded(), .none)
        XCTAssertEqual(HingeGate.wait, .milliseconds(450))
    }

    func testTheHingeReportingAgainDoesNotRestartTheWait() {
        var gate = HingeGate(shown: .fullyOpen)
        XCTAssertEqual(gate.update(.partiallyOpen), .startWait)
        for _ in 0..<5 { XCTAssertEqual(gate.update(.partiallyOpen), .none) }
        XCTAssertEqual(gate.waiting, .partiallyOpen)
        XCTAssertEqual(gate.waitEnded(), .show)
        // Half open already, more reports change nothing.
        XCTAssertEqual(gate.update(.partiallyOpen), .none)
        XCTAssertEqual(gate.shown, .partiallyOpen)
    }

    func testClosingWhileWaitingCancelsTheWait() {
        var gate = HingeGate(shown: .fullyOpen)
        XCTAssertEqual(gate.update(.partiallyOpen), .startWait)
        XCTAssertEqual(gate.update(.closed), .show)
        XCTAssertEqual(gate.shown, .closed)
        XCTAssertNil(gate.waiting)
        XCTAssertEqual(gate.waitEnded(), .none, "the half-open layout never comes")
        // Opening and laying it flat again before the wait ends: the wait stops and nothing changes.
        var flat = HingeGate(shown: .fullyOpen)
        XCTAssertEqual(flat.update(.partiallyOpen), .startWait)
        XCTAssertEqual(flat.update(.fullyOpen), .cancelWait)
        XCTAssertEqual(flat.shown, .fullyOpen)
        XCTAssertEqual(flat.waitEnded(), .none)
    }

    func testLeavingHalfOpenIsImmediate() {
        var gate = HingeGate(shown: .partiallyOpen)
        XCTAssertEqual(gate.update(.fullyOpen), .show)
        XCTAssertEqual(gate.shown, .fullyOpen)
        var shut = HingeGate(shown: .partiallyOpen)
        XCTAssertEqual(shut.update(.closed), .show)
        XCTAssertEqual(shut.shown, .closed)
        // Every other change is immediate too.
        var other = HingeGate()
        XCTAssertEqual(other.update(.fullyOpen), .show)
        XCTAssertEqual(other.update(.fullyOpen), .none)
    }

    // MARK: Turning

    func testOnlyTheInnerScreenTurns() {
        XCTAssertEqual(WatchAppDelegate.orientations(window: CGSize(width: 393, height: 852), screen: CGSize(width: 393, height: 852)), .portrait)
        XCTAssertEqual(WatchAppDelegate.orientations(window: cover, screen: cover), .portrait)
        XCTAssertEqual(WatchAppDelegate.orientations(window: .zero, screen: .zero), .portrait)
        // An ordinary iPhone is portrait only, whichever way its window is measured: the Pro and Pro Max included.
        for size in [CGSize(width: 375, height: 667), CGSize(width: 667, height: 375), pro, turned(pro), proMax, turned(proMax),
                     CGSize(width: 932, height: 430)] {
            XCTAssertEqual(WatchAppDelegate.orientations(window: size, screen: size), .portrait, "\(size)")
        }
        XCTAssertEqual(WatchAppDelegate.orientations(window: inner, screen: inner), .allButUpsideDown)
        XCTAssertEqual(WatchAppDelegate.orientations(window: book, screen: book), .allButUpsideDown)
        // Beside another app the window is narrow but the screen is the inner one.
        XCTAssertEqual(WatchAppDelegate.orientations(window: CGSize(width: 469, height: 669), screen: book), .allButUpsideDown)
    }

    func testInnerScreenIsAQuarterTurnFromThePhone() {
        XCTAssertEqual(DuoMonitor.orientation(device: .portrait, halfOpen: false, windowIsTall: true), .landscapeLeft)
        XCTAssertEqual(DuoMonitor.orientation(device: .landscapeLeft, halfOpen: false, windowIsTall: false), .portrait)
        XCTAssertEqual(DuoMonitor.orientation(device: .portraitUpsideDown, halfOpen: false, windowIsTall: true), .landscapeRight)
        // The one hold iOS will not turn to on an iPhone is left as it is.
        XCTAssertNil(DuoMonitor.orientation(device: .landscapeRight, halfOpen: false, windowIsTall: true))
        XCTAssertNil(DuoMonitor.orientation(device: .landscapeRight, halfOpen: true, windowIsTall: false))
        // Flat on a table it stays as it is, unless it is half open with the crease the wrong way.
        XCTAssertNil(DuoMonitor.orientation(device: .faceUp, halfOpen: false, windowIsTall: false))
        XCTAssertNil(DuoMonitor.orientation(device: .faceUp, halfOpen: true, windowIsTall: true))
        XCTAssertEqual(DuoMonitor.orientation(device: .faceUp, halfOpen: true, windowIsTall: false), .portrait)
        XCTAssertEqual(DuoMonitor.orientation(device: .unknown, halfOpen: true, windowIsTall: false), .portrait)
    }
}
