import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct WishlistScreen: View {
    @Environment(\.openURL) private var openURL
    @ObservedObject var store: AppStore
    let showSettings: () -> Void
    @State private var editingItem: WishlistItem?
    /// The candidate whose pictures are open large (`WishlistPhotoViewer`).
    @State private var viewingItem: WishlistItem?
    @State private var addingItem = false
    @State private var boughtItem: WishlistItem?
    @State private var radarBrand = ""
    @State private var prefilledBrand = ""
    /// Cards with their score breakdown open, kept here so they stay open when a folding iPhone is opened or shut.
    @State private var lensesShown: Set<String> = []
    /// Where the page is scrolled to, kept when a folding iPhone is opened or shut.
    @State private var fold = FoldScroll()
    @Environment(\.sectionIsActive) private var sectionIsActive
    @Environment(\.pageMargin) private var margin
    @Environment(\.duo) private var duo
    @AppStorage("wishlistSort") private var sort = Sort.fit.rawValue
    #if os(macOS)
    /// The candidate a card last asked to delete, and whether its confirmation is up. On the Mac the screen holds the
    /// one "Delete ...?" for every card: with every card built, a confirmation on each card cost time on every frame
    /// of a scroll. Kept after the dialog closes, so its title does not change while it goes.
    @State private var deleting: WishlistItem?
    @State private var confirmsDelete = false
    #endif

    enum Sort: String, CaseIterable { case fit = "Best Fit", lowest = "Lowest Price", highest = "Highest Price" }

    private var ranked: [WishlistItem] {
        Self.ranked(store.data?.wishlist ?? [], scores: store.scores)
    }

    /// Every candidate, in the order the sort menu asks for.
    private var shown: [WishlistItem] {
        switch Sort(rawValue: sort) ?? .fit {
        case .fit: ranked
        case .lowest: Self.byPrice(ranked, highestFirst: false)
        case .highest: Self.byPrice(ranked, highestFirst: true)
        }
    }

    /// The best-fitting candidate, shown large above the rest. Only in Best Fit order: sorted by price, every
    /// candidate is a card in its place.
    private var topPick: WishlistItem? {
        guard (Sort(rawValue: sort) ?? .fit) == .fit, let first = ranked.first, first.status == "considering" else { return nil }
        return first
    }

    /// The cards under the top pick.
    private var cards: [WishlistItem] { topPick == nil ? shown : Array(shown.dropFirst()) }

    /// Considering, then passed, then bought.
    private static func statusRank(_ status: String) -> Int {
        ["considering": 0, "passed": 1, "bought": 2][status] ?? 3
    }

    /// The wishlist's order: considering, then passed, then bought; the best score first; then the lower price.
    /// The Boxes tray lists candidates in the same order.
    static func ranked(_ items: [WishlistItem], scores: [String: WishlistScore]) -> [WishlistItem] {
        items.sorted { left, right in
            let leftStatus = statusRank(left.status)
            let rightStatus = statusRank(right.status)
            if leftStatus != rightStatus { return leftStatus < rightStatus }
            let leftScore = scores[left.id]?.total ?? Int.min
            let rightScore = scores[right.id]?.total ?? Int.min
            if leftScore != rightScore { return leftScore > rightScore }
            return (left.priceExpected ?? .infinity) < (right.priceExpected ?? .infinity)
        }
    }

    /// The same candidates by the price each card shows, lowest or highest first, still within the status groups
    /// (considering, then passed, then bought). Candidates without a price go last either way, and equal prices
    /// keep the order they came in.
    static func byPrice(_ items: [WishlistItem], highestFirst: Bool) -> [WishlistItem] {
        items.enumerated().sorted { left, right in
            let leftStatus = statusRank(left.element.status)
            let rightStatus = statusRank(right.element.status)
            if leftStatus != rightStatus { return leftStatus < rightStatus }
            switch (left.element.wholePrice, right.element.wholePrice) {
            case let (leftPrice?, rightPrice?) where leftPrice != rightPrice:
                return highestFirst ? leftPrice > rightPrice : leftPrice < rightPrice
            case (.some, nil): return true
            case (nil, .some): return false
            default: return left.offset < right.offset
            }
        }
        .map(\.element)
    }

    var body: some View {
        SectionStack {
            ScrollViewReader { proxy in
                RefreshableScreen(store: store) {
                    ScrollView {
                        if duo.isWide {
                            columns { id in
                                withAnimation { proxy.scrollTo("wishlist-\(id)", anchor: .top) }
                            }
                        } else {
                            PageStack {
                                #if os(iOS)
                                Masthead(kicker: "Wishlist", title: "Next Watch", subtitle: subtitle)
                                    .padding(.horizontal, max(margin - WatchTheme.narrowMargin, 0))
                                // Silent while sync is healthy; it redraws on its own, never this page.
                                SyncNoticeBar(store: store, openSettings: showSettings)
                                #endif
                                if ranked.isEmpty {
                                    EmptyCollectionView(title: "Wishlist empty", detail: "Add a candidate to start comparing fit.")
                                        .frame(minHeight: 320)
                                } else {
                                    if total.count > 0 {
                                        WishlistTotalPanel(total: total)
                                            .padding(.bottom, WatchTheme.panelPadding - WatchTheme.gridGap)
                                    }
                                    if let top = topPick {
                                        TopPickView(
                                            store: store,
                                            item: top,
                                            score: store.scores[top.id],
                                            edit: { editingItem = top },
                                            bought: { boughtItem = top },
                                            viewPhotos: { viewingItem = top }
                                        )
                                        .id("wishlist-\(top.id)")
                                        .padding(.bottom, WatchTheme.sectionGap - WatchTheme.gridGap)
                                    }
                                    // One column on the phone; as many as fit on the desktop.
                                    CandidateGrid(items: cards) { item in
                                        WishlistCard(
                                            store: store,
                                            item: item,
                                            score: store.scores[item.id],
                                            edit: { editingItem = item },
                                            viewPhotos: { viewingItem = item },
                                            pass: { Task { await store.passWishlist(id: item.id) } },
                                            bought: { boughtItem = item },
                                            findImage: { findImage(item.id) },
                                            delete: { Task { await store.deleteWishlist(id: item.id) } },
                                            showsLenses: lenses(item.id),
                                            askDelete: askDelete(item)
                                        )
                                        .id("wishlist-\(item.id)")
                                    }
                                }
                                nextMoveSection { id in
                                    withAnimation { proxy.scrollTo("wishlist-\(id)", anchor: .top) }
                                }
                                .padding(.top, WatchTheme.sectionGap - WatchTheme.gridGap)
                                radarStrip
                            }
                            .padding(.horizontal, Platform.isMac ? 24 : WatchTheme.narrowMargin)
                            .padding(.top, Platform.isMac ? 4 : 0)
                            .padding(.bottom, 24)
                            #if WC_PERF_BENCH && os(macOS)
                            // Bench builds only: hands this scroll view to the scroll driver.
                            .background(alignment: .topLeading) { PerfBenchProbe(store: store).frame(width: 1, height: 1) }
                            #endif
                        }
                    }
                    .mastheadTitle("Wishlist")
                    .atelierProbeScroll("wishlist")
                    .foldScroll($fold)
                    .keepsScrollAcrossFolds($fold)
                    .screenBackground()
                }
            }
            #if os(macOS)
            .desktopHeader("Wishlist", subtitle: subtitle) {
                EmptyView()
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
            .sheet(item: $editingItem) { item in
                WishlistDetailScreen(store: store, item: item)
            }
            .sheet(item: $viewingItem) { item in
                WishlistPhotoViewer(store: store, opened: item)
            }
            .sheet(isPresented: $addingItem) {
                WishlistDetailScreen(store: store, item: .newDraft(brand: prefilledBrand), isNew: true)
            }
            .sheet(item: $boughtItem) { item in
                BoughtSheet(store: store, item: item)
            }
            #if os(macOS)
            .confirmationDialog("Delete \(deleting?.name ?? "")?", isPresented: $confirmsDelete, titleVisibility: .visible, presenting: deleting) { item in
                Button("Delete", role: .destructive) { Task { await store.deleteWishlist(id: item.id) } }
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text("The wishlist record and its photos will be removed permanently.")
            }
            // A candidate a sync removed while its confirmation was up takes the confirmation with it, as its card did.
            .onChange(of: store.data?.wishlist.map(\.id) ?? []) { _, ids in
                if confirmsDelete, let id = deleting?.id, !ids.contains(id) { confirmsDelete = false }
            }
            #endif
        }
        .pageAppear()
    }

    /// The inner screen. Held like a book: the candidates in two columns, one per page, the masthead heading the left
    /// one, the top pick first and each column as level as it can be, then the suggestions one per page. With the
    /// crease across the brief asks for two columns; this is a deliberate departure from it, accepted on review: two
    /// columns would leave each card about 310 points wide and truncate its name and buttons, so the candidates and
    /// suggestions run full width there, the top pick with its photo beside its reasons.
    private func columns(scrollTo: @escaping (String) -> Void) -> some View {
        let count = duo.isBook ? duo.cardColumns : 1
        let gap = duo.isBook ? DuoLayout.creaseGap(inset: WatchTheme.narrowMargin) : WatchTheme.gridGap
        let top = topPick
        let rest = cards
        // Roughly in cards: the top pick is about 3.6 tall (its photo is in the tile's 2:3 shape, a fifth taller than
        // the old 4:5), the masthead well under one. Whatever heads the left column goes there first; the cards then
        // fill whichever column is shorter.
        let lead: CGFloat = (top == nil ? 0 : 3.6) + (duo.isBook ? 0.6 : 0) + (duo.isBook && total.count > 0 ? 0.5 : 0)
        let placed = DuoLayout.balance((lead > 0 ? [lead] : []) + rest.map { _ in 1 }, columns: count)
        let restColumns = lead > 0 ? Array(placed.dropFirst()) : placed
        let suggestionColumns = duo.isBook ? count : 1
        return VStack(spacing: 0) {
            #if os(iOS)
            if !duo.isBook {
                Masthead(kicker: "Wishlist", title: "Next Watch", subtitle: subtitle)
                    .padding(.horizontal, max(margin - WatchTheme.narrowMargin, 0))
                    .padding(.bottom, WatchTheme.gridGap)
                SyncNoticeBar(
                    store: store,
                    insets: EdgeInsets(top: 0, leading: 0, bottom: WatchTheme.gridGap, trailing: 0),
                    openSettings: showSettings
                )
            }
            #endif
            if ranked.isEmpty, !duo.isBook {
                EmptyCollectionView(title: "Wishlist empty", detail: "Add a candidate to start comparing fit.")
                    .frame(minHeight: 320)
            }
            if total.count > 0, !duo.isBook {
                WishlistTotalPanel(total: total)
                    .padding(.bottom, WatchTheme.panelPadding)
            }
            CardColumns(columns: count, spacing: WatchTheme.gridGap, gap: gap) {
                #if os(iOS)
                if duo.isBook {
                    Masthead(kicker: "Wishlist", title: "Next Watch", subtitle: subtitle)
                        .padding(.horizontal, max(margin - WatchTheme.narrowMargin, 0))
                        .cardColumn(0, of: count)
                    // Heads the left page under the masthead. The columns are balanced without it: it is not
                    // there on a healthy day, and this screen does not watch the sync status to know.
                    SyncNoticeBar(store: store, openSettings: showSettings)
                        .cardColumn(0, of: count)
                }
                #endif
                if ranked.isEmpty, duo.isBook {
                    EmptyCollectionView(title: "Wishlist empty", detail: "Add a candidate to start comparing fit.")
                        .frame(minHeight: 320)
                        .cardColumn(1, of: count)
                }
                if total.count > 0, duo.isBook {
                    WishlistTotalPanel(total: total)
                        .padding(.bottom, WatchTheme.panelPadding - WatchTheme.gridGap)
                        .cardColumn(0, of: count)
                }
                if let top {
                    TopPickView(
                        store: store,
                        item: top,
                        score: store.scores[top.id],
                        edit: { editingItem = top },
                        bought: { boughtItem = top },
                        viewPhotos: { viewingItem = top }
                    )
                    .id("wishlist-\(top.id)")
                    .cardColumn(0, of: count)
                }
                ForEach(Array(rest.enumerated()), id: \.element.id) { index, item in
                    WishlistCard(
                        store: store,
                        item: item,
                        score: store.scores[item.id],
                        edit: { editingItem = item },
                        viewPhotos: { viewingItem = item },
                        pass: { Task { await store.passWishlist(id: item.id) } },
                        bought: { boughtItem = item },
                        findImage: { findImage(item.id) },
                        delete: { Task { await store.deleteWishlist(id: item.id) } },
                        showsLenses: lenses(item.id)
                    )
                    .id("wishlist-\(item.id)")
                    .cardColumn(restColumns[safe: index] ?? 0, of: count)
                }
            }
            CardColumns(columns: suggestionColumns, spacing: WatchTheme.gridGap, gap: gap) {
                nextMoveSection(scrollTo: scrollTo)
                    .cardColumn(0, of: suggestionColumns)
                radarStrip
                    .cardColumn(1, of: suggestionColumns)
            }
            .padding(.top, WatchTheme.sectionGap)
        }
        .padding(.horizontal, WatchTheme.narrowMargin)
        .padding(.bottom, 24)
    }

    /// How a card asks before deleting its candidate: on the Mac through the screen's one confirmation (`deleting`),
    /// on the phone with its own, which comes from the card.
    private func askDelete(_ item: WishlistItem) -> (() -> Void)? {
        #if os(macOS)
        return {
            deleting = item
            confirmsDelete = true
        }
        #else
        return nil
        #endif
    }

    /// Whether a card's score breakdown is open.
    private func lenses(_ id: String) -> Binding<Bool> {
        Binding {
            lensesShown.contains(id)
        } set: { shown in
            if shown { lensesShown.insert(id) } else { lensesShown.remove(id) }
        }
    }

    private var addButton: some View {
        Button { prefilledBrand = ""; addingItem = true } label: { Image(systemName: "plus") }
            .disabled(store.isOffline)
            .accessibilityLabel("Add candidate")
    }

    /// The same control as the collection's sort menu.
    private var sortMenu: some View {
        Menu {
            Section("Sort By") {
                Picker("Sort By", selection: $sort) {
                    ForEach(Sort.allCases, id: \.self) { Text($0.rawValue).tag($0.rawValue) }
                }
            }
        } label: {
            Image(systemName: "line.3.horizontal.decrease")
        }
        .accessibilityLabel("Sort options")
    }

    /// What the candidates still being considered would cost. The page has no status filter; passed and bought
    /// candidates are listed under the rest but are not part of the figure.
    private var total: WishlistTotal { WishlistTotal(store.data?.wishlist ?? []) }

    private var subtitle: String {
        let count = ranked.filter { $0.status == "considering" }.count
        let order = switch Sort(rawValue: sort) ?? .fit {
        case .fit: "ranked for your collection"
        case .lowest: "lowest price first"
        case .highest: "highest price first"
        }
        return "\(count) candidate\(count == 1 ? "" : "s"), \(order)"
    }

    private var radarStrip: some View {
        SectionCard("On the Radar", systemImage: "scope", color: .pink, kicker: "Brands to explore") {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(store.data?.brandWatchlist ?? [], id: \.brand) { entry in
                        Menu {
                            Button("Add a \(entry.brand) model") {
                                prefilledBrand = entry.brand
                                addingItem = true
                            }
                            Button("Remove from radar", role: .destructive) {
                                Task { await store.deleteRadarBrand(entry.brand) }
                            }
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.brand)
                                    .font(.subheadline.weight(.bold))
                                    .foregroundStyle(WatchTheme.ink)
                                Text(radarStatus(entry.brand))
                                    .font(.caption)
                                    .foregroundStyle(WatchTheme.muted)
                            }
                            .padding(.horizontal, 18)
                            .padding(.vertical, 9)
                            .background(WatchTheme.fill, in: Capsule())
                        }
                        #if os(macOS)
                        .menuStyle(.button)
                        .buttonStyle(.plain)
                        .menuIndicator(.hidden)
                        .fixedSize()
                        #endif
                    }
                }
            }
            HStack {
                TextField("Add a brand", text: $radarBrand)
                    .disabled(!sectionIsActive)
                    .textInputAutocapitalization(.words)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(WatchTheme.raised, in: Capsule())
                Button("Add") {
                    let brand = radarBrand.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !brand.isEmpty else { return }
                    radarBrand = ""
                    Task { await store.addRadarBrand(brand) }
                }
                .quietButton()
                .controlSize(.small)
                .disabled(store.isOffline)
            }
        }
    }

    private func nextMoveSection(scrollTo: @escaping (String) -> Void) -> some View {
        SectionCard("Next Move", systemImage: "sparkles", color: .purple, kicker: "Collection gaps") {
            Text(saturationLine)
                .font(AtelierType.caption)
                .foregroundStyle(WatchTheme.muted)
            if let suggestions = store.suggestions?.suggestions, !suggestions.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 10) {
                        ForEach(Array(suggestions.enumerated()), id: \.offset) { _, suggestion in
                            NextMoveSuggestionCard(
                                suggestion: suggestion,
                                wishlist: store.data?.wishlist ?? [],
                                scrollTo: scrollTo
                            )
                            .frame(width: 286)
                        }
                    }
                    .scrollTargetLayout()
                }
                .scrollTargetBehavior(.viewAligned)
                .padding(.horizontal, -WatchTheme.panelPadding)
                .contentMargins(.horizontal, WatchTheme.panelPadding, for: .scrollContent)
            } else {
                Text("No eligible category gaps. Adjust suggestion categories in Settings.")
                    .font(.subheadline)
                    .foregroundStyle(Color.secondary)
            }
        }
    }

    private var saturationLine: String {
        guard let saturated = store.suggestions?.saturated else { return "Checking collection coverage…" }
        let owned = (store.data?.watches ?? []).filter { $0.status == "owned" }
        let categoryCounts = Dictionary(grouping: owned.compactMap { watch in watch.category.map { ($0, watch) } }, by: { $0.0 })
        let dialCounts = Dictionary(grouping: owned.compactMap { watch in watch.dialColor.map { ($0, watch) } }, by: { $0.0 })
        let brandEligible = owned.filter { $0.original != false && ($0.brand ?? "") != "Generic" }
        let brandCounts = Dictionary(grouping: brandEligible, by: { $0.brand ?? $0.name.components(separatedBy: " ").first ?? "Unknown" })
        let parts = saturated.categories.map { "\($0) ×\(categoryCounts[$0]?.count ?? 0)" }
            + saturated.dials.map { "\($0) dials ×\(dialCounts[$0]?.count ?? 0)" }
            + saturated.brands.map { "\($0) brand ×\(brandCounts[$0]?.count ?? 0)" }
        return parts.isEmpty ? "No saturated areas yet. The collection is wide open." : "Well covered: " + parts.joined(separator: " · ")
    }

    private func radarStatus(_ brand: String) -> String {
        let real = (store.data?.watches ?? []).filter { $0.original != false && ($0.brand ?? "") != "Generic" }
        if real.contains(where: { $0.status == "owned" && $0.brand == brand }) { return "owned" }
        if real.contains(where: { $0.brand == brand }) { return "explored before" }
        return "new brand"
    }

    private func findImage(_ id: String) {
        Task {
            if let url = await store.findWishlistImage(id: id) { openURL(url) }
        }
    }
}

