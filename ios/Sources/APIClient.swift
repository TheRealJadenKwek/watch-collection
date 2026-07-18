import Foundation

enum ServerConfiguration {
    static let productionURL = "http://localhost:8931"

    static var initialBaseURL: String {
        if let value = ProcessInfo.processInfo.environment["WATCH_BASE_URL"], !value.isEmpty {
            return value
        }
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(where: { $0 == "-WATCH_BASE_URL" || $0 == "--WATCH_BASE_URL" }),
           arguments.indices.contains(index + 1) {
            return arguments[index + 1]
        }
        if let value = UserDefaults.standard.string(forKey: "WATCH_BASE_URL"), !value.isEmpty {
            return value
        }
        return productionURL
    }
}

enum APIClientError: LocalizedError {
    case invalidBaseURL
    case invalidResponse
    case server(status: Int, message: String)
    case transport(String)
    case decoding(String)

    var errorDescription: String? {
        switch self {
        case .invalidBaseURL: "The server URL is invalid."
        case .invalidResponse: "The server returned an invalid response."
        case let .server(status, message): "Server \(status): \(message)"
        case let .transport(message): "Mac unreachable: \(message)"
        case let .decoding(message): "Could not read the server response: \(message)"
        }
    }
}

actor APIClient {
    private let baseURL: URL
    private let session: URLSession
    private let decoder = JSONDecoder()

    init(baseURL: String) throws {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: trimmed), url.scheme != nil, url.host != nil else {
            throw APIClientError.invalidBaseURL
        }
        self.baseURL = url
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        configuration.urlCache = URLCache.shared
        configuration.requestCachePolicy = .useProtocolCachePolicy
        self.session = URLSession(configuration: configuration)
    }

    func fetchData() async throws -> CollectionData {
        try await get("/api/data", as: CollectionData.self)
    }

    func fetchScores() async throws -> WishlistScoresResponse {
        try await get("/api/wishlist/scores", as: WishlistScoresResponse.self)
    }

    func fetchSuggestions() async throws -> SuggestionsResponse {
        try await get("/api/suggestions", as: SuggestionsResponse.self)
    }

    func testConnection() async throws -> Int {
        let data = try await fetchData()
        return data.watches.count
    }

    func updateWatch(_ watch: Watch) async throws -> Watch {
        try await send(
            "/api/watches/\(segment(watch.id))",
            method: "PUT",
            object: watchObject(watch),
            as: Watch.self
        )
    }

    func createWatch(_ watch: Watch) async throws -> Watch {
        try await send("/api/watches", method: "POST", object: watchObject(watch), as: Watch.self)
    }

    func deleteWatch(id: String) async throws {
        try await sendVoid("/api/watches/\(segment(id))", method: "DELETE", object: nil)
    }

    func updateWishlist(_ item: WishlistItem) async throws -> WishlistItem {
        try await send(
            "/api/wishlist/\(segment(item.id))",
            method: "PUT",
            object: wishlistObject(item),
            as: WishlistItem.self
        )
    }

    func createWishlist(_ item: WishlistItem) async throws -> WishlistItem {
        try await send("/api/wishlist", method: "POST", object: wishlistObject(item), as: WishlistItem.self)
    }

    func deleteWishlist(id: String) async throws {
        try await sendVoid("/api/wishlist/\(segment(id))", method: "DELETE", object: nil)
    }

    func markWishlistPassed(id: String) async throws {
        try await sendVoid("/api/wishlist/\(segment(id))", method: "PUT", object: ["status": "passed"])
    }

    func markBought(id: String, price: Double, purchased: String) async throws {
        try await sendVoid(
            "/api/wishlist/\(segment(id))/bought",
            method: "POST",
            object: ["price": price, "purchased": purchased]
        )
    }

    func findWishlistImage(id: String) async throws -> AutoImageResponse {
        try await send(
            "/api/wishlist/\(segment(id))/autoimage",
            method: "POST",
            object: nil,
            as: AutoImageResponse.self
        )
    }

    func updateSettings(_ settings: CollectionSettings) async throws {
        let wrist: [String: Any] = [
            "inches": settings.wrist.inches,
            "sweetSpotMin": settings.wrist.sweetSpotMin,
            "sweetSpotMax": settings.wrist.sweetSpotMax,
            "perfect": settings.wrist.perfect,
            "lugMax": settings.wrist.lugMax,
        ]
        try await sendVoid(
            "/api/settings",
            method: "PUT",
            object: [
                "autoBackup": settings.autoBackup,
                "autoImage": settings.autoImage,
                "suggestExclude": settings.suggestExclude ?? [],
                "backupRemote": settings.backupRemote ?? "gdrive:WatchCollection",
                "wrist": wrist,
            ]
        )
    }

    func backup() async throws -> BackupResponse {
        try await send("/api/backup", method: "POST", object: nil, as: BackupResponse.self)
    }

    func updateTaxonomy(route: TaxonomyRoute, operation: TaxonomyOperation) async throws {
        let object: [String: Any]
        switch operation {
        case let .add(value): object = ["add": value]
        case let .rename(from, to): object = ["rename": ["from": from, "to": to]]
        case let .delete(value): object = ["delete": value]
        case let .reorder(values): object = ["reorder": values]
        }
        try await sendVoid("/api/\(route.rawValue)", method: "PUT", object: object)
    }

    func addRadarBrand(_ brand: String) async throws {
        try await sendVoid("/api/brandwatchlist", method: "POST", object: ["brand": brand])
    }

    func deleteRadarBrand(_ brand: String) async throws {
        try await sendVoid("/api/brandwatchlist/\(segment(brand))", method: "DELETE", object: nil)
    }

    func uploadPhoto(data: Data, filename: String, mimeType: String, itemID: String, wishlist: Bool) async throws -> String {
        let boundary = "WatchCollection-\(UUID().uuidString)"
        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"photo\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: \(mimeType)\r\n\r\n".data(using: .utf8)!)
        body.append(data)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        let kind = wishlist ? "wishlist" : "watches"
        var request = try request(path: "/api/\(kind)/\(segment(itemID))/photos", method: "POST")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        let data = try await responseData(for: request)
        let response = try decode(PhotoUploadResponse.self, from: data)
        return response.filename
    }

    func setPhotoCover(itemID: String, filename: String, wishlist: Bool) async throws {
        let kind = wishlist ? "wishlist" : "watches"
        try await sendVoid(
            "/api/\(kind)/\(segment(itemID))/photos/\(segment(filename))/cover",
            method: "POST",
            object: nil
        )
    }

    func deletePhoto(itemID: String, filename: String, wishlist: Bool) async throws {
        let kind = wishlist ? "wishlist" : "watches"
        try await sendVoid(
            "/api/\(kind)/\(segment(itemID))/photos/\(segment(filename))",
            method: "DELETE",
            object: nil
        )
    }

    private func watchObject(_ watch: Watch) -> [String: Any] {
        [
            "name": watch.name,
            "story": watch.story,
            "purchased": watch.purchased ?? NSNull(),
            "purchasedText": watch.purchasedText,
            "diameter": watch.diameter ?? NSNull(),
            "lugToLug": watch.lugToLug ?? NSNull(),
            "price": watch.price,
            "original": watch.original ?? NSNull(),
            "status": watch.status,
            "statusNote": watch.statusNote,
            "category": watch.category ?? NSNull(),
            "dialColor": watch.dialColor ?? NSNull(),
            "material": watch.material ?? NSNull(),
            "brand": watch.brand ?? "",
        ]
    }

    private func wishlistObject(_ item: WishlistItem) -> [String: Any] {
        [
            "name": item.name,
            "brand": item.brand,
            "category": item.category ?? NSNull(),
            "priceExpected": item.priceExpected ?? NSNull(),
            "priceNote": item.priceNote,
            "notes": item.notes,
            "status": item.status,
            "added": item.added,
            "dialColor": item.dialColor ?? NSNull(),
            "diameter": item.diameter ?? NSNull(),
            "lugToLug": item.lugToLug ?? NSNull(),
            "material": item.material ?? NSNull(),
        ]
    }

    private func get<T: Decodable>(_ path: String, as type: T.Type) async throws -> T {
        let request = try request(path: path, method: "GET")
        let data = try await responseData(for: request)
        return try decode(type, from: data)
    }

    private func send<T: Decodable>(_ path: String, method: String, object: [String: Any]?, as type: T.Type) async throws -> T {
        var request = try request(path: path, method: method)
        if let object {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: object)
        }
        let data = try await responseData(for: request)
        return try decode(type, from: data)
    }

    private func sendVoid(_ path: String, method: String, object: [String: Any]?) async throws {
        var request = try request(path: path, method: method)
        if let object {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: object)
        }
        _ = try await responseData(for: request)
    }

    private func request(path: String, method: String) throws -> URLRequest {
        guard let url = URL(string: path, relativeTo: baseURL) else { throw APIClientError.invalidBaseURL }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    private func responseData(for request: URLRequest) async throws -> Data {
        do {
            let (data, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse else { throw APIClientError.invalidResponse }
            guard 200..<300 ~= response.statusCode else {
                let decoded = try? decoder.decode(APIMessage.self, from: data)
                let fallback = String(data: data, encoding: .utf8) ?? HTTPURLResponse.localizedString(forStatusCode: response.statusCode)
                throw APIClientError.server(status: response.statusCode, message: decoded?.error ?? fallback)
            }
            return data
        } catch let error as APIClientError {
            throw error
        } catch {
            throw APIClientError.transport(error.localizedDescription)
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do { return try decoder.decode(type, from: data) }
        catch { throw APIClientError.decoding(error.localizedDescription) }
    }

    private func segment(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))) ?? value
    }
}

enum CacheStore {
    private static var directory: URL? {
        try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent("WatchCollection", isDirectory: true)
    }

    static func loadData() -> CollectionData? { load(CollectionData.self, name: "data.json") }
    static func loadScores() -> WishlistScoresResponse? { load(WishlistScoresResponse.self, name: "scores.json") }
    static func loadSuggestions() -> SuggestionsResponse? { load(SuggestionsResponse.self, name: "suggestions.json") }

    static func save(_ value: CollectionData) { saveValue(value, name: "data.json") }
    static func save(_ value: WishlistScoresResponse) { saveValue(value, name: "scores.json") }
    static func save(_ value: SuggestionsResponse) { saveValue(value, name: "suggestions.json") }

    private static func load<T: Decodable>(_ type: T.Type, name: String) -> T? {
        guard let url = directory?.appendingPathComponent(name), let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private static func saveValue<T: Encodable>(_ value: T, name: String) {
        guard let directory else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(value) else { return }
        try? data.write(to: directory.appendingPathComponent(name), options: .atomic)
    }
}
