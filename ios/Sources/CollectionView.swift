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

    enum Scope: String, CaseIterable { case owned = "Owned", archive = "Archive" }
    enum Sort: String, CaseIterable { case value = "Value", newest = "Newest", oldest = "Oldest", name = "Name" }
    enum Layout: String { case cards, grid }

    private var all: [Watch] { store.data?.watches ?? [] }

    private var watches: [Watch] {
        let shown = all
            .filter { scope == Scope.owned.rawValue ? $0.status == "owned" : $0.status != "owned" }
        switch Sort(rawValue: sort) ?? .value {
        case .oldest:
            return acquisitionOrder(shown)
        case .newest:
            let ordered = acquisitionOrder(shown)
            return ordered.filter { $0.purchased != nil }.reversed() + ordered.filter { $0.purchased == nil }
        default:
            return shown.sorted(by: sorter)
        }
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
                    VStack(alignment: .leading, spacing: 18) {
                        Picker("Show", selection: $scope) {
                            ForEach(Scope.allCases, id: \.self) { Text($0.rawValue).tag($0.rawValue) }
                        }
                        .pickerStyle(.segmented)
                        .padding(.horizontal, 20)

                        if watches.isEmpty {
                            EmptyCollectionView(
                                title: "Nothing Here Yet",
                                detail: scope == Scope.owned.rawValue ? "Tap + to add your first watch." : "Watches you part with appear in the archive."
                            )
                            .frame(minHeight: 360)
                        } else if layout == Layout.grid.rawValue {
                            grid
                        } else {
                            cards
                        }
                    }
                    .padding(.top, 4)
                    .padding(.bottom, 24)
                }
                .containerBackground(WatchTheme.background, for: .navigation)
            }
            .navigationTitle(scope == Scope.owned.rawValue ? "Collection" : "Archive")
            .navigationSubtitle(subtitle)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { GearToolbarButton(action: showSettings) }
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
                    .navigationTransition(.zoom(sourceID: route.id, in: zoom))
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
    }

    private var subtitle: String {
        let owned = all.filter { $0.status == "owned" }
        return scope == Scope.owned.rawValue
            ? "\(owned.count) watches · \(cadWhole(owned.reduce(0) { $0 + $1.price }))"
            : "\(all.count - owned.count) moved on · \(all.count) all time"
    }

    private var cards: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 14, alignment: .top), count: 2), spacing: 24) {
            ForEach(watches) { watch in
                NavigationLink(value: WatchRoute(id: watch.id)) {
                    WatchTile(store: store, watch: watch, zoom: zoom)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 20)
    }

    private var grid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 3), spacing: 2) {
            ForEach(watches) { watch in
                NavigationLink(value: WatchRoute(id: watch.id)) {
                    FramedPhoto(
                        store: store,
                        itemID: watch.id,
                        filename: watch.photos.first,
                        focus: watch.focus(for: watch.photos.first),
                        aspect: PhotoShape.square
                    )
                    .matchedTransitionSource(id: watch.id, in: zoom)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(watch.name)
            }
        }
    }
}

/// Two-up card in the style of Apple's own libraries: rounded photo, name, then price and category.
struct WatchTile: View {
    @ObservedObject var store: AppStore
    let watch: Watch
    let zoom: Namespace.ID

    private var detail: String {
        if watch.status != "owned" { return statusLabel(watch.status) }
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
                .matchedTransitionSource(id: watch.id, in: zoom)
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
