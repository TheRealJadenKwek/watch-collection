import SwiftUI

extension WishlistItem {
    /// The expected price in whole Canadian dollars, as every card shows it. Nil when there is none: unset, zero,
    /// negative or not a number.
    var wholePrice: Int? {
        guard let price = priceExpected, price.isFinite, price > 0, price < 1e12 else { return nil }
        return max(1, Int(price.rounded()))
    }

    /// The line under the price: where the number came from. Nil when there is none, or when it only repeats the
    /// figure above it ("$2,400", "~C$2,400").
    var priceSource: String? {
        let note = priceNote.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !note.isEmpty else { return nil }
        if let price = wholePrice, !note.contains(where: { $0.isLetter && $0 != "C" && $0 != "c" }) {
            // Cents, if any, are not part of the figure.
            let dollars = note.split(separator: ".").first.map(String.init) ?? note
            if dollars.filter(\.isNumber) == String(price) { return nil }
        }
        return note
    }

    /// One line for a search result: the price, or the note when there is no price.
    var searchPriceLine: String {
        wholePrice.map { cadWhole(Double($0)) } ?? priceSource ?? "No price yet"
    }
}

/// What the wishlist would cost: the candidates still being considered, each at the whole-dollar price its card
/// shows, so the total is exactly the sum of the numbers on the page. Passed and bought candidates are left out:
/// a passed watch is not wanted, and a bought one is already counted in the collection.
struct WishlistTotal: Equatable {
    /// Whole Canadian dollars.
    var value: Int
    /// Candidates with a price.
    var priced: Int
    /// Candidates without one.
    var unpriced: Int

    var count: Int { priced + unpriced }

    init(_ items: [WishlistItem]) {
        let considering = items.filter { $0.status == "considering" }
        let prices = considering.compactMap(\.wholePrice)
        value = prices.reduce(0, +)
        priced = prices.count
        unpriced = considering.count - prices.count
    }

    /// "$93,589", or a dash while nothing has a price.
    var figure: String { priced == 0 ? "–" : cadWhole(Double(value)) }

    /// "across 20 watches"; with gaps, "across 17 of 20 watches. 3 have no price yet."
    var detail: String {
        func watches(_ count: Int) -> String { "\(count) watch\(count == 1 ? "" : "es")" }
        if priced == 0 { return "No price yet on \(unpriced == 1 ? "the watch" : "any of the \(watches(unpriced))")." }
        if unpriced == 0 { return "across \(watches(count))" }
        return "across \(priced) of \(watches(count)). \(unpriced) \(unpriced == 1 ? "has" : "have") no price yet."
    }
}

/// The wishlist's total, the first thing on the Wishlist screen: a kicker, the figure, and how many watches it
/// covers. Set like the hero figure on Insights.
struct WishlistTotalPanel: View {
    let total: WishlistTotal

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Eyebrow("Wishlist value")
            Text(total.figure)
                .font(.figure(.largeTitle))
                .foregroundStyle(WatchTheme.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .contentTransition(.numericText(value: Double(total.value)))
                .padding(.top, 6)
            Text(total.detail)
                .font(AtelierType.detail)
                .foregroundStyle(WatchTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .groupedCard()
        .animation(.easeInOut(duration: 0.35), value: total)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Wishlist value \(total.priced == 0 ? "not known" : total.figure), \(total.detail)")
    }
}

/// A candidate's price as a figure, with where it came from small underneath.
struct WishlistPrice: View {
    let item: WishlistItem
    var style: Font.TextStyle = .title2
    var sourceLines = 2

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let price = item.wholePrice {
                Text(cadWhole(Double(price)))
                    .font(.figure(style))
                    .foregroundStyle(WatchTheme.ink)
                    .lineLimit(1)
                    // The whole number always shows, however narrow the column or large the text. It only ever
                    // shrinks for width: without its full height pinned, a stack that is short of room takes the
                    // room from this line first and the figure comes out small.
                    .minimumScaleFactor(0.5)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("No price yet")
                    .font(AtelierType.detail)
                    .foregroundStyle(WatchTheme.muted)
            }
            if let source = item.priceSource {
                Text(source)
                    .font(AtelierType.caption)
                    .foregroundStyle(WatchTheme.muted)
                    .lineLimit(sourceLines)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
