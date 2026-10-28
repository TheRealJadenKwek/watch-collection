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
    guard let match = text.firstMatch(of: /\b(\d{1,2}),\s*\d{4}/), let day = Int(match.1) else { return 0 }
    return day
}

/// Short purchase date for photo overlays: "Sep 20, 2026" when the day is known, else "Nov 2025".
/// Nil for watches with no purchase month (e.g. undated trades).
func purchaseShortLabel(_ watch: Watch) -> String? {
    guard let parts = purchaseMonthParts(watch.purchased) else { return nil }
    let day = purchaseDay(watch.purchasedText)
    guard let date = Calendar.current.date(from: DateComponents(year: parts.year, month: parts.month, day: max(day, 1)))
    else { return nil }
    return day > 0
        ? date.formatted(.dateTime.month(.abbreviated).day().year())
        : date.formatted(.dateTime.month(.abbreviated).year())
}

/// Purchase date laid over the bottom-left of a photo, like the duration on a Photos thumbnail.
struct PurchaseDateOverlay: View {
    let watch: Watch

    var body: some View {
        if let label = purchaseShortLabel(watch) {
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
    watches.enumerated().sorted { left, right in
        let l = (left.element.purchased ?? "9999-99", purchaseDay(left.element.purchasedText), left.offset)
        let r = (right.element.purchased ?? "9999-99", purchaseDay(right.element.purchasedText), right.offset)
        return l < r
    }.map(\.element)
}

func catalogueLabel(_ number: Int?) -> String {
    guard let number else { return "Nº —" }
    return String(format: "Nº %02d", number)
}

// MARK: - Views

/// Full-bleed framed photo at a fixed aspect ratio.
struct FramedPhoto: View {
    @ObservedObject var store: AppStore
    let itemID: String
    let filename: String?
    let focus: PhotoFocus?
    var wishlist = false
    var aspect: CGFloat = PhotoShape.plate

    var body: some View {
        Color.clear
            .aspectRatio(aspect, contentMode: .fit)
            .overlay {
                RemoteWatchImage(
                    asset: filename.flatMap { store.photoAsset(itemID: itemID, filename: $0, wishlist: wishlist) },
                    allowsRemoteFetch: !store.isOffline,
                    focus: focus
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
            .glassEffect(.regular, in: .capsule)
    }
}
