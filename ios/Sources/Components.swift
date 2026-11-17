import SwiftUI
#if canImport(UIKit)
import UIKit
#endif
import ImageIO

struct WatchPlaceholder: View {
    var body: some View {
        ZStack {
            WatchTheme.card
            Image(systemName: "watch.analog")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(WatchTheme.muted)
        }
    }
}

struct RemoteWatchImage: View {
    let asset: PhotoAsset?
    let allowsRemoteFetch: Bool
    var focus: PhotoFocus?
    /// Show the whole photo instead of filling the frame (the desktop page's viewer).
    var fitWholePhoto: Bool
    /// A rendered tile: drawn by `RenderLayout` (the whole watch in any frame) instead of by a focus.
    var render: Bool
    var maxPixel: Int
    /// A cover's first photo standing in for a render that is not on this device yet (`WatchCover.fallback`): drawn
    /// in its own framing if the render is slow to come (`standInDelay`) or cannot be had, and replaced by the
    /// render the moment it arrives.
    var fallbackAsset: PhotoAsset?
    var fallbackFocus: PhotoFocus?
    @State private var shown: Shown?

    /// How long a render being fetched may leave the frame on its placeholder before the stand-in photo shows.
    static let standInDelay: Duration = .milliseconds(900)

    /// What the frame draws: a decoded file, and how to lay it out.
    private struct Shown {
        let image: UIImage
        let key: PhotoKey
        let isRender: Bool
        let focus: PhotoFocus?
    }

    init(
        asset: PhotoAsset?,
        allowsRemoteFetch: Bool,
        focus: PhotoFocus? = nil,
        fitWholePhoto: Bool = false,
        render: Bool = false,
        maxPixel: Int = DisplayImageCache.page,
        fallbackAsset: PhotoAsset? = nil,
        fallbackFocus: PhotoFocus? = nil
    ) {
        self.asset = asset
        self.allowsRemoteFetch = allowsRemoteFetch
        self.focus = focus
        self.fitWholePhoto = fitWholePhoto
        self.render = render
        self.maxPixel = maxPixel
        self.fallbackAsset = fallbackAsset
        self.fallbackFocus = fallbackFocus
        // Already decoded? Draw it in this very frame, so scrolling back never flashes a placeholder. A render that
        // could not be had lately draws its stand-in the same way.
        var initial: Shown?
        if let asset, let image = DisplayImageCache.image(for: asset.key, maxPixel: maxPixel) {
            initial = Shown(image: image, key: asset.key, isRender: render, focus: focus)
        } else if let asset, let fallbackAsset, RenderMisses.recent(asset.key),
                  let image = DisplayImageCache.image(for: fallbackAsset.key, maxPixel: maxPixel) {
            initial = Shown(image: image, key: fallbackAsset.key, isRender: false, focus: fallbackFocus)
        }
        _shown = State(initialValue: initial)
    }

    /// A watch's or a candidate's cover: its render (fetched if it is not on this device yet, its first photo
    /// standing in while it is slow or if it cannot be had), or its first photo in its saved framing.
    init(cover: WatchCover?, allowsRemoteFetch: Bool, fitWholePhoto: Bool = false, maxPixel: Int = DisplayImageCache.page) {
        let fallback = cover?.fallback
        self.init(
            asset: cover?.asset,
            allowsRemoteFetch: allowsRemoteFetch,
            focus: cover?.focus,
            fitWholePhoto: fitWholePhoto,
            render: cover?.isRender == true,
            maxPixel: maxPixel,
            fallbackAsset: fallback?.asset,
            fallbackFocus: fallback?.focus
        )
    }

    private var loadID: LoadID {
        LoadID(asset: asset, fallbackAsset: fallbackAsset, allowsRemoteFetch: allowsRemoteFetch, maxPixel: maxPixel)
    }

