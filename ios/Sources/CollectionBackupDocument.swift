import Foundation
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static let watchCollectionBackup = UTType(
        exportedAs: "com.jadenkwek.watchcollection.backup",
        conformingTo: .package
    )
}

enum CollectionBackupError: LocalizedError {
    case invalidDocument
    case unsupportedVersion(Int)
    case unsafeData
    case tooLarge

    var errorDescription: String? {
        switch self {
        case .invalidDocument:
            "That file is not a valid Watch Collection backup."
        case let .unsupportedVersion(version):
            "This backup uses unsupported format version \(version)."
        case .unsafeData:
            "The backup contains invalid or unsafe watch data."
        case .tooLarge:
            "The backup is too large to import safely."
        }
    }
}

struct BackupPhoto: Sendable {
    var key: PhotoKey
    var data: Data
}

struct CollectionImport: Identifiable, Sendable {
    let id = UUID()
    var data: CollectionData
    var photos: [BackupPhoto]
    var sourceName: String
    var includesPhotoArchive: Bool

    var summary: String {
        let owned = data.watches.filter { $0.status == "owned" }.count
        let photoText = includesPhotoArchive ? "\(photos.count) photos" : "JSON only"
        return "\(data.watches.count) watches, \(owned) currently owned, \(data.wishlist.count) wishlist entries, and \(photoText)."
    }
}

struct CollectionExportDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.watchCollectionBackup, .json] }

    let data: CollectionData
    let photos: [BackupPhoto]
    let includesPhotoArchive: Bool
    let missingPhotoCount: Int

    init(data: CollectionData, includePhotos: Bool) throws {
        try CollectionBackupArchive.validate(data)
        self.data = data
        includesPhotoArchive = includePhotos
        if includePhotos {
            let snapshot = try CollectionBackupArchive.photoSnapshot(for: data)
            photos = snapshot.photos
            missingPhotoCount = snapshot.missing
        } else {
            photos = []
            missingPhotoCount = 0
        }
    }

    init(configuration: ReadConfiguration) throws {
        let imported = try CollectionBackupArchive.load(
            from: configuration.file,
            sourceName: "Imported backup"
        )
        data = imported.data
        photos = imported.photos
        includesPhotoArchive = imported.includesPhotoArchive
        missingPhotoCount = 0
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        if configuration.contentType.conforms(to: .json) {
            return FileWrapper(regularFileWithContents: try CollectionBackupArchive.encode(data))
        }
        return try CollectionBackupArchive.package(data: data, photos: photos)
    }
}

enum CollectionBackupArchive {
    private struct Manifest: Codable {
        var schemaVersion: Int
        var exportedAt: String
        var photoCount: Int
    }

    private static let maximumJSONBytes = 10 * 1_024 * 1_024
    private static let maximumPhotoBytes = 30 * 1_024 * 1_024
    private static let maximumTotalPhotoBytes = 1_024 * 1_024 * 1_024
    private static let maximumPhotoCount = 2_000

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    static func encode(_ data: CollectionData) throws -> Data {
        try encoder.encode(data)
    }

    static func package(data: CollectionData, photos: [BackupPhoto]) throws -> FileWrapper {
        try validate(data)
        let manifest = Manifest(
            schemaVersion: 1,
            exportedAt: ISO8601DateFormatter().string(from: Date()),
            photoCount: photos.count
        )
        var photoDirectories: [String: [String: FileWrapper]] = [:]
        for photo in photos {
            guard isSafePathComponent(photo.key.directory), isSafePathComponent(photo.key.filename) else {
                throw CollectionBackupError.unsafeData
            }
            photoDirectories[photo.key.directory, default: [:]][photo.key.filename] = FileWrapper(
                regularFileWithContents: photo.data
            )
        }
        let photoWrappers = photoDirectories.mapValues { FileWrapper(directoryWithFileWrappers: $0) }
        return FileWrapper(directoryWithFileWrappers: [
            "manifest.json": FileWrapper(regularFileWithContents: try encoder.encode(manifest)),
            "watches.json": FileWrapper(regularFileWithContents: try encode(data)),
            "photos": FileWrapper(directoryWithFileWrappers: photoWrappers),
        ])
    }