struct NextMoveSuggestionCard: View {
    let suggestion: NextMoveSuggestion
    let wishlist: [WishlistItem]
    let scrollTo: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Text(suggestion.headline)
                    .font(AtelierType.cardTitle)
                    .foregroundStyle(WatchTheme.ink)
                    .frame(maxWidth: .infinity, alignment: .leading)
                VStack(spacing: 0) {
                    Text("\(suggestion.score)")
                        .font(.figure(.title2))
                        .foregroundStyle(WatchTheme.accent)
                    Text("/ 9")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(WatchTheme.muted)
                }
            }
            if let brands = suggestion.brands, !brands.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Eyebrow("Brands to explore")
                    ChipFlowLayout(spacing: 5) {
                        ForEach(brands, id: \.name) { brand in
                            CapsuleChip(
                                text: "\(brand.name) · \(brand.status)",
                                color: brand.status == "radar" ? WatchTheme.accent : WatchTheme.muted
                            )
                            .accessibilityLabel("\(brand.name), \(brand.status)")
                        }
                    }
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(suggestion.reasons.enumerated()), id: \.offset) { _, reason in
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Circle().fill(WatchTheme.muted).frame(width: 5, height: 5)
                        Text(reason)
                            .font(.caption)
                            .foregroundStyle(WatchTheme.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            if !suggestion.wishlistMatches.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    Eyebrow("Your candidates")
                    ForEach(suggestion.wishlistMatches, id: \.self) { id in
                        Button {
                            scrollTo(id)
                        } label: {
                            Label(wishlist.first(where: { $0.id == id })?.name ?? id, systemImage: "arrow.down")
                                .font(.caption.weight(.semibold))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(WatchTheme.accent)
                    }
                }
            }
        }
        .padding(16)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(WatchTheme.raised)
    }
}

