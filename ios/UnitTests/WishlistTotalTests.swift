import XCTest
@testable import WatchCollection

/// The wishlist's total and each candidate's price as its card shows it.
final class WishlistTotalTests: XCTestCase {
    private func candidate(_ id: String, price: Double?, status: String = "considering", note: String = "") -> WishlistItem {
        var item = BoxFixture.candidate(id, status: status)
        item.priceExpected = price
        item.priceNote = note
        return item
    }

    func testSumsThePricesOfTheCandidatesBeingConsidered() {
        let total = WishlistTotal([candidate("a", price: 5300), candidate("b", price: 2400), candidate("c", price: 1100)])
        XCTAssertEqual(total.value, 8800)
        XCTAssertEqual(total.priced, 3)
        XCTAssertEqual(total.unpriced, 0)
        XCTAssertEqual(total.count, 3)
        XCTAssertEqual(total.figure, cadWhole(8800))
        XCTAssertEqual(total.detail, "across 3 watches")
    }

    func testCandidatesWithoutAPriceAreCountedNotSummed() {
        let total = WishlistTotal([
            candidate("a", price: 5300), candidate("b", price: nil), candidate("c", price: 0),
            candidate("d", price: -40), candidate("e", price: .nan), candidate("f", price: .infinity),
        ])
        XCTAssertEqual(total.value, 5300)
        XCTAssertEqual(total.priced, 1)
        XCTAssertEqual(total.unpriced, 5)
        XCTAssertEqual(total.detail, "across 1 of 6 watches. 5 have no price yet.")
        let one = WishlistTotal([candidate("a", price: 5300), candidate("b", price: 700), candidate("c", price: nil)])
        XCTAssertEqual(one.detail, "across 2 of 3 watches. 1 has no price yet.")
    }

    func testAnEmptyWishlistIsZeroWithNothingToShow() {
        let total = WishlistTotal([])
        XCTAssertEqual(total.value, 0)
        XCTAssertEqual(total.count, 0)
        XCTAssertEqual(total.figure, "–")
    }

    func testNothingPricedShowsADashNotZeroDollars() {
        let several = WishlistTotal([candidate("a", price: nil), candidate("b", price: nil)])
        XCTAssertEqual(several.value, 0)
        XCTAssertEqual(several.figure, "–")
        XCTAssertEqual(several.detail, "No price yet on any of the 2 watches.")
        XCTAssertEqual(WishlistTotal([candidate("a", price: nil)]).detail, "No price yet on the watch.")
    }

    func testPassedAndBoughtCandidatesAreLeftOut() {
        let total = WishlistTotal([
            candidate("a", price: 1000), candidate("b", price: 9000, status: "passed"),
            candidate("c", price: 400, status: "bought"), candidate("d", price: nil, status: "passed"),
        ])
        XCTAssertEqual(total.value, 1000)
        XCTAssertEqual(total.count, 1)
        XCTAssertEqual(total.detail, "across 1 watch")
    }

    /// The total is the sum of the whole-dollar figures on the cards, so the page always adds up.
    func testTheTotalIsTheSumOfTheFiguresTheCardsShow() {
        let items = [candidate("a", price: 126.98), candidate("b", price: 197.97), candidate("c", price: 109.2), candidate("d", price: 125.62)]
        XCTAssertEqual(items.map(\.wholePrice), [127, 198, 109, 126])
        XCTAssertEqual(WishlistTotal(items).value, 127 + 198 + 109 + 126)
        // The raw prices sum to 559.77, which would round to 560 only by luck; halves show the difference.
        let halves = [candidate("a", price: 10.5), candidate("b", price: 10.5), candidate("c", price: 10.5)]
        XCTAssertEqual(WishlistTotal(halves).value, 33)
        XCTAssertEqual(candidate("x", price: 0.2).wholePrice, 1, "a price under a dollar is still a price")
    }

    func testTheSourceLineIsDroppedWhenItOnlyRepeatsTheFigure() {
        XCTAssertNil(candidate("a", price: 2400, note: "$2,400").priceSource)
        XCTAssertNil(candidate("a", price: 5300, note: " ~$5,300 ").priceSource)
        XCTAssertNil(candidate("a", price: 2400, note: "~C$2,400.00").priceSource)
        XCTAssertNil(candidate("a", price: 2400, note: "").priceSource)
        XCTAssertEqual(candidate("a", price: 2900, note: "$2,900 if findable").priceSource, "$2,900 if findable")
        XCTAssertEqual(candidate("a", price: 545, note: "£295 (~C$545)").priceSource, "£295 (~C$545)")
        XCTAssertEqual(candidate("a", price: 17900, note: "Chrono24 C$17,900-19,500, 12 listings, Nov 2026").priceSource,
                       "Chrono24 C$17,900-19,500, 12 listings, Nov 2026")
        XCTAssertEqual(candidate("a", price: nil, note: "$2,400").priceSource, "$2,400", "with no figure above it, the note stays")
    }

    func testASearchRowShowsThePriceThenTheNoteThenNothingKnown() {
        XCTAssertEqual(candidate("a", price: 2400, note: "Chrono24, Nov 2026").searchPriceLine, cadWhole(2400))
        XCTAssertEqual(candidate("a", price: nil, note: "US$315 retail").searchPriceLine, "US$315 retail")
        XCTAssertEqual(candidate("a", price: nil).searchPriceLine, "No price yet")
    }
}
