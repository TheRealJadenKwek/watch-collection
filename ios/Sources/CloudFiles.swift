import Foundation

// iCloud sync: where this device keeps its files, and the cloud link's own files beside `sync.json`
// (docs/icloud-plan.md section 4): `cloud.json` (the book), `cloud-photos.json` (the marks), `cloud-status.json`
// (a report for the lead) and the one-time `sync-before-icloud-<time>.json`.

/// The folders the app keeps its data in, and the DEBUG launch arguments that move them or stand in for settings.
enum AppPaths {
    /// Application Support, or in DEBUG the folder given by `-WCDataRoot`, which takes `sync.json`, the photo
    /// folder, the cloud files, the cache and the JSON mirror with it, so a run there never touches his data.
    /// Laid out like Application Support (`WatchCollection/`, `PhotoStore/`), so a copy of it seeds a root.
    static var support: URL {
        #if DEBUG
        if let root = dataRoot { return root }
        #endif
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    }

    /// `WatchCollection/`: `sync.json`, the cache and the cloud files.
    static var collectionFolder: URL { support.appendingPathComponent("WatchCollection", isDirectory: true) }

    /// `PhotoStore/`: every photo and tile, as "dir/file".
    static var photoRoot: URL { support.appendingPathComponent("PhotoStore", isDirectory: true) }

    /// `LocalBackup.mirrorJSON`, except that a DEBUG run with its own data root keeps the mirror there too.
    @discardableResult
    static func mirrorJSON(from data: CollectionData) throws -> URL {
        #if DEBUG
        if let root = dataRoot {
            let folder = root.appendingPathComponent("Watch Collection Backup", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            let destination = folder.appendingPathComponent("watches.json")
            try encoder.encode(data).write(to: destination, options: .atomic)
            return destination
        }
        #endif
        return try LocalBackup.mirrorJSON(from: data)
    }

    /// A key in UserDefaults for a setting that belongs with the data (the cloud link's join and its switch): in a
    /// DEBUG run with its own data root it is kept apart from the real one.
    static func defaultsKey(_ key: String) -> String {
        #if DEBUG
        if let root = dataRoot { return "\(key)@\(root.path)" }
        #endif
        return key
    }

    #if DEBUG
    /// `-WCDataRoot <folder>`. CloudKitStore's gate reads the same key: only a run with its own data syncs.
    static var dataRoot: URL? {
        guard let path = UserDefaults.standard.string(forKey: "WCDataRoot"), !path.isEmpty else { return nil }
        return URL(filePath: (path as NSString).expandingTildeInPath, directoryHint: .isDirectory)
    }

    /// `-WCRole phone|mac`: which side of the cloud link this run plays.
    static var role: CloudRole? {
        switch UserDefaults.standard.string(forKey: "WCRole")?.lowercased() {
        case "phone", "iphone": return .phone
        case "mac": return .mac
        default: return nil
        }
    }

    /// `-WCHub <address>`: the hub address for this run only (empty for none). Never saved.
    static var hub: String? { UserDefaults.standard.string(forKey: "WCHub") }

    /// `-WCCloudStatus <case>`: the iCloud status the screens show, for screenshots. No link runs.
    static var forcedCloudStatus: String? { UserDefaults.standard.string(forKey: "WCCloudStatus") }
    #endif
}

/// The cloud link's files in one folder (the one `sync.json` is in). Plain atomic JSON files; a file that is missing
/// or does not decode reads as empty, which costs one fuller pass, never data.
struct CloudFiles: Sendable {
    let folder: URL

    static var app: CloudFiles { CloudFiles(folder: AppPaths.collectionFolder) }

    var bookURL: URL { folder.appendingPathComponent("cloud.json") }
    var marksURL: URL { folder.appendingPathComponent("cloud-photos.json") }
    var reportURL: URL { folder.appendingPathComponent("cloud-status.json") }
    var syncURL: URL { folder.appendingPathComponent("sync.json") }
    static let preCloudPrefix = "sync-before-icloud-"

    func loadBook() -> CloudBook {
        read(CloudBook.self, bookURL) ?? CloudBook()
    }

    func saveBook(_ book: CloudBook) throws {
        try write(book, bookURL)
    }

    func loadMarks() -> CloudPhotoMarks {
        read(CloudPhotoMarks.self, marksURL) ?? CloudPhotoMarks()
    }

    func saveMarks(_ marks: CloudPhotoMarks) {
        try? write(marks, marksURL)
    }

    func loadReport() -> CloudStatusReport? {
        read(CloudStatusReport.self, reportURL)
    }

    func saveReport(_ report: CloudStatusReport) {
        try? write(report, reportURL)
    }

    /// The copies of `sync.json` made before this device's first cloud write or install. The app never deletes them.
    var preCloudCopies: [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.filter { $0.hasPrefix(Self.preCloudPrefix) && $0.hasSuffix(".json") }.sorted()
            .map { folder.appendingPathComponent($0) }
    }

    /// Copies `sync.json` as it is to `sync-before-icloud-<time>.json`; with no `sync.json` yet, the collection given.
    @discardableResult
    func writePreCloudCopy(of data: CollectionData, at date: Date) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        var target = folder.appendingPathComponent("\(Self.preCloudPrefix)\(formatter.string(from: date)).json")
        var suffix = 2
        while FileManager.default.fileExists(atPath: target.path) {
            target = folder.appendingPathComponent("\(Self.preCloudPrefix)\(formatter.string(from: date))-\(suffix).json")
            suffix += 1
        }
        let bytes = try (try? Data(contentsOf: syncURL)) ?? JSONEncoder().encode(data)
        try bytes.write(to: target, options: .withoutOverwriting)
        return target
    }

    private func read<T: Decodable>(_ type: T.Type, _ url: URL) -> T? {
        guard let bytes = try? Data(contentsOf: url) else { return nil }
        return try? Self.decoder.decode(type, from: bytes)
    }

    private func write<T: Encodable>(_ value: T, _ url: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Self.encoder.encode(value).write(to: url, options: .atomic)
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

/// `cloud-status.json`: what the last cloud pass did, rewritten after each one, for the lead to read without a screen.
struct CloudStatusReport: Codable, Equatable, Sendable {
    struct Photos: Codable, Equatable, Sendable {
        /// Photos and tiles the collection names, and how many of them are on this device.
        var referenced: Int
        var held: Int
        var inCloud: Int
        var notInCloud: Int
        var mismatched: Int
    }

    var at: Date
    var role: String
    var build: String
    /// "upToDate", "installed", "installed+wrote", "conflicts(n)" or "waiting(...)".
    var outcome: String
    /// The link this device syncs through now ("hub" or "cloud").
    var activeLink: String
    var joined: Bool
    var epoch: String?
    var revision: String?
    var tag: String?
    var lastSuccess: Date?
    var paused: String?
    var photos: Photos
    var lastError: String?
    /// `status-mac` and `status-iphone` as the last head fetch returned them.
    var statuses: [String: CloudStatus]
}

/// The app's photo folder as the cloud link sees it, with `PhotoStore`'s name check.
struct AppPhotoFiles: PhotoFiles {
    func url(_ name: String) -> URL? {
        let parts = name.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2 else { return nil }
        return PhotoStore.localURL(for: PhotoAsset(directory: parts[0], filename: parts[1], remoteURL: nil))
    }

    func exists(_ name: String) -> Bool {
        url(name).map { FileManager.default.fileExists(atPath: $0.path) } ?? false
    }
}
