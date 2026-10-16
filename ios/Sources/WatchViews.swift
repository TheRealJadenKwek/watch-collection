import PhotosUI
import SwiftUI
import UniformTypeIdentifiers
import UIKit

struct WatchCardView: View {
    @ObservedObject var store: AppStore
    let watch: Watch
    let isPast: Bool

    /// Width / height of the card photo. The framing editor uses the same ratio.
    static let photoAspect: CGFloat = 0.82

    private var wrist: WristProfile? { store.data?.settings.wrist }
    private var coverAsset: PhotoAsset? {
        watch.photos.first.flatMap { store.photoAsset(itemID: watch.id, filename: $0, wishlist: false) }
    }
    private var detailLine: String {
        [watch.category, watch.diameter.map { "\(compactNumber($0))mm" }]
            .compactMap { $0 }
            .joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Color.clear
                .aspectRatio(Self.photoAspect, contentMode: .fit)
                .overlay {
                    RemoteWatchImage(
                        asset: coverAsset,
                        allowsRemoteFetch: !store.isOffline,
                        focus: watch.focus(for: watch.photos.first)
                    )
                }
                .overlay(alignment: .bottom) {
                    LinearGradient(
                        colors: [.clear, Color.black.opacity(0.55), Color.black.opacity(0.85)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: 96)
                }
                .overlay(alignment: .bottomLeading) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(watch.name)
                            .font(.display(15))
                            .foregroundStyle(WatchTheme.ivory)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                            .shadow(color: .black.opacity(0.4), radius: 4, y: 1)
                        Text(cad(watch.price))
                            .font(.system(size: 12, weight: .semibold).monospacedDigit())
                            .foregroundStyle(WatchTheme.gold)
                    }
                    .padding(11)
                }
                .overlay(alignment: .topLeading) {
                    HStack(spacing: 5) {
                        if isPast {
                            CapsuleChip(text: statusLabel(watch.status), color: WatchTheme.gold, filled: true)
                        }
                        if watch.original == false {
                            CapsuleChip(text: "REP", color: WatchTheme.ivory, filled: true)
                        }
                    }
                    .padding(9)
                }
                .clipped()
                .allowsHitTesting(false)

            VStack(alignment: .leading, spacing: 5) {
                Text(detailLine.isEmpty ? "Details unset" : detailLine)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(WatchTheme.secondary)
                    .lineLimit(1)
                Group {
                    if isPast {
                        Text(watch.statusNote.isEmpty ? " " : watch.statusNote)
                            .font(.system(size: 11))
                            .foregroundStyle(WatchTheme.secondary.opacity(0.8))
                            .lineLimit(1)
                    } else if let wrist, let fit = fitInfo(for: watch.diameter, lugToLug: watch.lugToLug, wrist: wrist) {
                        FitIndicator(info: fit)
                    } else {
                        Text(" ").font(.system(size: 11))
                    }
                }
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 10)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .watchCard(cornerRadius: 18)
        // Clipping changes drawing only. Keep the scaled photo's hit area inside
        // the visible card so it cannot intercept nearby cards.
        .contentShape(.interaction, RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

struct WatchDetailScreen: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: AppStore
    let isNew: Bool
    @State private var draft: Watch
    @State private var baseline: Watch
    @State private var selectedPhotoIndex = 0
    @State private var framingTarget: PhotoFramingTarget?
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
        _baseline = State(initialValue: initial)
    }

    var body: some View {
        NavigationStack {
            Form {
                Group {
                    if !validationIssues.isEmpty { validationSection }
                    photoSection
                    identitySection
                    sizingSection
                    purchaseSection
                    if !isNew { ownershipSection }
                    storySection
                }
                .listRowBackground(WatchTheme.card)
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
                if status == "owned", !draft.isTrade, purchaseMonthParts(draft.purchased) == nil {
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
                    allowsRemoteFetch: !store.isOffline,
                    focus: draft.focus(for: filename)
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
                Button("Adjust") { framingTarget = PhotoFramingTarget(filename: filename) }
                Spacer()
                Button("Delete photo", role: .destructive) {
                    Task {
                        await store.deletePhoto(itemID: draft.id, filename: filename, wishlist: false)
                        reloadDraft()
                        selectedPhotoIndex = 0
                    }
                }
            }
            .buttonStyle(.borderless)
            .disabled(store.isOffline)
            .sheet(item: $framingTarget) { target in
                PhotoFramingSheet(
                    asset: store.photoAsset(itemID: draft.id, filename: target.filename, wishlist: false),
                    allowsRemoteFetch: !store.isOffline,
                    initialFocus: draft.focus(for: target.filename),
                    aspect: PhotoShape.plate,
                    previews: [("Watch page", PhotoShape.dossier), ("Grid", PhotoShape.square), ("Portrait", PhotoShape.square)]
                ) { focus in
                    await store.setPhotoFocus(itemID: draft.id, filename: target.filename, wishlist: false, focus: focus)
                    // Only pull the saved framing so unsaved form edits survive.
                    draft.photoFocus = store.data?.watches.first(where: { $0.id == draft.id })?.photoFocus
                }
            }
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
            Picker("Acquired by", selection: Binding(
                get: { draft.acquisitionMethod ?? "purchase" },
                set: { draft.acquisitionMethod = $0 }
            )) {
                Text("Purchase").tag("purchase")
                Text("Trade").tag("trade")
            }
            TextField(draft.costSourceWatchID == nil ? "Price paid (CAD)" : "Original purchase cost (CAD)", value: $draft.price, format: .number)
                .keyboardType(.decimalPad)
            if let sourceID = draft.costSourceWatchID {
                Text("Carried over from \(store.data?.watches.first(where: { $0.id == sourceID })?.name ?? "the traded watch"). Counted once in all-time spending.")
                    .font(.caption).foregroundStyle(WatchTheme.secondary)
            }
            MonthYearPicker(value: $draft.purchased, allowsUnknown: draft.status != "owned" || draft.isTrade)
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
        let services = serviceRecords(for: draft)
        let serviceCost = services.compactMap(\.cost).reduce(0, +)
        let nextDue = services.compactMap(\.nextDue).sorted().first
        return Section("Service") {
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
            if normalized.purchased != baseline.purchased { normalized.purchasedText = purchaseMonthLabel(normalized.purchased) }
            let uploads = pendingPhotos.map {
                LocalPhotoUpload(data: $0.data, filename: $0.filename, mimeType: $0.mimeType)
            }
            if let saved = await store.saveWatch(normalized, isNew: isNew, initialPhotos: uploads, baseline: baseline) {
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
        if draft.status == "owned", !draft.isTrade, purchaseMonthParts(draft.purchased) == nil {
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
    case maintenance

    var id: String { rawValue }
}

extension Watch {
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
