import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct WishlistScreen: View {
    @Environment(\.openURL) private var openURL
    @ObservedObject var store: AppStore
    let showSettings: () -> Void
    @State private var editingItem: WishlistItem?
    @State private var addingItem = false
    @State private var boughtItem: WishlistItem?
    @State private var radarBrand = ""
    @State private var prefilledBrand = ""

    private var ranked: [WishlistItem] {
        (store.data?.wishlist ?? []).sorted { left, right in
            let statusRank = ["considering": 0, "passed": 1, "bought": 2]
            let leftStatus = statusRank[left.status] ?? 3
            let rightStatus = statusRank[right.status] ?? 3
            if leftStatus != rightStatus { return leftStatus < rightStatus }
            let leftScore = store.scores[left.id]?.total ?? Int.min
            let rightScore = store.scores[right.id]?.total ?? Int.min
            if leftScore != rightScore { return leftScore > rightScore }
            return (left.priceExpected ?? .infinity) < (right.priceExpected ?? .infinity)
        }
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                RefreshableScreen(store: store) {
                    ScrollView {
                        LazyVStack(spacing: 14) {
                            wishlistHeader
                            nextMoveSection { id in
                                withAnimation { proxy.scrollTo("wishlist-\(id)", anchor: .top) }
                            }
                            radarStrip
                            if ranked.isEmpty {
                                EmptyCollectionView(title: "Wishlist empty", detail: "Add a candidate to start comparing fit.")
                                    .frame(minHeight: 320)
                            } else {
                                ForEach(ranked) { item in
                                    WishlistCard(
                                        store: store,
                                        item: item,
                                        score: store.scores[item.id],
                                        edit: { editingItem = item },
                                        pass: { Task { await store.passWishlist(id: item.id) } },
                                        bought: { boughtItem = item },
                                        findImage: { findImage(item.id) }
                                    )
                                    .id("wishlist-\(item.id)")
                                }
                            }
                        }
                        .padding(14)
                        .padding(.bottom, 18)
                    }
                    .background(WatchTheme.background)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("Wishlist").font(.headline).serifTitle()
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button { prefilledBrand = ""; addingItem = true } label: { Image(systemName: "plus") }
                        .disabled(store.isOffline)
                    GearToolbarButton(action: showSettings)
                }
            }
            .sheet(item: $editingItem) { item in
                WishlistDetailScreen(store: store, item: item)
            }
            .sheet(isPresented: $addingItem) {
                WishlistDetailScreen(store: store, item: .newDraft(brand: prefilledBrand), isNew: true)
            }
            .sheet(item: $boughtItem) { item in
                BoughtSheet(store: store, item: item)
            }
        }
    }

    private var wishlistHeader: some View {
        SectionCard(eyebrow: "Purchase decision engine", title: "\(ranked.filter { $0.status == "considering" }.count) candidates · six lenses") {
            Text("Category, brand, price, dial, size, and material scores come from the Mac. Fit chips use your saved wrist profile.")
                .font(.subheadline)
                .foregroundStyle(WatchTheme.secondary)
        }
    }

    private var radarStrip: some View {
        SectionCard(eyebrow: "Explore before repeating", title: "Brands on the radar") {
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
                            VStack(alignment: .leading, spacing: 3) {
                                Text(entry.brand).font(.caption.weight(.bold))
                                Text(radarStatus(entry.brand)).font(.caption2)
                            }
                            .foregroundStyle(WatchTheme.gold)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .background(WatchTheme.gold.opacity(0.1))
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                        }
                    }
                }
            }
            HStack {
                TextField("Add brand", text: $radarBrand)
                    .textInputAutocapitalization(.words)
                Button("Add") {
                    let brand = radarBrand.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !brand.isEmpty else { return }
                    radarBrand = ""
                    Task { await store.addRadarBrand(brand) }
                }
                .disabled(store.isOffline)
            }
        }
    }

    private func nextMoveSection(scrollTo: @escaping (String) -> Void) -> some View {
        SectionCard(eyebrow: "Collection gaps", title: "Next move") {
            Text(saturationLine)
                .font(.caption)
                .foregroundStyle(WatchTheme.secondary)
            if let suggestions = store.suggestions?.suggestions, !suggestions.isEmpty {
                VStack(spacing: 10) {
                    ForEach(Array(suggestions.enumerated()), id: \.offset) { _, suggestion in
                        NextMoveSuggestionCard(
                            suggestion: suggestion,
                            wishlist: store.data?.wishlist ?? [],
                            scrollTo: scrollTo
                        )
                    }
                }
            } else {
                Text("No eligible category gaps. Adjust suggestion categories in Settings.")
                    .font(.subheadline)
                    .foregroundStyle(WatchTheme.secondary)
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
        return parts.isEmpty ? "No saturated areas yet — the collection is wide open." : "Well covered: " + parts.joined(separator: " · ")
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
                    .font(.subheadline.weight(.semibold))
                    .serifTitle()
                    .frame(maxWidth: .infinity, alignment: .leading)
                VStack(spacing: 0) {
                    Text("\(suggestion.score)")
                        .font(.system(.title2, design: .serif, weight: .bold))
                        .foregroundStyle(WatchTheme.gold)
                    Text("/ 9")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(WatchTheme.secondary)
                }
            }
            if let brands = suggestion.brands, !brands.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("BRANDS TO EXPLORE")
                        .font(.system(size: 9, weight: .bold))
                        .tracking(1)
                        .foregroundStyle(WatchTheme.secondary.opacity(0.7))
                    ChipFlowLayout(spacing: 5) {
                        ForEach(brands, id: \.name) { brand in
                            CapsuleChip(
                                text: "\(brand.name) · \(brand.status)",
                                color: brand.status == "radar" ? WatchTheme.gold : WatchTheme.secondary
                            )
                            .accessibilityLabel("\(brand.name), \(brand.status)")
                        }
                    }
                }
            }
            ChipFlowLayout(spacing: 5) {
                ForEach(Array(suggestion.reasons.enumerated()), id: \.offset) { _, reason in
                    Text(reason)
                        .font(.caption2.weight(.medium))
                        .lineLimit(2)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .foregroundStyle(WatchTheme.secondary)
                        .background(WatchTheme.secondary.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }
            if !suggestion.wishlistMatches.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    Text("YOUR CANDIDATES")
                        .font(.system(size: 9, weight: .bold))
                        .tracking(1)
                        .foregroundStyle(WatchTheme.gold)
                    ForEach(suggestion.wishlistMatches, id: \.self) { id in
                        Button {
                            scrollTo(id)
                        } label: {
                            Label(wishlist.first(where: { $0.id == id })?.name ?? id, systemImage: "arrow.down")
                                .font(.caption.weight(.semibold))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(WatchTheme.gold)
                    }
                }
            }
        }
        .padding(12)
        .background(WatchTheme.raised.opacity(0.75))
        .clipShape(RoundedRectangle(cornerRadius: 13))
        .overlay { RoundedRectangle(cornerRadius: 13).stroke(Color.white.opacity(0.07)) }
    }
}

