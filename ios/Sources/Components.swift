import SwiftUI
import UIKit
import ImageIO

struct WatchPlaceholder: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [WatchTheme.raised, WatchTheme.card],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            VStack(spacing: 4) {
                Image(systemName: "applewatch.watchface")
                    .font(.system(size: 34, weight: .thin))
                    .foregroundStyle(WatchTheme.gold.opacity(0.78))
                Text("NO PHOTO")
                    .font(.system(size: 8, weight: .bold, design: .rounded))
                    .tracking(1.5)
                    .foregroundStyle(WatchTheme.secondary.opacity(0.65))
            }
        }
    }
}

struct RemoteWatchImage: View {
    let asset: PhotoAsset?
    let allowsRemoteFetch: Bool
    var focus: PhotoFocus? = nil
    @State private var image: UIImage?
    @State private var isLoading = false

    private var loadID: LoadID {
        LoadID(asset: asset, allowsRemoteFetch: allowsRemoteFetch)
    }

    var body: some View {
        ZStack {
            if let image {
                FocusedImage(image: image, focus: focus)
            } else {
                WatchPlaceholder()
            }
            if isLoading && image == nil {
                ProgressView().tint(WatchTheme.gold)
            }
        }
        .clipped()
        .task(id: loadID) {
            image = nil
            guard let asset else {
                isLoading = false
                return
            }
            if let cached = DisplayImageCache.image(for: asset.key) {
                image = cached
                isLoading = false
                return
            }
            isLoading = true
            let data = await PhotoStore.shared.load(asset, allowDownload: allowsRemoteFetch)
            if !Task.isCancelled, let data {
                let key = asset.key
                image = await Task.detached(priority: .userInitiated) {
                    DisplayImageCache.decode(data, key: key)
                }.value
            }
            isLoading = false
        }
    }

    private struct LoadID: Hashable {
        let asset: PhotoAsset?
        let allowsRemoteFetch: Bool
    }
}

/// Downsampled, cached images for display. Full 12 MP originals are only decoded by
/// the framing editor; every list, grid and page draws a ~1600 px version from here.
enum DisplayImageCache {
    private static let cache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.totalCostLimit = 160 * 1024 * 1024
        return cache
    }()

    private static func cacheKey(_ key: PhotoKey) -> NSString {
        "\(key.directory)/\(key.filename)" as NSString
    }

    static func image(for key: PhotoKey) -> UIImage? {
        cache.object(forKey: cacheKey(key))
    }

    static func decode(_ data: Data, key: PhotoKey, maxPixel: Int = 1600) -> UIImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { return UIImage(data: data) }
        let image = UIImage(cgImage: cgImage)
        cache.setObject(image, forKey: cacheKey(key), cost: cgImage.bytesPerRow * cgImage.height)
        return image
    }
}

struct CapsuleChip: View {
    let text: String
    var color: Color = WatchTheme.secondary
    var filled = false

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .foregroundStyle(filled ? WatchTheme.background : color)
            .background(filled ? color : color.opacity(0.12), in: Capsule())
    }
}

/// Coloured dot + short label: a quieter way to show fit than a full chip.
struct FitIndicator: View {
    let info: FitInfo

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(fitColor(info)).frame(width: 6, height: 6)
            Text(info.label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(WatchTheme.secondary)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityHint("Fit based on \(info.basis)")
    }
}

func fitColor(_ info: FitInfo) -> Color {
    switch info.key {
    case "perfect", "great": WatchTheme.gold
    case "sweet": WatchTheme.green
    default: WatchTheme.amber
    }
}

struct FitChip: View {
    let info: FitInfo

    var body: some View {
        CapsuleChip(text: info.label, color: fitColor(info))
            .accessibilityHint("Fit based on \(info.basis)")
    }
}

struct DialChip: View {
    let name: String

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(dialColor(name))
                .frame(width: 8, height: 8)
                .overlay { Circle().stroke(Color.white.opacity(0.35), lineWidth: 0.5) }
            Text(name).lineLimit(1)
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(WatchTheme.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(WatchTheme.secondary.opacity(0.1))
        .clipShape(Capsule())
    }
}

