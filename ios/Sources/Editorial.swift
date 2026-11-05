import SwiftUI

/// Navigation value for opening a watch's dossier.
struct WatchRoute: Hashable {
    let id: String
}

/// Photo shapes shared by the views and the framing editor so a framed cover
/// looks the same everywhere it appears.
enum PhotoShape {
    static let plate: CGFloat = 0.8
    static let dossier: CGFloat = 0.78
    static let square: CGFloat = 1
}

// MARK: - Collection helpers

/// Catalogue number for every watch ever acquired, oldest first ("Nº 07").
func catalogueNumbers(_ watches: [Watch]) -> [String: Int] {
    Dictionary(uniqueKeysWithValues: acquisitionOrder(watches).enumerated().map { ($0.element.id, $0.offset + 1) })
}

/// Day of the month from a label like "September 20, 2026"; 0 when the label has no day.
func purchaseDay(_ text: String) -> Int {
    // Hand-rolled match for `\b(\d{1,2}),\s*\d{4}`: this runs for every watch on every sort, and
    // a Swift Regex here showed up in profiles as most of the cost of drawing the collection.
    let bytes = Array(text.utf8)
    func isDigit(_ byte: UInt8) -> Bool { (48...57).contains(byte) }
    func isWord(_ byte: UInt8) -> Bool {
        isDigit(byte) || (65...90).contains(byte) || (97...122).contains(byte) || byte == 95 || byte >= 128
    }
    for comma in bytes.indices where bytes[comma] == 44 {
        var start = comma
        while start > 0, comma - start < 2, isDigit(bytes[start - 1]) { start -= 1 }
        guard start < comma, start == 0 || !isWord(bytes[start - 1]) else { continue }
        var next = comma + 1
        while next < bytes.count, [32, 9, 10, 13].contains(bytes[next]) { next += 1 }
        guard next + 4 <= bytes.count, bytes[next..<(next + 4)].allSatisfy(isDigit) else { continue }
        return bytes[start..<comma].reduce(0) { $0 * 10 + Int($1 - 48) }
    }
    return 0
}

/// Formatted dates, kept because formatting one per photo on every redraw adds up while scrolling.
@MainActor private var purchaseLabelCache: [String: String] = [:]

/// Short purchase date for photo overlays: "Sep 20, 2026" when the day is known, else "Nov 2025".
/// A trade with no date of its own shows when the watch it came from was bought
/// (Series 6 traded for the Series 8 shows the Series 8's Feb 2023). Nil when neither has a date.
@MainActor
func purchaseShortLabel(_ watch: Watch, in watches: [Watch]) -> String? {
    let dated = datedSource(watch, in: watches)
    guard let parts = purchaseMonthParts(dated.purchased) else { return nil }
    let cacheKey = "\(dated.purchased ?? "")|\(dated.purchasedText)"
    if let cached = purchaseLabelCache[cacheKey] { return cached }
    let day = purchaseDay(dated.purchasedText)
    guard let date = Calendar.current.date(from: DateComponents(year: parts.year, month: parts.month, day: max(day, 1)))
    else { return nil }
    let label = day > 0
        ? date.formatted(.dateTime.month(.abbreviated).day().year())
        : date.formatted(.dateTime.month(.abbreviated).year())
    purchaseLabelCache[cacheKey] = label
    return label
}

/// The watch whose purchase date stands for this one: itself, or for a trade with no date
/// of its own, the watch it was traded from.
func datedSource(_ watch: Watch, in watches: [Watch]) -> Watch {
    guard watch.purchased == nil else { return watch }
    return watches.first { $0.id == watch.costSourceWatchID } ?? watch
}

/// Purchase date laid over the bottom-left of a photo, like the duration on a Photos thumbnail.
struct PurchaseDateOverlay: View {
    let watch: Watch
    let watches: [Watch]

    var body: some View {
        if let label = purchaseShortLabel(watch, in: watches) {
            Text(label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.6), radius: 3)
                .padding(8)
        }
    }
}

/// Oldest first by purchase month, then day when known (month-only sorts first in its month),
/// then the order the watches were added. Undated watches (e.g. trades with no date) go last.
func acquisitionOrder(_ watches: [Watch]) -> [Watch] {
    watches.enumerated()
        .map { (month: $0.element.purchased ?? "9999-99", day: purchaseDay($0.element.purchasedText), index: $0.offset, watch: $0.element) }
        .sorted { ($0.month, $0.day, $0.index) < ($1.month, $1.day, $1.index) }
        .map(\.watch)
}

func catalogueLabel(_ number: Int?) -> String {
    guard let number else { return "Nº —" }
    return String(format: "Nº %02d", number)
}

// MARK: - Views

/// Full-bleed framed photo at a fixed aspect ratio.
struct FramedPhoto: View {
    let store: AppStore
    let itemID: String
    let filename: String?
    let focus: PhotoFocus?
    var wishlist = false
    var aspect: CGFloat = PhotoShape.plate
    var maxPixel = DisplayImageCache.tile

    var body: some View {
        Color.clear
            .aspectRatio(aspect, contentMode: .fit)
            .overlay {
                RemoteWatchImage(
                    asset: filename.flatMap { store.photoAsset(itemID: itemID, filename: $0, wishlist: wishlist) },
                    allowsRemoteFetch: !store.isOffline,
                    focus: focus,
                    maxPixel: maxPixel
                )
            }
            .clipped()
            .contentShape(Rectangle())
    }
}

/// Small Liquid Glass label laid over photos.
struct PhotoTag: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .foregroundStyle(.white)
            // A plain fill: live glass on every card in a scrolling grid is expensive to composite.
            .background(.black.opacity(0.45), in: Capsule())
    }
}
