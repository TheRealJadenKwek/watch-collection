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
    /// The title block's height on the inner screen's scrolling pane, for when to show the name in the bar.
    @State private var titleHeight: CGFloat = 120
    @Environment(\.pageMargin) private var margin
    @Environment(\.duo) private var duo
    /// Where the page is scrolled to, kept when the phone is opened or shut.
    @State private var fold = FoldScroll()
    /// The hero's height where it scrolls with the page.
    @State private var heroLead: CGFloat = 0

    private var watch: Watch? { store.data?.watches.first { $0.id == watchID } }

    var body: some View {
        Group {
            if let watch {
                content(watch)
            } else {
                EmptyCollectionView(title: "Watch removed", detail: "This watch is no longer in the collection.")
            }
        }
        .keepsScrollAcrossFolds($fold)
        // Held like a book the bar's title would sit on the crease: the right page pins the name instead.
        .navigationTitle(titleInBar && !duo.isBook ? watch?.name ?? "" : "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let watch {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button("Edit") { sheet = .edit }
                        .disabled(store.isOffline)
                    Menu {
                        // The render frames itself: on its page there is no photo to frame.
                        if let filename = pages(watch).photo(page) {
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
        #if DEBUG
        .task {
            guard AtelierProbe.opensEdit, watch != nil else { return }
            try? await Task.sleep(for: .seconds(2))
            sheet = .edit
        }
        #endif
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
        if Platform.isMac {
            desktopContent(watch)
        } else if duo.isBook || duo.isTableTop {
            panesContent(watch)
        } else {
            phoneContent(watch)
        }
    }

    /// Desktop: the photo fills the left of the window at full size, details scroll on the right.
    private func desktopContent(_ watch: Watch) -> some View {
        HStack(spacing: 0) {
            ZStack {
                WatchTheme.card
                let pages = pages(watch)
                if pages.isEmpty {
                    WatchPlaceholder()
                } else {
                    PhotoPager(selection: $page, count: pages.count) { index in
                        picture(index, of: pages, watch: watch, fitWholePhoto: true, maxPixel: DisplayImageCache.full)
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
                    // On a cover screen the photo runs under the status strip to the edge.
                    .runsUnderStatusStrip(duo)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { heroLead = $0 }
                pageText(watch)
            }
        }
        .atelierProbeScroll("dossier")
        .foldScroll($fold, lead: heroLead)
        .screenBackground()
        .ignoresSafeArea(edges: .top)
        // Once the large name has scrolled up under the bar, show it in the bar.
        .onScrollGeometryChange(for: Bool.self) { geometry in
            geometry.contentOffset.y > (heroHeight ?? geometry.containerSize.width / PhotoShape.dossier) - 10
        } action: { _, past in
            withAnimation(.easeInOut(duration: 0.2)) { titleInBar = past }
        }
    }

    /// The inner screen held like a book or half open on a table: the photos fill the left page (or the pane above
    /// the crease) and stay put, the title, statement and specs scroll on the right page (or below the crease).
    private func panesContent(_ watch: Watch) -> some View {
        // The photos run up under the navigation bar, as the phone's hero does. A page-style TabView keeps its pages
        // below the bars wherever it is put, unless it stands in a scroll view that runs under them, as the hero does:
        // so it stands in one that cannot scroll, the size of the pane.
        CreasePanes(firstRunsToTop: true) {
            GeometryReader { pane in
                ScrollView {
                    photos(watch)
                        .frame(width: pane.size.width, height: pane.size.height)
                }
                .scrollDisabled(true)
                .ignoresSafeArea(.container, edges: .top)
            }
            .clipped()
        } second: {
            ScrollView {
                pageText(watch)
            }
            .atelierProbeScroll("dossier")
            .foldScroll($fold)
            // Once the title block has scrolled away under the bar, show the name in the bar.
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentOffset.y + geometry.contentInsets.top > 24 + titleHeight - 20
            } action: { _, past in
                withAnimation(.easeInOut(duration: 0.2)) { titleInBar = past }
            }
            .overlay(alignment: .top) {
                if duo.isBook && titleInBar {
                    pinnedTitle(watch)
                        .transition(.opacity)
                }
            }
        }
        .screenBackground()
    }

    /// Held like a book, the name pinned to the top of the right page once the title block has scrolled away: the
    /// bar's title would sit on the crease.
    private func pinnedTitle(_ watch: Watch) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let kicker = watch.brand?.isEmpty == false ? watch.brand : watch.category { Eyebrow(kicker) }
            Text(watch.name)
                .font(AtelierType.cardTitle)
                .foregroundStyle(WatchTheme.ink)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, margin)
        .padding(.top, 8)
        .padding(.bottom, 10)
        .overlay(alignment: .bottom) {
            Hairline()
                .padding(.horizontal, margin)
        }
        // Runs on up behind the bar, so the text pane does not show through above the name.
        .background(WatchTheme.background)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    /// Everything under the photo: the title block, the statement, and the spec lists.
    private func pageText(_ watch: Watch) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            titleBlock(watch)
                .padding(.horizontal, margin)
                .padding(.top, 24)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { titleHeight = $0 }
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

    /// The hero's height where it is not the phone's shape: on a cover screen the phone's shape across the width
    /// left of the status strip, and with the crease across exactly the top half, down to the crease's clear band.
    private var heroHeight: CGFloat? {
        if duo.posture == .folded { return (duo.size.width - duo.statusStrip) / PhotoShape.dossier }
        if duo.isAcross, let crease = duo.crease { return crease - DuoLayout.creaseClearance }
        return nil
    }

    // MARK: Sections

    private func hero(_ watch: Watch) -> some View {
        Group {
            if let heroHeight {
                Color.clear.frame(height: heroHeight)
            } else {
                Color.clear.aspectRatio(PhotoShape.dossier, contentMode: .fit)
            }
        }
        .overlay { photos(watch) }
        .clipped()
        // Pulling down past the top stretches the photo instead of showing a gap.
        .visualEffect { content, proxy in
            let pull = max(0, proxy.frame(in: .scrollView).minY)
            return content
                .scaleEffect(1 + pull / 400, anchor: .bottom)
        }
    }

    /// The pictures to swipe through: the render first when the watch has one, then its photos.
    private func pages(_ watch: Watch) -> CoverPages {
        CoverPages(cover: watch.cover, photos: watch.photos)
    }

    /// The render first (so the page opens on the picture its tile showed), then the photos, each filling the frame
    /// in its saved framing.
    @ViewBuilder
    private func photos(_ watch: Watch) -> some View {
        let pages = pages(watch)
        if pages.isEmpty {
            WatchPlaceholder()
        } else {
            PhotoPager(selection: $page, count: pages.count) { index in
                picture(index, of: pages, watch: watch, fitWholePhoto: false, maxPixel: DisplayImageCache.page)
            }
        }
    }

    /// One page of the pager: the render, or a photo (whole on the desktop, in its saved framing elsewhere).
    @ViewBuilder
    private func picture(_ index: Int, of pages: CoverPages, watch: Watch, fitWholePhoto: Bool, maxPixel: Int) -> some View {
        if pages.isRender(index) {
            RemoteWatchImage(cover: pages.render, allowsRemoteFetch: !store.isOffline, maxPixel: maxPixel)
        } else if let filename = pages.photo(index) {
            RemoteWatchImage(
                asset: store.photoAsset(itemID: watch.id, filename: filename, wishlist: false),
                allowsRemoteFetch: !store.isOffline,
                focus: fitWholePhoto ? nil : watch.focus(for: filename),
                fitWholePhoto: fitWholePhoto,
                maxPixel: maxPixel
            )
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
            // Edge to edge, but on a cover screen it stops at the status strip rather than running on under it.
            .background(WatchTheme.card, ignoresSafeAreaEdges: duo.statusStrip > 0 ? Edge.Set.all.subtracting(.trailing) : .all)
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
            if watch.status == "owned" { boxRow(watch) }
        }
    }

    /// "Box": where the watch sits, or "Put in a box". Either opens the Boxes tab on it.
    private func boxRow(_ watch: Watch) -> some View {
        let space = store.data.flatMap { BoxModel.location(of: watch.id, in: $0) }
        let place = space.flatMap { space in
            store.data?.boxes?.first { $0.id == space.boxID }?.placeName(space.slot)
        }
        return GroupedRow("Box") {
            Button {
                store.openBoxes(place == nil ? .place(watch.id) : .show(watch.id))
            } label: {
                Text(place ?? "Put in a box")
                    .foregroundStyle(WatchTheme.accent)
            }
            .buttonStyle(.plain)
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
