import SwiftUI

/// The Search tab: every watch owned, archived or on the wishlist, found by name,
/// brand, category or story. With no query it lists brands to browse.
struct SearchScreen: View {
    @ObservedObject var store: AppStore
    @State private var query = ""
    @State private var editingItem: WishlistItem?
    @Environment(\.sectionIsActive) private var sectionIsActive
    @Environment(\.pageMargin) private var margin
    @Environment(\.duo) private var duo

    /// Two columns, one per page, on a folding iPhone held like a book; one everywhere else.
    private var columns: Int { duo.isBook ? 2 : 1 }
    private var columnGap: CGFloat { DuoLayout.creaseGap(inset: margin) }

    private var trimmed: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var watches: [Watch] { store.data?.watches ?? [] }
    private var wishlist: [WishlistItem] { store.data?.wishlist ?? [] }

    private func matches(_ fields: [String?]) -> Bool {
        fields.compactMap { $0 }.joined(separator: " ").localizedCaseInsensitiveContains(trimmed)
    }

    private var foundWatches: [Watch] {
        watches
            .filter { matches([$0.name, $0.brand, $0.category, $0.dialColor, $0.material, $0.story, $0.statusNote]) }
            .sorted { $0.price > $1.price }
    }

    private var foundWishlist: [WishlistItem] {
        wishlist.filter { matches([$0.name, $0.brand, $0.category, $0.dialColor, $0.material, $0.notes]) }
    }

    /// Brands across the collection and wishlist, most represented first.
    private var brands: [(name: String, count: Int)] {
        let names = watches.compactMap(\.brand) + wishlist.map(\.brand)
        let counts = Dictionary(grouping: names.filter { !$0.isEmpty }, by: { $0 }).mapValues(\.count)
        return counts.map { ($0.key, $0.value) }.sorted {
            $0.count != $1.count ? $0.count > $1.count : $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    var body: some View {
        SectionStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: WatchTheme.sectionGap) {
                    if trimmed.isEmpty {
                        #if os(iOS)
                        Group {
                            if columns > 1 {
                                // Held like a book the masthead heads the left page.
                                CardColumns(columns: columns, spacing: 0, gap: columnGap) {
                                    Masthead(kicker: "Search", title: "Find a watch")
                                        .cardColumn(0, of: columns)
                                }
                            } else {
                                Masthead(kicker: "Search", title: "Find a watch")
                            }
                        }
                        .padding(.bottom, -WatchTheme.sectionGap + 8)
                        #endif
                        GroupedSection("Browse by Brand", columns: columns, gap: columnGap) {
                            ForEach(brands, id: \.name) { brand in
                                Button { query = brand.name } label: {
                                    HStack(spacing: 12) {
                                        Image(systemName: "magnifyingglass")
                                            .foregroundStyle(WatchTheme.muted)
                                        Text(brand.name)
                                            .font(.system(.body, weight: .bold))
                                            .foregroundStyle(WatchTheme.ink)
                                        Spacer()
                                        Text("\(brand.count)")
                                            .font(AtelierType.detail)
                                            .foregroundStyle(WatchTheme.muted)
                                    }
                                    .padding(.vertical, 14)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    } else {
                        resultSection("Collection", foundWatches.filter { $0.status == "owned" })
                        resultSection("Archive", foundWatches.filter { $0.status != "owned" })
                        if !foundWishlist.isEmpty {
                            GroupedSection("Wishlist", columns: columns, gap: columnGap) {
                                ForEach(foundWishlist) { item in
                                    Button { editingItem = item } label: {
                                        SearchRow(
                                            store: store,
                                            itemID: item.id,
                                            filename: item.photos.first,
                                            focus: item.focus(for: item.photos.first),
                                            wishlist: true,
                                            title: item.name,
                                            subtitle: item.priceNote.isEmpty ? cad(item.priceExpected) : item.priceNote
                                        )
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, margin)
                .padding(.top, Platform.isMac ? 8 : 12)
                .padding(.bottom, 32)
            }
            .scrollDismissesKeyboard(.immediately)
            .mastheadTitle("Search", showsMasthead: trimmed.isEmpty)
            .atelierProbeScroll("search")
            .screenBackground()
            .overlay {
                if !trimmed.isEmpty, foundWatches.isEmpty, foundWishlist.isEmpty {
                    ContentUnavailableView.search(text: trimmed)
                }
            }
            #if os(macOS)
            .desktopHeader("Search", leading: {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Watches, brands and stories", text: $query)
                        .textFieldStyle(.plain)
                        .disabled(!sectionIsActive)
                    if !query.isEmpty {
                        Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("Clear search")
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .frame(maxWidth: 480)
                .background(WatchTheme.fill, in: Capsule())
            })
            #else
            .searchable(text: $query, prompt: "Watches, brands and stories")
            #endif
            #if DEBUG
            .onAppear {
                if let probe = AtelierProbe.search, query.isEmpty { query = probe }
            }
            #endif
            #if os(iOS)
            .navigationDestination(for: WatchRoute.self) { route in
                WatchDossierView(store: store, watchID: route.id)
            }
            #endif
            .sheet(item: $editingItem) { item in
                WishlistDetailScreen(store: store, item: item)
            }
        }
        .pageAppear()
    }

    @ViewBuilder
    private func resultSection(_ title: String, _ found: [Watch]) -> some View {
        if !found.isEmpty {
            GroupedSection(title, columns: columns, gap: columnGap) {
                ForEach(found) { watch in
                    NavigationLink(value: WatchRoute(id: watch.id)) {
                        SearchRow(
                            store: store,
                            itemID: watch.id,
                            filename: watch.photos.first,
                            focus: watch.focus(for: watch.photos.first),
                            wishlist: false,
                            title: watch.name,
                            subtitle: watch.status == "owned"
                                ? [watch.brand, cadWhole(watch.price)].compactMap { $0 }.joined(separator: " · ")
                                : archiveDetail(watch)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

private struct SearchRow: View {
    let store: AppStore
    let itemID: String
    let filename: String?
    let focus: PhotoFocus?
    let wishlist: Bool
    let title: String
    let subtitle: String

    var body: some View {
        HStack(spacing: 14) {
            RemoteWatchImage(
                asset: filename.flatMap { store.photoAsset(itemID: itemID, filename: $0, wishlist: wishlist) },
                allowsRemoteFetch: !store.isOffline,
                focus: focus,
                maxPixel: DisplayImageCache.icon
            )
            .frame(width: 56, height: 56)
            .clipped()
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(.body, weight: .bold))
                    .foregroundStyle(WatchTheme.ink)
                    .lineLimit(1)
                Text(subtitle)
                    .font(AtelierType.detail)
                    .foregroundStyle(WatchTheme.muted)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(WatchTheme.muted)
        }
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }
}
