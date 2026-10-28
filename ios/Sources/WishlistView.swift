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
                        .padding(.horizontal, 16)
                        .padding(.top, 4)
                        .padding(.bottom, 24)
                    }
                    .containerBackground(WatchTheme.background, for: .navigation)
                }
            }
            .navigationTitle("Wishlist")
            .navigationSubtitle(subtitle)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { GearToolbarButton(action: showSettings) }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { prefilledBrand = ""; addingItem = true } label: { Image(systemName: "plus") }
                        .disabled(store.isOffline)
                        .accessibilityLabel("Add candidate")
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

    private var subtitle: String {
        let count = ranked.filter { $0.status == "considering" }.count
        return "\(count) candidate\(count == 1 ? "" : "s"), ranked for your collection"
    }

    private var radarStrip: some View {
        SectionCard("On the Radar", systemImage: "scope", color: .pink, detail: "Brands to explore") {
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
                                Text(entry.brand).font(.subheadline.weight(.semibold))
                                Text(radarStatus(entry.brand)).font(.caption).foregroundStyle(.secondary)
                            }
                            .foregroundStyle(.pink)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 9)
                            .background(Color.pink.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                    }
                }
            }
            HStack {
                TextField("Add a brand", text: $radarBrand)
                    .textInputAutocapitalization(.words)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(WatchTheme.raised, in: Capsule())
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
        SectionCard("Next Move", systemImage: "sparkles", color: .purple, detail: "Collection gaps") {
            Text(saturationLine)
                .font(.caption)
                .foregroundStyle(Color.secondary)
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
                .padding(.horizontal, -16)
                .contentMargins(.horizontal, 16, for: .scrollContent)
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
                    .font(.headline)
                    .frame(maxWidth: .infinity, alignment: .leading)
                VStack(spacing: 0) {
                    Text("\(suggestion.score)")
                        .font(.figure(.title2))
                        .foregroundStyle(.purple)
                    Text("/ 9")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(Color.secondary)
                }
            }
            if let brands = suggestion.brands, !brands.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Eyebrow("Brands to explore")
                    ChipFlowLayout(spacing: 5) {
                        ForEach(brands, id: \.name) { brand in
                            CapsuleChip(
                                text: "\(brand.name) · \(brand.status)",
                                color: brand.status == "radar" ? .pink : .secondary
                            )
                            .accessibilityLabel("\(brand.name), \(brand.status)")
                        }
                    }
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(suggestion.reasons.enumerated()), id: \.offset) { _, reason in
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Circle().fill(Color.purple.opacity(0.7)).frame(width: 5, height: 5)
                        Text(reason)
                            .font(.caption)
                            .foregroundStyle(Color.secondary)
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
                        .foregroundStyle(.purple)
                    }
                }
            }
        }
        .padding(16)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(WatchTheme.raised, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
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
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                VStack(alignment: .leading, spacing: 6) {
                    Text(item.name)
                        .font(.headline)
                        .lineLimit(3)
                    Text(item.priceNote.isEmpty ? cad(item.priceExpected) : item.priceNote)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    if !detailLine.isEmpty {
                        Text(detailLine)
                            .font(.footnote)
                            .foregroundStyle(Color.secondary)
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
                                .foregroundStyle(Color.primary)
                                .frame(width: 62, alignment: .leading)
                            Text(lens?.reason ?? "Waiting for score")
                                .font(.caption)
                                .foregroundStyle(Color.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text(lens.map { $0.score >= 0 ? "+\($0.score)" : "\($0.score)" } ?? "—")
                                .font(.caption.weight(.bold).monospacedDigit())
                                .foregroundStyle((lens?.score ?? 0) > 0 ? Color.green : Color.secondary)
                        }
                        .padding(.vertical, 6)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 8)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            Divider().padding(.leading, 14)

            HStack(spacing: 8) {
                if item.status == "considering" {
                    Button("Bought It", action: bought)
                        .prominentButton()
                    Button("Pass", action: pass)
                        .buttonStyle(.bordered)
                } else {
                    CapsuleChip(text: item.status.capitalized)
                }
                Spacer()
                Button("Edit", action: edit)
                    .buttonStyle(.bordered)
                Menu {
                    Button(action: findImage) { Label("Find Image Online", systemImage: "photo.badge.magnifyingglass") }
                } label: {
                    Image(systemName: "ellipsis")
                        .frame(height: 20)
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.circle)
                .accessibilityLabel("More")
            }
            .controlSize(.small)
            .buttonBorderShape(.capsule)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .disabled(store.isOffline)
        }
        .background(WatchTheme.card, in: RoundedRectangle(cornerRadius: WatchTheme.corner, style: .continuous))
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
                            .fill(value > 0 ? Color.green.opacity(min(1, 0.45 + Double(value) * 0.18)) : WatchTheme.fill)
                            .frame(height: 4)
                        Text(name.capitalized)
                            .font(.system(size: 10, weight: .medium))
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                            .foregroundStyle(value > 0 ? Color.primary : Color.secondary)
                    }
                }
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Color.secondary)
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
                .clipShape(RoundedRectangle(cornerRadius: WatchTheme.corner, style: .continuous))
                .overlay(alignment: .topLeading) {
                    PhotoTag(text: "Top Pick").padding(14)
                }
                .overlay(alignment: .topTrailing) {
                    ScoreRing(score: score?.total, maximum: score?.max ?? 14)
                        .padding(8)
                        .glassEffect(.regular, in: .circle)
                        .padding(12)
                }
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 6) {
                Text(item.name)
                    .font(.title2.bold())
                    .fixedSize(horizontal: false, vertical: true)
                Text(item.priceNote.isEmpty ? cad(item.priceExpected) : item.priceNote)
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
            if !highlights.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(highlights.prefix(4), id: \.self) { reason in
                        HStack(alignment: .firstTextBaseline, spacing: 9) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                            Text(reason)
                                .font(.subheadline)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            HStack(spacing: 12) {
                Button("Bought It", action: bought)
                    .prominentButton()
                Button("Details", action: edit)
                    .buttonStyle(.bordered)
                Spacer()
            }
            .controlSize(.large)
            .buttonBorderShape(.capsule)
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
            Circle().stroke(Color.green.opacity(0.2), lineWidth: 6)
            Circle()
                .trim(from: 0, to: fraction)
                .stroke(Color.green, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: -2) {
                Text(score.map(String.init) ?? "—")
                    .font(.figure(.headline))
                Text("/\(maximum)")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Color.secondary)
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
