import Foundation

// The baseline and visible collection share one atomic file. A crash can never
// acknowledge a server revision without also saving the matching local data.
struct SyncCheckpoint: Codable {
    var data: CollectionData
    var base: CollectionData?
    var server: String
    var lastSuccess: Date?
}

enum SyncDisk {
    static var url: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WatchCollection/sync.json")
    }
    static func load() -> SyncCheckpoint? {
        guard let bytes = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(SyncCheckpoint.self, from: bytes)
    }
    static func save(_ checkpoint: SyncCheckpoint) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(checkpoint).write(to: url, options: .atomic)
    }
}

struct SyncConflict: Decodable, Identifiable {
    let id: String
    let path: [String]
    let local: SyncValue?
    let remote: SyncValue?
    let localDeleted: Bool
    let remoteDeleted: Bool

    var title: String { path.joined(separator: " / ") }
    var localText: String { localDeleted ? "Deleted" : local?.description ?? "Empty" }
    var remoteText: String { remoteDeleted ? "Deleted" : remote?.description ?? "Empty" }
}

indirect enum SyncValue: Decodable {
    case string(String), number(Double), bool(Bool), array([SyncValue]), object([String: SyncValue]), null
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([SyncValue].self) { self = .array(v) }
        else { self = .object(try c.decode([String: SyncValue].self)) }
    }
    var description: String {
        switch self {
        case let .string(v): return v
        case let .number(v): return v.formatted()
        case let .bool(v): return v ? "Yes" : "No"
        case let .array(v): return v.map(\.description).joined(separator: ", ")
        case let .object(v): return v.keys.sorted().map { "\($0): \(v[$0]!.description)" }.joined(separator: "; ")
        case .null: return "Empty"
        }
    }
}

struct SyncSnapshot: Decodable {
    var data: CollectionData
    var revision: String
    var photos: [String]
    var conflicts: [SyncConflict]
}

struct SyncRequest: Encodable {
    var base: CollectionData?
    var local: CollectionData
    var resolutions: [String: String]
}

enum CollectionSyncError: LocalizedError {
    case invalidAddress, missingPhoto, server(String)
    var errorDescription: String? {
        switch self {
        case .invalidAddress: return "Enter the Mac's Tailscale address, including http:// and :8931."
        case .missingPhoto: return "Some photos have not transferred yet. Sync will retry."
        case let .server(message): return message
        }
    }
}

actor CollectionSyncClient {
    let baseURL: URL
    let session: URLSession
    init(address: String) throws {
        guard let url = URL(string: address), ["http", "https"].contains(url.scheme),
              url.host != nil, url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil else { throw CollectionSyncError.invalidAddress }
        baseURL = url
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 12
        configuration.timeoutIntervalForResource = 25
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: configuration)
    }

    func snapshot() async throws -> SyncSnapshot {
        try JSONDecoder().decode(SyncSnapshot.self, from: await request("api/sync"))
    }

    func exchange(base: CollectionData?, local: CollectionData, resolutions: [String: String], remote: SyncSnapshot) async throws -> SyncSnapshot {
        let existing = Set(remote.photos)
        for asset in PhotoStore.assets(in: local, baseURL: nil) where !existing.contains(asset.directory + "/" + asset.filename) {
            try Task.checkCancellation()
            guard let file = PhotoStore.localURL(for: asset), let bytes = try? Data(contentsOf: file) else {
                throw CollectionSyncError.missingPhoto
            }
            let body = try JSONEncoder().encode(["data": bytes.base64EncodedString()])
            _ = try await request("api/sync/photos/\(asset.directory)/\(asset.filename)", body: body)
        }
        let body = try JSONEncoder().encode(SyncRequest(base: base, local: local, resolutions: resolutions))
        return try JSONDecoder().decode(SyncSnapshot.self, from: await request("api/sync", body: body))
    }

    func downloadPhotos(_ data: CollectionData) async throws {
        // Download without garbage collection: local edits can happen during awaits.
        for asset in PhotoStore.assets(in: data, baseURL: baseURL.absoluteString) {
            try Task.checkCancellation()
            guard await PhotoStore.shared.load(asset, allowDownload: true) != nil else {
                throw CollectionSyncError.missingPhoto
            }
        }
    }

    private func request(_ path: String, body: Data? = nil) async throws -> Data {
        try Task.checkCancellation()
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        if let body {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard 200..<300 ~= http.statusCode else {
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
            throw CollectionSyncError.server(message ?? "The Mac's sync service is not available yet (\(http.statusCode)).")
        }
        return data
    }
}