struct WishlistCard: View {
    @ObservedObject var store: AppStore
    let item: WishlistItem
    let score: WishlistScore?
    let edit: () -> Void
    let pass: () -> Void
    let bought: () -> Void
    let findImage: () -> Void

    private let lensOrder = ["category", "brand", "price", "dial", "size", "material"]
    private var imageAsset: PhotoAsset? {
        item.photos.first.flatMap { store.photoAsset(itemID: item.id, filename: $0, wishlist: true) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                RemoteWatchImage(asset: imageAsset, allowsRemoteFetch: !store.isOffline)
                    .frame(width: 104, height: 112)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 7) {
                    Text(item.name)
                        .font(.headline)
                        .serifTitle()
                        .lineLimit(3)
                    Text(item.priceNote.isEmpty ? cad(item.priceExpected) : item.priceNote)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(WatchTheme.gold)
                    HStack(spacing: 5) {
                        CapsuleChip(text: item.category ?? "category unset")
                        if let material = item.material { CapsuleChip(text: material) }
                    }
                    if let wrist = store.data?.settings.wrist,
                       let fit = fitInfo(for: item.diameter, lugToLug: item.lugToLug, wrist: wrist) {
                        FitChip(info: fit)
                    }
                }
                Spacer(minLength: 0)
                VStack(spacing: 0) {
                    Text(score.map { "\($0.total)" } ?? "—")
                        .font(.system(size: 30, weight: .bold, design: .serif))
                        .foregroundStyle(WatchTheme.gold)
                    Text("/ \(score?.max ?? 14)")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(WatchTheme.secondary)
                }
                .frame(minWidth: 43)
            }
            .padding(14)

