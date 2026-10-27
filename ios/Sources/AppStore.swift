import Foundation
import SwiftUI
import Network
import BackgroundTasks

enum LocalStoreError: LocalizedError {
    case missingData
    case itemNotFound
    case duplicateValue
    case valueInUse(Int)
    case invalidOperation
    case saveFailed

    var errorDescription: String? {
        switch self {
        case .missingData: "No collection data is stored on this iPhone yet."
        case .itemNotFound: "That item is no longer in the collection."
        case .duplicateValue: "That name already exists."
        case let .valueInUse(count): "Cannot delete this value because it is used by \(count) item(s). Reassign them first."
        case .invalidOperation: "That change could not be applied."
        case .saveFailed: "The collection could not be saved. Check the iPhone's available storage and try again."
        }
    }
}

@MainActor
final class AppStore: ObservableObject {
    @Published private(set) var data: CollectionData?
    @Published private(set) var scores: [String: WishlistScore] = [:]
    @Published private(set) var suggestions: SuggestionsResponse?
    @Published private(set) var isOffline = false
    @Published private(set) var isRefreshing = false
    @Published var errorMessage: String?
    @Published var notice: String?
    @Published private(set) var syncMessage = "Waiting to sync"
    @Published private(set) var isSyncing = false
    @Published private(set) var syncConflicts: [SyncConflict] = []
    @Published private(set) var lastSync: Date?
    @Published private(set) var syncEnabled = UserDefaults.standard.object(forKey: "syncEnabled") as? Bool ?? true
    @Published private(set) var syncAddress = UserDefaults.standard.string(forKey: "syncAddress")
        ?? LegacyServerConfiguration.migrationURL ?? ""

    static let backgroundSyncID = "com.jadenkwek.watchcollection.refresh"
    private var syncBase: CollectionData?
    private var editGeneration = 0
    private var connectionMonitor: NWPathMonitor?
    private var syncTimer: Task<Void, Never>?
    private var syncResolutions: [String: String] = [:]

    private var started = false

    func start() async {
        guard !started else { return }
        started = true
        isRefreshing = true
        defer { isRefreshing = false }

        if let checkpoint = SyncDisk.load() {
            syncBase = checkpoint.server == syncAddress ? checkpoint.base : nil
            lastSync = checkpoint.lastSuccess
            publish(checkpoint.data, persist: false)
        } else if let cached = CacheStore.loadData() {
            publish(cached, persist: true)
        }

        // Never replace a populated standalone phone with the old migration snapshot.
        startConnectionMonitor()
        await syncNow()

        if let data, data.settings.autoBackup {
            _ = try? LocalBackup.mirrorJSON(from: data)
        }

        if data == nil {
            errorMessage = "Set the Mac's sync address in Settings, or restore a collection backup."
        }
    }

    func refresh() async {
        isRefreshing = true
        await syncNow()
        isRefreshing = false
    }

    func configureSync(enabled: Bool, address: String) async {
        let clean = address.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if clean != syncAddress {
            syncBase = nil
            lastSync = nil
            syncConflicts = []
            syncResolutions = [:]
        }
        syncAddress = clean
        syncEnabled = enabled
        editGeneration += 1
        UserDefaults.standard.set(clean, forKey: "syncAddress")
        UserDefaults.standard.set(enabled, forKey: "syncEnabled")
        if let data { publish(data, persist: true) }
        await syncNow()
        scheduleBackgroundSync()
    }

    func resolveSyncConflict(_ id: String, choice: String) async {
        syncResolutions[id] = choice
        guard syncConflicts.allSatisfy({ syncResolutions[$0.id] != nil }) else { return }
        while isSyncing { try? await Task.sleep(for: .milliseconds(200)) }
        await syncNow()
    }

    func sceneChanged(_ phase: ScenePhase) {
        syncTimer?.cancel()
        if phase == .active {
            syncTimer = Task { [weak self] in
                while !Task.isCancelled {
                    await self?.syncNow()
                    do { try await Task.sleep(for: .seconds(60)) } catch { break }
                }
            }
        } else if phase == .background {
            scheduleBackgroundSync()
        }
    }

    func scheduleBackgroundSync() {
        guard syncEnabled, !syncAddress.isEmpty else { return }
        let request = BGAppRefreshTaskRequest(identifier: Self.backgroundSyncID)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        // The system determines the actual launch time; foreground sync is the fallback.
        try? BGTaskScheduler.shared.submit(request)
    }

