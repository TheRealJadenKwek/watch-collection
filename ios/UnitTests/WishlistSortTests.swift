import XCTest
@testable import WatchCollection

/// The wishlist sorted by price from the sort menu.
final class WishlistSortTests: XCTestCase {
    private func candidate(_ id: String, price: Double?, status: String = "considering") -> WishlistItem {
        var item = BoxFixture.candidate(id, status: status)
        item.priceExpected = price
        return item
    }

    private func ids(_ items: [WishlistItem]) -> [String] { items.map(\.id) }

    func testLowestAndHighestPriceFirst() {
        let items = [candidate("mid", price: 15_200), candidate("low", price: 2_200), candidate("high", price: 292_486)]
        XCTAssertEqual(ids(WishlistScreen.byPrice(items, highestFirst: false)), ["low", "mid", "high"])
        XCTAssertEqual(ids(WishlistScreen.byPrice(items, highestFirst: true)), ["high", "mid", "low"])
    }

    func testCandidatesWithoutAPriceGoLastEitherWay() {
        let items = [candidate("none", price: nil), candidate("a", price: 900), candidate("zero", price: 0), candidate("b", price: 400)]
        XCTAssertEqual(ids(WishlistScreen.byPrice(items, highestFirst: false)), ["b", "a", "none", "zero"])
        XCTAssertEqual(ids(WishlistScreen.byPrice(items, highestFirst: true)), ["a", "b", "none", "zero"])
    }

    func testPassedAndBoughtStayBelowTheCandidatesBeingConsidered() {
        let items = [
            candidate("bought", price: 1, status: "bought"), candidate("passed", price: 500_000, status: "passed"),
            candidate("cheap", price: 100), candidate("dear", price: 9_000),
        ]
        XCTAssertEqual(ids(WishlistScreen.byPrice(items, highestFirst: true)), ["dear", "cheap", "passed", "bought"])
        XCTAssertEqual(ids(WishlistScreen.byPrice(items, highestFirst: false)), ["cheap", "dear", "passed", "bought"])
    }

    func testEqualPricesKeepTheirBestFitOrder() {
        // The price each card shows is whole dollars, so 2,400.20 and 2,399.80 tie.
        let items = [candidate("first", price: 2_400.2), candidate("second", price: 2_399.8), candidate("third", price: 2_400)]
        XCTAssertEqual(ids(WishlistScreen.byPrice(items, highestFirst: false)), ["first", "second", "third"])
        XCTAssertEqual(ids(WishlistScreen.byPrice(items, highestFirst: true)), ["first", "second", "third"])
    }
}
