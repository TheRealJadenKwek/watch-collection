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

/// Circular watch portrait used in the watch box strip and lists.
struct WatchPortrait: View {
    @ObservedObject var store: AppStore
    let watch: Watch
    var size: CGFloat = 64
    var highlighted = false

    var body: some View {
        RemoteWatchImage(
            asset: watch.photos.first.flatMap { store.photoAsset(itemID: watch.id, filename: $0, wishlist: false) },
            allowsRemoteFetch: !store.isOffline,
            focus: watch.focus(for: watch.photos.first)
        )
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay {
            Circle().stroke(highlighted ? WatchTheme.gold : WatchTheme.hairline, lineWidth: highlighted ? 2 : 1)
        }
        .padding(highlighted ? 3 : 0)
        .overlay {
            if highlighted { Circle().stroke(WatchTheme.gold.opacity(0.35), lineWidth: 1) }
        }
    }
}

/// Big Didot figure with a small label underneath.
struct Figure: View {
    let value: String
    let label: String
    var size: CGFloat = 34
    var color: Color = WatchTheme.ivory

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value)
                .font(.display(size))
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Eyebrow(label, color: WatchTheme.secondary)
        }
    }
}

/// Small dark-glass label laid over photos.
struct PhotoTag: View {
    let text: String
    var color: Color = WatchTheme.ivory

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .tracking(1.4)
            .foregroundStyle(color)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(Color.black.opacity(0.42), in: Capsule())
            .background(.ultraThinMaterial, in: Capsule())
            .environment(\.colorScheme, .dark)
    }
}

/// Screen header: small label above a large Didot title.
struct ScreenHeader: View {
    let eyebrow: String
    let title: String
    var subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Eyebrow(eyebrow)
            Text(title)
                .font(.display(42, relativeTo: .largeTitle))
                .foregroundStyle(WatchTheme.ivory)
                .lineLimit(2)
                .minimumScaleFactor(0.7)
            if let subtitle {
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(WatchTheme.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Capsule segmented control in the editorial style.
struct PillPicker: View {
    let options: [(value: String, label: String)]
    @Binding var selection: String

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.value) { option in
                let selected = selection == option.value
                Button {
                    withAnimation(.snappy) { selection = option.value }
                } label: {
                    Text(option.label)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(selected ? WatchTheme.background : WatchTheme.secondary)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(selected ? WatchTheme.ivory : .clear, in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(3)
        .background(WatchTheme.card, in: Capsule())
        .overlay { Capsule().stroke(WatchTheme.hairline) }
    }
}
