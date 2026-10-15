import SwiftUI

/// The collection as an editorial catalogue: owned pieces and the archive in one place.
struct CollectionScreen: View {
    @ObservedObject var store: AppStore
    let showSettings: () -> Void
    @State private var search = ""
    @State private var addingWatch = false
    @AppStorage("collectionScope") private var scope = Scope.owned.rawValue
    @AppStorage("collectionSort") private var sort = Sort.value.rawValue
    @AppStorage("collectionLayout") private var layout = Layout.plates.rawValue
    @Namespace private var zoom

    enum Scope: String, CaseIterable { case owned = "Owned", archive = "Archive" }
    enum Sort: String, CaseIterable { case value = "Value", newest = "Newest", oldest = "Oldest", worn = "Most worn", name = "Name" }
    enum Layout: String { case plates, grid }

    private var all: [Watch] { store.data?.watches ?? [] }
    private var numbers: [String: Int] { catalogueNumbers(all) }

    private var watches: [Watch] {
        all
            .filter { scope == Scope.owned.rawValue ? $0.status == "owned" : $0.status != "owned" }
            .filter { search.isEmpty || "\($0.name) \($0.brand ?? "") \($0.story) \($0.statusNote)".localizedCaseInsensitiveContains(search) }
            .sorted(by: sorter)
    }

    private func sorter(_ a: Watch, _ b: Watch) -> Bool {
        switch Sort(rawValue: sort) ?? .value {
        case .value: return a.price > b.price
        case .newest: return (a.purchased ?? "") > (b.purchased ?? "")
        case .oldest: return (a.purchased ?? "9999") < (b.purchased ?? "9999")
        case .worn: return wearMinutes(for: a) > wearMinutes(for: b)
        case .name: return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }

    var body: some View {
        NavigationStack {
            RefreshableScreen(store: store) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        header
                            .padding(.horizontal, 20)
                            .padding(.bottom, 22)
                        controls
                            .padding(.horizontal, 20)
                            .padding(.bottom, 22)
                        if watches.isEmpty {
                            EmptyCollectionView(
                                title: search.isEmpty ? "Nothing here yet" : "No matches",
                                detail: search.isEmpty ? "Watches you part with appear in the archive." : "Try a different search."
                            )
                            .frame(minHeight: 320)
                        } else if layout == Layout.grid.rawValue {
                            grid
                        } else {
                            plates
                        }
                    }
                    .padding(.top, 6)
                    .padding(.bottom, 40)
                }
                .background(WatchTheme.background)
            }
            .searchable(text: $search, prompt: "Name, brand or story")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button { addingWatch = true } label: { Image(systemName: "plus") }
                        .disabled(store.isOffline)
                    GearToolbarButton(action: showSettings)
                }
            }
            .navigationDestination(for: WatchRoute.self) { route in
                WatchDossierView(store: store, watchID: route.id)
                    .navigationTransition(.zoom(sourceID: route.id, in: zoom))
            }
            .sheet(isPresented: $addingWatch) {
                WatchDetailScreen(store: store, watch: .newDraft, isNew: true)
            }
        }
    }

    private var header: some View {
        let owned = all.filter { $0.status == "owned" }
        let subtitle = scope == Scope.owned.rawValue
            ? "\(owned.count) pieces · \(cadWhole(owned.reduce(0) { $0 + $1.price })) invested"
            : "\(all.count - owned.count) watches that have moved on · \(all.count) all-time"
        return ScreenHeader(eyebrow: "Watch Collection", title: scope == Scope.owned.rawValue ? "The Collection" : "The Archive", subtitle: subtitle)
    }

    private var controls: some View {
        HStack(spacing: 10) {
            PillPicker(options: Scope.allCases.map { ($0.rawValue, $0.rawValue) }, selection: $scope)

            Spacer()

            Menu {
                Picker("Sort", selection: $sort) {
                    ForEach(Sort.allCases, id: \.self) { Text($0.rawValue).tag($0.rawValue) }
                }
            } label: {
                Image(systemName: "arrow.up.arrow.down")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 38, height: 38)
                    .background(WatchTheme.card, in: Circle())
                    .overlay { Circle().stroke(WatchTheme.hairline) }
            }
            .accessibilityLabel("Sort by \(sort)")

            Button {
                withAnimation(.snappy) { layout = layout == Layout.plates.rawValue ? Layout.grid.rawValue : Layout.plates.rawValue }
            } label: {
                Image(systemName: layout == Layout.plates.rawValue ? "square.grid.3x3" : "rectangle.grid.1x2")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 38, height: 38)
                    .background(WatchTheme.card, in: Circle())
                    .overlay { Circle().stroke(WatchTheme.hairline) }
            }
            .buttonStyle(.plain)
            .foregroundStyle(WatchTheme.gold)
            .accessibilityLabel(layout == Layout.plates.rawValue ? "Show grid" : "Show large photos")
        }
    }

    private var plates: some View {
        LazyVStack(spacing: 34) {
            ForEach(watches) { watch in
                NavigationLink(value: WatchRoute(id: watch.id)) {
                    PlateView(store: store, watch: watch, number: numbers[watch.id])
                        .matchedTransitionSource(id: watch.id, in: zoom)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 20)
    }

    private var grid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 3), count: 3), spacing: 3) {
            ForEach(watches) { watch in
                NavigationLink(value: WatchRoute(id: watch.id)) {
                    FramedPhoto(
                        store: store,
                        itemID: watch.id,
                        filename: watch.photos.first,
                        focus: watch.focus(for: watch.photos.first),
                        aspect: PhotoShape.square
                    )
                    .overlay(alignment: .bottomLeading) {
                        Text(catalogueLabel(numbers[watch.id]))
                            .font(.system(size: 9, weight: .bold).monospacedDigit())
                            .tracking(1)
                            .foregroundStyle(WatchTheme.ivory)
                            .shadow(color: .black.opacity(0.7), radius: 3)
                            .padding(6)
                    }
                    .matchedTransitionSource(id: watch.id, in: zoom)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(watch.name)
            }
        }
        .padding(.horizontal, 3)
    }
}

