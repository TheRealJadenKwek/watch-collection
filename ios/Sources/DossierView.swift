import SwiftUI

/// A watch's full page: full-bleed photography, spec sheet, story and service.
/// Editing still happens in WatchDetailScreen, opened from the toolbar.
struct WatchDossierView: View {
    @ObservedObject var store: AppStore
    let watchID: String
    @State private var page = 0
    @Environment(\.dismiss) private var dismiss
    @State private var sheet: DossierSheet?

    private var watch: Watch? { store.data?.watches.first { $0.id == watchID } }

    var body: some View {
        Group {
            if let watch {
                content(watch)
            } else {
                EmptyCollectionView(title: "Watch removed", detail: "This watch is no longer in the collection.")
            }
        }
        .background(WatchTheme.background.ignoresSafeArea())
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
                VStack(alignment: .leading, spacing: 34) {
                    titleBlock(watch)
                    if watch.status != "owned" { statusNote(watch) }
                    specSheet(watch)
                    story(watch)
                    service(watch)
                }
                .padding(.horizontal, 20)
                .padding(.top, 4)
                .padding(.bottom, 48)
            }
        }
        .ignoresSafeArea(edges: .top)
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
            .overlay(alignment: .bottom) {
                LinearGradient(colors: [.clear, WatchTheme.background], startPoint: .top, endPoint: .bottom)
                    .frame(height: 120)
                    .allowsHitTesting(false)
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
        let eyebrow = [catalogueLabel(number), watch.purchasedText.isEmpty ? nil : watch.purchasedText]
            .compactMap { $0 }
            .joined(separator: " · ")
        return VStack(alignment: .leading, spacing: 10) {
            Eyebrow(eyebrow)
            Text(watch.name)
                .font(.display(38, relativeTo: .largeTitle))
                .foregroundStyle(WatchTheme.ivory)
                .fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(cad(watch.price))
                    .font(.display(24))
                    .foregroundStyle(WatchTheme.gold)
                if watch.isTrade { PhotoTag(text: "Trade", color: WatchTheme.gold) }
                if watch.original == false { PhotoTag(text: "Replica") }
                Spacer()
                if let wrist = store.data?.settings.wrist,
                   let fit = fitInfo(for: watch.diameter, lugToLug: watch.lugToLug, wrist: wrist) {
                    FitIndicator(info: fit)
                }
            }
        }
    }

    private func statusNote(_ watch: Watch) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "archivebox")
                .foregroundStyle(WatchTheme.gold)
            VStack(alignment: .leading, spacing: 4) {
                Text(statusLabel(watch.status))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(WatchTheme.ivory)
                if !watch.statusNote.isEmpty {
                    Text(watch.statusNote)
                        .font(.footnote)
                        .foregroundStyle(WatchTheme.secondary)
                }
            }
            Spacer()
        }
        .padding(14)
        .watchCard(cornerRadius: 16)
    }

    private func specSheet(_ watch: Watch) -> some View {
        let specs: [(String, String, String?)] = [
            ("Diameter", watch.diameter.map { "\(compactNumber($0)) mm" } ?? "—", nil),
            ("Lug to lug", watch.lugToLug.map { "\(compactNumber($0)) mm" } ?? "—", nil),
            ("Case", watch.material ?? "—", nil),
            ("Dial", watch.dialColor ?? "—", watch.dialColor),
            ("Category", watch.category ?? "—", nil),
            ("Brand", watch.brand ?? "—", nil),
        ]
        return VStack(alignment: .leading, spacing: 16) {
            GoldRule()
            Eyebrow("Specification")
            LazyVGrid(columns: [GridItem(.flexible(), alignment: .topLeading), GridItem(.flexible(), alignment: .topLeading)], alignment: .leading, spacing: 20) {
                ForEach(specs, id: \.0) { label, value, dial in
                    VStack(alignment: .leading, spacing: 5) {
                        Eyebrow(label, color: WatchTheme.secondary)
                        HStack(spacing: 7) {
                            if let dial {
                                Circle()
                                    .fill(dialColor(dial))
                                    .frame(width: 11, height: 11)
                                    .overlay { Circle().stroke(Color.white.opacity(0.4), lineWidth: 0.5) }
                            }
                            Text(value)
                                .font(.display(20))
                                .foregroundStyle(WatchTheme.ivory)
                                .lineLimit(2)
                                .minimumScaleFactor(0.8)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func story(_ watch: Watch) -> some View {
        let text = watch.story.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                GoldRule()
                Eyebrow("The story")
                Text("“\(text)”")
                    .font(.displayItalic(22))
                    .foregroundStyle(WatchTheme.ivory.opacity(0.92))
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func service(_ watch: Watch) -> some View {
        let records = serviceRecords(for: watch)
        let nextDue = records.compactMap(\.nextDue).sorted().first
        return VStack(alignment: .leading, spacing: 14) {
            GoldRule()
            HStack(alignment: .firstTextBaseline) {
                Eyebrow("Service")
                Spacer()
                Button(records.isEmpty ? "Add record" : "Service log") { sheet = .service }
                    .font(.caption.weight(.semibold))
                    .disabled(store.isOffline)
            }
            if let latest = records.last {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(latest.kind)
                            .font(.display(20))
                            .foregroundStyle(WatchTheme.ivory)
                        Text(calendarDayLabel(latest.date))
                            .font(.caption)
                            .foregroundStyle(WatchTheme.secondary)
                    }
                    Spacer()
                    if let nextDue {
                        VStack(alignment: .trailing, spacing: 3) {
                            Text("Next due")
                                .font(.caption)
                                .foregroundStyle(WatchTheme.secondary)
                            Text(calendarDayLabel(nextDue))
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(WatchTheme.gold)
                        }
                    }
                }
            } else {
                Text("No service history logged.")
                    .font(.footnote)
                    .foregroundStyle(WatchTheme.secondary)
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
