import SwiftUI

/// The collection as a photo library: owned pieces and the archive in one place.
struct CollectionScreen: View {
    @ObservedObject var store: AppStore
    let showSettings: () -> Void
    @State private var addingWatch = false
    @AppStorage("collectionScope") private var scope = Scope.owned.rawValue
    @AppStorage("collectionSort") private var sort = Sort.value.rawValue
    @AppStorage("collectionLayout") private var layout = Layout.cards.rawValue
    @Namespace private var zoom
    @Environment(\.pageMargin) private var margin
    #if DEBUG
    @State private var probePath = NavigationPath()
    #endif

    enum Scope: String, CaseIterable { case owned = "Owned", archive = "Archive", allTime = "All Time" }
    enum Sort: String, CaseIterable { case value = "Value", newest = "Newest", oldest = "Oldest", name = "Name" }
    enum Layout: String { case cards, grid }

    private var all: [Watch] { store.data?.watches ?? [] }

    private var watches: [Watch] {
        let shown = all.filter { watch in
            switch Scope(rawValue: scope) ?? .owned {
            case .owned: watch.status == "owned"
            case .archive: watch.status != "owned"
            case .allTime: true
            }
        }
        switch Sort(rawValue: sort) ?? .value {
        case .oldest:
            return byPurchaseDate(shown)
        case .newest:
            let ordered = byPurchaseDate(shown)
            return ordered.filter { datedSource($0, in: all).purchased != nil }.reversed()
                + ordered.filter { datedSource($0, in: all).purchased == nil }
        default:
            return shown.sorted(by: sorter)
        }
    }

    /// Acquisition order, with an undated trade placed at the date shown on its photo (the
    /// watch it was traded from). Catalogue numbers and the timeline keep plain acquisitionOrder.
    private func byPurchaseDate(_ shown: [Watch]) -> [Watch] {
        let byID = Dictionary(uniqueKeysWithValues: shown.map { ($0.id, $0) })
        let stand = shown.map { watch in
            var copy = watch
            let source = datedSource(watch, in: all)
            copy.purchased = source.purchased
            copy.purchasedText = source.purchasedText
            return copy
        }
        return acquisitionOrder(stand).compactMap { byID[$0.id] }
    }

