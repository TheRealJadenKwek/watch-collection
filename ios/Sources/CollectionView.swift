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
    @Environment(\.duo) private var duo
    /// Where the tiles are scrolled to, kept when the phone is opened or shut.
    @State private var fold = FoldScroll()
    /// How far down the scrolling page the tiles start, under the masthead and the feature.
    @State private var tilesTop: CGFloat = 0
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
                pages
            }
            .keepsScrollAcrossFolds($fold)
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
                let assets = watches.prefix(32).compactMap { $0.cover?.asset }
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

    /// The page for how the phone is held. A phone, the cover and the inner screen with the crease across scroll as
    /// one page. Held like a book the masthead and the feature stand on the left page and the tiles scroll on the
    /// right; half open on a table they stand above the crease and the tiles scroll below it.
    @ViewBuilder
    private var pages: some View {
        #if os(iOS)
        if duo.isBook || duo.isTableTop {
            CreasePanes {
                fixedPane(watches)
            } second: {
                ScrollView {
                    tileArea(watches)
                        .animation(.easeInOut(duration: 0.2), value: contentKey)
                        .padding(.bottom, 24)
                }
                .navigationTitle("")
                .navigationBarTitleDisplayMode(.inline)
                .atelierProbeScroll("collection")
                .foldScroll($fold)
                // Half open on a table the sync notice is one row held above the tiles, under the crease. It is an
                // inset, not content, so the place kept across folds does not move with it.
                .safeAreaInset(edge: .top, spacing: 0) {
                    if duo.isTableTop {
                        SyncNoticeBar(
                            store: store,
                            compact: true,
                            insets: EdgeInsets(top: 0, leading: WatchTheme.narrowMargin, bottom: WatchTheme.gridGap, trailing: WatchTheme.narrowMargin),
                            openSettings: showSettings
                        )
                        .background(WatchTheme.background)
                    }
                }
            }
            .screenBackground()
        } else {
            scrollingPage
        }
        #else
        scrollingPage
        #endif
    }

    private static let page = "collection-page"

    private var scrollingPage: some View {
        ScrollView {
            // Lazy, not VStack: a LazyVGrid inside an eager VStack re-measures as rows load,
            // which bounced the scroll position back and forth on every drag from the top.
            LazyVStack(alignment: .leading, spacing: 0) {
                let shown = watches
                #if os(iOS)
                Masthead(kicker: "Watch Collection", title: title, subtitle: subtitle)
                    .padding(.horizontal, margin)
                // Silent while sync is healthy; it redraws on its own, never this page.
                SyncNoticeBar(
                    store: store,
                    insets: EdgeInsets(top: 0, leading: margin, bottom: 20, trailing: margin),
                    openSettings: showSettings
                )
                UnderlineTabs(selection: $scope, options: Scope.allCases.map { (value: $0.rawValue, label: $0.rawValue) })
                    .padding(.horizontal, margin)
                    .padding(.bottom, 20)
                #endif

                if let featured = featuredWatch(shown) {
                    featureBlock(featured, aspect: featureAspect)
                        // On a cover screen the photo runs under the status strip to the edge. Its slot is offered
                        // only the width left of the strip, so its height is set here or it would overflow its slot.
                        .runsUnderStatusStrip(duo)
                        .frame(height: coverFeatureHeight)
                        .padding(.bottom, WatchTheme.gridGap)
                        .id("feature-\(contentKey)")
                        .transition(.opacity)
                }

                tileArea(shown)
                    .onGeometryChange(for: CGFloat.self) { $0.frame(in: .named(Self.page)).minY } action: { tilesTop = $0 }
            }
            .animation(.easeInOut(duration: 0.2), value: contentKey)
            .coordinateSpace(.named(Self.page))
            .padding(.top, Platform.isMac ? 4 : 0)
            .padding(.bottom, 24)
        }
        .mastheadTitle(title)
        .atelierProbeScroll("collection")
        .foldScroll($fold, lead: tilesTop)
        .screenBackground()
    }

    /// The tiles in the layout chosen, or the empty state.
    private func tileArea(_ shown: [Watch]) -> some View {
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

    /// The pane that stays put on the inner screen: the masthead, the scope tabs, and the feature filling the rest,
    /// down to the tab bar on a book's left page, down to the crease on a table.
    private func fixedPane(_ shown: [Watch]) -> some View {
        VStack(spacing: 0) {
            Masthead(kicker: "Watch Collection", title: title, subtitle: subtitle)
                .padding(.horizontal, margin)
            // Half open on a table this pane is too short for it: there it heads the tiles (see `pages`).
            if !duo.isTableTop {
                SyncNoticeBar(
                    store: store,
                    insets: EdgeInsets(top: 0, leading: margin, bottom: 20, trailing: margin),
                    openSettings: showSettings
                )
            }
            UnderlineTabs(selection: $scope, options: Scope.allCases.map { (value: $0.rawValue, label: $0.rawValue) })
                .padding(.horizontal, margin)
                .padding(.bottom, 20)
            ZStack {
                if let featured = paneFeature {
                    featureBlock(featured, aspect: nil, kicker: scope == Scope.archive.rawValue ? "From the archive" : "Latest arrival")
                        .id("feature-\(scope)-\(featured.id)")
                        .transition(.opacity)
                } else {
                    WatchPlaceholder()
                        .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(.easeInOut(duration: 0.2), value: scope)
        }
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
            .last { datedSource($0, in: all).purchased != nil && $0.cover != nil }
    }

    /// The feature on the inner screen's fixed pane, in every scope and layout: the newest dated watch with a photo
    /// in the scope shown.
    private var paneFeature: Watch? {
        let inScope = all.filter { watch in
            switch Scope(rawValue: scope) ?? .owned {
            case .owned: watch.status == "owned"
            case .archive: watch.status != "owned"
            case .allTime: true
            }
        }
        return byPurchaseDate(inScope).last { datedSource($0, in: all).purchased != nil && $0.cover != nil }
    }

    /// The feature's shape on a scrolling page: `PhotoShape.feature`, but no taller than 420 points with the crease
    /// across. On a cover screen it runs under the status strip as wide as the window, but only as tall as that shape
    /// across the width left of the strip, so its name and pill are on the first screen.
    private var featureAspect: CGFloat {
        if duo.isAcross { return max(PhotoShape.feature, duo.size.width / 420) }
        if duo.statusStrip > 0, duo.size.width > duo.statusStrip {
            return PhotoShape.feature * duo.size.width / (duo.size.width - duo.statusStrip)
        }
        return PhotoShape.feature
    }

    /// The feature's height on a cover screen: its shape across the width left of the status strip. Nil elsewhere.
    private var coverFeatureHeight: CGFloat? {
        guard duo.posture == .folded, duo.statusStrip > 0, duo.size.width > duo.statusStrip else { return nil }
        return (duo.size.width - duo.statusStrip) / PhotoShape.feature
    }

    /// Edge to edge, the cover in its saved framing, the name set large over a dark fade. With no `aspect` the photo
    /// fills whatever frame it is given.
    /// Its zoom source has its own id, so it never collides with the same watch's tile in the grid.
    private func featureBlock(_ watch: Watch, aspect: CGFloat?, kicker: String = "Latest arrival") -> some View {
        let zoomID = "feature-\(watch.id)"
        // Half open on a table the pane above the crease is short: the words close up so a two-line name still fits.
        let tight = aspect == nil && duo.isTableTop
        return NavigationLink(value: WatchRoute(id: watch.id, zoomID: zoomID)) {
            Group {
                if let aspect {
                    FramedPhoto(
                        store: store,
                        cover: watch.cover,
                        aspect: aspect,
                        // The size the watch's page decodes, so opening it reuses this image.
                        maxPixel: DisplayImageCache.page
                    )
                } else {
                    Color.clear
                        .overlay {
                            RemoteWatchImage(cover: watch.cover, allowsRemoteFetch: !store.isOffline, maxPixel: DisplayImageCache.page)
                        }
                        .clipped()
                        .contentShape(Rectangle())
                }
            }
            .overlay {
                // In the inner screen's fixed pane (a book's left page, a table's top half) the feature is short and
                // the words fill most of it, so the fade starts at its top edge there.
                let short = aspect == nil
                LinearGradient(
                    stops: [
                        .init(color: .black.opacity(short ? 0.25 : 0), location: short ? 0 : 0.5),
                        .init(color: .black.opacity(0.55), location: 1),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .allowsHitTesting(false)
            }
            .overlay(alignment: .bottom) {
                VStack(spacing: tight ? 6 : 12) {
                    Eyebrow(kicker, color: .white)
                    Text(watch.name)
                        .font(AtelierType.display)
                        .tracking(-0.6)
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .minimumScaleFactor(0.7)
                        .multilineTextAlignment(.center)
                    AtelierPill(kind: .quietOverPhoto) { Text("View watch") }
                        .padding(.top, tight ? 0 : 8)
                }
                .padding(.horizontal, 28)
                .padding(.bottom, tight ? 14 : 32)
                // Under a cover screen's status strip the text stays centred in the width left of it.
                .padding(.trailing, duo.statusStrip)
            }
            .zoomSource(id: zoomID, in: zoom)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(kicker), \(watch.name)")
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
                  : Array(repeating: GridItem(.flexible(), spacing: WatchTheme.gridGap, alignment: .top), count: duo.tileColumns),
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
                  : Array(repeating: GridItem(.flexible(), spacing: 2), count: duo.photoColumns), spacing: 2) {
            ForEach(watches) { watch in
                NavigationLink(value: WatchRoute(id: watch.id)) {
                    FramedPhoto(
                        store: store,
                        cover: watch.cover,
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

/// Two-up tile: the cover in the plate shape across the top, then the name, a spec line and the price.
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
            FramedPhoto(store: store, cover: watch.cover)
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