            Divider().overlay(Color.white.opacity(0.07))

            VStack(spacing: 0) {
                ForEach(lensOrder, id: \.self) { name in
                    let lens = score?.lenses[name]
                    HStack(alignment: .firstTextBaseline) {
                        Text(name.capitalized)
                            .font(.caption.weight(.bold))
                            .frame(width: 58, alignment: .leading)
                        Text(lens?.reason ?? "Waiting for score")
                            .font(.caption)
                            .foregroundStyle(WatchTheme.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(lens.map { $0.score >= 0 ? "+\($0.score)" : "\($0.score)" } ?? "—")
                            .font(.caption.weight(.bold))
                            .foregroundStyle((lens?.score ?? 0) > 0 ? WatchTheme.gold : WatchTheme.secondary)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                }
            }

            HStack {
                Button("Edit", action: edit)
                if item.status == "considering" {
                    Button("Pass", action: pass)
                    Button("Bought", action: bought)
                        .buttonStyle(.borderedProminent)
                } else {
                    CapsuleChip(text: item.status.capitalized, color: WatchTheme.secondary)
                }
                Spacer()
                Button(action: findImage) { Label("Find image", systemImage: "photo.badge.magnifyingglass") }
            }
            .font(.caption.weight(.semibold))
            .padding(14)
            .disabled(store.isOffline)
        }
        .watchCard()
        .opacity(item.status == "passed" ? 0.58 : 1)
    }
}