    var body: some View {
        ZStack {
            WatchPlaceholder()
            if let shown {
                Group {
                    if shown.isRender {
                        RenderImage(image: shown.image)
                    } else if fitWholePhoto {
                        Image(uiImage: shown.image).resizable().scaledToFit()
                    } else {
                        FocusedImage(image: shown.image, focus: shown.focus)
                    }
                }
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.15), value: shown != nil)
        .clipped()
        // clipped() trims drawing only; without this a zoomed photo steals taps above its frame.
        .contentShape(Rectangle())
        .task(id: loadID) {
            await load()
        }
    }

    private func load() async {
        guard let asset else {
            shown = nil
            return
        }
        let target = maxPixel
        if let cached = DisplayImageCache.image(for: asset.key, maxPixel: target) {
            shown = Shown(image: cached, key: asset.key, isRender: render, focus: focus)
            return
        }
        // Another picture of the same watch stays up until this one is ready (a stand-in giving way to its render,
        // a new cover photo); a different watch's picture goes at once.
        if shown?.key.directory != asset.directory { shown = nil }
        // A row that scrolls straight past cancels here, before any decoding is spent on it.
        try? await Task.sleep(for: .milliseconds(25))
        guard !Task.isCancelled else { return }
        let allowDownload = allowsRemoteFetch
        guard let fallbackAsset else {
            let decoded = await Self.decoded(asset, maxPixel: target, allowDownload: allowDownload)
            if !Task.isCancelled, let decoded {
                shown = Shown(image: decoded, key: asset.key, isRender: render, focus: focus)
            }
            return
        }
        // A render not on this device: its stand-in shows if the fetch is slow (at once if it failed lately).
        let quick = RenderMisses.recent(asset.key)
        let standIn = Task { @MainActor in
            if !quick { try? await Task.sleep(for: Self.standInDelay) }
            guard !Task.isCancelled else { return }
            await showStandIn(fallbackAsset, maxPixel: target, allowDownload: allowDownload)
        }
        let decoded = await withTaskCancellationHandler {
            await Self.decoded(asset, maxPixel: target, allowDownload: allowDownload)
        } onCancel: {
            standIn.cancel()
        }
        guard !Task.isCancelled else { return }
        if let decoded {
            standIn.cancel()
            RenderMisses.clear(asset.key)
            shown = Shown(image: decoded, key: asset.key, isRender: render, focus: focus)
            return
        }
        // The render cannot be had: the stand-in now, if it is not up already.
        if allowDownload { RenderMisses.note(asset.key) }
        standIn.cancel()
        if shown?.key != fallbackAsset.key {
            await showStandIn(fallbackAsset, maxPixel: target, allowDownload: allowDownload)
        }
    }

    @MainActor
    private func showStandIn(_ standIn: PhotoAsset, maxPixel: Int, allowDownload: Bool) async {
        var decoded = DisplayImageCache.image(for: standIn.key, maxPixel: maxPixel)
        if decoded == nil {
            decoded = await Self.decoded(standIn, maxPixel: maxPixel, allowDownload: allowDownload)
        }
        guard !Task.isCancelled, let decoded else { return }
        shown = Shown(image: decoded, key: standIn.key, isRender: false, focus: fallbackFocus)
    }

    /// The file decoded at `maxPixel`, from this device or else (with `allowDownload`) fetched by `PhotoStore`.
    private static func decoded(_ asset: PhotoAsset, maxPixel: Int, allowDownload: Bool) async -> UIImage? {
        await Task.detached(priority: .userInitiated) {
            if let file = PhotoStore.existingLocalURL(for: asset) {
                return DisplayImageCache.decode(file: file, key: asset.key, maxPixel: maxPixel)
            }
            guard let data = await PhotoStore.shared.load(asset, allowDownload: allowDownload) else { return nil }
            return DisplayImageCache.decode(data, key: asset.key, maxPixel: maxPixel)
        }.value
    }

    private struct LoadID: Hashable {
        let asset: PhotoAsset?
        let fallbackAsset: PhotoAsset?
        let allowsRemoteFetch: Bool
        let maxPixel: Int
    }
}

