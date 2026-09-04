import Foundation
import SwiftUI

enum LocalStoreError: LocalizedError {
    case missingData
    case itemNotFound
    case duplicateValue
    case valueInUse(Int)
    case invalidOperation

    var errorDescription: String? {
        switch self {
        case .missingData: "No collection data is stored on this iPhone yet."
        case .itemNotFound: "That item is no longer in the collection."
        case .duplicateValue: "That name already exists."
        case let .valueInUse(count): "Cannot delete this value because it is used by \(count) item(s). Reassign them first."
        case .invalidOperation: "That change could not be applied."
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

    private var started = false

    func start() async {
        guard !started else { return }
        started = true
        isRefreshing = true
        defer { isRefreshing = false }

        if let cached = CacheStore.loadData() {
            publish(cached, persist: true)
        }

        await migrateFromLegacyServerIfNeeded()

        if let data, data.settings.autoBackup {
            _ = try? LocalBackup.mirrorJSON(from: data)
        }

        if data == nil {
            errorMessage = "Open the previous version once while its server is reachable, then install this update again."
        }
    }

    func refresh() async {
        guard let data else { return }
        isRefreshing = true
        publish(data, persist: true)
        await PhotoStore.shared.sync(PhotoStore.assets(in: data, baseURL: nil))
        isRefreshing = false
        notice = "Collection refreshed."
    }

    func saveWatch(_ watch: Watch, isNew: Bool = false, initialPhotos: [LocalPhotoUpload] = []) async -> Watch? {
        do {
            var updated = try requireData()
            var saved = watch
            saved.purchasedText = purchaseMonthLabel(saved.purchased)
            saved.wearSessions = wearSessions(for: saved)
            saved.wearDates = nil
            saved.serviceRecords = serviceRecords(for: saved)
            if isNew {
                saved = Watch(
                    id: uniqueID(for: watch.name, existing: updated.watches.map(\.id)),
                    name: watch.name.trimmingCharacters(in: .whitespacesAndNewlines),
                    story: watch.story,
                    purchased: watch.purchased,
                    purchasedText: purchaseMonthLabel(watch.purchased),
                    diameter: watch.diameter,
                    price: watch.price,
                    original: watch.original,
                    status: watch.status,
                    statusNote: watch.statusNote,
                    photos: [],
                    category: watch.category,
                    dialColor: watch.dialColor,
                    lugToLug: watch.lugToLug,
                    material: watch.material,
                    brand: watch.brand
                )
                for photo in initialPhotos {
                    let extensionName = safePhotoExtension(filename: photo.filename, mimeType: photo.mimeType)
                    let storedFilename = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased() + extensionName
                    guard let asset = PhotoStore.asset(
                        itemID: saved.id,
                        filename: storedFilename,
                        wishlist: false,
                        baseURL: nil
                    ) else { throw LocalStoreError.invalidOperation }
                    try await PhotoStore.shared.storeUploaded(photo.data, as: asset)
                    saved.photos.append(storedFilename)
                }
                updated.watches.append(saved)
            } else if let index = updated.watches.firstIndex(where: { $0.id == watch.id }) {
                updated.watches[index] = saved
            } else {
                throw LocalStoreError.itemNotFound
            }
            await commit(updated)
            notice = isNew ? "Watch added." : "Watch saved."
            return saved
        } catch {
            surface(error)
            return nil
        }
    }

    func saveWishlist(_ item: WishlistItem, isNew: Bool = false) async -> WishlistItem? {
        do {
            var updated = try requireData()
            var saved = item
            if isNew {
                saved = WishlistItem(
                    id: uniqueID(for: item.name, existing: updated.wishlist.map(\.id)),
                    name: item.name.trimmingCharacters(in: .whitespacesAndNewlines),
                    brand: item.brand.trimmingCharacters(in: .whitespacesAndNewlines),
                    category: item.category,
                    priceExpected: item.priceExpected,
                    priceNote: item.priceNote,
                    notes: item.notes,
                    status: item.status,
                    added: item.added,
                    dialColor: item.dialColor,
                    diameter: item.diameter,
                    lugToLug: item.lugToLug,
                    material: item.material,
                    photos: []
                )
                updated.wishlist.append(saved)
            } else if let index = updated.wishlist.firstIndex(where: { $0.id == item.id }) {
                updated.wishlist[index] = saved
            } else {
                throw LocalStoreError.itemNotFound
            }
            await commit(updated)
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
            let watch = Watch(
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
            data.watches.append(watch)
            data.wishlist[index].status = "bought"
            self.notice = "Moved into the collection."
        }
    }

    func logWear(watchID: String, on date: Date = Date(), durationMinutes: Int) async {
        await mutate { data in
            guard (15...(24 * 60)).contains(durationMinutes) else {
                throw LocalStoreError.invalidOperation
            }
            guard let index = data.watches.firstIndex(where: { $0.id == watchID }) else {
                throw LocalStoreError.itemNotFound
            }
            var sessions = wearSessions(for: data.watches[index])
            sessions.append(WearSession(
                id: UUID().uuidString.lowercased(),
                date: calendarDayKey(date),
                durationMinutes: durationMinutes
            ))
            data.watches[index].wearDates = nil
            data.watches[index].wearSessions = sessions
            self.notice = "Logged \(wearDurationLabel(durationMinutes)) with \(data.watches[index].name)."
        }
    }

    func removeWear(watchID: String, sessionID: String) async {
        await mutate { data in
            guard let index = data.watches.firstIndex(where: { $0.id == watchID }) else {
                throw LocalStoreError.itemNotFound
            }
            var sessions = wearSessions(for: data.watches[index])
            guard sessions.contains(where: { $0.id == sessionID }) else { throw LocalStoreError.itemNotFound }
            sessions.removeAll { $0.id == sessionID }
            data.watches[index].wearDates = nil
            data.watches[index].wearSessions = sessions
            self.notice = "Wear session removed."
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

    func saveSettings(_ settings: CollectionSettings) async {
        await mutate { data in
            data.settings = settings
            self.notice = "Settings saved."
        }
    }

    func backup() async -> String {
        do {
            var updated = try requireData()
            let timestamp = ISO8601DateFormatter().string(from: Date())
            updated.settings.lastBackup = timestamp
            await commit(updated)
            _ = try await Task.detached(priority: .utility) {
                try LocalBackup.createFullBackup(from: updated)
            }.value
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
            await commit(imported.data)
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
            var updated = try requireData()
            let extensionName = safePhotoExtension(filename: filename, mimeType: mimeType)
            let storedFilename = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased() + extensionName
            guard let asset = PhotoStore.asset(itemID: itemID, filename: storedFilename, wishlist: wishlist, baseURL: nil) else {
                throw LocalStoreError.invalidOperation
            }
            try await PhotoStore.shared.storeUploaded(photoData, as: asset)
            if wishlist {
                guard let index = updated.wishlist.firstIndex(where: { $0.id == itemID }) else { throw LocalStoreError.itemNotFound }
                updated.wishlist[index].photos.insert(storedFilename, at: 0)
            } else {
                guard let index = updated.watches.firstIndex(where: { $0.id == itemID }) else { throw LocalStoreError.itemNotFound }
                updated.watches[index].photos.insert(storedFilename, at: 0)
            }
            await commit(updated)
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
            } else {
                guard let index = data.watches.firstIndex(where: { $0.id == itemID }),
                      data.watches[index].photos.contains(filename) else { throw LocalStoreError.itemNotFound }
                data.watches[index].photos.removeAll { $0 == filename }
            }
        }
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

    private func commit(_ updated: CollectionData) async {
        publish(updated, persist: true)
        if updated.settings.autoBackup { _ = try? LocalBackup.mirrorJSON(from: updated) }
        await PhotoStore.shared.sync(PhotoStore.assets(in: updated, baseURL: nil))
    }

    private func publish(_ rawData: CollectionData, persist: Bool) {
        let derived = DecisionEngine.withDerivedStats(rawData)
        data = derived
        scores = DecisionEngine.scores(for: derived)
        suggestions = DecisionEngine.suggestions(for: derived)
        isOffline = false
        errorMessage = nil
        if persist {
            CacheStore.save(derived)
            CacheStore.save(WishlistScoresResponse(scores: scores))
            if let suggestions { CacheStore.save(suggestions) }
        }
    }

    private func mutate(_ operation: (inout CollectionData) throws -> Void) async {
        do {
            var updated = try requireData()
            try operation(&updated)
            await commit(updated)
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

    private func surface(_ error: Error) {
        errorMessage = error.localizedDescription
    }

    private static var currentMonth: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM"
        return formatter.string(from: Date())
    }
}