/// The wishlist page's stack. Lazy on the phone, where it builds what scrolls into view. On the Mac every part of the
/// page is built once instead: there a lazy stack built each row of cards as it scrolled in, about 25 ms a card, and
/// missed frames all the way down the page.
private struct PageStack<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        #if os(macOS)
        VStack(spacing: WatchTheme.gridGap) { content }
        #else
        LazyVStack(spacing: WatchTheme.gridGap) { content }
        #endif
    }
}

/// The cards under the top pick: one column on the phone, in a lazy grid; as many as fit on the desktop, every card
/// built once (`AdaptiveCardGrid`, laid out as the lazy grid with an adaptive column of 380 laid them out).
private struct CandidateGrid<Card: View>: View {
    let items: [WishlistItem]
    @ViewBuilder let card: (WishlistItem) -> Card
    #if os(macOS)
    /// How many cards are built yet. Built in one go, the cards stalled the window for over a second (36 of them)
    /// when the page was first made, so the first rows come at once and the rest a row at a time.
    @State private var built = 4
    /// Whether the cards past the first screen have started coming (after `firstWait`, once per page).
    @State private var started = false
    /// Cards come only while the wishlist is the section on screen, so opening the app on another section, or a
    /// sync while the wishlist is hidden, builds none of them.
    @Environment(\.sectionIsActive) private var sectionIsActive
    /// Cards built straight away, more than the first screen shows under the top pick: whole rows for one, two,
    /// three or six columns.
    static var firstScreen: Int { 6 }
    /// How long the page waits, once its first screen is built, before the cards below it start: the window
    /// opening, or the first switch to the wishlist, draws its first frames with only those cards to update.
    static var firstWait: Duration { .milliseconds(500) }

