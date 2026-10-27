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
                            if ranked.isEmpty {
                                EmptyCollectionView(title: "Wishlist empty", detail: "Add a candidate to start comparing fit.")
                                    .frame(minHeight: 320)
                            } else {
                                if let top = ranked.first, top.status == "considering" {
                                    TopPickView(
                                        store: store,
                                        item: top,
                                        score: store.scores[top.id],
                                        edit: { editingItem = top },
                                        bought: { boughtItem = top }
                                    )
                                    .id("wishlist-\(top.id)")
                                    .padding(.bottom, 10)
                                }
                                ForEach(ranked.first?.status == "considering" ? Array(ranked.dropFirst()) : ranked) { item in
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
                            nextMoveSection { id in
                                withAnimation { proxy.scrollTo("wishlist-\(id)", anchor: .top) }
                            }
                            radarStrip
                        }
                        .padding(.horizontal, 20)
                        .padding(.top, 6)
                        .padding(.bottom, 40)
                    }
                    .background(WatchTheme.background)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
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
        let count = ranked.filter { $0.status == "considering" }.count
        return ScreenHeader(
            eyebrow: "Purchase decision engine",
            title: "Wishlist",
            subtitle: "\(count) candidate\(count == 1 ? "" : "s"), ranked by category, brand, price, dial, size and material."
        )
        .padding(.bottom, 4)
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
                .padding(.horizontal, -20)
                .contentMargins(.horizontal, 20, for: .scrollContent)
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
                        .font(.display(26))
                        .foregroundStyle(WatchTheme.gold)
                    Text("/ 9")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(WatchTheme.secondary)
                }
            }
            if let brands = suggestion.brands, !brands.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Eyebrow("Brands to explore", color: WatchTheme.secondary)
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
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(suggestion.reasons.enumerated()), id: \.offset) { _, reason in
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Circle().fill(WatchTheme.gold.opacity(0.7)).frame(width: 4, height: 4)
                        Text(reason)
                            .font(.caption)
                            .foregroundStyle(WatchTheme.secondary)
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
                        .foregroundStyle(WatchTheme.gold)
                    }
                }
            }
        }
        .padding(14)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(WatchTheme.raised.opacity(0.7), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(WatchTheme.hairline) }
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
    @State private var showsLenses = false

    /// Width / height of the wishlist thumbnail. The framing editor uses the same ratio.
    static let photoAspect: CGFloat = 96.0 / 120.0

    private let lensOrder = ["category", "brand", "price", "dial", "size", "material"]
    private var imageAsset: PhotoAsset? {
        item.photos.first.flatMap { store.photoAsset(itemID: item.id, filename: $0, wishlist: true) }
    }
    private var detailLine: String {
        [item.category, item.diameter.map { "\(compactNumber($0))mm" }]
            .compactMap { $0 }
            .joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 14) {
                RemoteWatchImage(asset: imageAsset, allowsRemoteFetch: !store.isOffline, focus: item.focus(for: item.photos.first))
                    .frame(width: 96, height: 120)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                VStack(alignment: .leading, spacing: 6) {
                    Text(item.name)
                        .font(.display(17))
                        .foregroundStyle(WatchTheme.ivory)
                        .lineLimit(3)
                    Text(item.priceNote.isEmpty ? cad(item.priceExpected) : item.priceNote)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(WatchTheme.gold)
                        .lineLimit(2)
                    if !detailLine.isEmpty {
                        Text(detailLine)
                            .font(.caption)
                            .foregroundStyle(WatchTheme.secondary)
                            .lineLimit(1)
                    }
                    if let wrist = store.data?.settings.wrist,
                       let fit = fitInfo(for: item.diameter, lugToLug: item.lugToLug, wrist: wrist) {
                        FitIndicator(info: fit)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                ScoreRing(score: score?.total, maximum: score?.max ?? 14)
            }
            .padding(14)

            lensStrip
                .padding(.horizontal, 14)
                .padding(.bottom, showsLenses ? 4 : 12)

            if showsLenses {
                VStack(spacing: 0) {
                    ForEach(lensOrder, id: \.self) { name in
                        let lens = score?.lenses[name]
                        HStack(alignment: .firstTextBaseline) {
                            Text(name.capitalized)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(WatchTheme.ivory)
                                .frame(width: 62, alignment: .leading)
                            Text(lens?.reason ?? "Waiting for score")
                                .font(.caption)
                                .foregroundStyle(WatchTheme.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text(lens.map { $0.score >= 0 ? "+\($0.score)" : "\($0.score)" } ?? "—")
                                .font(.caption.weight(.bold).monospacedDigit())
                                .foregroundStyle((lens?.score ?? 0) > 0 ? WatchTheme.gold : WatchTheme.secondary)
                        }
                        .padding(.vertical, 6)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 8)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            Rectangle().fill(WatchTheme.hairline).frame(height: 1)

            HStack(spacing: 10) {
                if item.status == "considering" {
                    Button(action: bought) {
                        Text("Bought it")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(WatchTheme.background)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(WatchTheme.gold, in: Capsule())
                    }
                    Button("Pass", action: pass)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(WatchTheme.secondary)
                } else {
                    CapsuleChip(text: item.status.capitalized, color: WatchTheme.secondary)
                }
                Spacer()
                Button("Edit", action: edit)
                    .font(.caption.weight(.semibold))
                Menu {
                    Button(action: findImage) { Label("Find image online", systemImage: "photo.badge.magnifyingglass") }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(width: 30, height: 26)
                        .contentShape(Rectangle())
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(WatchTheme.gold)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .disabled(store.isOffline)
        }
        .watchCard()
        .opacity(item.status == "passed" ? 0.55 : 1)
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
                        Capsule()
                            .fill(value > 0 ? WatchTheme.gold.opacity(min(1, 0.45 + Double(value) * 0.18)) : Color.white.opacity(0.08))
                            .frame(height: 4)
                        Text(name.capitalized)
                            .font(.system(size: 9, weight: .semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                            .foregroundStyle(value > 0 ? WatchTheme.gold : WatchTheme.secondary.opacity(0.7))
                    }
                }
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(WatchTheme.secondary)
                    .rotationEffect(.degrees(showsLenses ? 180 : 0))
                    .padding(.leading, 2)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(showsLenses ? "Hide score breakdown" : "Show score breakdown")
    }
}

/// The highest-scoring candidate, presented large.
struct TopPickView: View {
    @ObservedObject var store: AppStore
    let item: WishlistItem
    let score: WishlistScore?
    let edit: () -> Void
    let bought: () -> Void

    private var highlights: [String] {
        ["category", "brand", "price", "dial", "size", "material"].compactMap { name in
            guard let lens = score?.lenses[name], lens.score > 0 else { return nil }
            return lens.reason
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Button(action: edit) {
                FramedPhoto(
                    store: store,
                    itemID: item.id,
                    filename: item.photos.first,
                    focus: item.focus(for: item.photos.first),
                    wishlist: true,
                    aspect: PhotoShape.plate
                )
                .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                .overlay(alignment: .topLeading) {
                    PhotoTag(text: "Top pick", color: WatchTheme.gold).padding(14)
                }
                .overlay(alignment: .topTrailing) {
                    ScoreRing(score: score?.total, maximum: score?.max ?? 14)
                        .padding(8)
                        .background(.ultraThinMaterial, in: Circle())
                        .environment(\.colorScheme, .dark)
                        .padding(12)
                }
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 6) {
                Text(item.name)
                    .font(.display(32))
                    .foregroundStyle(WatchTheme.ivory)
                    .fixedSize(horizontal: false, vertical: true)
                Text(item.priceNote.isEmpty ? cad(item.priceExpected) : item.priceNote)
                    .font(.display(20))
                    .foregroundStyle(WatchTheme.gold)
            }
            if !highlights.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(highlights.prefix(4), id: \.self) { reason in
                        HStack(alignment: .firstTextBaseline, spacing: 9) {
                            Image(systemName: "plus")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(WatchTheme.gold)
                            Text(reason)
                                .font(.subheadline)
                                .foregroundStyle(WatchTheme.ivory.opacity(0.85))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            HStack(spacing: 12) {
                Button(action: bought) {
                    Text("Bought it")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(WatchTheme.background)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 11)
                        .background(WatchTheme.gold, in: Capsule())
                }
                .buttonStyle(.plain)
                Button("Details", action: edit)
                    .font(.subheadline.weight(.semibold))
                Spacer()
            }
            .disabled(store.isOffline)
        }
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
            Circle().stroke(Color.white.opacity(0.08), lineWidth: 3)
            Circle()
                .trim(from: 0, to: fraction)
                .stroke(WatchTheme.gold, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: -2) {
                Text(score.map(String.init) ?? "—")
                    .font(.display(20))
                    .foregroundStyle(WatchTheme.ivory)
                Text("/\(maximum)")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(WatchTheme.secondary)
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
                    Section("Notes") {
                        TextField("Notes", text: $draft.notes, axis: .vertical).lineLimit(4...10)
                        if !isNew {
                            Button("Delete candidate", role: .destructive) { confirmDelete = true }
                                .disabled(store.isOffline)
                        }
                    }
                }
                .listRowBackground(WatchTheme.card)
            }
            .scrollContentBackground(.hidden)
            .background(WatchTheme.background)
            .navigationBarTitleDisplayMode(.inline)
            .storeErrorAlert(store)
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
                            allowsRemoteFetch: !store.isOffline,
                            focus: draft.focus(for: filename)
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
                        Button("Adjust") { framingTarget = PhotoFramingTarget(filename: filename) }
                        Spacer()
                        Button("Delete photo", role: .destructive) {
                            Task { await store.deletePhoto(itemID: draft.id, filename: filename, wishlist: true); reloadDraft(); selectedPhotoIndex = 0 }
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
            if isNew { Text("Save first, then reopen to add a photo.").font(.caption).foregroundStyle(WatchTheme.secondary) }
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
                .listRowBackground(WatchTheme.card)
            }
            .scrollContentBackground(.hidden)
            .background(WatchTheme.background)
            .navigationTitle("Mark Bought")
            .navigationBarTitleDisplayMode(.inline)
            .storeErrorAlert(store)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add to Collection") {
                        guard let purchased else { return }
                        Task { await store.markBought(id: item.id, price: price, purchased: purchased); dismiss() }
                    }
                    .disabled(store.isOffline || price < 0 || purchaseMonthParts(purchased) == nil)
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
