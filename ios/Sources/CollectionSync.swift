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
    /// Wording worked out from the collection, so a box space reads "Black Box, space 6".
    private var label: Label? = nil

    private struct Label {
        var title: String
        var local: String?
        var remote: String?
    }

    private enum CodingKeys: String, CodingKey {
        case id, path, local, remote, localDeleted, remoteDeleted
    }

    var title: String { label?.title ?? path.joined(separator: " / ") }
    var localText: String { localDeleted ? "Deleted" : label?.local ?? local?.description ?? "Empty" }
    var remoteText: String { remoteDeleted ? "Deleted" : label?.remote ?? remote?.description ?? "Empty" }

    /// This conflict worded with names from the given collections (the first that knows a name wins):
    /// `boxes / black / slots / 5` becomes "Black Box, space 6" and its two values the watches' names.
    func labelled(using collections: [CollectionData?]) -> SyncConflict {
        guard path.count == 4, path[0] == "boxes", path[2] == "slots", let slot = BoxModel.slotIndex(path[3]) else {
            return self
        }
        let known = collections.compactMap { $0 }
        let boxName = known.lazy.compactMap { $0.boxes?.first { $0.id == path[1] }?.name }.first ?? path[1]
        func watchName(_ value: SyncValue?) -> String? {
            guard case let .string(id)? = value else { return nil }
            return known.lazy.compactMap { $0.watches.first { $0.id == id }?.name }.first
        }
        var labelled = self
        labelled.label = Label(title: "\(boxName), space \(slot + 1)", local: watchName(local), remote: watchName(remote))
        return labelled
    }
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
    /// When a device other than this Mac last completed a sync with the hub.
    var lastRemoteSync: String?
    /// What the hub's sync understands. Absent on a hub running code from before boxes.
    var features: [String]? = nil

    /// The hub keeps `boxes`. One that does not drops the key from every document it returns, so its
    /// answer must never replace the boxes on this device, and nothing may seed or offer the starting
    /// layout on its word.
    var supportsBoxes: Bool { features?.contains("boxes") == true }
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
        var local = local
        var lost: Set<String> = []
        for asset in Self.uploads(from: local, hub: remote.data, hubFiles: remote.photos) {
            try Task.checkCancellation()
            guard let file = PhotoStore.localURL(for: asset), let bytes = try? Data(contentsOf: file) else {
                // Gone on both sides (e.g. a partial restore): drop the reference instead of blocking sync forever.
                lost.insert(asset.directory + "/" + asset.filename)
                continue
            }
            let body = try JSONEncoder().encode(["data": bytes.base64EncodedString()])
            _ = try await request("api/sync/photos/\(asset.directory)/\(asset.filename)", body: body)
        }
        if !lost.isEmpty { local = Self.removingPhotos(lost, from: local) }
        let body = try JSONEncoder().encode(SyncRequest(base: base, local: local, resolutions: resolutions))
        return try JSONDecoder().decode(SyncSnapshot.self, from: await request("api/sync", body: body))
    }

    func downloadPhotos(_ data: CollectionData) async throws {
        // Download without garbage collection: local edits can happen during awaits.
        for asset in PhotoStore.assets(in: data, baseURL: baseURL.absoluteString) {
            try Task.checkCancellation()
            if let file = PhotoStore.localURL(for: asset), FileManager.default.fileExists(atPath: file.path) { continue }
            // A photo the Mac can't serve shows as a placeholder; it must not stall the whole sync.
            _ = await PhotoStore.shared.load(asset, allowDownload: true)
        }
    }

    /// The files an exchange sends: every photo the hub does not list, and the box tiles of items the
    /// hub's document does not have yet (a candidate bought here moves its tiles to the new watch's
    /// folder). Tiles of items the hub has are the hub's: a file of theirs it does not list was replaced
    /// or removed there, so it is not sent back; nor are the empty tiles, which only the hub makes.
    static func uploads(from local: CollectionData, hub: CollectionData, hubFiles: [String]) -> [PhotoAsset] {
        let listed = Set(hubFiles)
        let hubWatches = Set(hub.watches.map(\.id))
        let hubCandidates = Set(hub.wishlist.map(\.id))
        let watchFiles = local.watches.flatMap { watch in
            (watch.photos + (hubWatches.contains(watch.id) ? [] : PhotoStore.tileNames(watch.boxTiles))).compactMap {
                PhotoStore.asset(itemID: watch.id, filename: $0, wishlist: false, baseURL: nil)
            }
        }
        let candidateFiles = local.wishlist.flatMap { item in
            (item.photos + (hubCandidates.contains(item.id) ? [] : PhotoStore.tileNames(item.boxTiles))).compactMap {
                PhotoStore.asset(itemID: item.id, filename: $0, wishlist: true, baseURL: nil)
            }
        }
        return (watchFiles + candidateFiles).filter { !listed.contains($0.directory + "/" + $0.filename) }
    }

    /// Drops references to files that are gone on both sides ("dir/file" keys): photos, their framing,
    /// a box cutout made from a lost photo, and box tiles.
    static func removingPhotos(_ keys: Set<String>, from data: CollectionData) -> CollectionData {
        var data = data
        func tiles(_ tiles: [String: String]?, in dir: String) -> [String: String]? {
            let kept = tiles?.filter { !keys.contains(dir + "/" + $0.value) }
            return kept?.isEmpty == false ? kept : nil
        }
        for i in data.watches.indices {
            let dir = data.watches[i].id
            data.watches[i].photos.removeAll { keys.contains(dir + "/" + $0) }
            data.watches[i].photoFocus = data.watches[i].photoFocus?.filter { !keys.contains(dir + "/" + $0.key) }
            if let cutout = data.watches[i].boxCutout, keys.contains(dir + "/" + cutout.photo) { data.watches[i].boxCutout = nil }
            data.watches[i].boxTiles = tiles(data.watches[i].boxTiles, in: dir)
        }
        for i in data.wishlist.indices {
            let dir = "wl-" + data.wishlist[i].id
            data.wishlist[i].photos.removeAll { keys.contains(dir + "/" + $0) }
            data.wishlist[i].photoFocus = data.wishlist[i].photoFocus?.filter { !keys.contains(dir + "/" + $0.key) }
            if let cutout = data.wishlist[i].boxCutout, keys.contains(dir + "/" + cutout.photo) { data.wishlist[i].boxCutout = nil }
            data.wishlist[i].boxTiles = tiles(data.wishlist[i].boxTiles, in: dir)
        }
        data.emptyBoxTiles = tiles(data.emptyBoxTiles, in: PhotoStore.boxTileDirectory)
        return data
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