    private struct BuildID: Hashable {
        let count: Int
        let active: Bool
    }
    #endif

    var body: some View {
        #if os(macOS)
        AdaptiveCardGrid(minimum: 380, spacing: WatchTheme.gridGap) {
            ForEach(items.prefix(built)) { card($0) }
        }
        // A scroll moves the grid as one piece. Without the group every card in it was moved on every frame, which
        // with every card built took most of a frame.
        .geometryGroup()
        // Cards not built yet come a row at a time, also when a sync or a restore brings many at once after the page
        // was made. A count that changes restarts this from where it got to; leaving the section pauses it.
        .task(id: BuildID(count: items.count, active: sectionIsActive)) {
            guard sectionIsActive else { return }
            while built < items.count {
                if !started, built >= Self.firstScreen {
                    guard (try? await Task.sleep(for: Self.firstWait)) != nil else { return }
                    started = true
                }
                // A frame or so between rows, so each row is its own short update.
                guard (try? await Task.sleep(for: .milliseconds(16))) != nil else { return }
                built += 2
            }
        }
        #else
        LazyVGrid(columns: [GridItem(.flexible(), alignment: .top)], spacing: WatchTheme.gridGap) {
            ForEach(items) { card($0) }
        }
        #endif
    }
}

/// A grid laid out as `LazyVGrid` lays out one `GridItem(.adaptive(minimum:), spacing:, alignment: .top)`, with every
/// card built at once: as many equal columns at least `minimum` wide as fit, `spacing` between columns and between
/// rows, each row as tall as its tallest card, and each card at the top of its cell, centred across it.
struct AdaptiveCardGrid: SwiftUI.Layout {
    var minimum: CGFloat
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        // An unlimited width (a scroll view along it) is laid out at one column, as the lazy grid did, not at infinity.
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? minimum
        return CGSize(width: width, height: grid(width: width, subviews: subviews).height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let grid = grid(width: bounds.width, subviews: subviews)
        // Each card is offered its column's width, as it was when it was measured.
        let cell = ProposedViewSize(width: grid.column, height: nil)
        for (subview, frame) in zip(subviews, grid.frames) {
            subview.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY), proposal: cell)
        }
    }

    /// The columns that fit across `width`: one, and one more for each further `minimum` and `spacing`.
    func columns(in width: CGFloat) -> Int {
        guard width.isFinite, width > 0 else { return 1 }
        return max(1, Int(((width + spacing) / (minimum + spacing)).rounded(.down)))
    }

    /// Each card's frame, the width of a column, and the height of the whole grid.
    func grid(width: CGFloat, subviews: Subviews) -> (frames: [CGRect], column: CGFloat, height: CGFloat) {
        let count = columns(in: width)
        let column = max(0, (width - spacing * CGFloat(count - 1)) / CGFloat(count))
        let sizes = subviews.map { $0.sizeThatFits(ProposedViewSize(width: column, height: nil)) }
        var frames: [CGRect] = []
        var top: CGFloat = 0
        for start in stride(from: 0, to: sizes.count, by: count) {
            let row = sizes[start..<min(start + count, sizes.count)]
            for (index, size) in row.enumerated() {
                let left = CGFloat(index) * (column + spacing) + (column - size.width) / 2
                frames.append(CGRect(x: left, y: top, width: size.width, height: size.height))
            }
            top += (row.map(\.height).max() ?? 0) + spacing
        }
        return (frames, column, max(0, top - spacing))
    }
}

