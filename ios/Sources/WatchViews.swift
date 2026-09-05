import PhotosUI
import SwiftUI
import UniformTypeIdentifiers
import UIKit

struct CollectionScreen: View {
    @ObservedObject var store: AppStore
    let showSettings: () -> Void
    @State private var search = ""
    @State private var presentedSheet: CollectionSheet?

    private let columns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12),
    ]

    private var watches: [Watch] {
        guard let data = store.data else { return [] }
        return data.watches
            .filter { $0.status == "owned" }
            .filter { search.isEmpty || "\($0.name) \($0.story)".localizedCaseInsensitiveContains(search) }
            .sorted { $0.price > $1.price }
    }

    var body: some View {
        NavigationStack {
            RefreshableScreen(store: store) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        collectionHeader
                        if watches.isEmpty {
                            EmptyCollectionView(title: "No watches found", detail: "Try a different search.")
                                .frame(minHeight: 360)
                        } else {
                            LazyVGrid(columns: columns, spacing: 12) {
                                ForEach(watches) { watch in
                                    Button { presentedSheet = .watch(watch) } label: {
                                        WatchCardView(store: store, watch: watch, isPast: false)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                    .padding(14)
                    .padding(.bottom, 12)
                }
                .background(WatchTheme.background)
            }
            .searchable(text: $search, prompt: "Name or story")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("My Collection").font(.headline).serifTitle()
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button { presentedSheet = .addWatch } label: { Image(systemName: "plus") }
                        .disabled(store.isOffline)
                    GearToolbarButton(action: showSettings)
                }
            }
            .sheet(item: $presentedSheet) { sheet in
                switch sheet {
                case let .watch(watch):
                    WatchDetailScreen(store: store, watch: watch)
                case .addWatch:
                    WatchDetailScreen(store: store, watch: .newDraft, isNew: true)
                case .wearToday:
                    WearTodaySheet(store: store)
                }
            }
        }
    }

    private var collectionHeader: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(alignment: .lastTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("CURRENT ROTATION")
                        .font(.caption2.weight(.bold))
                        .tracking(1.5)
                        .foregroundStyle(WatchTheme.gold)
                    Text("\(watches.count) owned watches")
                        .font(.title2.weight(.semibold))
                        .serifTitle()
                }
                Spacer()
                Text(cad(watches.reduce(0) { $0 + $1.price }))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(WatchTheme.gold)
            }
            Button {
                presentedSheet = .wearToday
            } label: {
                Label("Log today’s wear", systemImage: "watch.analog")
                    .frame(maxWidth: .infinity, minHeight: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(watches.isEmpty || store.isOffline)
        }
    }
}

private enum CollectionSheet: Identifiable {
    case watch(Watch)
    case addWatch
    case wearToday

    var id: String {
        switch self {
        case let .watch(watch): "watch-\(watch.id)"
        case .addWatch: "add-watch"
        case .wearToday: "wear-today"
        }
    }
}

struct PastScreen: View {
    @ObservedObject var store: AppStore
    let showSettings: () -> Void
    @State private var search = ""
    @State private var statusFilter = ""
    @State private var selectedWatch: Watch?

    private let columns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12),
    ]

    private var statuses: [String] {
        Array(Set(store.data?.watches.filter { $0.status != "owned" }.map(\Watch.status) ?? [])).sorted()
    }

    private var watches: [Watch] {
        guard let data = store.data else { return [] }
        return data.watches
            .filter { $0.status != "owned" }
            .filter { statusFilter.isEmpty || $0.status == statusFilter }
            .filter { search.isEmpty || "\($0.name) \($0.story) \($0.statusNote)".localizedCaseInsensitiveContains(search) }
            .sorted { ($0.purchased ?? "") > ($1.purchased ?? "") }
    }

    var body: some View {
        NavigationStack {
            RefreshableScreen(store: store) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("THE ARCHIVE")
                                    .font(.caption2.weight(.bold))
                                    .tracking(1.5)
                                    .foregroundStyle(WatchTheme.gold)
                                Text("\(watches.count) past watches")
                                    .font(.title2.weight(.semibold))
                                    .serifTitle()
                            }
                            Spacer()
                            Menu {
                                Picker("Status", selection: $statusFilter) {
                                    Text("All outcomes").tag("")
                                    ForEach(statuses, id: \.self) { status in
                                        Text(statusLabel(status)).tag(status)
                                    }
                                }
                            } label: {
                                Label(statusFilter.isEmpty ? "All" : statusLabel(statusFilter), systemImage: "line.3.horizontal.decrease.circle")
                                    .font(.caption.weight(.semibold))
                            }
                        }
                        if watches.isEmpty {
                            EmptyCollectionView(title: "No past watches found", detail: "Change the search or status filter.")
                                .frame(minHeight: 360)
                        } else {
                            LazyVGrid(columns: columns, spacing: 12) {
                                ForEach(watches) { watch in
                                    Button { selectedWatch = watch } label: {
                                        WatchCardView(store: store, watch: watch, isPast: true)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                    .padding(14)
                    .padding(.bottom, 12)
                }
                .background(WatchTheme.background)
            }
            .searchable(text: $search, prompt: "Name, story, or note")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("Past Watches").font(.headline).serifTitle()
                }
                ToolbarItem(placement: .topBarTrailing) { GearToolbarButton(action: showSettings) }
            }
            .sheet(item: $selectedWatch) { watch in
                WatchDetailScreen(store: store, watch: watch)
            }
        }
    }
}

