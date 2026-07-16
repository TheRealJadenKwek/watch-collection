import Foundation
import SwiftUI

@MainActor
final class AppStore: ObservableObject {
    @Published private(set) var data: CollectionData?
    @Published private(set) var scores: [String: WishlistScore] = [:]
    @Published private(set) var suggestions: SuggestionsResponse?
    @Published private(set) var isOffline = false
    @Published private(set) var isRefreshing = false
    @Published var errorMessage: String?
    @Published var notice: String?

    private(set) var serverURL: String
    private var started = false

    init(serverURL: String) {
        self.serverURL = serverURL
    }

    func start() async {
        guard !started else { return }
        started = true
        if let cached = CacheStore.loadData() { data = cached }
        if let cached = CacheStore.loadScores() { scores = cached.scores }
        if let cached = CacheStore.loadSuggestions() { suggestions = cached }
        await refresh()
    }

    func setServerURL(_ value: String) {
        serverURL = value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func refresh() async {
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let client = try makeClient()
            async let freshData = client.fetchData()
            async let freshScores = client.fetchScores()
            async let freshSuggestions = client.fetchSuggestions()
            let (loadedData, loadedScores, loadedSuggestions) = try await (freshData, freshScores, freshSuggestions)
            data = loadedData
            scores = loadedScores.scores
            suggestions = loadedSuggestions
            CacheStore.save(loadedData)
            CacheStore.save(loadedScores)
            CacheStore.save(loadedSuggestions)
            isOffline = false
            errorMessage = nil
        } catch {
            isOffline = data != nil
            errorMessage = error.localizedDescription
        }
    }

    func testConnection(url: String) async -> String {
        do {
            let client = try APIClient(baseURL: url)
            let count = try await client.testConnection()
            return "Connected · \(count) watches"
        } catch {
            return error.localizedDescription
        }
    }

    func saveWatch(_ watch: Watch, isNew: Bool = false) async -> Watch? {
        guard writable else { return nil }
        do {
            let client = try makeClient()
            let saved = try await (isNew ? client.createWatch(watch) : client.updateWatch(watch))
            await refresh()
            notice = isNew ? "Watch added." : "Watch saved."
            return saved
        } catch { surface(error); return nil }
    }

    func saveWishlist(_ item: WishlistItem, isNew: Bool = false) async -> WishlistItem? {
        guard writable else { return nil }
        do {
            let client = try makeClient()
            let saved = try await (isNew ? client.createWishlist(item) : client.updateWishlist(item))
            await refresh()
            notice = isNew ? "Candidate added." : "Candidate saved."
            return saved
        } catch { surface(error); return nil }
    }

    func deleteWatch(id: String) async {
        await mutate {
            let client = try self.makeClient()
            try await client.deleteWatch(id: id)
            self.notice = "Watch deleted."
        }
    }

    func deleteWishlist(id: String) async {
        await mutate {
            let client = try self.makeClient()
            try await client.deleteWishlist(id: id)
            self.notice = "Candidate deleted."
        }
    }

    func passWishlist(id: String) async {
        await mutate {
            let client = try self.makeClient()
            try await client.markWishlistPassed(id: id)
            self.notice = "Marked passed."
        }
    }

    func markBought(id: String, price: Double, purchased: String) async {
        await mutate {
            let client = try self.makeClient()
            try await client.markBought(id: id, price: price, purchased: purchased)
            self.notice = "Moved into the collection."
        }
    }

    func findWishlistImage(id: String) async -> URL? {
        guard writable else { return nil }
        do {
            let client = try makeClient()
            let result = try await client.findWishlistImage(id: id)
            await refresh()
            if result.ok { notice = "Image updated."; return nil }
            notice = "No image found. Open search or add a photo manually."
            return result.searchUrl.flatMap(URL.init(string:))
        } catch { surface(error); return nil }
    }

    func saveSettings(_ settings: CollectionSettings) async {
        await mutate {
            let client = try self.makeClient()
            try await client.updateSettings(settings)
            self.notice = "Settings saved."
        }
    }

    func backup() async -> String {
        guard writable else { return "Mac unreachable." }
        do {
            let client = try makeClient()
            let result = try await client.backup()
            await refresh()
            notice = "Backup complete."
            return result.output
        } catch { surface(error); return error.localizedDescription }
    }

    func taxonomy(_ route: TaxonomyRoute, operation: TaxonomyOperation) async {
        await mutate {
            let client = try self.makeClient()
            try await client.updateTaxonomy(route: route, operation: operation)
            self.notice = "\(route.title) updated."
        }
    }

    func addRadarBrand(_ brand: String) async {
        await mutate {
            let client = try self.makeClient()
            try await client.addRadarBrand(brand)
        }
    }

    func deleteRadarBrand(_ brand: String) async {
        await mutate {
            let client = try self.makeClient()
            try await client.deleteRadarBrand(brand)
        }
    }

    func uploadPhoto(data: Data, filename: String, mimeType: String, itemID: String, wishlist: Bool) async {
        await mutate {
            let client = try self.makeClient()
            try await client.uploadPhoto(data: data, filename: filename, mimeType: mimeType, itemID: itemID, wishlist: wishlist)
            self.notice = "Photo uploaded."
        }
    }

    func setCover(itemID: String, filename: String, wishlist: Bool) async {
        await mutate {
            let client = try self.makeClient()
            try await client.setPhotoCover(itemID: itemID, filename: filename, wishlist: wishlist)
        }
    }

    func deletePhoto(itemID: String, filename: String, wishlist: Bool) async {
        await mutate {
            let client = try self.makeClient()
            try await client.deletePhoto(itemID: itemID, filename: filename, wishlist: wishlist)
        }
    }

    func imageURL(itemID: String, filename: String, wishlist: Bool) -> URL? {
        let directory = wishlist ? "wl-\(itemID)" : itemID
        let id = directory.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? directory
        let file = filename.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? filename
        return URL(string: "\(serverURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")))/photos/\(id)/\(file)")
    }

    var writable: Bool {
        guard !isOffline else {
            errorMessage = "Mac unreachable. Cached data is read-only."
            return false
        }
        return true
    }

    private func makeClient() throws -> APIClient {
        try APIClient(baseURL: serverURL)
    }

    private func mutate(_ operation: () async throws -> Void) async {
        guard writable else { return }
        do {
            try await operation()
            await refresh()
        } catch { surface(error) }
    }

    private func surface(_ error: Error) {
        errorMessage = error.localizedDescription
    }
}
