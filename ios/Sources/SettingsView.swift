import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: AppStore
    @State private var draftSettings: CollectionSettings
    @State private var baselineSettings: CollectionSettings?
    @State private var backupResult = ""
    @State private var saving = false
    @State private var backingUp = false
    @State private var transferBusy = false
    @State private var showingExporter = false
    @State private var showingImporter = false
    @State private var exportDocument: CollectionExportDocument?
    @State private var exportContentType = UTType.watchCollectionBackup
    @State private var exportFilename = "Watch Collection Backup"
    @State private var pendingImport: CollectionImport?
    @State private var syncEnabled: Bool
    @State private var syncAddress: String
    @State private var resolvedConflicts: Set<String> = []

    init(store: AppStore) {
        self.store = store
        _baselineSettings = State(initialValue: store.data?.settings)
        _syncEnabled = State(initialValue: store.syncEnabled)
        _syncAddress = State(initialValue: store.syncAddress)
        _draftSettings = State(initialValue: store.data?.settings ?? CollectionSettings(
            autoBackup: true,
            backupRemote: "gdrive:WatchCollection",
            lastBackup: nil,
            autoImage: true,
            suggestExclude: ["Smartwatch", "Other", "Iced Out", "Novelty", "Fashion/Minimalist"],
            wrist: WristProfile(inches: 6, sweetSpotMin: 35, sweetSpotMax: 40, perfect: 38, lugMax: 47)
        ))
    }

    var body: some View {
        NavigationStack {
            Form {
                Group {
                    storageSection
                    syncSection
                    wristSection
                    suggestionSection
                    automationSection
                    taxonomySection
                    aboutSection
                }
                .listRowBackground(WatchTheme.card)
            }
            .scrollContentBackground(.hidden)
            .background(WatchTheme.background)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                ToolbarItem(placement: .principal) { Text("Settings").font(.headline).serifTitle() }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saving ? "Saving…" : "Save") { save() }
                        .disabled(saving)
                }
            }
            .alert("Watch Collection", isPresented: errorBinding) {
                Button("OK", role: .cancel) { store.errorMessage = nil }
            } message: { Text(store.errorMessage ?? "Unknown error") }
            .alert(item: $pendingImport) { imported in
                Alert(
                    title: Text("Replace current collection?"),
                    message: Text("\(imported.sourceName) contains \(imported.summary) Your current on-phone collection will be replaced, and if Mac sync is on, the Mac copy will follow."),
                    primaryButton: .destructive(Text("Restore")) {
                        restore(imported)
                    },
                    secondaryButton: .cancel()
                )
            }
            .fileExporter(
                isPresented: $showingExporter,
                document: exportDocument,
                contentType: exportContentType,
                defaultFilename: exportFilename
            ) { result in
                switch result {
                case let .success(url):
                    backupResult = "Exported \(url.lastPathComponent)."
                case let .failure(error):
                    store.errorMessage = error.localizedDescription
                }
                exportDocument = nil
            }
            .fileImporter(
                isPresented: $showingImporter,
                allowedContentTypes: [.watchCollectionBackup, .json]
            ) { result in
                inspectImport(result)
            }
        }
    }

    private var storageSection: some View {
        Section("Storage") {
            LabeledContent("Collection", value: "On this iPhone")
            LabeledContent("Connection required", value: "No")
            Text("Your collection and photos stay on this iPhone and work offline. Sync shares changes when your Mac is reachable through Tailscale.")
                .font(.caption)
                .foregroundStyle(WatchTheme.secondary)
        }
    }

    private var syncSection: some View {
        Section("Automatic sync") {
            Toggle("Sync with my Mac", isOn: $syncEnabled)
            TextField("http://your-mac:8931", text: $syncAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .accessibilityLabel("Mac sync address")
            Button("Apply sync settings") {
                Task { await store.configureSync(enabled: syncEnabled, address: syncAddress) }
            }
            .disabled(store.isSyncing)
            LabeledContent("Status", value: store.syncMessage)
                .font(.caption)
            if let date = store.lastSync {
                LabeledContent("Last synced", value: date.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
            }
            Button(store.isSyncing ? "Syncing..." : "Sync now") {
                Task { await store.syncNow() }
            }
            .disabled(store.isSyncing || !store.syncEnabled)
            Text("Sync runs when you open the app, after edits, and when a connection returns. iOS chooses when background refresh runs. Keep your Mac awake and Tailscale connected on both devices.")
                .font(.caption)
                .foregroundStyle(WatchTheme.secondary)
            ForEach(store.syncConflicts) { conflict in
                VStack(alignment: .leading, spacing: 8) {
                    Text(conflict.title).font(.caption.weight(.semibold))
                    Text("iPhone: \(conflict.localText)").font(.caption)
                    Text("Mac: \(conflict.remoteText)").font(.caption)
                    HStack {
                        Button("Keep iPhone") { choose(conflict, "local") }
                        Button("Keep Mac") { choose(conflict, "remote") }
                    }
                    .buttonStyle(.bordered)
                    .disabled(resolvedConflicts.contains(conflict.id) || store.isSyncing)
                    if resolvedConflicts.contains(conflict.id) { Text("Choice saved").font(.caption) }
                }
            }
        }
    }

    private func choose(_ conflict: SyncConflict, _ choice: String) {
        resolvedConflicts.insert(conflict.id)
        Task { await store.resolveSyncConflict(conflict.id, choice: choice) }
    }

    private var wristSection: some View {
        Section("Wrist profile") {
            numberField("Wrist size — inches", value: $draftSettings.wrist.inches)
            numberField("Sweet spot min — mm", value: $draftSettings.wrist.sweetSpotMin)
            numberField("Sweet spot max — mm", value: $draftSettings.wrist.sweetSpotMax)
            numberField("Perfect size — mm", value: $draftSettings.wrist.perfect)
            numberField("Lug-to-lug ceiling — mm", value: $draftSettings.wrist.lugMax)
            Text("Fit chips prefer lug-to-lug when known, then fall back to diameter.")
                .font(.caption)
                .foregroundStyle(WatchTheme.secondary)
        }
    }

    private var automationSection: some View {
        Section("Backups & recovery") {
            Toggle("Keep JSON backup in Files", isOn: $draftSettings.autoBackup)
            LabeledContent("Destination", value: "On My iPhone / Watch Collection Backup")
            if let lastBackup = draftSettings.lastBackup {
                LabeledContent("Last backup", value: lastBackup)
                    .font(.caption)
            }
            Button {
                backingUp = true
                Task {
                    backupResult = await store.backup()
                    backingUp = false
                    draftSettings.lastBackup = store.data?.settings.lastBackup
                }
            } label: {
                Label(backingUp ? "Backing up…" : "Back up data & photos now", systemImage: "externaldrive.badge.timemachine")
            }
            .disabled(backingUp)

            Button {
                prepareExport(includePhotos: true)
            } label: {
                Label("Export portable backup", systemImage: "shippingbox.and.arrow.backward")
            }
            .disabled(transferBusy)

            Button {
                prepareExport(includePhotos: false)
            } label: {
                Label("Export JSON only", systemImage: "doc.text")
            }
            .disabled(transferBusy)

            Button {
                showingImporter = true
            } label: {
                Label("Restore backup or JSON", systemImage: "arrow.clockwise.icloud")
            }
            .disabled(transferBusy)

            if transferBusy {
                HStack {
                    ProgressView()
                    Text("Preparing collection…")
                }
                .font(.caption)
                .foregroundStyle(WatchTheme.secondary)
            }
            if !backupResult.isEmpty {
                Text(backupResult)
                    .font(.caption.monospaced())
                    .foregroundStyle(WatchTheme.secondary)
                    .textSelection(.enabled)
            }
            Text("The portable backup includes your JSON and photos in one file. Save it to iCloud Drive for off-phone recovery. Restore always shows a summary and asks before replacing anything.")
                .font(.caption)
                .foregroundStyle(WatchTheme.secondary)
        }
    }

    private var suggestionSection: some View {
        Section("Suggestions may propose…") {
            ChipFlowLayout(spacing: 7) {
                ForEach(store.data?.categories ?? [], id: \.self) { category in
                    let allowed = !(draftSettings.suggestExclude ?? []).contains(category)
                    Button {
                        toggleSuggestionCategory(category)
                    } label: {
                        CapsuleChip(
                            text: category,
                            color: allowed ? WatchTheme.gold : WatchTheme.secondary,
                            filled: allowed
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(category), \(allowed ? "included" : "excluded")")
                }
            }
            Text("Selected categories can appear in Next move. Turn off styles you do not want suggested.")
                .font(.caption)
                .foregroundStyle(WatchTheme.secondary)
        }
    }

    private var taxonomySection: some View {
        Section("Collection vocabulary") {
            ForEach(TaxonomyRoute.allCases) { route in
                NavigationLink(route.title) {
                    TaxonomyManagerView(store: store, route: route)
                }
            }
            Text("Renames propagate to every watch and candidate. In-use values cannot be deleted until records are reassigned.")
                .font(.caption)
                .foregroundStyle(WatchTheme.secondary)
        }
    }

    private var aboutSection: some View {
        Section("About") {
            LabeledContent("Source of truth", value: "This iPhone")
            LabeledContent("Offline editing", value: "Ready")
            LabeledContent("Score maximum", value: "14")
        }
    }

    private func numberField(_ title: String, value: Binding<Double>) -> some View {
        LabeledContent(title) {
            NumberField("Value", value: value)
                .multilineTextAlignment(.trailing)
                .frame(minWidth: 52, maxWidth: 72)
        }
    }

    private func toggleSuggestionCategory(_ category: String) {
        var excluded = draftSettings.suggestExclude ?? []
        if let index = excluded.firstIndex(of: category) {
            excluded.remove(at: index)
        } else {
            excluded.append(category)
        }
        draftSettings.suggestExclude = excluded
    }

    private func save() {
        saving = true
        Task {
            await store.saveSettings(draftSettings, baseline: baselineSettings)
            saving = false
            if store.errorMessage == nil { dismiss() }
        }
    }

    private func prepareExport(includePhotos: Bool) {
        transferBusy = true
        Task {
            let document = await store.prepareExport(includePhotos: includePhotos)
            transferBusy = false
            guard let document else { return }
            exportDocument = document
            exportContentType = includePhotos ? .watchCollectionBackup : .json
            exportFilename = includePhotos
                ? "Watch Collection Backup \(exportDateStamp)"
                : "Watch Collection \(exportDateStamp)"
            if document.missingPhotoCount > 0 {
                backupResult = "Warning: \(document.missingPhotoCount) referenced photo(s) are missing from this phone."
            }
            showingExporter = true
        }
    }

    private func inspectImport(_ result: Result<URL, Error>) {
        switch result {
        case let .failure(error):
            store.errorMessage = error.localizedDescription
        case let .success(url):
            transferBusy = true
            Task {
                pendingImport = await store.inspectImport(from: url)
                transferBusy = false
            }
        }
    }

    private func restore(_ imported: CollectionImport) {
        transferBusy = true
        Task {
            let restored = await store.restore(imported)
            transferBusy = false
            if restored {
                backupResult = store.notice ?? "Collection restored."
                if let settings = store.data?.settings { draftSettings = settings }
            }
        }
    }

    private var exportDateStamp: String {
        Date().formatted(.iso8601.year().month().day().dateSeparator(.dash))
    }

    private var errorBinding: Binding<Bool> {
        Binding(get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } })
    }
}

struct TaxonomyManagerView: View {
    @ObservedObject var store: AppStore
    let route: TaxonomyRoute
    @State private var newValue = ""
    @State private var renameSource: String?
    @State private var renameValue = ""

    private var values: [String] {
        guard let data = store.data else { return [] }
        switch route {
        case .categories: return data.categories
        case .dialcolors: return data.dialColors
        case .materials: return data.materials
        }
    }

    var body: some View {
        List {
            Section("Add") {
                HStack {
                    TextField("New value", text: $newValue)
                    Button("Add") {
                        let clean = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !clean.isEmpty else { return }
                        newValue = ""
                        Task { await store.taxonomy(route, operation: .add(clean)) }
                    }
                    .disabled(store.isOffline)
                }
            }
            Section("Order & names") {
                ForEach(Array(values.enumerated()), id: \.element) { index, value in
                    HStack {
                        VStack(spacing: 3) {
                            Button { move(value, by: -1) } label: { Image(systemName: "chevron.up") }
                                .disabled(index == 0 || store.isOffline)
                            Button { move(value, by: 1) } label: { Image(systemName: "chevron.down") }
                                .disabled(index == values.count - 1 || store.isOffline)
                        }
                        .font(.caption)
                        Text(value)
                        Spacer()
                        Menu {
                            Button("Rename") { renameSource = value; renameValue = value }
                            Button("Delete", role: .destructive) {
                                Task { await store.taxonomy(route, operation: .delete(value)) }
                            }
                        } label: { Image(systemName: "ellipsis.circle") }
                        .disabled(store.isOffline)
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(WatchTheme.background)
        .navigationTitle(route.title)
        .navigationBarTitleDisplayMode(.inline)
        .alert("Rename value", isPresented: Binding(
            get: { renameSource != nil },
            set: { if !$0 { renameSource = nil } }
        )) {
            TextField("Name", text: $renameValue)
            Button("Cancel", role: .cancel) { renameSource = nil }
            Button("Rename") {
                guard let source = renameSource else { return }
                let target = renameValue.trimmingCharacters(in: .whitespacesAndNewlines)
                renameSource = nil
                guard !target.isEmpty else { return }
                Task { await store.taxonomy(route, operation: .rename(from: source, to: target)) }
            }
        } message: {
            Text("Every watch and wishlist entry using this value will be updated atomically.")
        }
    }

    private func move(_ value: String, by offset: Int) {
        guard let index = values.firstIndex(of: value) else { return }
        let destination = index + offset
        guard values.indices.contains(destination) else { return }
        var reordered = values
        reordered.swapAt(index, destination)
        Task { await store.taxonomy(route, operation: .reorder(reordered)) }
    }
}
