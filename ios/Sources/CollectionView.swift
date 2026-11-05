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
        NavigationStack {
            RefreshableScreen(store: store) {
                ScrollView {
                    // Lazy, not VStack: a LazyVGrid inside an eager VStack re-measures as rows load,
                    // which bounced the scroll position back and forth on every drag from the top.
                    LazyVStack(alignment: .leading, spacing: 18) {
                        let shown = watches
                        Picker("Show", selection: $scope) {
                            ForEach(Scope.allCases, id: \.self) { Text($0.rawValue).tag($0.rawValue) }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(maxWidth: Platform.isMac ? 240 : .infinity, alignment: .leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 20)

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
                    .padding(.top, 4)
                    .padding(.bottom, 24)
                }
                .screenBackground()
            }
            .navigationTitle(title)
            .navigationSubtitle(subtitle)
            .toolbar {
                if !Platform.isMac {
                    ToolbarItem(placement: .topBarLeading) { GearToolbarButton(action: showSettings) }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
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
                    Button { addingWatch = true } label: { Image(systemName: "plus") }
                        .disabled(store.isOffline)
                        .accessibilityLabel("Add watch")
                }
            }
            .navigationDestination(for: WatchRoute.self) { route in
                WatchDossierView(store: store, watchID: route.id)
                    .zoomDestination(id: route.id, in: zoom)
                    .desktopPageAppear()
            }
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
            .sheet(isPresented: $addingWatch) {
                WatchDetailScreen(store: store, watch: .newDraft, isNew: true)
            }
        }
        .pageAppear()
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
                  ? [GridItem(.adaptive(minimum: 230, maximum: 340), spacing: 20, alignment: .top)]
                  : Array(repeating: GridItem(.flexible(), spacing: 14, alignment: .top), count: 2),
                  spacing: Platform.isMac ? 30 : 24) {
            ForEach(watches) { watch in
                NavigationLink(value: WatchRoute(id: watch.id)) {
                    WatchTile(store: store, watch: watch, zoom: zoom)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 20)
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
    return "\(cost) · \(statusLabel(watch.status))"
}

/// Two-up card in the style of Apple's own libraries: rounded photo, name, then price and category.
struct WatchTile: View {
    let store: AppStore
    let watch: Watch
    let zoom: Namespace.ID

    private var detail: String {
        if watch.status != "owned" { return archiveDetail(watch) }
        return [cadWhole(watch.price), watch.category].compactMap { $0 }.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            FramedPhoto(store: store, itemID: watch.id, filename: watch.photos.first, focus: watch.focus(for: watch.photos.first))
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                .overlay(alignment: .topLeading) {
                    if watch.original == false {
                        PhotoTag(text: "Replica").padding(8)
                    }
                }
                .overlay(alignment: .bottomLeading) { PurchaseDateOverlay(watch: watch, watches: store.data?.watches ?? []) }
                .zoomSource(id: watch.id, in: zoom)
            VStack(alignment: .leading, spacing: 2) {
                Text(watch.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2, reservesSpace: true)
                    .multilineTextAlignment(.leading)
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 2)
        }
        .contentShape(Rectangle())
    }
}
