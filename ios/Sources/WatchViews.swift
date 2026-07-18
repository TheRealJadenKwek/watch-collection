import PhotosUI
import SwiftUI
import UniformTypeIdentifiers
import UIKit

struct CollectionScreen: View {
    @ObservedObject var store: AppStore
    let showSettings: () -> Void
    @State private var search = ""
    @State private var selectedWatch: Watch?
    @State private var addingWatch = false

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
                                    Button { selectedWatch = watch } label: {
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
                    Button { addingWatch = true } label: { Image(systemName: "plus") }
                        .disabled(store.isOffline)
                    GearToolbarButton(action: showSettings)
                }
            }
            .sheet(item: $selectedWatch) { watch in
                WatchDetailScreen(store: store, watch: watch)
            }
            .sheet(isPresented: $addingWatch) {
                WatchDetailScreen(store: store, watch: .newDraft, isNew: true)
            }
        }
    }

    private var collectionHeader: some View {
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
    }
}

struct WatchDetailScreen: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: AppStore
    let isNew: Bool
    @State private var draft: Watch
    @State private var selectedPhotoIndex = 0
    @State private var photoItem: PhotosPickerItem?
    @State private var showCamera = false
    @State private var isSaving = false
    @State private var confirmDelete = false

    init(store: AppStore, watch: Watch, isNew: Bool = false) {
        self.store = store
        self.isNew = isNew
        _draft = State(initialValue: watch)
    }

    var body: some View {
        NavigationStack {
            Form {
                if store.isOffline {
                    Section { Label("Mac unreachable · editing is disabled", systemImage: "wifi.slash") }
                        .foregroundStyle(WatchTheme.amber)
                }
                photoSection
                identitySection
                sizingSection
                purchaseSection
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
                        .disabled(store.isOffline || isSaving || draft.name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onChange(of: photoItem) { _, item in
                guard let item else { return }
                Task { await importPhoto(item) }
            }
            .fullScreenCover(isPresented: $showCamera) {
                CameraPicker { image in
                    guard let data = image.jpegData(compressionQuality: 0.9) else { return }
                    Task { await upload(data: data, filename: "camera-\(UUID().uuidString).jpg", mimeType: "image/jpeg") }
                }
                .ignoresSafeArea()
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
            if draft.photos.isEmpty {
                WatchPlaceholder()
                    .frame(height: 230)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
            } else {
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
            .disabled(store.isOffline || isNew)
            if isNew {
                Text("Save the watch first, then reopen it to add photos.")
                    .font(.caption)
                    .foregroundStyle(WatchTheme.secondary)
            }
        }
    }

    private var identitySection: some View {
        Section("Identity") {
            TextField("Name", text: $draft.name)
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
            TextField("Purchase month (YYYY-MM)", text: Binding(get: { draft.purchased ?? "" }, set: { draft.purchased = $0.isEmpty ? nil : $0 }))
            TextField("Purchase date as written", text: $draft.purchasedText)
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

    private func save() {
        isSaving = true
        Task {
            if await store.saveWatch(draft, isNew: isNew) != nil { dismiss() }
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
        guard !isNew else { return }
        await store.uploadPhoto(data: data, filename: filename, mimeType: mimeType, itemID: draft.id, wishlist: false)
        reloadDraft()
    }

    private func reloadDraft() {
        if let updated = store.data?.watches.first(where: { $0.id == draft.id }) { draft = updated }
    }
}

private extension Watch {
    static var newDraft: Watch {
        Watch(
            id: "new",
            name: "",
            story: "",
            purchased: nil,
            purchasedText: "",
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
