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
    @Environment(\.pageMargin) private var margin

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
                    .menuIndicator(.hidden)
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

    @ViewBuilder
    private func content(_ watch: Watch) -> some View {
        if Platform.isMac { desktopContent(watch) } else { phoneContent(watch) }
    }

    /// Desktop: the photo fills the left of the window at full size, details scroll on the right.
    private func desktopContent(_ watch: Watch) -> some View {
        HStack(spacing: 0) {
            ZStack {
                WatchTheme.card
                if watch.photos.isEmpty {
                    WatchPlaceholder()
                } else {
                    PhotoPager(selection: $page, count: watch.photos.count) { index in
                        RemoteWatchImage(
                            asset: store.photoAsset(itemID: watch.id, filename: watch.photos[index], wishlist: false),
                            allowsRemoteFetch: !store.isOffline,
                            fitWholePhoto: true,
                            maxPixel: DisplayImageCache.full
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 36) {
                    titleBlock(watch)
                    if let statement = statement(watch) {
                        statement
                            .padding(.horizontal, -24)
                    }
                    if watch.status != "owned" { statusNote(watch) }
                    details(watch)
                    story(watch)
                    service(watch)
                }
                .padding(24)
            }
            .frame(width: 400)
            .screenBackground()
        }
    }

    private func phoneContent(_ watch: Watch) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                hero(watch)
                titleBlock(watch)
                    .padding(.horizontal, margin)
                    .padding(.top, 24)
                    .padding(.bottom, 32)
                // Full bleed: the statement panel runs edge to edge.
                if let statement = statement(watch) {
                    statement
                        .padding(.bottom, 36)
                }
                VStack(alignment: .leading, spacing: 40) {
                    if watch.status != "owned" { statusNote(watch) }
                    details(watch)
                    story(watch)
                    service(watch)
                }
                .padding(.horizontal, margin)
                .padding(.bottom, 48)
            }
        }
        .atelierProbeScroll("dossier")
        .screenBackground()
        .ignoresSafeArea(edges: .top)
        // Once the large name has scrolled up under the bar, show it in the bar.
        .onScrollGeometryChange(for: Bool.self) { geometry in
            geometry.contentOffset.y > geometry.containerSize.width / PhotoShape.dossier - 10
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
                    PhotoPager(selection: $page, count: watch.photos.count) { index in
                        RemoteWatchImage(
                            asset: store.photoAsset(itemID: watch.id, filename: watch.photos[index], wishlist: false),
                            allowsRemoteFetch: !store.isOffline,
                            focus: watch.focus(for: watch.photos[index])
                        )
                    }
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
        let number = catalogueNumbers(store.data?.watches ?? [])[watch.id]
        let kicker = watch.brand?.isEmpty == false ? watch.brand : watch.category
        // The kicker already says the category when there is no brand, so the line under the name skips it.
        let summary = [
            kicker == watch.category ? nil : watch.category,
            watch.diameter.map { "\(compactNumber($0)) mm" },
            watch.material,
        ]
        .compactMap { $0 }
        .joined(separator: ", ")
        return VStack(alignment: .leading, spacing: 10) {
            if let kicker { Eyebrow(kicker) }
            Text(watch.name)
                .font(Platform.isMac ? AtelierType.displayLarge : AtelierType.display)
                .tracking(-0.6)
                .foregroundStyle(WatchTheme.ink)
                .fixedSize(horizontal: false, vertical: true)
            if !summary.isEmpty {
                Text(summary)
                    .font(AtelierType.body)
                    .foregroundStyle(WatchTheme.muted)
            }
            HStack(alignment: .firstTextBaseline, spacing: 14) {
                Text(catalogueLabel(number))
                    .font(AtelierType.kicker)
                    .tracking(1.4)
                    .foregroundStyle(WatchTheme.gold)
                Text(cad(watch.price))
                    .font(.system(.body, weight: .regular))
                    .foregroundStyle(WatchTheme.ink)
            }
            .padding(.top, 2)
            if watch.isTrade || watch.original == false || fit(watch) != nil {
                HStack(spacing: 8) {
                    if watch.isTrade { CapsuleChip(text: "Trade", color: WatchTheme.accent) }
                    if watch.original == false { CapsuleChip(text: "Replica") }
                    if let fit = fit(watch) { FitIndicator(info: fit) }
                }
                .padding(.top, 4)
            }
        }
    }

    /// One sentence built from the watch's own fields, on a full-width panel.
    private func statement(_ watch: Watch) -> AnyView? {
        guard let parts = statementParts(name: watch.name, material: watch.material, dialColor: watch.dialColor)
        else { return nil }
        // One Text built run by run, so the sentence wraps as a single paragraph.
        let sentence = parts.reduce(Text(verbatim: "")) { text, part in
            Text("\(text)\(Text(verbatim: part.text).foregroundStyle(part.emphasized ? WatchTheme.ink : WatchTheme.muted))")
        }
        return AnyView(
            VStack(alignment: .leading, spacing: 12) {
                if let category = watch.category { Eyebrow(category) }
                sentence
                    .font(AtelierType.heading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 28)
            .padding(.horizontal, Platform.isMac ? 24 : margin)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(WatchTheme.card)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(statementSentence(parts))
        )
    }

    private func fit(_ watch: Watch) -> FitInfo? {
        guard let wrist = store.data?.settings.wrist else { return nil }
        return fitInfo(for: watch.diameter, lugToLug: watch.lugToLug, wrist: wrist)
    }

    /// Where an archived watch went, on a square panel.
    private func statusNote(_ watch: Watch) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "archivebox.fill")
                .foregroundStyle(WatchTheme.muted)
            VStack(alignment: .leading, spacing: 4) {
                Text(statusLabel(watch.status))
                    .font(.system(.body, weight: .bold))
                    .foregroundStyle(WatchTheme.ink)
                if !watch.statusNote.isEmpty {
                    Text(watch.statusNote)
                        .font(AtelierType.detail)
                        .foregroundStyle(WatchTheme.muted)
                }
            }
            Spacer(minLength: 0)
        }
        .groupedCard()
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
                            .overlay { Circle().stroke(WatchTheme.separator, lineWidth: 0.5) }
                        Text(dial)
                    }
                }
            }
            if !watch.purchasedText.isEmpty { GroupedRow(watch.isTrade ? "Acquired" : "Purchased", value: watch.purchasedText) }
            if let sale = watch.salePrice {
                GroupedRow("Sold for", value: [cad(sale), soldMonthLabel(watch.soldOn)].filter { !$0.isEmpty }.joined(separator: " · "))
            }
            GroupedRow("Catalogue", value: catalogueLabel(number))
        }
    }

    @ViewBuilder
    private func story(_ watch: Watch) -> some View {
        let text = watch.story.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty {
            GroupedSection("Story") {
                Text(text)
                    .font(AtelierType.body)
                    .lineSpacing(5)
                    .foregroundStyle(WatchTheme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 16)
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
                    .font(AtelierType.detail)
                    .foregroundStyle(WatchTheme.muted)
                    .padding(.vertical, 16)
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