struct SectionCard<Content: View>: View {
    let eyebrow: String?
    let title: String
    @ViewBuilder let content: Content

    init(eyebrow: String? = nil, title: String, @ViewBuilder content: () -> Content) {
        self.eyebrow = eyebrow
        self.title = title
        self.content = content()
    }

    var body: some View {
        // Editorial section: a gold rule, small label and Didot title, no box.
        VStack(alignment: .leading, spacing: 16) {
            GoldRule()
            VStack(alignment: .leading, spacing: 8) {
                if let eyebrow { Eyebrow(eyebrow) }
                Text(title)
                    .font(.display(30))
                    .foregroundStyle(WatchTheme.ivory)
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 14)
    }
}

struct MonthYearPicker: View {
    @Binding var value: String?
    var allowsUnknown = true

    private let monthNames = Calendar.current.shortMonthSymbols
    private var currentYear: Int { Calendar.current.component(.year, from: Date()) }
    private var years: [Int] { Array((1950...(currentYear + 1)).reversed()) }

    private var month: Binding<Int?> {
        Binding(
            get: { purchaseMonthParts(value)?.month },
            set: { newMonth in
                guard let newMonth else {
                    value = nil
                    return
                }
                value = purchaseMonthKey(
                    year: purchaseMonthParts(value)?.year ?? currentYear,
                    month: newMonth
                )
            }
        )
    }

    private var year: Binding<Int?> {
        Binding(
            get: { purchaseMonthParts(value)?.year },
            set: { newYear in
                guard let newYear else {
                    value = nil
                    return
                }
                value = purchaseMonthKey(
                    year: newYear,
                    month: purchaseMonthParts(value)?.month ?? Calendar.current.component(.month, from: Date())
                )
            }
        )
    }

    var body: some View {
        HStack {
            Picker("Purchase month", selection: month) {
                if allowsUnknown { Text("Unknown").tag(nil as Int?) }
                ForEach(1...12, id: \.self) { month in
                    Text(monthNames[month - 1]).tag(Optional(month))
                }
            }
            .pickerStyle(.menu)

            Spacer()

            Picker("Purchase year", selection: year) {
                if allowsUnknown { Text("Unknown").tag(nil as Int?) }
                ForEach(years, id: \.self) { year in
                    Text(String(year)).tag(Optional(year))
                }
            }
            .pickerStyle(.menu)
        }
        .onAppear {
            if !allowsUnknown, purchaseMonthParts(value) == nil {
                value = currentPurchaseMonth()
            }
        }
        .accessibilityElement(children: .contain)
    }
}

struct EmptyCollectionView: View {
    let title: String
    let detail: String

    var body: some View {
        ContentUnavailableView(
            title,
            systemImage: "applewatch",
            description: Text(detail)
        )
        .foregroundStyle(WatchTheme.secondary)
    }
}

struct GearToolbarButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "gearshape")
                .foregroundStyle(WatchTheme.gold)
        }
        .accessibilityLabel("Settings")
    }
}

struct RefreshableScreen<Content: View>: View {
    @ObservedObject var store: AppStore
    @ViewBuilder let content: Content

    init(store: AppStore, @ViewBuilder content: () -> Content) {
        self.store = store
        self.content = content()
    }

    var body: some View {
        content
            .refreshable { await store.refresh() }
            .overlay(alignment: .top) {
                if store.isRefreshing {
                    ProgressView()
                        .tint(WatchTheme.gold)
                        .padding(.top, 4)
                }
            }
    }
}

/// Left-aligned wrapping layout for chip rows, so cards keep one compact block
/// instead of one chip per line.
struct ChipFlowLayout: Layout {
    var spacing: CGFloat = 5

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = Self.fittedSize(subview, maxWidth: width)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: width, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = Self.fittedSize(subview, maxWidth: bounds.width)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }

    /// A chip wider than the row wraps its text instead of spilling past the edge.
    private static func fittedSize(_ subview: LayoutSubview, maxWidth: CGFloat) -> CGSize {
        let natural = subview.sizeThatFits(.unspecified)
        guard maxWidth.isFinite, natural.width > maxWidth else { return natural }
        return subview.sizeThatFits(ProposedViewSize(width: maxWidth, height: nil))
    }
}