/// Renders a screen could not have lately (not in iCloud, or the fetch failed), so a row scrolling back draws its
/// stand-in photo at once instead of waiting on the render again. Forgotten after `span`, or when the render loads.
enum RenderMisses {
    static let span: TimeInterval = 5 * 60
    private static let lock = NSLock()
    nonisolated(unsafe) private static var missed: [PhotoKey: Date] = [:]

    static func note(_ key: PhotoKey, at date: Date = Date()) {
        lock.lock()
        defer { lock.unlock() }
        missed[key] = date
    }

    static func clear(_ key: PhotoKey) {
        lock.lock()
        defer { lock.unlock() }
        missed[key] = nil
    }

    static func recent(_ key: PhotoKey, at date: Date = Date()) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let when = missed[key] else { return false }
        return date.timeIntervalSince(when) < span
    }
}

/// Downsampled, cached images for display, decoded at the size each place actually draws.
/// A card used to decode a 1600 px image to show it at about 500, which also overflowed the
/// cache, so scrolling kept decoding the same photos again.
enum DisplayImageCache {
    static let icon = 400      // list rows and small thumbnails
    static let thumb = 600     // the dense photo grid
    static let tile = 900      // collection cards
    static let page = 1600     // a watch's page and forms
    static let full = 2400     // the desktop page's full-window viewer

    private static let cache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.totalCostLimit = (Platform.isMac ? 480 : 220) * 1024 * 1024
        return cache
    }()

    private static func cacheKey(_ key: PhotoKey, _ maxPixel: Int) -> NSString {
        "\(key.directory)/\(key.filename)@\(maxPixel)" as NSString
    }

    static func image(for key: PhotoKey, maxPixel: Int) -> UIImage? {
        cache.object(forKey: cacheKey(key, maxPixel))
    }

    static func decode(_ data: Data, key: PhotoKey, maxPixel: Int = page) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = decode(source, key: key, maxPixel: maxPixel)
        else { return UIImage(data: data) }
        return image
    }

    /// From the file directly, so a downsample doesn't read the whole original into memory first.
    static func decode(file: URL, key: PhotoKey, maxPixel: Int) -> UIImage? {
        guard let source = CGImageSourceCreateWithURL(file as CFURL, nil) else { return nil }
        return decode(source, key: key, maxPixel: maxPixel)
    }

    private static func decode(_ source: CGImageSource, key: PhotoKey, maxPixel: Int) -> UIImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let image = UIImage(cgImage: cgImage)
        cache.setObject(image, forKey: cacheKey(key, maxPixel), cost: cgImage.bytesPerRow * cgImage.height)
        return image
    }

    /// Decodes what's about to be on screen ahead of time, quietly, one photo at a time.
    static func preheat(_ assets: [PhotoAsset], maxPixel: Int) {
        Task.detached(priority: .utility) {
            for asset in assets {
                guard !Task.isCancelled else { return }
                if image(for: asset.key, maxPixel: maxPixel) != nil { continue }
                if let file = PhotoStore.existingLocalURL(for: asset) {
                    _ = decode(file: file, key: asset.key, maxPixel: maxPixel)
                }
            }
        }
    }
}

/// Swipeable photos on iOS; on the Mac, where page-style TabViews don't exist,
/// one photo at a time with previous/next buttons and arrow keys.
struct PhotoPager<Content: View>: View {
    @Binding var selection: Int
    let count: Int
    var showsDotsForOne = false
    @ViewBuilder let content: (Int) -> Content