    private func sorter(_ a: Watch, _ b: Watch) -> Bool {
        switch Sort(rawValue: sort) ?? .value {
        case .value, .newest, .oldest: return a.price > b.price
        case .name: return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }

    var body: some View {
        SectionStack(path: stackPath) {
            RefreshableScreen(store: store) {
                ScrollView {
                    // Lazy, not VStack: a LazyVGrid inside an eager VStack re-measures as rows load,
                    // which bounced the scroll position back and forth on every drag from the top.
                    LazyVStack(alignment: .leading, spacing: 0) {
                        let shown = watches
                        #if os(iOS)
                        Masthead(kicker: "Watch Collection", title: title, subtitle: subtitle)
                            .padding(.horizontal, margin)
                        UnderlineTabs(selection: $scope, options: Scope.allCases.map { (value: $0.rawValue, label: $0.rawValue) })
                            .padding(.horizontal, margin)
                            .padding(.bottom, 20)
                        #endif

                        if let featured = featuredWatch(shown) {
                            featureBlock(featured)
                                .padding(.bottom, WatchTheme.gridGap)
                                .id("feature-\(contentKey)")
                                .transition(.opacity)
                        }

                        Group {
                        if shown.isEmpty {
                            EmptyCollectionView(
                                title: "Nothing Here Yet",
                                detail: scope == Scope.archive.rawValue ? "Watches you part with appear in the archive." : Platform.isMac ? "Click + to add your first watch." : "Tap + to add your first watch."
                            )
                            .frame(minHeight: 360)
                        } else if layout == Layout.grid.rawValue {
                            grid(shown)
                        } else {
                            cards(shown)
                        }
                        }
                        // A simple fade between Owned, Archive and All Time, and on a new sort or layout.
                        .id(contentKey)
                        .transition(.opacity)
                    }
                    .animation(.easeInOut(duration: 0.2), value: contentKey)
                    .padding(.top, Platform.isMac ? 4 : 0)
                    .padding(.bottom, 24)
                }
                .mastheadTitle(title)
                .atelierProbeScroll("collection")
                .screenBackground()
            }
            #if os(macOS)
            .desktopHeader(title, subtitle: subtitle) {
                scopePicker.fixedSize()
            } trailing: {
                sortMenu.menuIndicator(.hidden).fixedSize()
                addButton
            }
            #else
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { GearToolbarButton(action: showSettings) }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    sortMenu
                    addButton
                }
            }
            #endif
            #if os(iOS)
            .navigationDestination(for: WatchRoute.self) { route in
                WatchDossierView(store: store, watchID: route.id)
                    .zoomDestination(id: route.zoomSourceID, in: zoom)
            }
            #endif
            .task(id: contentKey) {
                // Have the next cards ready before they scroll into view.
                let assets = watches.prefix(32).compactMap { watch in
                    watch.photos.first.flatMap { store.photoAsset(itemID: watch.id, filename: $0, wishlist: false) }
                }
                DisplayImageCache.preheat(assets, maxPixel: layout == Layout.grid.rawValue ? DisplayImageCache.thumb : DisplayImageCache.tile)
            }
            .onAppear {
                // "Most worn" went away with wear logging, and the one-up plates became cards.
                if Sort(rawValue: sort) == nil { sort = Sort.value.rawValue }
                if Layout(rawValue: layout) == nil { layout = Layout.cards.rawValue }
            }
            #if DEBUG
            .task {
                guard let id = AtelierProbe.dossierID, probePath.isEmpty else { return }
                try? await Task.sleep(for: .seconds(3))
                probePath.append(WatchRoute(id: id))
            }
            #endif
            .sheet(isPresented: $addingWatch) {
                WatchDetailScreen(store: store, watch: .newDraft, isNew: true)
            }
        }
        .pageAppear()
    }

    /// Debug builds can open a watch's page at launch for screenshots; otherwise the stack keeps its own path.
    private var stackPath: Binding<NavigationPath>? {
        #if DEBUG
        AtelierProbe.dossierID == nil ? nil : $probePath
        #else
        nil
        #endif
    }

    /// The newest dated owned watch with a photo, shown large above the cards. Phone only: on the Mac a
    /// full-bleed photo at this shape would be taller than the window.
    private func featuredWatch(_ shown: [Watch]) -> Watch? {
        guard !Platform.isMac,
              Scope(rawValue: scope) == .owned,
              layout == Layout.cards.rawValue,
              !shown.isEmpty
        else { return nil }
        return byPurchaseDate(all.filter { $0.status == "owned" })
            .last { datedSource($0, in: all).purchased != nil && !$0.photos.isEmpty }
    }

    /// Edge to edge, the cover in its saved framing, the name set large over a dark fade.
    /// Its zoom source has its own id, so it never collides with the same watch's tile in the grid.
    private func featureBlock(_ watch: Watch) -> some View {
        let zoomID = "feature-\(watch.id)"
        return NavigationLink(value: WatchRoute(id: watch.id, zoomID: zoomID)) {
            FramedPhoto(
                store: store,
                itemID: watch.id,
                filename: watch.photos.first,
                focus: watch.focus(for: watch.photos.first),
                aspect: PhotoShape.plate,
                // The size the watch's page decodes, so opening it reuses this image.
                maxPixel: DisplayImageCache.page
            )
            .overlay {
                LinearGradient(
                    stops: [.init(color: .black.opacity(0), location: 0.5), .init(color: .black.opacity(0.55), location: 1)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .allowsHitTesting(false)
            }
            .overlay(alignment: .bottom) {
                VStack(spacing: 12) {
                    Eyebrow("Latest arrival", color: .white)
                    Text(watch.name)
                        .font(AtelierType.display)
                        .tracking(-0.6)
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .minimumScaleFactor(0.7)
                        .multilineTextAlignment(.center)
                    AtelierPill(kind: .quietOverPhoto) { Text("View watch") }
                        .padding(.top, 8)
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 32)
            }
            .zoomSource(id: zoomID, in: zoom)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Latest arrival, \(watch.name)")
        .accessibilityHint("Opens the watch")
        .accessibilityAddTraits(.isButton)
    }

    private var scopePicker: some View {
        Picker("Show", selection: $scope) {
            ForEach(Scope.allCases, id: \.self) { Text($0.rawValue).tag($0.rawValue) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }

    private var sortMenu: some View {
        Menu {
            Section("Sort By") {
                Picker("Sort By", selection: $sort) {
                    ForEach(Sort.allCases, id: \.self) { Text($0.rawValue).tag($0.rawValue) }
                }
            }
            Section("View As") {
                Picker("View As", selection: $layout) {
                    Label("Cards", systemImage: "square.grid.2x2").tag(Layout.cards.rawValue)
                    Label("Photos", systemImage: "square.grid.3x3").tag(Layout.grid.rawValue)
                }
            }
        } label: {
            Image(systemName: "line.3.horizontal.decrease")
        }
        .accessibilityLabel("Sort and view options")
    }

    private var addButton: some View {
        Button { addingWatch = true } label: { Image(systemName: "plus") }
            .disabled(store.isOffline)
            .accessibilityLabel("Add watch")
    }

    private var contentKey: String { "\(scope)-\(sort)-\(layout)" }

    private var title: String {
        switch Scope(rawValue: scope) ?? .owned {
        case .owned: "Collection"
        case .archive: "Archive"
        case .allTime: "All Time"
        }
    }

    private var subtitle: String {
        let owned = all.filter { $0.status == "owned" }
        switch Scope(rawValue: scope) ?? .owned {
        case .owned:
            return "\(owned.count) watches · \(cadWhole(owned.reduce(0) { $0 + $1.price }))"
        case .archive:
            return "\(all.count - owned.count) moved on · \(all.count) all time"
        case .allTime:
            // Same total as Insights: a trade or lot watch is counted once, through its source.
            return "\(all.count) watches · \(cadWhole(uniqueCostRecords(all).reduce(0) { $0 + $1.price }))"
        }
    }

    private func cards(_ watches: [Watch]) -> some View {
        LazyVGrid(columns: Platform.isMac
                  ? [GridItem(.adaptive(minimum: 230, maximum: 340), spacing: WatchTheme.gridGap, alignment: .top)]
                  : Array(repeating: GridItem(.flexible(), spacing: WatchTheme.gridGap, alignment: .top), count: 2),
                  spacing: WatchTheme.gridGap) {
            ForEach(watches) { watch in
                NavigationLink(value: WatchRoute(id: watch.id)) {
                    WatchTile(store: store, watch: watch, zoom: zoom)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, Platform.isMac ? margin : WatchTheme.narrowMargin)
    }

    private func grid(_ watches: [Watch]) -> some View {
        LazyVGrid(columns: Platform.isMac
                  ? [GridItem(.adaptive(minimum: 170), spacing: 2)]
                  : Array(repeating: GridItem(.flexible(), spacing: 2), count: 3), spacing: 2) {
            ForEach(watches) { watch in
                NavigationLink(value: WatchRoute(id: watch.id)) {
                    FramedPhoto(
                        store: store,
                        itemID: watch.id,
                        filename: watch.photos.first,
                        focus: watch.focus(for: watch.photos.first),
                        aspect: PhotoShape.square,
                        maxPixel: DisplayImageCache.thumb
                    )
                    .overlay(alignment: .bottomLeading) { PurchaseDateOverlay(watch: watch, watches: all) }
                    .zoomSource(id: watch.id, in: zoom)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(watch.name)
            }
        }
    }
}

/// What an archive row says under the name: what it cost, then where it went. A watch that came
/// in a lot has no price of its own, because the lot's record already carries the cost.
func archiveDetail(_ watch: Watch) -> String {
    let cost = watch.costSourceWatchID != nil && watch.price == 0 ? "Part of lot" : cadWhole(watch.price)
    if let sale = watch.salePrice { return "\(cost) · Sold for \(cadWhole(sale))" }
    return "\(cost) · \(statusLabel(watch.status))"
}

/// Two-up tile: a square panel with the photo across the top, then the name, a spec line and the price.
struct WatchTile: View {
    let store: AppStore
    let watch: Watch
    let zoom: Namespace.ID

    /// Category and diameter, as "Dive, 38 mm".
    private var specLine: String {
        [watch.category, watch.diameter.map { "\(compactNumber($0)) mm" }]
            .compactMap { $0 }
            .joined(separator: ", ")
    }

    /// What it cost, or for a watch that has moved on, what it cost and where it went.
    private var priceLine: String {
        watch.status == "owned" ? cadWhole(watch.price) : archiveDetail(watch)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            FramedPhoto(store: store, itemID: watch.id, filename: watch.photos.first, focus: watch.focus(for: watch.photos.first))
                .overlay(alignment: .topLeading) {
                    if watch.original == false {
                        PhotoTag(text: "Replica").padding(8)
                    }
                }
                .overlay(alignment: .bottomLeading) { PurchaseDateOverlay(watch: watch, watches: store.data?.watches ?? []) }
                .zoomSource(id: watch.id, in: zoom)
            VStack(alignment: .leading, spacing: 4) {
                Text(watch.name)
                    .font(AtelierType.cardTitle)
                    .foregroundStyle(WatchTheme.ink)
                    .lineLimit(2, reservesSpace: true)
                    .multilineTextAlignment(.leading)
                // A space keeps the line's height when nothing is known, so tiles in a row stay level.
                Text(specLine.isEmpty ? " " : specLine)
                    .font(AtelierType.detail)
                    .foregroundStyle(WatchTheme.muted)
                    .lineLimit(1)
                Text(priceLine)
                    .font(.system(.subheadline, weight: .regular))
                    .foregroundStyle(WatchTheme.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 14)
        }
        .background(WatchTheme.card)
        .contentShape(Rectangle())
    }
}