struct WishlistCard: View {
    @ObservedObject var store: AppStore
    let item: WishlistItem
    let score: WishlistScore?
    let edit: () -> Void
    /// Opens the candidate's pictures large.
    let viewPhotos: () -> Void
    let pass: () -> Void
    let bought: () -> Void
    let findImage: () -> Void
    let delete: () -> Void
    @Binding var showsLenses: Bool
    /// Asks the screen to confirm deleting this candidate, where the screen holds the confirmation (the Mac). Without
    /// it the card asks itself, and calls `delete` once confirmed.
    var askDelete: (() -> Void)? = nil
    @State private var confirmDelete = false

    /// Width / height of the wishlist thumbnail: the tile's own shape, like every other card picture, so a render
    /// fills it strap to strap. The framing editor frames at this ratio, the top pick's (`PhotoShape.plate`).
    static let photoAspect: CGFloat = PhotoShape.plate

    private let lensOrder = ["category", "brand", "price", "dial", "size", "material"]
    /// Category and diameter, as "Dive, 40 mm".
    private var detailLine: String {
        [item.category, item.diameter.map { "\(compactNumber($0)) mm" }]
            .compactMap { $0 }
            .joined(separator: ", ")
    }

    var body: some View {
        let cover = item.cover
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 14) {
                // The render where there is one (a little larger than a photo thumbnail is decoded, so the dial stays
                // sharp), else the photo.
                Button(action: viewPhotos) {
                    RemoteWatchImage(cover: cover, allowsRemoteFetch: !store.isOffline, maxPixel: cover?.isRender == true ? DisplayImageCache.thumb : DisplayImageCache.icon)
                        .frame(width: 80, height: 120)
                        .clipped()
                }
                .buttonStyle(.plain)
                .disabled(cover == nil)
                .help("View larger")
                .accessibilityLabel("Pictures of \(item.name)")
                VStack(alignment: .leading, spacing: 5) {
                    Text(item.name)
                        .font(AtelierType.cardTitle)
                        .foregroundStyle(WatchTheme.ink)
                        .lineLimit(3)
                    if !detailLine.isEmpty {
                        Text(detailLine)
                            .font(AtelierType.detail)
                            .foregroundStyle(WatchTheme.muted)
                            .lineLimit(1)
                    }
                    WishlistPrice(item: item)
                        .padding(.top, 3)
                    if let wrist = store.data?.settings.wrist,
                       let fit = fitInfo(for: item.diameter, lugToLug: item.lugToLug, wrist: wrist) {
                        FitIndicator(info: fit)
                            .padding(.top, 2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                ScoreRing(score: score?.total, maximum: score?.max ?? 14)
            }
            .padding(WatchTheme.panelPadding)

            lensStrip
                .padding(.horizontal, WatchTheme.panelPadding)
                .padding(.bottom, showsLenses ? 4 : 14)

            if showsLenses {
                VStack(spacing: 0) {
                    ForEach(lensOrder, id: \.self) { name in
                        let lens = score?.lenses[name]
                        HStack(alignment: .firstTextBaseline) {
                            Text(name.capitalized)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(WatchTheme.ink)
                                .frame(width: 62, alignment: .leading)
                            Text(lens?.reason ?? "Waiting for score")
                                .font(.caption)
                                .foregroundStyle(WatchTheme.muted)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text(lens.map { $0.score >= 0 ? "+\($0.score)" : "\($0.score)" } ?? "–")
                                .font(.caption.weight(.bold).monospacedDigit())
                                .foregroundStyle((lens?.score ?? 0) > 0 ? WatchTheme.accent : WatchTheme.muted)
                        }
                        .padding(.vertical, 6)
                    }
                }
                .padding(.horizontal, WatchTheme.panelPadding)
                .padding(.bottom, 8)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            Hairline().padding(.horizontal, WatchTheme.panelPadding)

            // "Try in my box" is a pill where the row has room for it (the Mac, wide windows), otherwise an item in
            // the ellipsis menu. Where even that does not fit (large text on a small phone), Edit and the menu move
            // to a second line.
            ViewThatFits(in: .horizontal) {
                actionRow(tryPill: true)
                actionRow(tryPill: false)
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        statusButtons
                        Spacer(minLength: 0)
                    }
                    HStack(spacing: 8) {
                        Spacer(minLength: 0)
                        editButtons(tryPill: false)
                    }
                }
            }
            .controlSize(.small)
            .padding(.horizontal, WatchTheme.panelPadding)
            .padding(.vertical, 14)
        }
        .background(WatchTheme.card)
        .opacity(item.status == "passed" ? 0.55 : 1)
        // Right-click on the Mac, a long press on the phone: the card's actions, Delete among them.
        .contextMenu {
            Button { store.openBoxes(.tryOn(item.id)) } label: { Label("Try in my box", systemImage: "square.grid.3x2") }
            Button(action: edit) { Label("Edit", systemImage: "pencil") }
            Divider()
            deleteButton
        }
        .modifier(CardDeleteConfirmation(name: item.name, isPresented: $confirmDelete, delete: delete, attached: askDelete == nil))
    }