    static func photoSnapshot(for data: CollectionData) throws -> (photos: [BackupPhoto], missing: Int) {
        let uniqueAssets = Dictionary(
            PhotoStore.assets(in: data, baseURL: nil).map { ($0.key, $0) },
            uniquingKeysWith: { first, _ in first }
        ).values.sorted {
            if $0.directory == $1.directory { return $0.filename < $1.filename }
            return $0.directory < $1.directory
        }
        guard uniqueAssets.count <= maximumPhotoCount else { throw CollectionBackupError.tooLarge }
        var photos: [BackupPhoto] = []
        var missing = 0
        var totalBytes = 0
        for asset in uniqueAssets {
            guard let url = PhotoStore.localURL(for: asset), FileManager.default.fileExists(atPath: url.path) else {
                missing += 1
                continue
            }
            let photoData = try Data(contentsOf: url, options: .mappedIfSafe)
            guard photoData.count <= maximumPhotoBytes else { throw CollectionBackupError.tooLarge }
            totalBytes += photoData.count
            guard totalBytes <= maximumTotalPhotoBytes else { throw CollectionBackupError.tooLarge }
            photos.append(BackupPhoto(key: asset.key, data: photoData))
        }
        return (photos, missing)
    }

    static func load(from url: URL) throws -> CollectionImport {
        let wrapper = try FileWrapper(url: url, options: [.immediate])
        return try load(from: wrapper, sourceName: url.lastPathComponent)
    }

    static func load(from wrapper: FileWrapper, sourceName: String) throws -> CollectionImport {
        if wrapper.isRegularFile {
            guard let json = wrapper.regularFileContents else { throw CollectionBackupError.invalidDocument }
            let data = try decodeCollection(json)
            return CollectionImport(
                data: data,
                photos: [],
                sourceName: sourceName,
                includesPhotoArchive: false
            )
        }

        guard wrapper.isDirectory,
              let children = wrapper.fileWrappers,
              let json = children["watches.json"]?.regularFileContents
        else { throw CollectionBackupError.invalidDocument }

        if let manifestData = children["manifest.json"]?.regularFileContents {
            let manifest = try JSONDecoder().decode(Manifest.self, from: manifestData)
            guard manifest.schemaVersion == 1 else {
                throw CollectionBackupError.unsupportedVersion(manifest.schemaVersion)
            }
        }

        let data = try decodeCollection(json)
        let photosRoot = children["photos"]
        guard photosRoot == nil || photosRoot?.isDirectory == true else {
            throw CollectionBackupError.invalidDocument
        }
        let photos = try decodePhotos(from: photosRoot, referencedBy: data)
        return CollectionImport(
            data: data,
            photos: photos,
            sourceName: sourceName,
            includesPhotoArchive: true
        )
    }

    static func validate(_ data: CollectionData) throws {
        guard data.watches.count <= 10_000, data.wishlist.count <= 10_000 else {
            throw CollectionBackupError.tooLarge
        }
        let watchIDs = data.watches.map(\.id)
        let wishlistIDs = data.wishlist.map(\.id)
        guard Set(watchIDs).count == watchIDs.count,
              Set(wishlistIDs).count == wishlistIDs.count,
              data.watches.allSatisfy({
                  !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                      isSafePathComponent($0.id) &&
                      $0.photos.allSatisfy(isSafePathComponent)
              }),
              data.wishlist.allSatisfy({
                  !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                      isSafePathComponent("wl-\($0.id)") &&
                      $0.photos.allSatisfy(isSafePathComponent)
              })
        else { throw CollectionBackupError.unsafeData }
    }

    private static func decodeCollection(_ json: Data) throws -> CollectionData {
        guard json.count <= maximumJSONBytes else { throw CollectionBackupError.tooLarge }
        do {
            let data = try JSONDecoder().decode(CollectionData.self, from: json)
            try validate(data)
            return data
        } catch let error as CollectionBackupError {
            throw error
        } catch {
            throw CollectionBackupError.invalidDocument
        }
    }

    private static func decodePhotos(from root: FileWrapper?, referencedBy data: CollectionData) throws -> [BackupPhoto] {
        guard let root, let directories = root.fileWrappers else { return [] }
        let keys = Set(PhotoStore.assets(in: data, baseURL: nil).map(\.key))
        guard keys.count <= maximumPhotoCount else { throw CollectionBackupError.tooLarge }
        var result: [BackupPhoto] = []
        var totalBytes = 0
        for key in keys.sorted(by: {
            if $0.directory == $1.directory { return $0.filename < $1.filename }
            return $0.directory < $1.directory
        }) {
            guard let photoData = directories[key.directory]?.fileWrappers?[key.filename]?.regularFileContents else {
                continue
            }
            guard photoData.count <= maximumPhotoBytes else { throw CollectionBackupError.tooLarge }
            totalBytes += photoData.count
            guard totalBytes <= maximumTotalPhotoBytes else { throw CollectionBackupError.tooLarge }
            result.append(BackupPhoto(key: key, data: photoData))
        }
        return result
    }

    private static func isSafePathComponent(_ value: String) -> Bool {
        !value.isEmpty && value != "." && value != ".." &&
            !value.contains("/") && !value.contains("\\") && !value.contains("\0")
    }
}