struct WatchCardView: View {
    @ObservedObject var store: AppStore
    let watch: Watch
    let isPast: Bool

    private var wrist: WristProfile? { store.data?.settings.wrist }
    private var coverAsset: PhotoAsset? {
        watch.photos.first.flatMap { store.photoAsset(itemID: watch.id, filename: $0, wishlist: false) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .topLeading) {
                RemoteWatchImage(asset: coverAsset, allowsRemoteFetch: !store.isOffline)
                    .frame(height: 142)
                    .clipped()
                    .allowsHitTesting(false)
                if isPast {
                    CapsuleChip(text: statusLabel(watch.status), color: WatchTheme.gold, filled: true)
                        .padding(8)
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                // Every card reserves the same name/note space so grid rows stay perfectly even.
                Text(watch.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2, reservesSpace: true)
                    .multilineTextAlignment(.leading)
                Text(cad(watch.price))
                    .font(.caption.weight(.bold))
                    .foregroundStyle(WatchTheme.gold)
                if isPast {
                    Text(watch.statusNote)
                        .font(.caption2)
                        .foregroundStyle(WatchTheme.secondary)
                        .lineLimit(1, reservesSpace: true)
                }
                ChipFlowLayout(spacing: 5) {
                    CapsuleChip(text: watch.category ?? "Uncategorised")
                    if let wrist, let fit = fitInfo(for: watch.diameter, lugToLug: watch.lugToLug, wrist: wrist) {
                        FitChip(info: fit)
                    }
                    if watch.original == false {
                        CapsuleChip(text: "Rep", color: WatchTheme.gold)
                    }
                    if let material = watch.material {
                        CapsuleChip(text: material)
                    }
                }
                .frame(height: 51, alignment: .topLeading)
                .clipped()
            }
            .padding(11)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .watchCard()
        // Clipping changes drawing only. Keep the scaled photo's hit area inside
        // the visible card so it cannot intercept the wear button or nearby cards.
        .contentShape(.interaction, RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

struct WatchDetailScreen: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: AppStore
    let isNew: Bool
    @State private var draft: Watch
    @State private var selectedPhotoIndex = 0
    @State private var photoItem: PhotosPickerItem?
    @State private var pendingPhotos: [PendingWatchPhoto] = []
    @State private var showCamera = false
    @State private var isSaving = false
    @State private var confirmDelete = false
    @State private var activitySheet: WatchActivitySheet?

    init(store: AppStore, watch: Watch, isNew: Bool = false) {
        self.store = store
        self.isNew = isNew
        var initial = watch
        if isNew {
            initial.purchased = initial.purchased ?? currentPurchaseMonth()
            initial.purchasedText = purchaseMonthLabel(initial.purchased)
            if let category = UserDefaults.standard.string(forKey: WatchEditorDefaults.category),
               store.data?.categories.contains(category) == true {
                initial.category = category
            }
            if let dialColor = UserDefaults.standard.string(forKey: WatchEditorDefaults.dialColor),
               store.data?.dialColors.contains(dialColor) == true {
                initial.dialColor = dialColor
            }
            if let material = UserDefaults.standard.string(forKey: WatchEditorDefaults.material),
               store.data?.materials.contains(material) == true {
                initial.material = material
            }
        }
        _draft = State(initialValue: initial)
    }

    var body: some View {
        NavigationStack {
            Form {
                if !validationIssues.isEmpty { validationSection }
                photoSection
                identitySection
                sizingSection
                purchaseSection
                if !isNew { ownershipSection }
                storySection
            }
            .scrollContentBackground(.hidden)
            .background(WatchTheme.background)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                ToolbarItem(placement: .principal) {
                    Text(isNew ? "Add Watch" : "Watch Details").font(.headline).serifTitle()
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isSaving ? "Saving…" : "Save") { save() }
                        .disabled(store.isOffline || isSaving || !validationIssues.isEmpty)
                }
            }
            .onChange(of: photoItem) { _, item in
                guard let item else { return }
                Task { await importPhoto(item) }
            }
            .onChange(of: draft.status) { _, status in
                if status == "owned", purchaseMonthParts(draft.purchased) == nil {
                    draft.purchased = currentPurchaseMonth()
                    draft.purchasedText = purchaseMonthLabel(draft.purchased)
                }
            }
            .fullScreenCover(isPresented: $showCamera) {
                CameraPicker { image in
                    guard let data = image.jpegData(compressionQuality: 0.9) else { return }
                    Task { await upload(data: data, filename: "camera-\(UUID().uuidString).jpg", mimeType: "image/jpeg") }
                }
                .ignoresSafeArea()
            }
            .sheet(item: $activitySheet, onDismiss: reloadDraft) { sheet in
                switch sheet {
                case .wearHistory:
                    WearHistorySheet(store: store, watchID: draft.id)
                case .maintenance:
                    MaintenanceSheet(store: store, watchID: draft.id)
                }
            }
            .confirmationDialog("Delete \(draft.name)?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete watch", role: .destructive) {
                    Task { await store.deleteWatch(id: draft.id); dismiss() }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The record and its photos will be removed permanently.")
            }
        }
        .preferredColorScheme(.dark)
    }

    private var photoSection: some View {
        Section("Gallery") {
            if isNew, pendingPhotos.isEmpty {
                WatchPlaceholder()
                    .frame(height: 230)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
            } else if isNew {
                TabView(selection: $selectedPhotoIndex) {
                    ForEach(Array(pendingPhotos.enumerated()), id: \.element.id) { index, pending in
                        Group {
                            if let image = UIImage(data: pending.data) {
                                Image(uiImage: image)
                                    .resizable()
                                    .scaledToFill()
                            } else {
                                WatchPlaceholder()
                            }
                        }
                            .frame(height: 250)
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                            .tag(index)
                    }
                }
                .frame(height: 260)
                .tabViewStyle(.page(indexDisplayMode: .automatic))
                if pendingPhotos.indices.contains(selectedPhotoIndex) {
                    HStack {
                        Button("Set cover") {
                            let photo = pendingPhotos.remove(at: selectedPhotoIndex)
                            pendingPhotos.insert(photo, at: 0)
                            selectedPhotoIndex = 0
                        }
                        Spacer()
                        Button("Delete photo", role: .destructive) {
                            pendingPhotos.remove(at: selectedPhotoIndex)
                            selectedPhotoIndex = min(selectedPhotoIndex, max(0, pendingPhotos.count - 1))
                        }
                    }
                }
            } else if draft.photos.isEmpty {
                WatchPlaceholder()
                    .frame(height: 230)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
            } else {
                existingPhotoGallery
            }
            HStack {
                PhotosPicker(selection: $photoItem, matching: .images) {
                    Label("Photos", systemImage: "photo.on.rectangle")
                }
                Spacer()
                Button { showCamera = true } label: { Label("Camera", systemImage: "camera") }
            }
            // Borderless keeps each control its own tap target — otherwise the Form row
            // acts as one big button and every tap opens the camera.
            .buttonStyle(.borderless)
            .disabled(store.isOffline)
            if isNew {
                Text(pendingPhotos.isEmpty
                     ? "Add photos now; they will be saved with the new watch."
                     : "\(pendingPhotos.count) photo\(pendingPhotos.count == 1 ? "" : "s") ready to save. The first photo is the cover.")
                    .font(.caption)
                    .foregroundStyle(WatchTheme.secondary)
            }
        }
    }

    @ViewBuilder
    private var existingPhotoGallery: some View {
        TabView(selection: $selectedPhotoIndex) {
            ForEach(Array(draft.photos.enumerated()), id: \.offset) { index, filename in
                RemoteWatchImage(
                    asset: store.photoAsset(itemID: draft.id, filename: filename, wishlist: false),
                    allowsRemoteFetch: !store.isOffline
                )
                .frame(height: 250)
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .tag(index)
            }
        }
        .frame(height: 260)
        .tabViewStyle(.page(indexDisplayMode: .automatic))
        if draft.photos.indices.contains(selectedPhotoIndex) {
            let filename = draft.photos[selectedPhotoIndex]
            HStack {
                Button("Set cover") {
                    Task {
                        await store.setCover(itemID: draft.id, filename: filename, wishlist: false)
                        reloadDraft()
                        selectedPhotoIndex = 0
                    }
                }
                Spacer()
                Button("Delete photo", role: .destructive) {
                    Task {
                        await store.deletePhoto(itemID: draft.id, filename: filename, wishlist: false)
                        reloadDraft()
                        selectedPhotoIndex = 0
                    }
                }
            }
            .disabled(store.isOffline)
        }
    }

    private var validationSection: some View {
        Section("Required before saving") {
            ForEach(validationIssues, id: \.self) { issue in
                Label(issue, systemImage: "exclamationmark.circle")
                    .font(.caption)
                    .foregroundStyle(WatchTheme.amber)
            }
        }
    }

    private var identitySection: some View {
        Section("Identity") {
            TextField("Name (required)", text: $draft.name)
            TextField("Brand", text: Binding(get: { draft.brand ?? "" }, set: { draft.brand = $0.isEmpty ? nil : $0 }))
            Picker("Category", selection: optionalSelectionBinding($draft.category)) {
                Text("Unset").tag("")
                ForEach(store.data?.categories ?? [], id: \.self) { Text($0).tag($0) }
            }
            Picker("Dial colour", selection: optionalSelectionBinding($draft.dialColor)) {
                Text("Unset").tag("")
                ForEach(store.data?.dialColors ?? [], id: \.self) { Text($0).tag($0) }
            }
            Picker("Case material", selection: optionalSelectionBinding($draft.material)) {
                Text("Unset").tag("")
                ForEach(store.data?.materials ?? [], id: \.self) { Text($0).tag($0) }
            }
        }
    }

    private var sizingSection: some View {
        Section("Sizing & fit") {
            TextField("Diameter (mm)", text: optionalNumberBinding($draft.diameter))
                .keyboardType(.decimalPad)
            TextField("Lug-to-lug (mm)", text: optionalNumberBinding($draft.lugToLug))
                .keyboardType(.decimalPad)
            if let wrist = store.data?.settings.wrist,
               let fit = fitInfo(for: draft.diameter, lugToLug: draft.lugToLug, wrist: wrist) {
                HStack { Text("Fit"); Spacer(); FitChip(info: fit) }
            }
        }
    }

    private var purchaseSection: some View {
        Section("Purchase & status") {
            TextField("Price paid (CAD)", value: $draft.price, format: .number)
                .keyboardType(.decimalPad)
            MonthYearPicker(value: $draft.purchased, allowsUnknown: draft.status != "owned")
            if !purchaseMonthLabel(draft.purchased).isEmpty {
                LabeledContent("Timeline date", value: purchaseMonthLabel(draft.purchased))
                    .font(.caption)
                    .foregroundStyle(WatchTheme.secondary)
            }
            Picker("Original design", selection: Binding(
                get: { draft.original.map { $0 ? "true" : "false" } ?? "" },
                set: { draft.original = $0.isEmpty ? nil : $0 == "true" }
            )) {
                Text("Unknown").tag("")
                Text("Original").tag("true")
                Text("Rep / homage").tag("false")
            }
            Picker("Status", selection: $draft.status) {
                ForEach(WatchStatus.allCases) { status in Text(status.label).tag(status.rawValue) }
            }
            TextField("Status note", text: $draft.statusNote, axis: .vertical)
        }
    }

    private var storySection: some View {
        Section("Story") {
            TextField("What makes this watch memorable?", text: $draft.story, axis: .vertical)
                .lineLimit(4...10)
            if !isNew {
                Button("Delete watch", role: .destructive) { confirmDelete = true }
                    .disabled(store.isOffline)
            }
        }
    }

    private var ownershipSection: some View {
        let sessions = wearSessions(for: draft)
        let services = serviceRecords(for: draft)
        let serviceCost = services.compactMap(\.cost).reduce(0, +)
        let totalMinutes = sessions.reduce(0) { $0 + $1.durationMinutes }
        let todayMinutes = wearMinutes(for: draft, on: calendarDayKey())
        let nextDue = services.compactMap(\.nextDue).sorted().first
        return Section("Wear & service") {
            if draft.status == "owned" {
                LabeledContent("Wear sessions", value: "\(sessions.count)")
                LabeledContent("Total wrist time", value: wearDurationLabel(totalMinutes))
                if todayMinutes > 0 {
                    LabeledContent("Today", value: wearDurationLabel(todayMinutes))
                }
                LabeledContent("Last worn", value: lastWearDate(for: draft).map { calendarDayLabel($0) } ?? "Not logged")
                Button {
                    activitySheet = .wearHistory
                } label: {
                    Label("Log wear or view history", systemImage: "watch.analog")
                }
            } else {
                Text("Wear logging is available while this watch is in your current collection.")
                    .font(.caption)
                    .foregroundStyle(WatchTheme.secondary)
            }

            LabeledContent("Service records", value: "\(services.count)")
            if serviceCost > 0 {
                LabeledContent("Maintenance spent", value: cad(serviceCost))
            }
            if let nextDue {
                LabeledContent("Next due", value: calendarDayLabel(nextDue))
            }
            Button("Manage service history") { activitySheet = .maintenance }
        }
    }

    private func save() {
        isSaving = true
        Task {
            var normalized = draft
            normalized.purchasedText = purchaseMonthLabel(normalized.purchased)
            let uploads = pendingPhotos.map {
                LocalPhotoUpload(data: $0.data, filename: $0.filename, mimeType: $0.mimeType)
            }
            if let saved = await store.saveWatch(normalized, isNew: isNew, initialPhotos: uploads) {
                rememberSelections(from: saved)
                dismiss()
            }
            isSaving = false
        }
    }

    private func importPhoto(_ item: PhotosPickerItem) async {
        guard let data = try? await item.loadTransferable(type: Data.self) else { return }
        let type = item.supportedContentTypes.first
        let ext = type?.preferredFilenameExtension ?? "jpg"
        let mime = type?.preferredMIMEType ?? "image/jpeg"
        await upload(data: data, filename: "photo-\(UUID().uuidString).\(ext)", mimeType: mime)
        photoItem = nil
    }

    private func upload(data: Data, filename: String, mimeType: String) async {
        if isNew {
            pendingPhotos.append(PendingWatchPhoto(data: data, filename: filename, mimeType: mimeType))
            selectedPhotoIndex = pendingPhotos.count - 1
            return
        }
        await store.uploadPhoto(data: data, filename: filename, mimeType: mimeType, itemID: draft.id, wishlist: false)
        reloadDraft()
    }

    private var validationIssues: [String] {
        var issues: [String] = []
        if draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append("Enter the watch name.")
        }
        if draft.status == "owned", purchaseMonthParts(draft.purchased) == nil {
            issues.append("Choose the purchase month and year.")
        }
        if draft.price < 0 {
            issues.append("Price paid cannot be negative.")
        }
        return issues
    }

