import SwiftUI
import UIKit
import ImageIO

struct WatchPlaceholder: View {
    var body: some View {
        ZStack {
            Color(.systemGray5)
            Image(systemName: "watch.analog")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.tertiary)
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
                ProgressView()
            }
        }
        .clipped()
        // clipped() trims drawing only; without this a zoomed photo steals taps above its frame.
        .contentShape(Rectangle())
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
    var color: Color = .secondary
    var filled = false

    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .foregroundStyle(filled ? .white : color)
            .background(filled ? color : color.opacity(0.15), in: Capsule())
    }
}

/// Coloured dot + short label: a quieter way to show fit than a full chip.
struct FitIndicator: View {
    let info: FitInfo

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(fitColor(info)).frame(width: 7, height: 7)
            Text(info.label)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityHint("Fit based on \(info.basis)")
    }
}

func fitColor(_ info: FitInfo) -> Color {
    switch info.key {
    case "perfect", "great": .green
    case "sweet": .teal
    case "over": .red
    default: .orange
    }
}

struct FitChip: View {
    let info: FitInfo

    var body: some View {
        CapsuleChip(text: info.label, color: fitColor(info))
            .accessibilityHint("Fit based on \(info.basis)")
    }
}

/// Insights card in the style of Health's summary tiles: a coloured symbol and title,
/// optional detail on the right. Content colours its own marks; a .tint here would leak
/// into the tab bar's selection colour.
struct SectionCard<Content: View>: View {
    let title: String
    let systemImage: String
    let color: Color
    let detail: String?
    @ViewBuilder let content: Content

    init(_ title: String, systemImage: String, color: Color = WatchTheme.accent, detail: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.systemImage = systemImage
        self.color = color
        self.detail = detail
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Label(title, systemImage: systemImage)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(color)
                Spacer(minLength: 8)
                if let detail {
                    Text(detail)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            content
        }
        .groupedCard()
    }
}

/// Inset-grouped section like Settings or the App Store's Information block:
/// a bold header, rows on a rounded card, inset dividers between rows.
struct GroupedSection<Content: View, Accessory: View>: View {
    let title: String?
    @ViewBuilder let accessory: Accessory
    @ViewBuilder let content: Content

    init(_ title: String? = nil, @ViewBuilder accessory: () -> Accessory, @ViewBuilder content: () -> Content) {
        self.title = title
        self.accessory = accessory()
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title {
                HStack(alignment: .firstTextBaseline) {
                    Text(title).font(.title3.bold())
                    Spacer()
                    accessory.font(.body)
                }
                .padding(.horizontal, 4)
            }
            VStack(alignment: .leading, spacing: 0) {
                Group(subviews: content) { rows in
                    ForEach(rows) { row in
                        row
                        if row.id != rows.last?.id {
                            Divider().padding(.leading, 16)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(WatchTheme.card, in: RoundedRectangle(cornerRadius: WatchTheme.corner, style: .continuous))
        }
    }
}

extension GroupedSection where Accessory == EmptyView {
    init(_ title: String? = nil, @ViewBuilder content: () -> Content) {
        self.init(title, accessory: { EmptyView() }, content: content)
    }
}

/// One label/value row inside a GroupedSection.
struct GroupedRow<Value: View>: View {
    let label: String
    @ViewBuilder let value: Value

    init(_ label: String, @ViewBuilder value: () -> Value) {
        self.label = label
        self.value = value()
    }

    var body: some View {
        HStack(spacing: 12) {
            Text(label)
            Spacer(minLength: 12)
            value
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .frame(minHeight: 44)
    }
}

extension GroupedRow where Value == Text {
    init(_ label: String, value: String) {
        self.init(label) { Text(value) }
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
        LabeledContent("Purchased") {
            HStack(spacing: 0) {
                Picker("Purchase month", selection: month) {
                    if allowsUnknown { Text("Unknown").tag(nil as Int?) }
                    ForEach(1...12, id: \.self) { month in
                        Text(monthNames[month - 1]).tag(Optional(month))
                    }
                }
                Picker("Purchase year", selection: year) {
                    if allowsUnknown { Text("Unknown").tag(nil as Int?) }
                    ForEach(years, id: \.self) { year in
                        Text(String(year)).tag(Optional(year))
                    }
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
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
            systemImage: "watch.analog",
            description: Text(detail)
        )
    }
}

struct GearToolbarButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "gearshape")
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
        // Pull-to-refresh shows the system spinner; no custom overlay, as in Apple's apps.
        content
            .refreshable { await store.refresh() }
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

extension View {
    /// Shows store errors inside a sheet; the root alert can't present over one.
    func storeErrorAlert(_ store: AppStore) -> some View {
        alert("Couldn't save", isPresented: Binding(
            get: { store.errorMessage != nil },
            set: { if !$0 { store.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { store.errorMessage = nil }
        } message: {
            Text(store.errorMessage ?? "")
        }
    }
}