struct WishlistDetailScreen: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: AppStore
    let isNew: Bool
    @State private var draft: WishlistItem
    @State private var photoItem: PhotosPickerItem?
    @State private var selectedPhotoIndex = 0
    @State private var isSaving = false
    @State private var confirmDelete = false

    init(store: AppStore, item: WishlistItem, isNew: Bool = false) {
        self.store = store
        self.isNew = isNew
        _draft = State(initialValue: item)
    }

    var body: some View {
        NavigationStack {
            Form {
                if store.isOffline {
                    Section { Label("Mac unreachable · editing is disabled", systemImage: "wifi.slash") }
                        .foregroundStyle(WatchTheme.amber)
                }
                photoSection
                Section("Candidate") {
                    TextField("Name", text: $draft.name)
                    TextField("Brand", text: $draft.brand)
                    Picker("Category", selection: optionalSelectionBinding($draft.category)) {
                        Text("Unset").tag("")
                        ForEach(store.data?.categories ?? [], id: \.self) { Text($0).tag($0) }
                    }
                    TextField("Expected price (CAD)", text: optionalNumberBinding($draft.priceExpected))
                        .keyboardType(.decimalPad)
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
                    TextField("Diameter (mm)", text: optionalNumberBinding($draft.diameter)).keyboardType(.decimalPad)
                    TextField("Lug-to-lug (mm)", text: optionalNumberBinding($draft.lugToLug)).keyboardType(.decimalPad)
                    if let wrist = store.data?.settings.wrist,
                       let fit = fitInfo(for: draft.diameter, lugToLug: draft.lugToLug, wrist: wrist) {
                        HStack { Text("Fit"); Spacer(); FitChip(info: fit) }
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
            .scrollContentBackground(.hidden)
            .background(WatchTheme.background)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                ToolbarItem(placement: .principal) { Text(isNew ? "Add Candidate" : "Edit Candidate").font(.headline).serifTitle() }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isSaving ? "Saving…" : "Save") { save() }
                        .disabled(store.isOffline || isSaving || draft.name.isEmpty || draft.brand.isEmpty)
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
        .preferredColorScheme(.dark)
    }

    private var photoSection: some View {
        Section("Gallery") {
            if draft.photos.isEmpty {
                WatchPlaceholder().frame(height: 210).clipShape(RoundedRectangle(cornerRadius: 14))
            } else {
                TabView(selection: $selectedPhotoIndex) {
                    ForEach(Array(draft.photos.enumerated()), id: \.offset) { index, filename in
                        RemoteWatchImage(
                            asset: store.photoAsset(itemID: draft.id, filename: filename, wishlist: true),
                            allowsRemoteFetch: !store.isOffline
                        )
                            .frame(height: 230)
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                            .tag(index)
                    }
                }
                .frame(height: 240)
                .tabViewStyle(.page)
                if draft.photos.indices.contains(selectedPhotoIndex) {
                    let filename = draft.photos[selectedPhotoIndex]
                    HStack {
                        Button("Set cover") {
                            Task { await store.setCover(itemID: draft.id, filename: filename, wishlist: true); reloadDraft(); selectedPhotoIndex = 0 }
                        }
                        Spacer()
                        Button("Delete photo", role: .destructive) {
                            Task { await store.deletePhoto(itemID: draft.id, filename: filename, wishlist: true); reloadDraft(); selectedPhotoIndex = 0 }
                        }
                    }
                }
            }
            PhotosPicker(selection: $photoItem, matching: .images) {
                Label("Add from Photos", systemImage: "photo.on.rectangle")
            }
            .disabled(store.isOffline || isNew)
            if isNew { Text("Save first, then reopen to add a photo.").font(.caption).foregroundStyle(WatchTheme.secondary) }
        }
    }

    private func save() {
        isSaving = true
        Task {
            if await store.saveWishlist(draft, isNew: isNew) != nil { dismiss() }
            isSaving = false
        }
    }

    private func importPhoto(_ item: PhotosPickerItem) async {
        guard let data = try? await item.loadTransferable(type: Data.self) else { return }
        let type = item.supportedContentTypes.first
        await store.uploadPhoto(
            data: data,
            filename: "photo-\(UUID().uuidString).\(type?.preferredFilenameExtension ?? "jpg")",
            mimeType: type?.preferredMIMEType ?? "image/jpeg",
            itemID: draft.id,
            wishlist: true
        )
        reloadDraft()
        photoItem = nil
    }

    private func reloadDraft() {
        if let updated = store.data?.wishlist.first(where: { $0.id == draft.id }) { draft = updated }
    }
}

struct BoughtSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: AppStore
    let item: WishlistItem
    @State private var price: Double
    @State private var purchased: String

    init(store: AppStore, item: WishlistItem) {
        self.store = store
        self.item = item
        _price = State(initialValue: item.priceExpected ?? 0)
        _purchased = State(initialValue: String(Calendar.current.component(.year, from: Date())) + "-" + String(format: "%02d", Calendar.current.component(.month, from: Date())))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(item.name) {
                    TextField("Final price paid (CAD)", value: $price, format: .number).keyboardType(.decimalPad)
                    TextField("Purchase month (YYYY-MM)", text: $purchased)
                }
            }
            .navigationTitle("Mark Bought")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add to Collection") {
                        Task { await store.markBought(id: item.id, price: price, purchased: purchased); dismiss() }
                    }
                    .disabled(store.isOffline || price < 0 || purchased.count != 7)
                }
            }
        }
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