    var body: some View {
        #if os(iOS)
        TabView(selection: $selection) {
            ForEach(0..<count, id: \.self) { index in
                content(index).tag(index)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: count > 1 ? .always : .never))
        #else
        ZStack {
            if count > 0 {
                content(min(max(selection, 0), count - 1))
                    .id(selection)
            }
            if count > 1 {
                HStack {
                    pagerButton("chevron.left", label: "Previous photo", by: -1, key: .leftArrow)
                    Spacer()
                    pagerButton("chevron.right", label: "Next photo", by: 1, key: .rightArrow)
                }
                .padding(12)
                VStack {
                    Spacer()
                    HStack(spacing: 6) {
                        ForEach(0..<count, id: \.self) { index in
                            Circle()
                                .fill(index == selection ? Color.white : Color.white.opacity(0.45))
                                .frame(width: 7, height: 7)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.black.opacity(0.35), in: Capsule())
                    .padding(.bottom, 12)
                }
            }
        }
        #endif
    }

    #if os(macOS)
    private func pagerButton(_ symbol: String, label: String, by step: Int, key: KeyEquivalent) -> some View {
        Button {
            selection = (selection + step + count) % count
        } label: {
            Image(systemName: symbol)
                .font(.body.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(.black.opacity(0.4), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut(key, modifiers: [])
        .accessibilityLabel(label)
    }
    #endif
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
            // Filled chips (the green ones included) carry a white label in both modes.
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
    default: .yellow
    }
}

struct FitChip: View {
    let info: FitInfo

    var body: some View {
        CapsuleChip(text: info.label, color: fitColor(info))
            .accessibilityHint("Fit based on \(info.basis)")
    }
}

/// A square panel: a bold title, an optional quiet detail on the right, or a kicker above the title.
/// `systemImage` and `color` are kept so call sites read as before, but the header draws no symbol and
/// no colour. Content colours its own marks; a .tint here would leak into the tab bar's selection colour.
struct SectionCard<Content: View>: View {
    let title: String
    let systemImage: String
    let color: Color
    let detail: String?
    let kicker: String?
    @ViewBuilder let content: Content

    init(
        _ title: String,
        systemImage: String,
        color: Color = WatchTheme.accent,
        detail: String? = nil,
        kicker: String? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.systemImage = systemImage
        self.color = color
        self.detail = detail
        self.kicker = kicker
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                if let kicker { Eyebrow(kicker) }
                HStack(alignment: .firstTextBaseline) {
                    Text(title)
                        .font(AtelierType.title)
                        .foregroundStyle(WatchTheme.ink)
                    Spacer(minLength: 8)
                    if let detail {
                        Text(detail)
                            .font(AtelierType.caption)
                            .foregroundStyle(WatchTheme.muted)
                            .lineLimit(1)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isHeader)
            }
            content
        }
        .groupedCard()
    }
}

/// A spec list: the section title, then rows on the page between full-width hairlines,
/// one above the first row and one after each row. No card behind it.
/// With more than one column (a folding iPhone held like a book) the rows run down the first column and on down
/// the next, each column with its own hairlines, `gap` apart.
struct GroupedSection<Content: View, Accessory: View>: View {
    let title: String?
    let columns: Int
    let gap: CGFloat
    @ViewBuilder let accessory: Accessory
    @ViewBuilder let content: Content

    init(
        _ title: String? = nil,
        columns: Int = 1,
        gap: CGFloat = 0,
        @ViewBuilder accessory: () -> Accessory,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.columns = columns
        self.gap = gap
        self.accessory = accessory()
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let title {
                HStack(alignment: .firstTextBaseline) {
                    Text(title)
                        .font(AtelierType.title)
                        .foregroundStyle(WatchTheme.ink)
                        .accessibilityAddTraits(.isHeader)
                    Spacer()
                    accessory
                        .font(.system(.body, weight: .bold))
                        .tint(WatchTheme.accent)
                }
            }
            if columns > 1 {
                Group(subviews: content) { rows in
                    let perColumn = max(1, (rows.count + columns - 1) / columns)
                    // A column the rows do not reach stays empty, without a hairline of its own.
                    let used = max(1, (rows.count + perColumn - 1) / perColumn)
                    CardColumns(columns: columns, spacing: 0, gap: gap) {
                        ForEach(0..<used, id: \.self) { column in
                            Hairline().cardColumn(column, of: columns)
                        }
                        ForEach(rows.indices, id: \.self) { index in
                            VStack(alignment: .leading, spacing: 0) {
                                rows[index]
                                Hairline()
                            }
                            .cardColumn(index / perColumn, of: columns)
                        }
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    Hairline()
                    Group(subviews: content) { rows in
                        ForEach(rows) { row in
                            row
                            Hairline()
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

extension GroupedSection where Accessory == EmptyView {
    init(_ title: String? = nil, columns: Int = 1, gap: CGFloat = 0, @ViewBuilder content: () -> Content) {
        self.init(title, columns: columns, gap: gap, accessory: { EmptyView() }, content: content)
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
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .font(.system(.body, weight: .bold))
                .foregroundStyle(WatchTheme.ink)
            Spacer(minLength: 12)
            value
                .font(AtelierType.detail)
                .foregroundStyle(WatchTheme.muted)
                .multilineTextAlignment(.trailing)
        }
        .padding(.vertical, 16)
        .frame(minHeight: 44)
        .accessibilityElement(children: .combine)
    }
}

extension GroupedRow where Value == Text {
    init(_ label: String, value: String) {
        self.init(label) { Text(value) }
    }
}

/// Page-level switch drawn as text tabs: equal widths, the selected one in green with a 2 pt green
/// underline that slides between tabs, and a hairline under the whole row. Pickers inside forms and
/// sheets stay system pickers.
struct UnderlineTabs<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(value: Value, label: String)]
    @Namespace private var underline

    init(selection: Binding<Value>, options: [(value: Value, label: String)]) {
        _selection = selection
        self.options = options
    }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                let selected = option.value == selection
                Button {
                    guard !selected else { return }
                    withAnimation(.easeInOut(duration: 0.25)) { selection = option.value }
                } label: {
                    Text(option.label)
                        .font(.system(.subheadline, weight: .bold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .foregroundStyle(selected ? WatchTheme.accent : WatchTheme.ink)
                        .padding(.vertical, 13)
                        .overlay(alignment: .bottom) {
                            if selected {
                                Rectangle()
                                    .fill(WatchTheme.accent)
                                    .frame(height: 2)
                                    .matchedGeometryEffect(id: "underline", in: underline)
                            }
                        }
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .bottom)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? [.isSelected] : [])
            }
        }
        // Its own timing, whatever animation the screen around it runs for the same change.
        .animation(.easeInOut(duration: 0.25), value: selection)
        .background(alignment: .bottom) { Hairline() }
    }
}

struct MonthYearPicker: View {
    @Binding var value: String?
    var allowsUnknown = true
    var title = "Purchased"
    /// Lets the month stay Unknown while the year is set, stored as "2019".
    var allowsYearOnly = false

    private let monthNames = Calendar.current.shortMonthSymbols
    private var currentYear: Int { Calendar.current.component(.year, from: Date()) }
    private var years: [Int] { Array((1950...(currentYear + 1)).reversed()) }

    private var month: Binding<Int?> {
        Binding(
            get: { purchaseMonthParts(value)?.month },
            set: { newMonth in
                guard let newMonth else {
                    value = allowsYearOnly ? knownYear.map(String.init) : nil
                    return
                }
                value = purchaseMonthKey(
                    year: knownYear ?? currentYear,
                    month: newMonth
                )
            }
        )
    }

    private var year: Binding<Int?> {
        Binding(
            get: { knownYear },
            set: { newYear in
                guard let newYear else {
                    value = nil
                    return
                }
                if allowsYearOnly, purchaseMonthParts(value) == nil {
                    value = String(newYear)
                    return
                }
                value = purchaseMonthKey(
                    year: newYear,
                    month: purchaseMonthParts(value)?.month ?? Calendar.current.component(.month, from: Date())
                )
            }
        )
    }

    private var knownYear: Int? {
        if let year = purchaseMonthParts(value)?.year { return year }
        guard allowsYearOnly, let value, value.count == 4 else { return nil }
        return Int(value)
    }

    var body: some View {
        LabeledContent(title) {
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
