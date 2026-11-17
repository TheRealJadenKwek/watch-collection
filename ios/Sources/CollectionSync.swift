import Foundation
import os

// The baseline and visible collection share one atomic file. A crash can never
// acknowledge a server revision without also saving the matching local data.
struct SyncCheckpoint: Codable {
    var data: CollectionData
    var base: CollectionData?
    var server: String
    var lastSuccess: Date?
    /// The hub revision a bridge run's settled hub pass took `data` from; nil once anything else wrote this file.
    /// A bridge run that finds it starts on the hub's fast path (polish 6).
    var revision: String? = nil
}

enum SyncDisk {
    static var url: URL {
        AppPaths.collectionFolder.appendingPathComponent("sync.json")
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
    /// The link that asked, so the choice goes back to that link's `resolutions`. Not in the hub's JSON.
    private(set) var link: SyncLinkKind = .hub
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

    /// A conflict from this device's own merge with iCloud: "local" is this device, "remote" is iCloud.
    init(_ conflict: CollectionMerge.Conflict) {
        id = conflict.id
        path = conflict.path
        local = conflict.local.map(SyncValue.init)
        remote = conflict.remote.map(SyncValue.init)
        localDeleted = conflict.localDeleted
        remoteDeleted = conflict.remoteDeleted
        link = .cloud
    }

    func tagged(_ link: SyncLinkKind) -> SyncConflict {
        var tagged = self
        tagged.link = link
        return tagged
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
    init(_ value: JSONValue) {
        switch value {
        case .null: self = .null
        case let .bool(v): self = .bool(v)
        case let .number(v): self = .number(v)
        case let .string(v): self = .string(v)
        case let .array(v): self = .array(v.map(SyncValue.init))
        case let .object(v): self = .object(v.mapValues(SyncValue.init))
        }
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

/// A photo the exchange would send is on this device but could not be read (docs/icloud-fixes.md R4). It is not
/// gone, so its reference is kept and nothing is sent; the next pass tries again. Kept apart from
/// `CollectionSyncError`, whose cases `SyncFailure.classify` lists.
struct UnreadablePhotoError: LocalizedError {
    /// "dir/file".
    var name: String
    /// The watch it belongs to, by name (`CloudLink.photoOwner`); nil for an empty box tile.
    var owner: String? = nil
    var errorDescription: String? {
        guard let owner else { return "A photo on this device could not be read. Sync will retry." }
        return "A photo of \(owner) on this device could not be read. Sync will retry."
    }
}

actor CollectionSyncClient {
    let baseURL: URL
    let session: URLSession
    /// `protocolClasses`: tests only, a hub answered in-process (`StubHub`); nil in the app.
    init(address: String, protocolClasses: [AnyClass]? = nil) throws {
        guard let url = URL(string: address), ["http", "https"].contains(url.scheme),
              url.host != nil, url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil else { throw CollectionSyncError.invalidAddress }
        baseURL = url
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 12
        configuration.timeoutIntervalForResource = 25
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        if let protocolClasses { configuration.protocolClasses = protocolClasses }
        session = URLSession(configuration: configuration)
    }

    func snapshot() async throws -> SyncSnapshot {
        try JSONDecoder().decode(SyncSnapshot.self, from: await request("api/sync"))
    }

    /// - Parameters:
    ///   - dropping: which references to files gone on this device and the hub may be dropped. nil drops them all,
    ///     as before iCloud; with the cloud link on it is the names iCloud has said it does not have, and any other
    ///     such file skips this exchange (nil is returned) until the cloud link has fetched it or heard it is not
    ///     there (docs/icloud-plan.md section 5).
    ///   - keeping: the names the cloud link has given up on as unreadable (D3, polish 2 item 8). Such a file gone
    ///     here and on the hub is neither dropped nor waited on: the hub is sent the collection without its
    ///     reference (the hub answers 409 to a document naming a file it lacks). Empty, the rule is `dropping`'s
    ///     alone.
    /// - Returns: the hub's answer, and `heldBack`: the kept names this exchange actually left out of what it sent,
    ///   which the caller lays back into what it installs (`restoringPhotos`) and nothing else (review F1). nil when
    ///   the drop rule waits.
    ///
    /// A file still on this device that cannot be read is not gone (R4): the exchange throws
    /// `UnreadablePhotoError` with nothing dropped, and, when the check before sending finds it, nothing sent.
    func exchange(base: CollectionData?, local: CollectionData, resolutions: [String: String], remote: SyncSnapshot,
                  dropping: Set<String>? = nil,
                  keeping: Set<String> = []) async throws -> (answer: SyncSnapshot, heldBack: Set<String>)? {
        let assets = Self.uploads(from: local, hub: remote.data, hubFiles: remote.photos)
        guard let plan = Self.photoPlan(gone: Set(Self.goneFiles(assets)), dropping: dropping, keeping: keeping) else {
            return nil
        }
        if let asset = assets.first(where: Self.isUnreadable) { throw Self.unreadable(asset, in: local) }
        var lost: Set<String> = []
        var kept = plan.keep
        for asset in assets {
            try Task.checkCancellation()
            guard let file = PhotoStore.localURL(for: asset), let bytes = try? Data(contentsOf: file) else {
                // Still here but it would not read (it changed since the check above): not gone, as above.
                if Self.isHeld(asset) { throw Self.unreadable(asset, in: local) }
                let key = asset.directory + "/" + asset.filename
                // Given up on: kept here, held back from the hub (also when its file went after the first check).
                if keeping.contains(key) {
                    kept.insert(key)
                    continue
                }
                // Gone on both sides (e.g. a partial restore): drop the reference instead of blocking sync forever.
                if let dropping, !dropping.contains(key) { return nil }
                lost.insert(key)
                continue
            }
            let body = try JSONEncoder().encode(["data": bytes.base64EncodedString()])
            _ = try await request("api/sync/photos/\(asset.directory)/\(asset.filename)", body: body)
        }
        let withheld = lost.union(kept)
        let sent = withheld.isEmpty ? local : Self.removingPhotos(withheld, from: local)
        let body = try JSONEncoder().encode(SyncRequest(base: base, local: sent, resolutions: resolutions))
        let answer = try JSONDecoder().decode(SyncSnapshot.self, from: await request("api/sync", body: body))
        return (answer, kept)
    }

    /// What the exchange does with the files gone here and on the hub: those the cloud link has given up on are
    /// kept (held back from the hub only); the rest are dropped when `dropping` is nil or holds every one of them;
    /// otherwise nil, and the exchange waits. With `keeping` empty this is the drop rule as it was.
    static func photoPlan(gone: Set<String>, dropping: Set<String>?,
                          keeping: Set<String>) -> (drop: Set<String>, keep: Set<String>)? {
        let keep = gone.intersection(keeping)
        let drop = gone.subtracting(keep)
        if let dropping, !drop.isSubset(of: dropping) { return nil }
        return (drop, keep)
    }

    /// The files an exchange would send that are on neither side, as "dir/file": the ones its drop rule decides on.
    static func goneFiles(local: CollectionData, remote: SyncSnapshot) -> [String] {
        goneFiles(uploads(from: local, hub: remote.data, hubFiles: remote.photos))
    }

    private static func goneFiles(_ assets: [PhotoAsset]) -> [String] {
        assets.filter { asset in
            PhotoStore.localURL(for: asset).map { !FileManager.default.fileExists(atPath: $0.path) } ?? true
        }.map { $0.directory + "/" + $0.filename }
    }

    static let log = Logger(subsystem: "com.jadenkwek.watchcollection", category: "hub-sync")

    private static func isHeld(_ asset: PhotoAsset) -> Bool {
        PhotoStore.localURL(for: asset).map { FileManager.default.fileExists(atPath: $0.path) } ?? false
    }

    /// On this device, but this process may not read it.
    private static func isUnreadable(_ asset: PhotoAsset) -> Bool {
        guard let file = PhotoStore.localURL(for: asset), FileManager.default.fileExists(atPath: file.path) else {
            return false
        }
        return !FileManager.default.isReadableFile(atPath: file.path)
    }

    private static func unreadable(_ asset: PhotoAsset, in local: CollectionData) -> UnreadablePhotoError {
        let name = asset.directory + "/" + asset.filename
        let path = PhotoStore.localURL(for: asset)?.path ?? name
        log.error("could not read \(path, privacy: .public); the hub exchange keeps its reference and waits")
        return UnreadablePhotoError(name: name, owner: CloudLink.photoOwner(name, in: local))
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

    /// The inverse of `removingPhotos` over the same four things, for the references the exchange held back from
    /// the hub (`keys`, "dir/file"), laid back into what the hub answered (`data`) from the collection that was sent
    /// (`local`). Only on items `data` still has, and never over the hub's own changes:
    /// - a photo `local` names and `data` lacks goes back after the nearest earlier photo of `local`'s order that
    ///   `data` has (first when there is none);
    /// - its framing (`photoFocus`) goes back when `data` has none for it;
    /// - a box cutout made from it goes back only when `data` has no cutout;
    /// - a tile slot whose file is a key goes back only when `data` has nothing in that slot (items and the empty
    ///   tiles).
    /// Running it twice gives what running it once does.
    static func restoringPhotos(_ keys: Set<String>, from local: CollectionData, into data: CollectionData) -> CollectionData {
        guard !keys.isEmpty else { return data }
        var data = data
        func tiles(_ tiles: [String: String]?, from source: [String: String]?, in dir: String) -> [String: String]? {
            var result = tiles ?? [:]
            for (slot, file) in source ?? [:] where keys.contains(dir + "/" + file) && result[slot] == nil {
                result[slot] = file
            }
            return result.isEmpty ? tiles : result
        }
        func photos(_ photos: [String], from source: [String], in dir: String) -> [String] {
            var result = photos
            for (index, photo) in source.enumerated() where keys.contains(dir + "/" + photo) && !result.contains(photo) {
                let earlier = source[..<index].last { result.contains($0) }
                let at = earlier.flatMap { result.firstIndex(of: $0) }.map { $0 + 1 } ?? 0
                result.insert(photo, at: at)
            }
            return result
        }
        func focus(_ focus: [String: PhotoFocus]?, from source: [String: PhotoFocus]?, photos: [String],
                   in dir: String) -> [String: PhotoFocus]? {
            var result = focus
            for (photo, frame) in source ?? [:]
            where keys.contains(dir + "/" + photo) && photos.contains(photo) && result?[photo] == nil {
                if result == nil { result = [:] }
                result?[photo] = frame
            }
            return result
        }
        func cutout(_ cutout: BoxCutout?, from source: BoxCutout?, in dir: String) -> BoxCutout? {
            guard cutout == nil, let source, keys.contains(dir + "/" + source.photo) else { return cutout }
            return source
        }
        for i in data.watches.indices {
            guard let mine = local.watches.first(where: { $0.id == data.watches[i].id }) else { continue }
            let dir = mine.id
            data.watches[i].photos = photos(data.watches[i].photos, from: mine.photos, in: dir)
            data.watches[i].photoFocus = focus(data.watches[i].photoFocus, from: mine.photoFocus,
                                               photos: data.watches[i].photos, in: dir)
            data.watches[i].boxCutout = cutout(data.watches[i].boxCutout, from: mine.boxCutout, in: dir)
            data.watches[i].boxTiles = tiles(data.watches[i].boxTiles, from: mine.boxTiles, in: dir)
        }
        for i in data.wishlist.indices {
            guard let mine = local.wishlist.first(where: { $0.id == data.wishlist[i].id }) else { continue }
            let dir = "wl-" + mine.id
            data.wishlist[i].photos = photos(data.wishlist[i].photos, from: mine.photos, in: dir)
            data.wishlist[i].photoFocus = focus(data.wishlist[i].photoFocus, from: mine.photoFocus,
                                                photos: data.wishlist[i].photos, in: dir)
            data.wishlist[i].boxCutout = cutout(data.wishlist[i].boxCutout, from: mine.boxCutout, in: dir)
            data.wishlist[i].boxTiles = tiles(data.wishlist[i].boxTiles, from: mine.boxTiles, in: dir)
        }
        data.emptyBoxTiles = tiles(data.emptyBoxTiles, from: local.emptyBoxTiles, in: PhotoStore.boxTileDirectory)
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