    private var deleteButton: some View {
        Button(role: .destructive) {
            if let askDelete { askDelete() } else { confirmDelete = true }
        } label: {
            Label("Delete from Wishlist", systemImage: "trash")
        }
    }

    private func actionRow(tryPill: Bool) -> some View {
        HStack(spacing: 8) {
            statusButtons
            Spacer(minLength: 0)
            editButtons(tryPill: tryPill)
        }
    }

    /// Bought It and Pass, or the status once decided. They need the hub, so they wait while offline.
    @ViewBuilder
    private var statusButtons: some View {
        Group {
            if item.status == "considering" {
                Button("Bought It", action: bought)
                    .prominentButton()
                Button("Pass", action: pass)
                    .quietButton()
            } else {
                CapsuleChip(text: item.status.capitalized)
            }
        }
        .disabled(store.isOffline)
    }

    /// "Try in my box" (a pill, or an item in the menu), Edit and the menu. A trial stays on this device, so trying
    /// works offline; the rest waits for the hub.
    @ViewBuilder
    private func editButtons(tryPill: Bool) -> some View {
        if tryPill {
            Button("Try in my box") { store.openBoxes(.tryOn(item.id)) }
                .quietButton()
                .fixedSize()
        }
        Button("Edit", action: edit)
            .quietButton()
            .disabled(store.isOffline)
        Menu {
            if !tryPill {
                Button { store.openBoxes(.tryOn(item.id)) } label: { Label("Try in my box", systemImage: "square.grid.3x2") }
            }
            Button(action: findImage) { Label("Find Image Online", systemImage: "photo.badge.magnifyingglass") }
                .disabled(store.isOffline)
            Divider()
            deleteButton
        } label: {
            Image(systemName: "ellipsis")
                .font(.body.weight(.bold))
                .foregroundStyle(WatchTheme.ink)
                .frame(width: 34, height: 34)
                .background(WatchTheme.fill, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("More")
    }

    /// One compact segment per lens; tap to expand the reasons.
    private var lensStrip: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) { showsLenses.toggle() }
        } label: {
            HStack(spacing: 6) {
                ForEach(lensOrder, id: \.self) { name in
                    let value = score?.lenses[name]?.score ?? 0
                    VStack(spacing: 4) {
                        Rectangle()
                            .fill(value > 0 ? WatchTheme.accent.opacity(min(1, 0.45 + Double(value) * 0.18)) : WatchTheme.raised)
                            .frame(height: 4)
                        Text(name.capitalized)
                            .font(.system(size: 10, weight: .medium))
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                            .foregroundStyle(value > 0 ? WatchTheme.ink : WatchTheme.muted)
                    }
                }
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(WatchTheme.muted)
                    .rotationEffect(.degrees(showsLenses ? 180 : 0))
                    .padding(.leading, 2)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(showsLenses ? "Hide score breakdown" : "Show score breakdown")
    }
}

/// A card's own "Delete ...?" confirmation, where the screen does not hold one for every card
/// (`WishlistCard.askDelete`).
private struct CardDeleteConfirmation: ViewModifier {
    let name: String
    @Binding var isPresented: Bool
    let delete: () -> Void
    let attached: Bool

    func body(content: Content) -> some View {
        if attached {
            content.confirmationDialog("Delete \(name)?", isPresented: $isPresented, titleVisibility: .visible) {
                Button("Delete", role: .destructive, action: delete)
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The wishlist record and its photos will be removed permanently.")
            }
        } else {
            content
        }
    }
}

/// The highest-scoring candidate, presented large.
struct TopPickView: View {
    @ObservedObject var store: AppStore
    let item: WishlistItem
    let score: WishlistScore?
    let edit: () -> Void
    let bought: () -> Void
    /// Opens the candidate's pictures large.
    let viewPhotos: () -> Void
    @Environment(\.duo) private var duo

    private var highlights: [String] {
        ["category", "brand", "price", "dial", "size", "material"].compactMap { name in
            guard let lens = score?.lenses[name], lens.score > 0 else { return nil }
            return lens.reason
        }
    }

