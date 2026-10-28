import SwiftUI

/// The Search tab: every watch owned, archived or on the wishlist, found by name,
/// brand, category or story. With no query it lists brands to browse.
struct SearchScreen: View {
    @ObservedObject var store: AppStore
    @State private var query = ""
    @State private var editingItem: WishlistItem?

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
        NavigationStack {
            List {
                if trimmed.isEmpty {
                    Section("Browse by Brand") {
                        ForEach(brands, id: \.name) { brand in
                            Button { query = brand.name } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: "magnifyingglass")
                                        .foregroundStyle(.secondary)
                                    Text(brand.name)
                                        .foregroundStyle(.primary)
                                    Spacer()
                                    Text("\(brand.count)")
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                } else {
                    resultSection("Collection", foundWatches.filter { $0.status == "owned" })
                    resultSection("Archive", foundWatches.filter { $0.status != "owned" })
                    if !foundWishlist.isEmpty {
                        Section("Wishlist") {
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
                            }
                        }
                    }
                }
            }
            .overlay {
                if !trimmed.isEmpty, foundWatches.isEmpty, foundWishlist.isEmpty {
                    ContentUnavailableView.search(text: trimmed)
                }
            }
            .navigationTitle("Search")
            .searchable(text: $query, prompt: "Watches, brands and stories")
            .navigationDestination(for: WatchRoute.self) { route in
                WatchDossierView(store: store, watchID: route.id)
            }
            .sheet(item: $editingItem) { item in
                WishlistDetailScreen(store: store, item: item)
            }
        }
    }

    @ViewBuilder
    private func resultSection(_ title: String, _ found: [Watch]) -> some View {
        if !found.isEmpty {
            Section(title) {
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
                                : statusLabel(watch.status)
                        )
                    }
                }
            }
        }
    }
}

private struct SearchRow: View {
    @ObservedObject var store: AppStore
    let itemID: String
    let filename: String?
    let focus: PhotoFocus?
    let wishlist: Bool
    let title: String
    let subtitle: String

    var body: some View {
        HStack(spacing: 12) {
            RemoteWatchImage(
                asset: filename.flatMap { store.photoAsset(itemID: itemID, filename: $0, wishlist: wishlist) },
                allowsRemoteFetch: !store.isOffline,
                focus: focus
            )
            .frame(width: 48, height: 48)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }
}