    private func startConnectionMonitor() {
        guard connectionMonitor == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            guard path.status == .satisfied else { return }
            Task { @MainActor [weak self] in await self?.syncNow() }
        }
        monitor.start(queue: DispatchQueue(label: "watch-collection.connection"))
        connectionMonitor = monitor
    }

    @discardableResult
    func syncNow() async -> Bool {
        guard started, !isSyncing else { return false }
        guard syncEnabled else { syncMessage = "Automatic sync is off"; return false }
        guard !syncAddress.isEmpty else { syncMessage = "Add the Mac's address in Settings"; return false }
        isSyncing = true
        syncMessage = "Syncing collection and photos..."
        defer { isSyncing = false }
        let address = syncAddress
        do {
            let client = try CollectionSyncClient(address: address)
            for _ in 0..<3 {
                let generation = editGeneration
                let local = data
                let remote = try await client.snapshot()
                let result: SyncSnapshot
                if let local {
                    result = try await client.exchange(base: syncBase, local: local, resolutions: syncResolutions, remote: remote)
                } else { result = remote }
                guard syncAddress == address, syncEnabled else { return false }
                // Do not install a response over edits made while a request was in flight.
                guard generation == editGeneration else { continue }
                if !result.conflicts.isEmpty {
                    syncConflicts = result.conflicts
                    syncMessage = "\(result.conflicts.count) changes need your choice in Settings"
                    return false
                }
                try await client.downloadPhotos(result.data)
                try Task.checkCancellation()
                guard generation == editGeneration, syncAddress == address, syncEnabled else { continue }
                var merged = result.data
                if let local {
                    merged.settings.autoBackup = local.settings.autoBackup
                    merged.settings.backupRemote = local.settings.backupRemote
                    merged.settings.lastBackup = local.settings.lastBackup
                }
                let now = Date()
                try SyncDisk.save(SyncCheckpoint(data: merged, base: result.data, server: address, lastSuccess: now))
                syncBase = result.data
                lastSync = now
                publish(merged, persist: false)
                CacheStore.save(merged)
                if merged.settings.autoBackup { _ = try? LocalBackup.mirrorJSON(from: merged) }
                syncConflicts = []
                syncResolutions = [:]
                syncMessage = "Up to date"
                isOffline = false
                return true
            }
            syncMessage = "New edits are saved locally; sync will retry"
        } catch is CancellationError {
            syncMessage = "Saved on this iPhone; sync will resume"
        } catch {
            syncMessage = "Saved on this iPhone. \(error.localizedDescription)"
            // Keep local editing enabled when the sync server is unreachable.
        }
        return false
    }

    func saveWatch(_ watch: Watch, isNew: Bool = false, initialPhotos: [LocalPhotoUpload] = [], baseline: Watch? = nil) async -> Watch? {
        do {
            var saved = watch
            saved.name = saved.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !saved.name.isEmpty else { throw LocalStoreError.invalidOperation }
            saved.diameter = positiveOrNil(saved.diameter)
            saved.lugToLug = positiveOrNil(saved.lugToLug)
            guard saved.price.isFinite, saved.price >= 0 else { throw LocalStoreError.invalidOperation }
            // Photo writes await; re-read the collection afterwards so a sync landing meanwhile isn't reverted.
            var stored: [String] = []
            let newID = isNew ? uniqueID(for: saved.name, existing: try requireData().watches.map(\.id)) : saved.id
            for photo in isNew ? initialPhotos : [] {
                let extensionName = safePhotoExtension(filename: photo.filename, mimeType: photo.mimeType)
                let storedFilename = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased() + extensionName
                guard let asset = PhotoStore.asset(
                    itemID: newID,
                    filename: storedFilename,
                    wishlist: false,
                    baseURL: nil
                ) else { throw LocalStoreError.invalidOperation }
                try await PhotoStore.shared.storeUploaded(photo.data, as: asset)
                stored.append(storedFilename)
            }
            var updated = try requireData()
            if isNew || (baseline != nil && baseline?.purchased != watch.purchased) {
                saved.purchasedText = purchaseMonthLabel(saved.purchased)
            }
            saved.wearSessions = wearSessions(for: saved)
            saved.wearDates = nil
            saved.serviceRecords = serviceRecords(for: saved)
            if isNew {
                guard !updated.watches.contains(where: { $0.id == newID }) else { throw LocalStoreError.duplicateValue }
                saved = Watch(
                    id: newID,
                    name: saved.name,
                    story: watch.story,
                    purchased: watch.purchased,
                    purchasedText: purchaseMonthLabel(watch.purchased),
                    diameter: saved.diameter,
                    price: watch.price,
                    original: watch.original,
                    status: watch.status,
                    statusNote: watch.statusNote,
                    photos: stored,
                    category: watch.category,
                    dialColor: watch.dialColor,
                    lugToLug: saved.lugToLug,
                    material: watch.material,
                    brand: watch.brand,
                    acquisitionMethod: watch.acquisitionMethod,
                    costSourceWatchID: watch.costSourceWatchID
                )
                updated.watches.append(saved)
            } else if let index = updated.watches.firstIndex(where: { $0.id == watch.id }) {
                if let baseline { saved = try mergeDraft(base: baseline, draft: saved, current: updated.watches[index]) }
                updated.watches[index] = saved
            } else {
                throw LocalStoreError.itemNotFound
            }
            try await commit(updated)
            notice = isNew ? "Watch added." : "Watch saved."
            return saved
        } catch {
            surface(error)
            return nil
        }
    }

    func saveWishlist(_ item: WishlistItem, isNew: Bool = false, baseline: WishlistItem? = nil) async -> WishlistItem? {
        do {
            var updated = try requireData()
            var saved = item
            saved.name = saved.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !saved.name.isEmpty else { throw LocalStoreError.invalidOperation }
            saved.diameter = positiveOrNil(saved.diameter)
            saved.lugToLug = positiveOrNil(saved.lugToLug)
            if saved.added.range(of: #"^\d{4}-(0[1-9]|1[0-2])$"#, options: .regularExpression) == nil {
                saved.added = Self.currentMonth
            }
            if isNew {
                saved = WishlistItem(
                    id: uniqueID(for: item.name, existing: updated.wishlist.map(\.id)),
                    name: saved.name,
                    brand: item.brand.trimmingCharacters(in: .whitespacesAndNewlines),
                    category: item.category,
                    priceExpected: item.priceExpected,
                    priceNote: item.priceNote,
                    notes: item.notes,
                    status: item.status,
                    added: saved.added,
                    dialColor: item.dialColor,
                    diameter: saved.diameter,
                    lugToLug: saved.lugToLug,
                    material: item.material,
                    photos: []
                )
                updated.wishlist.append(saved)
            } else if let index = updated.wishlist.firstIndex(where: { $0.id == item.id }) {
                if let baseline { saved = try mergeDraft(base: baseline, draft: saved, current: updated.wishlist[index]) }
                updated.wishlist[index] = saved
            } else {
                throw LocalStoreError.itemNotFound
            }
            try await commit(updated)
            notice = isNew ? "Candidate added." : "Candidate saved."
            return saved
        } catch {
            surface(error)
            return nil
        }
    }

    func deleteWatch(id: String) async {
        await mutate { data in
            guard data.watches.contains(where: { $0.id == id }) else { throw LocalStoreError.itemNotFound }
            data.watches.removeAll { $0.id == id }
            self.notice = "Watch deleted."
        }
    }

    func deleteWishlist(id: String) async {
        await mutate { data in
            guard data.wishlist.contains(where: { $0.id == id }) else { throw LocalStoreError.itemNotFound }
            data.wishlist.removeAll { $0.id == id }
            self.notice = "Candidate deleted."
        }
    }

    func passWishlist(id: String) async {
        await mutate { data in
            guard let index = data.wishlist.firstIndex(where: { $0.id == id }) else { throw LocalStoreError.itemNotFound }
            data.wishlist[index].status = "passed"
            self.notice = "Marked passed."
        }
    }

    func markBought(id: String, price: Double, purchased: String) async {
        await mutate { data in
            guard let index = data.wishlist.firstIndex(where: { $0.id == id }) else { throw LocalStoreError.itemNotFound }
            let item = data.wishlist[index]
            guard item.status != "bought" else { throw LocalStoreError.duplicateValue }
            var watch = Watch(
                id: self.uniqueID(for: item.name, existing: data.watches.map(\.id)),
                name: item.name,
                story: item.notes,
                purchased: purchased,
                purchasedText: purchaseMonthLabel(purchased),
                diameter: item.diameter,
                price: price,
                original: true,
                status: "owned",
                statusNote: "",
                photos: [],
                category: item.category,
                dialColor: item.dialColor,
                lugToLug: item.lugToLug,
                material: item.material,
                brand: item.brand
            )
            watch.photos = PhotoStore.copyPhotos(item.photos, fromWishlist: item.id, toWatch: watch.id)
            watch.photoFocus = item.photoFocus?.filter { watch.photos.contains($0.key) }
            data.watches.append(watch)
            data.wishlist[index].status = "bought"
            self.notice = "Moved into the collection."
        }
    }

    func addServiceRecord(watchID: String, record: ServiceRecord) async {
        await mutate { data in
            guard let index = data.watches.firstIndex(where: { $0.id == watchID }),
                  calendarDayDate(record.date) != nil,
                  record.nextDue == nil || calendarDayDate(record.nextDue) != nil,
                  !record.kind.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  record.cost.map({ $0.isFinite && $0 >= 0 }) ?? true
            else { throw LocalStoreError.invalidOperation }
            var records = serviceRecords(for: data.watches[index])
            guard !records.contains(where: { $0.id == record.id }) else { throw LocalStoreError.duplicateValue }
            records.append(record)
            data.watches[index].serviceRecords = records.sorted {
                if $0.date == $1.date { return $0.id < $1.id }
                return $0.date < $1.date
            }
            self.notice = "Service entry added."
        }
    }

    func deleteServiceRecord(watchID: String, recordID: String) async {
        await mutate { data in
            guard let index = data.watches.firstIndex(where: { $0.id == watchID }) else {
                throw LocalStoreError.itemNotFound
            }
            var records = serviceRecords(for: data.watches[index])
            guard records.contains(where: { $0.id == recordID }) else { throw LocalStoreError.itemNotFound }
            records.removeAll { $0.id == recordID }
            data.watches[index].serviceRecords = records
            self.notice = "Service entry removed."
        }
    }

    func findWishlistImage(id: String) async -> URL? {
        guard let item = data?.wishlist.first(where: { $0.id == id }) else {
            surface(LocalStoreError.itemNotFound)
            return nil
        }
        var components = URLComponents(string: "https://www.google.com/search")
        components?.queryItems = [
            URLQueryItem(name: "tbm", value: "isch"),
            URLQueryItem(name: "q", value: "\(item.name) watch product image"),
        ]
        notice = "Choose a photo, then add it from your library."
        return components?.url
    }

    func saveSettings(_ settings: CollectionSettings, baseline: CollectionSettings? = nil) async {
        await mutate { data in
            data.settings = try baseline.map { try mergeDraft(base: $0, draft: settings, current: data.settings) } ?? settings
            let wrist = data.settings.wrist
            if wrist.sweetSpotMin > wrist.sweetSpotMax {
                (data.settings.wrist.sweetSpotMin, data.settings.wrist.sweetSpotMax) = (wrist.sweetSpotMax, wrist.sweetSpotMin)
            }
            self.notice = "Settings saved."
        }
    }

    func backup() async -> String {
        do {
            let snapshot = try requireData()
            _ = try await Task.detached(priority: .utility) {
                try LocalBackup.createFullBackup(from: snapshot)
            }.value
            var updated = try requireData()
            updated.settings.lastBackup = ISO8601DateFormatter().string(from: Date())
            try await commit(updated)
            notice = "Backup saved in Files."
            return "Saved to On My iPhone / Watch Collection Backup."
        } catch {
            surface(error)
            return error.localizedDescription
        }
    }

    func prepareExport(includePhotos: Bool) async -> CollectionExportDocument? {
        do {
            let data = try requireData()
            return try await Task.detached(priority: .userInitiated) {
                try CollectionExportDocument(data: data, includePhotos: includePhotos)
            }.value
        } catch {
            surface(error)
            return nil
        }
    }

    func inspectImport(from url: URL) async -> CollectionImport? {
        do {
            return try await Task.detached(priority: .userInitiated) {
                let accessing = url.startAccessingSecurityScopedResource()
                defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                return try CollectionBackupArchive.load(from: url)
            }.value
        } catch {
            surface(error)
            return nil
        }
    }

    func restore(_ imported: CollectionImport) async -> Bool {
        do {
            try await PhotoStore.shared.restore(imported.photos)
            try await commit(imported.data)
            let missing = PhotoStore.missingLocalCount(PhotoStore.assets(in: imported.data, baseURL: nil))
            notice = missing == 0
                ? "Collection restored with all photos."
                : "Collection restored; \(missing) referenced photo(s) were not in the import."
            return true
        } catch {
            surface(error)
            return false
        }
    }

    func taxonomy(_ route: TaxonomyRoute, operation: TaxonomyOperation) async {
        await mutate { data in
            var values = self.taxonomyValues(route, data: data)
            switch operation {
            case let .add(value):
                let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !clean.isEmpty else { throw LocalStoreError.invalidOperation }
                guard !values.contains(clean) else { throw LocalStoreError.duplicateValue }
                values.append(clean)
            case let .rename(from, to):
                let clean = to.trimmingCharacters(in: .whitespacesAndNewlines)
                guard let index = values.firstIndex(of: from), !clean.isEmpty else { throw LocalStoreError.invalidOperation }
                guard clean == from || !values.contains(clean) else { throw LocalStoreError.duplicateValue }
                values[index] = clean
                for watchIndex in data.watches.indices where self.taxonomyValue(route, watch: data.watches[watchIndex]) == from {
                    self.setTaxonomyValue(route, value: clean, watch: &data.watches[watchIndex])
                }
                for itemIndex in data.wishlist.indices where self.taxonomyValue(route, item: data.wishlist[itemIndex]) == from {
                    self.setTaxonomyValue(route, value: clean, item: &data.wishlist[itemIndex])
                }
                if route == .categories {
                    data.settings.suggestExclude = (data.settings.suggestExclude ?? []).map { $0 == from ? clean : $0 }
                }
            case let .delete(value):
                let uses = data.watches.filter { self.taxonomyValue(route, watch: $0) == value }.count
                    + data.wishlist.filter { self.taxonomyValue(route, item: $0) == value }.count
                guard uses == 0 else { throw LocalStoreError.valueInUse(uses) }
                guard values.contains(value) else { throw LocalStoreError.invalidOperation }
                values.removeAll { $0 == value }
                if route == .categories { data.settings.suggestExclude?.removeAll { $0 == value } }
            case let .reorder(reordered):
                guard reordered.count == values.count, Set(reordered) == Set(values) else { throw LocalStoreError.invalidOperation }
                values = reordered
            }
            self.setTaxonomyValues(route, values: values, data: &data)
            self.notice = "\(route.title) updated."
        }
    }

    func addRadarBrand(_ brand: String) async {
        await mutate { data in
            let clean = brand.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty else { throw LocalStoreError.invalidOperation }
            guard !data.brandWatchlist.contains(where: { $0.brand.caseInsensitiveCompare(clean) == .orderedSame }) else {
                throw LocalStoreError.duplicateValue
            }
            data.brandWatchlist.append(BrandRadarItem(brand: clean, notes: "", added: Self.currentMonth))
        }
    }

    func deleteRadarBrand(_ brand: String) async {
        await mutate { data in
            guard data.brandWatchlist.contains(where: { $0.brand == brand }) else { throw LocalStoreError.itemNotFound }
            data.brandWatchlist.removeAll { $0.brand == brand }
        }
    }

    func uploadPhoto(data photoData: Data, filename: String, mimeType: String, itemID: String, wishlist: Bool) async {
        do {
            let extensionName = safePhotoExtension(filename: filename, mimeType: mimeType)
            let storedFilename = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased() + extensionName
            guard let asset = PhotoStore.asset(itemID: itemID, filename: storedFilename, wishlist: wishlist, baseURL: nil) else {
                throw LocalStoreError.invalidOperation
            }
            try await PhotoStore.shared.storeUploaded(photoData, as: asset)
            var updated = try requireData()
            if wishlist {
                guard let index = updated.wishlist.firstIndex(where: { $0.id == itemID }) else { throw LocalStoreError.itemNotFound }
                updated.wishlist[index].photos.insert(storedFilename, at: 0)
            } else {
                guard let index = updated.watches.firstIndex(where: { $0.id == itemID }) else { throw LocalStoreError.itemNotFound }
                updated.watches[index].photos.insert(storedFilename, at: 0)
            }
            try await commit(updated)
            notice = "Photo added."
        } catch {
            surface(error)
        }
    }

    func setCover(itemID: String, filename: String, wishlist: Bool) async {
        await mutate { data in
            if wishlist {
                guard let index = data.wishlist.firstIndex(where: { $0.id == itemID }),
                      let photoIndex = data.wishlist[index].photos.firstIndex(of: filename) else { throw LocalStoreError.itemNotFound }
                data.wishlist[index].photos.remove(at: photoIndex)
                data.wishlist[index].photos.insert(filename, at: 0)
            } else {
                guard let index = data.watches.firstIndex(where: { $0.id == itemID }),
                      let photoIndex = data.watches[index].photos.firstIndex(of: filename) else { throw LocalStoreError.itemNotFound }
                data.watches[index].photos.remove(at: photoIndex)
                data.watches[index].photos.insert(filename, at: 0)
            }
        }
    }

    func deletePhoto(itemID: String, filename: String, wishlist: Bool) async {
        await mutate { data in
            if wishlist {
                guard let index = data.wishlist.firstIndex(where: { $0.id == itemID }),
                      data.wishlist[index].photos.contains(filename) else { throw LocalStoreError.itemNotFound }
                data.wishlist[index].photos.removeAll { $0 == filename }
                data.wishlist[index].photoFocus = Self.focusMap(data.wishlist[index].photoFocus, setting: nil, for: filename)
            } else {
                guard let index = data.watches.firstIndex(where: { $0.id == itemID }),
                      data.watches[index].photos.contains(filename) else { throw LocalStoreError.itemNotFound }
                data.watches[index].photos.removeAll { $0 == filename }
                data.watches[index].photoFocus = Self.focusMap(data.watches[index].photoFocus, setting: nil, for: filename)
            }
        }
    }

    /// Saves how a photo is framed (nil = default centred fill).
    func setPhotoFocus(itemID: String, filename: String, wishlist: Bool, focus: PhotoFocus?) async {
        await mutate { data in
            if wishlist {
                guard let index = data.wishlist.firstIndex(where: { $0.id == itemID }),
                      data.wishlist[index].photos.contains(filename) else { throw LocalStoreError.itemNotFound }
                data.wishlist[index].photoFocus = Self.focusMap(data.wishlist[index].photoFocus, setting: focus, for: filename)
            } else {
                guard let index = data.watches.firstIndex(where: { $0.id == itemID }),
                      data.watches[index].photos.contains(filename) else { throw LocalStoreError.itemNotFound }
                data.watches[index].photoFocus = Self.focusMap(data.watches[index].photoFocus, setting: focus, for: filename)
            }
        }
    }

    private nonisolated static func focusMap(
        _ map: [String: PhotoFocus]?,
        setting focus: PhotoFocus?,
        for filename: String
    ) -> [String: PhotoFocus]? {
        var updated = map ?? [:]
        updated[filename] = focus
        return updated.isEmpty ? nil : updated
    }

    func photoAsset(itemID: String, filename: String, wishlist: Bool) -> PhotoAsset? {
        PhotoStore.asset(itemID: itemID, filename: filename, wishlist: wishlist, baseURL: nil)
    }

    var writable: Bool { true }

    private func migrateFromLegacyServerIfNeeded() async {
        guard !UserDefaults.standard.bool(forKey: "standaloneMigrationComplete") else { return }
        let localCopyIsComplete = data.map {
            PhotoStore.missingLocalCount(PhotoStore.assets(in: $0, baseURL: nil)) == 0
        } ?? false
        guard let legacyURL = LegacyServerConfiguration.migrationURL else {
            if localCopyIsComplete { UserDefaults.standard.set(true, forKey: "standaloneMigrationComplete") }
            return
        }
        do {
            let migrated = try await APIClient(baseURL: legacyURL).fetchData()
            let remoteAssets = PhotoStore.assets(in: migrated, baseURL: legacyURL)
            await PhotoStore.shared.sync(remoteAssets)
            publish(migrated, persist: true)
            if PhotoStore.missingLocalCount(PhotoStore.assets(in: migrated, baseURL: nil)) == 0 {
                UserDefaults.standard.set(true, forKey: "standaloneMigrationComplete")
                notice = "Collection moved onto this iPhone."
            } else {
                notice = "Collection moved; some photos still need the old server once."
            }
        } catch {
            if data == nil {
                errorMessage = error.localizedDescription
            } else if localCopyIsComplete {
                UserDefaults.standard.set(true, forKey: "standaloneMigrationComplete")
            }
        }
    }

    private func requireData() throws -> CollectionData {
        guard let data else { throw LocalStoreError.missingData }
        return data
    }

    private func commit(_ updated: CollectionData) async throws {
        guard publish(updated, persist: true) else { throw LocalStoreError.saveFailed }
        editGeneration += 1
        if updated.settings.autoBackup { _ = try? LocalBackup.mirrorJSON(from: updated) }
        // Retain photo bytes until both devices acknowledge deletions. Incoming and
        // queued uploads must not be garbage-collected by a simultaneous local edit.
        Task { await self.syncNow() }
    }

    @discardableResult
    private func publish(_ rawData: CollectionData, persist: Bool) -> Bool {
        let derived = DecisionEngine.withDerivedStats(rawData)
        if persist {
            do {
                try SyncDisk.save(SyncCheckpoint(data: derived, base: syncBase, server: syncAddress, lastSuccess: lastSync))
            } catch {
                errorMessage = "The collection could not be saved: \(error.localizedDescription)"
                return false
            }
        }
        data = derived
        scores = DecisionEngine.scores(for: derived)
        suggestions = DecisionEngine.suggestions(for: derived)
        isOffline = false
        if persist {
            CacheStore.save(derived)
            CacheStore.save(WishlistScoresResponse(scores: scores))
            if let suggestions { CacheStore.save(suggestions) }
        }
        return true
    }

    private func mutate(_ operation: (inout CollectionData) throws -> Void) async {
        do {
            var updated = try requireData()
            try operation(&updated)
            try await commit(updated)
        } catch {
            surface(error)
        }
    }

    private func uniqueID(for name: String, existing: [String]) -> String {
        let folded = name.folding(options: [.diacriticInsensitive, .widthInsensitive], locale: .current).lowercased()
        let base = folded.replacingOccurrences(of: #"[^a-z0-9]+"#, with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let stem = base.isEmpty ? "watch" : base
        var candidate = stem
        var suffix = 2
        while existing.contains(candidate) {
            candidate = "\(stem)-\(suffix)"
            suffix += 1
        }
        return candidate
    }

    private func safePhotoExtension(filename: String, mimeType: String) -> String {
        let allowed = [".jpg", ".jpeg", ".png", ".webp", ".heic"]
        let candidate = URL(fileURLWithPath: filename).pathExtension.lowercased()
        if allowed.contains(".\(candidate)") { return ".\(candidate)" }
        switch mimeType.lowercased() {
        case "image/png": return ".png"
        case "image/webp": return ".webp"
        case "image/heic", "image/heif": return ".heic"
        default: return ".jpg"
        }
    }

    private func taxonomyValues(_ route: TaxonomyRoute, data: CollectionData) -> [String] {
        switch route {
        case .categories: data.categories
        case .dialcolors: data.dialColors
        case .materials: data.materials
        }
    }

    private func setTaxonomyValues(_ route: TaxonomyRoute, values: [String], data: inout CollectionData) {
        switch route {
        case .categories: data.categories = values
        case .dialcolors: data.dialColors = values
        case .materials: data.materials = values
        }
    }

    private func taxonomyValue(_ route: TaxonomyRoute, watch: Watch) -> String? {
        switch route {
        case .categories: watch.category
        case .dialcolors: watch.dialColor
        case .materials: watch.material
        }
    }

    private func taxonomyValue(_ route: TaxonomyRoute, item: WishlistItem) -> String? {
        switch route {
        case .categories: item.category
        case .dialcolors: item.dialColor
        case .materials: item.material
        }
    }

    private func setTaxonomyValue(_ route: TaxonomyRoute, value: String, watch: inout Watch) {
        switch route {
        case .categories: watch.category = value
        case .dialcolors: watch.dialColor = value
        case .materials: watch.material = value
        }
    }

    private func setTaxonomyValue(_ route: TaxonomyRoute, value: String, item: inout WishlistItem) {
        switch route {
        case .categories: item.category = value
        case .dialcolors: item.dialColor = value
        case .materials: item.material = value
        }
    }

    private func positiveOrNil(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value > 0 else { return nil }
        return value
    }

    private func surface(_ error: Error) {
        errorMessage = error.localizedDescription
    }

    private static var currentMonth: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM"
        return formatter.string(from: Date())
    }
}