/// Large magazine plate: photo, catalogue number, name and the essentials.
struct PlateView: View {
    @ObservedObject var store: AppStore
    let watch: Watch
    let number: Int?

    private var meta: String {
        [watch.brand, watch.category, watch.diameter.map { "\(compactNumber($0)) mm" }]
            .compactMap { $0 }
            .joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            FramedPhoto(store: store, itemID: watch.id, filename: watch.photos.first, focus: watch.focus(for: watch.photos.first))
                .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
                .overlay(alignment: .topLeading) {
                    HStack(spacing: 6) {
                        PhotoTag(text: catalogueLabel(number))
                        if watch.status != "owned" { PhotoTag(text: statusLabel(watch.status), color: WatchTheme.gold) }
                        if watch.original == false { PhotoTag(text: "Rep") }
                    }
                    .padding(14)
                }
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(watch.name)
                        .font(.display(26))
                        .foregroundStyle(WatchTheme.ivory)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Text(meta.isEmpty ? "Details unset" : meta)
                        .font(.footnote)
                        .foregroundStyle(WatchTheme.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Text(cadWhole(watch.price))
                    .font(.display(20))
                    .foregroundStyle(WatchTheme.gold)
            }
            if watch.status != "owned", !watch.statusNote.isEmpty {
                Text(watch.statusNote)
                    .font(.footnote)
                    .foregroundStyle(WatchTheme.secondary)
            } else if watch.status == "owned", let wrist = store.data?.settings.wrist,
                      let fit = fitInfo(for: watch.diameter, lugToLug: watch.lugToLug, wrist: wrist) {
                FitIndicator(info: fit)
            }
        }
        .contentShape(Rectangle())
    }
}