    private func rememberSelections(from watch: Watch) {
        if let category = watch.category { UserDefaults.standard.set(category, forKey: WatchEditorDefaults.category) }
        if let dialColor = watch.dialColor { UserDefaults.standard.set(dialColor, forKey: WatchEditorDefaults.dialColor) }
        if let material = watch.material { UserDefaults.standard.set(material, forKey: WatchEditorDefaults.material) }
    }

    private func reloadDraft() {
        if let updated = store.data?.watches.first(where: { $0.id == draft.id }) { draft = updated }
    }
}

private enum WatchActivitySheet: String, Identifiable {
    case wearHistory
    case maintenance

    var id: String { rawValue }
}

private extension Watch {
    static var newDraft: Watch {
        Watch(
            id: "new",
            name: "",
            story: "",
            purchased: currentPurchaseMonth(),
            purchasedText: purchaseMonthLabel(currentPurchaseMonth()),
            diameter: nil,
            price: 0,
            original: nil,
            status: "owned",
            statusNote: "",
            photos: [],
            category: nil,
            dialColor: nil,
            lugToLug: nil,
            material: nil,
            brand: nil
        )
    }
}

private struct PendingWatchPhoto: Identifiable {
    let id = UUID()
    var data: Data
    var filename: String
    var mimeType: String
}

private enum WatchEditorDefaults {
    static let category = "watchEditor.lastCategory"
    static let dialColor = "watchEditor.lastDialColor"
    static let material = "watchEditor.lastMaterial"
}

struct CameraPicker: UIViewControllerRepresentable {
    let onImage: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = UIImagePickerController.isSourceTypeAvailable(.camera) ? .camera : .photoLibrary
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    final class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        let parent: CameraPicker
        init(parent: CameraPicker) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage { parent.onImage(image) }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { parent.dismiss() }
    }
}
