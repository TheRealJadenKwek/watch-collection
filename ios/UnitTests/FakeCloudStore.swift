import Foundation
@testable import WatchCollection

/// An iCloud in memory for `CloudLinkTests`: per account one private database holding the `Collection` zone, the
/// document, the photos (bytes copied into the fake's own folder) and the statuses. It keeps `CloudKitStore`'s
/// contract:
/// - `head` and `document` report a missing zone or record as no document; a zone he erased throws `.purged` from
///   every call until `prepareZone` or `write(over: nil)` saves the zone again (as the real store's do).
/// - `write(over: nil)` makes the zone and creates, or throws `.changed` when a document is already there; saving over
///   a version that is no longer the current one (or is gone) throws `.changed`.
/// - `uploadPhoto` makes a missing zone (never an erased one), throws `.photoFileMissing` for a missing file, returns
///   true when the name is already there with the same bytes and false when with other bytes.
/// - `downloadPhoto` returns false when iCloud does not have the name, and writes the file atomically.
actor FakeCloudStore: CloudStore {
    enum Call: Hashable, Sendable {
        case account, head, document, write, presence, upload, download, status, zone
    }

    enum Zone: Sendable {
        case missing, present, erased
    }

    struct Stored: Sendable {
        var body: Data
        var revision: String
        var epoch: String
        var origin: String
        var device: String
        var writtenAt: Date
        var tag: String
        var format: Int
    }

    struct Photo: Sendable {
        var file: URL
        var sha256: String
        var bytes: Int
    }

    struct Database: Sendable {
        var zone = Zone.missing
        var document: Stored?
        var photos: [String: Photo] = [:]
        var statuses: [String: CloudStatus] = [:]
    }

    let folder: URL
    private var databases: [String: Database] = [:]
    /// The iCloud account the device is signed in to; nil when none.
    private(set) var signedIn: String? = "account-A"

    // Switches.
    private var offline = false
    private var quotaFull = false
    private var retryAfter: TimeInterval?
    private var failing: [Call: CloudFailure] = [:]
    /// Names `photosPresent` does not report although they are there (as if another device sent them a moment after).
    private var hiddenFromPresence: Set<String> = []
    private var downloadDelay: UInt64 = 0

    // Counters.
    private(set) var calls: [Call: Int] = [:]
    /// The device of each document save that landed, in order.
    private(set) var writes: [String] = []
    /// `uploadPhoto` calls per name.
    private(set) var uploadCalls: [String: Int] = [:]
    /// Photo records created, in order.
    private(set) var photoSaves: [String] = []
    private(set) var downloads: [String] = []
    private(set) var statusWrites: [String] = []
    /// "zone", "photo <name>" and "document <device>" in the order they landed.
    private(set) var log: [String] = []
    private(set) var maxDownloadsInFlight = 0
    private var downloadsInFlight = 0
    private var tags = 0

    // Hooks, each run once.
    private var afterDocument: (@Sendable () async -> Void)?
    private var afterUpload: (count: Int, run: @Sendable () async -> Void)?
    /// Runs inside every upload that makes a photo record (a test moves its clock here).
    private var everyUpload: (@Sendable () -> Void)?

    init(folder: URL) {
        self.folder = folder
    }

    // MARK: CloudStore

    func account() async throws -> String {
        try begin(.account)
        guard let signedIn else { throw CloudFailure.noAccount }
        return signedIn
    }

    func head() async throws -> (document: CloudHead?, statuses: [String: CloudStatus]) {
        try begin(.head)
        let db = try database()
        return (db.document.map(Self.head), db.statuses)
    }

    func document() async throws -> CloudDocument? {
        try begin(.document)
        let db = try database()
        let document = db.document.map(Self.document)
        if let hook = afterDocument {
            afterDocument = nil
            await hook()
        }
        return document
    }

    func write(body: Data, revision: String, epoch: String, origin: String, device: String,
               over systemFields: Data?) async throws -> CloudDocument {
        try begin(.write)
        // Creating saves the zone first, which is also what brings back a zone he erased.
        var db = try database(allowErased: systemFields == nil)
        if quotaFull { throw CloudFailure.quotaFull }
        if let systemFields {
            guard db.zone == .present, let current = db.document, Data(current.tag.utf8) == systemFields else {
                throw CloudFailure.changed
            }
        } else {
            db.zone = .present
            if db.document != nil {
                store(db)
                throw CloudFailure.changed
            }
        }
        tags += 1
        let stored = Stored(body: body, revision: revision, epoch: epoch, origin: origin, device: device,
                            writtenAt: Date(), tag: "tag-\(tags)", format: CloudRecords.format)
        db.document = stored
        store(db)
        writes.append(device)
        log.append("document \(device)")
        return Self.document(stored)
    }

    func photosPresent(_ names: [String]) async throws -> Set<String> {
        try begin(.presence)
        let db = try database()
        return Set(names.filter { db.photos[$0] != nil && !hiddenFromPresence.contains($0) })
    }

    func uploadPhoto(_ name: String, file: URL, sha256: String, bytes: Int) async throws -> Bool {
        try begin(.upload)
        uploadCalls[name, default: 0] += 1
        var db = try database()
        if quotaFull { throw CloudFailure.quotaFull }
        guard let data = try? Data(contentsOf: file) else { throw CloudFailure.photoFileMissing }
        guard CloudLink.sha256(data) == sha256, data.count == bytes else { throw CloudFailure.other("\(name) described wrongly") }
        db.zone = .present
        if let existing = db.photos[name] {
            store(db)
            return existing.sha256 == sha256
        }
        let copy = folder.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try data.write(to: copy)
        db.photos[name] = Photo(file: copy, sha256: sha256, bytes: bytes)
        store(db)
        photoSaves.append(name)
        log.append("photo \(name)")
        everyUpload?()
        if let hook = afterUpload, hook.count == photoSaves.count {
            afterUpload = nil
            await hook.run()
        }
        return true
    }

    func downloadPhoto(_ name: String, to file: URL) async throws -> Bool {
        try begin(.download)
        let db = try database()
        guard let photo = db.photos[name] else { return false }
        downloadsInFlight += 1
        maxDownloadsInFlight = max(maxDownloadsInFlight, downloadsInFlight)
        if downloadDelay > 0 { try? await Task.sleep(nanoseconds: downloadDelay) }
        downloadsInFlight -= 1
        let data = try Data(contentsOf: photo.file)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: file, options: .atomic)
        downloads.append(name)
        return true
    }

    func writeStatus(_ key: String, _ status: CloudStatus) async throws {
        try begin(.status)
        var db = try database()
        if quotaFull { throw CloudFailure.quotaFull }
        db.zone = .present
        db.statuses[key] = status
        store(db)
        statusWrites.append(key)
    }

    func prepareZone() async throws {
        try begin(.zone)
        var db = try database(allowErased: true)
        db.zone = .present
        store(db)
        log.append("zone")
    }

    // MARK: Switches

    func signIn(_ account: String?) { signedIn = account }
    func setOffline(_ value: Bool) { offline = value }
    func setQuotaFull(_ value: Bool) { quotaFull = value }
    func setRetryAfter(_ seconds: TimeInterval?) { retryAfter = seconds }
    func fail(_ call: Call, with failure: CloudFailure?) { failing[call] = failure }
    func hideFromPresence(_ names: Set<String>) { hiddenFromPresence = names }
    func setDownloadDelay(milliseconds: UInt64) { downloadDelay = milliseconds * 1_000_000 }

    /// He erased the app's data in Settings: the zone and everything in it go, and the zone answers `.purged`.
    func eraseByUser() { databases[key] = Database(zone: .erased) }

    /// The zone is simply not there (`zoneNotFound`), as after a Development reset.
    func deleteZone() { databases[key] = Database(zone: .missing) }

    /// Another device (a newer build, a restarted Mac) saves this body directly.
    func setDocument(_ body: Data, epoch: String, device: String = "elsewhere") {
        var db = databases[key] ?? Database()
        db.zone = .present
        tags += 1
        db.document = Stored(body: body, revision: CloudLink.sha256(body), epoch: epoch, origin: CloudLink.hubOrigin,
                             device: device, writtenAt: Date(), tag: "tag-\(tags)", format: CloudRecords.format)
        databases[key] = db
    }

    func corruptRevision() {
        databases[key]?.document?.revision = String(repeating: "0", count: 64)
    }

    func setFormat(_ format: Int) {
        databases[key]?.document?.format = format
    }

    /// A photo already in iCloud, put there by another device.
    func putPhoto(_ name: String, _ data: Data) throws {
        var db = databases[key] ?? Database()
        db.zone = .present
        let copy = folder.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try data.write(to: copy)
        db.photos[name] = Photo(file: copy, sha256: CloudLink.sha256(data), bytes: data.count)
        databases[key] = db
    }

    func onNextDocument(_ hook: @escaping @Sendable () async -> Void) { afterDocument = hook }

    /// Runs `hook` inside the upload that makes the `count`th photo record.
    func onUpload(_ count: Int, _ hook: @escaping @Sendable () async -> Void) { afterUpload = (count, hook) }

    func onEveryUpload(_ hook: @escaping @Sendable () -> Void) { everyUpload = hook }

    // MARK: Reading

    func count(_ call: Call) -> Int { calls[call, default: 0] }

    var currentHead: CloudHead? { databases[key]?.document.map(Self.head) }

    var zone: Zone { databases[key]?.zone ?? .missing }

    /// The document's body, parsed.
    func body() throws -> JSONValue? {
        guard let stored = databases[key]?.document else { return nil }
        return try JSONDecoder().decode(JSONValue.self, from: stored.body)
    }

    func photoNames() -> Set<String> { Set(databases[key].map { Array($0.photos.keys) } ?? []) }

    func status(_ key: String) -> CloudStatus? { databases[self.key]?.statuses[key] }

    // MARK: Helpers

    private var key: String { signedIn ?? "" }

    private func begin(_ call: Call) throws {
        calls[call, default: 0] += 1
        if offline { throw CloudFailure.network }
        if let retryAfter { throw CloudFailure.retryAfter(retryAfter) }
        if let failure = failing[call] { throw failure }
    }

    private func database(allowErased: Bool = false) throws -> Database {
        guard let signedIn else { throw CloudFailure.noAccount }
        let db = databases[signedIn] ?? Database()
        if db.zone == .erased, !allowErased { throw CloudFailure.purged }
        return db
    }

    private func store(_ db: Database) { databases[key] = db }

    private static func head(_ stored: Stored) -> CloudHead {
        CloudHead(tag: stored.tag, revision: stored.revision, epoch: stored.epoch, format: stored.format)
    }

    private static func document(_ stored: Stored) -> CloudDocument {
        CloudDocument(head: head(stored), origin: stored.origin, body: stored.body, systemFields: Data(stored.tag.utf8),
                      device: stored.device, writtenAt: stored.writtenAt)
    }
}

/// A photo folder in a temp directory, with the same name check `PhotoStore` applies.
struct TempPhotoFiles: PhotoFiles {
    let root: URL

    func url(_ name: String) -> URL? {
        let parts = name.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\\") }) else {
            return nil
        }
        return root.appendingPathComponent(parts[0], isDirectory: true).appendingPathComponent(parts[1], isDirectory: false)
    }

    func exists(_ name: String) -> Bool {
        url(name).map { FileManager.default.fileExists(atPath: $0.path) } ?? false
    }

    func put(_ name: String, _ data: Data) throws {
        guard let file = url(name) else { throw CocoaError(.fileWriteInvalidFileName) }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: file)
    }

    func remove(_ name: String) throws {
        guard let file = url(name) else { return }
        try FileManager.default.removeItem(at: file)
    }
}

/// A clock the test moves by hand.
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var time = Date(timeIntervalSince1970: 1_800_000_000)

    func now() -> Date {
        lock.lock()
        defer { lock.unlock() }
        return time
    }

    func advance(_ seconds: TimeInterval) {
        lock.lock()
        time = time.addingTimeInterval(seconds)
        lock.unlock()
    }
}
