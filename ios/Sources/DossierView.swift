import SwiftUI

/// A watch's full page: full-bleed photography, then details, story and service like a product page.
/// Editing still happens in WatchDetailScreen, opened from the toolbar.
struct WatchDossierView: View {
    @ObservedObject var store: AppStore
    let watchID: String
    @State private var page = 0
    @Environment(\.dismiss) private var dismiss
    @State private var sheet: DossierSheet?
    @State private var titleInBar = false

    private var watch: Watch? { store.data?.watches.first { $0.id == watchID } }

    var body: some View {
        Group {
            if let watch {
                content(watch)
            } else {
                EmptyCollectionView(title: "Watch removed", detail: "This watch is no longer in the collection.")
            }
        }
        .navigationTitle(titleInBar ? watch?.name ?? "" : "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let watch {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button("Edit") { sheet = .edit }
                        .disabled(store.isOffline)
                    Menu {
                        if let filename = watch.photos[safe: page] ?? watch.photos.first {
                            Button { sheet = .frame(filename) } label: { Label("Frame this photo", systemImage: "crop") }
                        }
                        Button { sheet = .service } label: { Label("Service log", systemImage: "wrench.and.screwdriver") }
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                    .disabled(store.isOffline)
                }
            }
        }
        .onChange(of: watch == nil) { _, removed in
            // Deleted here or by a sync: close any open sheet and leave the page.
            guard removed else { return }
            sheet = nil
            dismiss()
        }
        .sheet(item: $sheet) { item in
            if let watch {
                switch item {
                case .edit:
                    WatchDetailScreen(store: store, watch: watch)
                case .service:
                    MaintenanceSheet(store: store, watchID: watch.id)
                case let .frame(filename):
                    PhotoFramingSheet(
                        asset: store.photoAsset(itemID: watch.id, filename: filename, wishlist: false),
                        allowsRemoteFetch: !store.isOffline,
                        initialFocus: watch.focus(for: filename),
                        aspect: PhotoShape.plate,
                        previews: [("This page", PhotoShape.dossier), ("Grid", PhotoShape.square), ("Portrait", PhotoShape.square)]
                    ) { focus in
                        await store.setPhotoFocus(itemID: watch.id, filename: filename, wishlist: false, focus: focus)
                    }
                }
            }
        }
    }

    private func content(_ watch: Watch) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                hero(watch)
                VStack(alignment: .leading, spacing: 28) {
                    titleBlock(watch)
                    if watch.status != "owned" { statusNote(watch) }
                    details(watch)
                    story(watch)
                    service(watch)
                }
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .padding(.bottom, 40)
            }
        }
        .containerBackground(WatchTheme.background, for: .navigation)
        .ignoresSafeArea(edges: .top)
        // Once the large name has scrolled up under the bar, show it in the bar.
        .onScrollGeometryChange(for: Bool.self) { geometry in
            geometry.contentOffset.y > geometry.containerSize.width / PhotoShape.dossier + 60
        } action: { _, past in
            withAnimation(.easeInOut(duration: 0.2)) { titleInBar = past }
        }
    }

    // MARK: Sections

    private func hero(_ watch: Watch) -> some View {
        Color.clear
            .aspectRatio(PhotoShape.dossier, contentMode: .fit)
            .overlay {
                if watch.photos.isEmpty {
                    WatchPlaceholder()
                } else {
                    TabView(selection: $page) {
                        ForEach(Array(watch.photos.enumerated()), id: \.offset) { index, filename in
                            RemoteWatchImage(
                                asset: store.photoAsset(itemID: watch.id, filename: filename, wishlist: false),
                                allowsRemoteFetch: !store.isOffline,
                                focus: watch.focus(for: filename)
                            )
                            .tag(index)
                        }
                    }
                    .tabViewStyle(.page(indexDisplayMode: watch.photos.count > 1 ? .always : .never))
                }
            }
            .clipped()
            // Pulling down past the top stretches the photo instead of showing a gap.
            .visualEffect { content, proxy in
                let pull = max(0, proxy.frame(in: .scrollView).minY)
                return content
                    .scaleEffect(1 + pull / 400, anchor: .bottom)
            }
    }

    private func titleBlock(_ watch: Watch) -> some View {
        let summary = [cad(watch.price), watch.category, watch.diameter.map { "\(compactNumber($0)) mm" }]
            .compactMap { $0 }
            .joined(separator: " · ")
        return VStack(alignment: .leading, spacing: 8) {
            Text(watch.name)
                .font(.title.bold())
                .fixedSize(horizontal: false, vertical: true)
            Text(summary)
                .font(.body)
                .foregroundStyle(.secondary)
            if watch.isTrade || watch.original == false || fit(watch) != nil {
                HStack(spacing: 8) {
                    if watch.isTrade { CapsuleChip(text: "Trade", color: WatchTheme.accent) }
                    if watch.original == false { CapsuleChip(text: "Replica") }
                    if let fit = fit(watch) { FitIndicator(info: fit) }
                }
                .padding(.top, 2)
            }
        }
    }

    private func fit(_ watch: Watch) -> FitInfo? {
        guard let wrist = store.data?.settings.wrist else { return nil }
        return fitInfo(for: watch.diameter, lugToLug: watch.lugToLug, wrist: wrist)
    }

    private func statusNote(_ watch: Watch) -> some View {
        GroupedSection {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "archivebox.fill")
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 3) {
                    Text(statusLabel(watch.status))
                        .font(.body.weight(.semibold))
                    if !watch.statusNote.isEmpty {
                        Text(watch.statusNote)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(16)
        }
    }

    private func details(_ watch: Watch) -> some View {
        let number = catalogueNumbers(store.data?.watches ?? [])[watch.id]
        return GroupedSection("Details") {
            if let brand = watch.brand { GroupedRow("Brand", value: brand) }
            if let category = watch.category { GroupedRow("Category", value: category) }
            if let diameter = watch.diameter { GroupedRow("Diameter", value: "\(compactNumber(diameter)) mm") }
            if let lugToLug = watch.lugToLug { GroupedRow("Lug to Lug", value: "\(compactNumber(lugToLug)) mm") }
            if let material = watch.material { GroupedRow("Case", value: material) }
            if let dial = watch.dialColor {
                GroupedRow("Dial") {
                    HStack(spacing: 7) {
                        Circle()
                            .fill(dialColor(dial))
                            .frame(width: 12, height: 12)
                            .overlay { Circle().stroke(Color.primary.opacity(0.15), lineWidth: 0.5) }
                        Text(dial)
                    }
                }
            }
            if !watch.purchasedText.isEmpty { GroupedRow(watch.isTrade ? "Acquired" : "Purchased", value: watch.purchasedText) }
            GroupedRow("Catalogue", value: catalogueLabel(number))
        }
    }

    @ViewBuilder
    private func story(_ watch: Watch) -> some View {
        let text = watch.story.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty {
            GroupedSection("Story") {
                Text(text)
                    .font(.body)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(16)
            }
        }
    }

    private func service(_ watch: Watch) -> some View {
        let records = serviceRecords(for: watch)
        let nextDue = records.compactMap(\.nextDue).sorted().first
        return GroupedSection("Service") {
            Button(records.isEmpty ? "Add" : "See All") { sheet = .service }
                .disabled(store.isOffline)
        } content: {
            if let latest = records.last {
                GroupedRow(latest.kind, value: calendarDayLabel(latest.date))
                if let nextDue {
                    GroupedRow("Next Due") {
                        Text(calendarDayLabel(nextDue)).foregroundStyle(WatchTheme.accent)
                    }
                }
            } else {
                Text("No service history logged.")
                    .foregroundStyle(.secondary)
                    .padding(16)
            }
        }
    }
}

private enum DossierSheet: Identifiable {
    case edit, service
    case frame(String)

    var id: String {
        switch self {
        case .edit: "edit"
        case .service: "service"
        case let .frame(filename): "frame-\(filename)"
        }
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