    var body: some View {
        if Platform.isMac || duo.isAcross {
            // Desktop, and a folding iPhone's inner screen with the crease across: photo beside the reasons, so the
            // card doesn't fill the whole window.
            HStack(alignment: .center, spacing: 28) {
                // The inner screen is narrower than a desktop window: a smaller photo leaves the buttons their room.
                photo.frame(width: Platform.isMac ? 340 : 280)
                VStack(alignment: .leading, spacing: 16) { details }
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            VStack(alignment: .leading, spacing: 16) {
                photo
                details
            }
        }
    }

    private var photo: some View {
            Button(action: viewPhotos) {
                FramedPhoto(store: store, cover: item.cover, aspect: PhotoShape.plate, maxPixel: DisplayImageCache.page)
                .overlay(alignment: .topLeading) {
                    PhotoTag(text: "Top Pick").padding(14)
                }
                .overlay(alignment: .topTrailing) {
                    ScoreRing(score: score?.total, maximum: score?.max ?? 14)
                        .padding(8)
                        .background(WatchTheme.card, in: Circle())
                        .padding(12)
                }
            }
            .buttonStyle(.plain)
            .disabled(!item.hasPictures)
            .help("View larger")
            .accessibilityLabel("Pictures of \(item.name)")
    }

    @ViewBuilder
    private var details: some View {
            VStack(alignment: .leading, spacing: 8) {
                Eyebrow(item.brand.isEmpty ? "Top pick" : item.brand)
                Text(item.name)
                    .font(AtelierType.heading)
                    .tracking(-0.4)
                    .foregroundStyle(WatchTheme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                WishlistPrice(item: item, style: .title, sourceLines: 3)
                    .padding(.top, 2)
            }
            if !highlights.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(highlights.prefix(4), id: \.self) { reason in
                        HStack(alignment: .firstTextBaseline, spacing: 9) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(WatchTheme.accent)
                            Text(reason)
                                .font(AtelierType.detail)
                                .foregroundStyle(WatchTheme.ink)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    hubButtons
                    tryInBox
                    Spacer(minLength: 0)
                }
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 12) {
                        hubButtons
                    }
                    tryInBox
                }
            }
            .padding(.top, 4)
    }

    /// Bought It and Details need the hub, so they wait while offline; a trial stays on this device, so "Try in my
    /// box" does not.
    @ViewBuilder
    private var hubButtons: some View {
        Group {
            Button("Bought It", action: bought)
                .prominentButton()
            Button("Details", action: edit)
                .quietButton()
        }
        .disabled(store.isOffline)
    }

    private var tryInBox: some View {
        Button("Try in my box") { store.openBoxes(.tryOn(item.id)) }
            .quietButton()
            .fixedSize()
    }
}

struct ScoreRing: View {
    let score: Int?
    let maximum: Int

    private var fraction: Double {
        guard let score, maximum > 0 else { return 0 }
        return min(max(Double(score) / Double(maximum), 0), 1)
    }

    var body: some View {
        ZStack {
            Circle().stroke(WatchTheme.separator, lineWidth: 6)
            Circle()
                .trim(from: 0, to: fraction)
                .stroke(WatchTheme.accent, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: -2) {
                Text(score.map(String.init) ?? "–")
                    .font(.figure(.headline))
                    .foregroundStyle(WatchTheme.ink)
                Text("/\(maximum)")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(WatchTheme.muted)
            }
        }
        .frame(width: 52, height: 52)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Score \(score ?? 0) of \(maximum)")
    }
}

struct WishlistDetailScreen: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: AppStore
    let isNew: Bool
    @State private var draft: WishlistItem
    @State private var baseline: WishlistItem
    @State private var photoItem: PhotosPickerItem?
    @State private var selectedPhotoIndex = 0
    @State private var framingTarget: PhotoFramingTarget?
    @State private var isSaving = false
    @State private var confirmDelete = false

    init(store: AppStore, item: WishlistItem, isNew: Bool = false) {
        self.store = store
        self.isNew = isNew
        _draft = State(initialValue: item)
        _baseline = State(initialValue: item)
    }

    var body: some View {
        NavigationStack {
            Form {
                Group {
                    photoSection
                    Section("Candidate") {
                        TextField("Name", text: $draft.name)
                        TextField("Brand", text: $draft.brand)
                        Picker("Category", selection: optionalSelectionBinding($draft.category)) {
                            Text("Unset").tag("")
                            ForEach(store.data?.categories ?? [], id: \.self) { Text($0).tag($0) }
                        }
                        NumberField("Expected price (CAD)", value: $draft.priceExpected)
                        TextField("Quote text", text: $draft.priceNote)
                        TextField("Added (YYYY-MM)", text: $draft.added)
                        Picker("Status", selection: $draft.status) {
                            Text("Considering").tag("considering")
                            Text("Passed").tag("passed")
                            Text("Bought").tag("bought")
                        }
                    }
                    Section("Variety & fit") {
                        Picker("Dial colour", selection: optionalSelectionBinding($draft.dialColor)) {
                            Text("Unset").tag("")
                            ForEach(store.data?.dialColors ?? [], id: \.self) { Text($0).tag($0) }
                        }
                        Picker("Case material", selection: optionalSelectionBinding($draft.material)) {
                            Text("Unset").tag("")
                            ForEach(store.data?.materials ?? [], id: \.self) { Text($0).tag($0) }
                        }
                        NumberField("Diameter (mm)", value: $draft.diameter)
                        NumberField("Lug-to-lug (mm)", value: $draft.lugToLug)
                        if let wrist = store.data?.settings.wrist,
                           let fit = fitInfo(for: draft.diameter, lugToLug: draft.lugToLug, wrist: wrist) {
                            HStack { Text("Fit"); Spacer(); FitChip(info: fit) }
                        }
                    }
                    if !isNew && baseline.status != "bought" {
                        Section {
                            Button("Try in my box") {
                                let id = draft.id
                                dismiss()
                                store.openBoxes(.tryOn(id))
                            }
                            .disabled(draft != baseline)
                        } footer: {
                            if draft != baseline { Text("Save the changes first.") }
                        }
                    }
                    Section("Notes") {
                        TextField("Notes", text: $draft.notes, axis: .vertical).lineLimit(4...10)
                        if !isNew {
                            Button("Delete candidate", role: .destructive) { confirmDelete = true }
                                .disabled(store.isOffline)
                        }
                    }
                }
            }
            .navigationTitle(isNew ? "New Candidate" : "Edit Candidate")
            .navigationBarTitleDisplayMode(.inline)
            .storeErrorAlert(store)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(role: .close) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if isSaving {
                        ProgressView()
                    } else {
                        Button(role: .confirm) { save() }
                            .disabled(store.isOffline || draft.name.isEmpty || draft.brand.isEmpty)
                    }
                }
            }
            .onChange(of: photoItem) { _, item in
                guard let item else { return }
                Task { await importPhoto(item) }
            }
            .confirmationDialog("Delete \(draft.name)?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete candidate", role: .destructive) {
                    Task { await store.deleteWishlist(id: draft.id); dismiss() }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The wishlist record and its photos will be removed permanently.")
            }
        }
        .desktopSheet()
    }

    private var photoSection: some View {
        Section("Gallery") {
            // The render first, as the card shows the watch, then the photos. Set cover, Adjust and Delete act on a
            // photo, so the render's page has none of them.
            let pages = CoverPages(cover: isNew ? nil : draft.cover, photos: draft.photos)
            if pages.isEmpty {
                WatchPlaceholder().frame(height: 210)
            } else {
                PhotoPager(selection: $selectedPhotoIndex, count: pages.count) { index in
                    Group {
                        if pages.isRender(index) {
                            RemoteWatchImage(cover: pages.render, allowsRemoteFetch: !store.isOffline)
                        } else if let filename = pages.photo(index) {
                            RemoteWatchImage(
                                asset: store.photoAsset(itemID: draft.id, filename: filename, wishlist: true),
                                allowsRemoteFetch: !store.isOffline,
                                focus: draft.focus(for: filename)
                            )
                        }
                    }
                    .frame(height: 230)
                    .clipped()
                }
                .frame(height: 240)
                if pages.isRender(selectedPhotoIndex) {
                    Text(pages.photos.isEmpty ? "Rendered picture." : "Rendered picture. Your photos come next.")
                        .font(AtelierType.caption)
                        .foregroundStyle(WatchTheme.muted)
                } else if let filename = pages.photo(selectedPhotoIndex) {
                    HStack {
                        Button("Set cover") {
                            Task { await store.setCover(itemID: draft.id, filename: filename, wishlist: true); reloadDraft(); selectedPhotoIndex = pages.firstPhotoPage }
                        }
                        Spacer()
                        Button("Adjust") { framingTarget = PhotoFramingTarget(filename: filename) }
                        Spacer()
                        Button("Delete photo", role: .destructive) {
                            Task { await store.deletePhoto(itemID: draft.id, filename: filename, wishlist: true); reloadDraft(); selectedPhotoIndex = draft.photos.isEmpty ? 0 : pages.firstPhotoPage }
                        }
                    }
                    .buttonStyle(.borderless)
                    .sheet(item: $framingTarget) { target in
                        PhotoFramingSheet(
                            asset: store.photoAsset(itemID: draft.id, filename: target.filename, wishlist: true),
                            allowsRemoteFetch: !store.isOffline,
                            initialFocus: draft.focus(for: target.filename),
                            aspect: WishlistCard.photoAspect,
                            previews: [("Gallery", 1.55)]
                        ) { focus in
                            await store.setPhotoFocus(itemID: draft.id, filename: target.filename, wishlist: true, focus: focus)
                            draft.photoFocus = store.data?.wishlist.first(where: { $0.id == draft.id })?.photoFocus
                        }
                    }
                }
            }
            PhotosPicker(selection: $photoItem, matching: .images) {
                Label("Add from Photos", systemImage: "photo.on.rectangle")
            }
            .disabled(store.isOffline || isNew)
            if isNew { Text("Save first, then reopen to add a photo.").font(.caption).foregroundStyle(Color.secondary) }
        }
    }

    private func save() {
        isSaving = true
        Task {
            if await store.saveWishlist(draft, isNew: isNew, baseline: baseline) != nil { dismiss() }
            isSaving = false
        }
    }

    private func importPhoto(_ item: PhotosPickerItem) async {
        defer { photoItem = nil }
        guard let data = try? await item.loadTransferable(type: Data.self) else {
            store.notice = "Couldn't load that photo."
            return
        }
        let type = item.supportedContentTypes.first
        await store.uploadPhoto(
            data: data,
            filename: "photo-\(UUID().uuidString).\(type?.preferredFilenameExtension ?? "jpg")",
            mimeType: type?.preferredMIMEType ?? "image/jpeg",
            itemID: draft.id,
            wishlist: true
        )
        reloadDraft()
    }

    /// Pull only what photo actions change, so unsaved form edits survive.
    private func reloadDraft() {
        guard let updated = store.data?.wishlist.first(where: { $0.id == draft.id }) else { return }
        draft.photos = updated.photos
        draft.photoFocus = updated.photoFocus
        baseline.photos = updated.photos
        baseline.photoFocus = updated.photoFocus
    }
}

struct BoughtSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: AppStore
    let item: WishlistItem
    @State private var price: Double
    @State private var purchased: String?

    init(store: AppStore, item: WishlistItem) {
        self.store = store
        self.item = item
        _price = State(initialValue: item.priceExpected ?? 0)
        _purchased = State(initialValue: currentPurchaseMonth())
    }

    var body: some View {
        NavigationStack {
            Form {
                Group {
                    Section(item.name) {
                        NumberField("Final price paid (CAD)", value: $price)
                        MonthYearPicker(value: $purchased, allowsUnknown: false)
                    }
                }
            }
            .navigationTitle("Mark Bought")
            .navigationBarTitleDisplayMode(.inline)
            .storeErrorAlert(store)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(role: .cancel) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(role: .confirm) {
                        guard let purchased else { return }
                        Task { await store.markBought(id: item.id, price: price, purchased: purchased); dismiss() }
                    }
                    .disabled(store.isOffline || price < 0 || purchaseMonthParts(purchased) == nil)
                }
            }
        }
        .desktopSheet()
    }
}

private extension WishlistItem {
    static func newDraft(brand: String) -> WishlistItem {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM"
        return WishlistItem(
            id: "new",
            name: "",
            brand: brand,
            category: nil,
            priceExpected: nil,
            priceNote: "",
            notes: "",
            status: "considering",
            added: formatter.string(from: Date()),
            dialColor: nil,
            diameter: nil,
            lugToLug: nil,
            material: nil,
            photos: []
        )
    }
}
