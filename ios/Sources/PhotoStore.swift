import Foundation

struct PhotoAsset: Hashable, Sendable {
    let directory: String
    let filename: String
    let remoteURL: URL?

    var key: PhotoKey {
        PhotoKey(directory: directory, filename: filename)
    }
}

struct PhotoKey: Hashable, Sendable {
    let directory: String
    let filename: String
}

actor PhotoStore {
    static let shared = PhotoStore()

    private let session: URLSession
    private var downloads: [PhotoKey: Task<Data, Error>] = [:]
    private var uploadedButUnconfirmed: Set<PhotoKey> = []

    private init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        session = URLSession(configuration: configuration)
    }

    nonisolated static func asset(
        itemID: String,
        filename: String,
        wishlist: Bool,
        baseURL: String
    ) -> PhotoAsset? {
        let directory = wishlist ? "wl-\(itemID)" : itemID
        guard isSafePathComponent(directory), isSafePathComponent(filename) else { return nil }
        return PhotoAsset(
            directory: directory,
            filename: filename,
            remoteURL: remoteURL(baseURL: baseURL, directory: directory, filename: filename)
        )
    }

    nonisolated static func assets(in data: CollectionData, baseURL: String) -> [PhotoAsset] {
        let watchPhotos = data.watches.flatMap { watch in
            watch.photos.compactMap {
                asset(itemID: watch.id, filename: $0, wishlist: false, baseURL: baseURL)
            }
        }
        let wishlistPhotos = data.wishlist.flatMap { item in
            item.photos.compactMap {
                asset(itemID: item.id, filename: $0, wishlist: true, baseURL: baseURL)
            }
        }
        return watchPhotos + wishlistPhotos
    }

    func load(_ asset: PhotoAsset, allowDownload: Bool) async -> Data? {
        guard let fileURL = Self.localURL(for: asset) else { return nil }

        // A content-unique filename is immutable. Once it exists, it is always used
        // as-is and is never revalidated or downloaded again.
        if FileManager.default.fileExists(atPath: fileURL.path) {
            return try? Data(contentsOf: fileURL)
        }
        guard allowDownload, let remoteURL = asset.remoteURL else { return nil }

        if let download = downloads[asset.key] {
            return try? await download.value
        }

        let session = session
        let download = Task.detached(priority: .utility) {
            let (data, response) = try await session.data(from: remoteURL)
            guard let response = response as? HTTPURLResponse,
                  200..<300 ~= response.statusCode else {
                throw URLError(.badServerResponse)
            }
            try Self.persist(data, to: fileURL)
            return data
        }
        downloads[asset.key] = download

        do {
            let data = try await download.value
            downloads[asset.key] = nil
            return data
        } catch {
            downloads[asset.key] = nil
            return nil
        }
    }

    func storeUploaded(_ data: Data, as asset: PhotoAsset) throws {
        guard let fileURL = Self.localURL(for: asset) else { throw CocoaError(.fileWriteInvalidFileName) }
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            try Self.persist(data, to: fileURL)
        }
        uploadedButUnconfirmed.insert(asset.key)
    }

    func sync(_ assets: [PhotoAsset]) async {
        let uniqueAssets = Array(Dictionary(assets.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first }).values)
        let referenced = Set(uniqueAssets.map(\.key))

        // Once a successful data refresh includes an uploaded file, normal reference
        // tracking protects it and the temporary upload guard is no longer needed.
        uploadedButUnconfirmed.subtract(referenced)

        await withTaskGroup(of: Void.self) { group in
            for asset in uniqueAssets {
                group.addTask {
                    _ = await PhotoStore.shared.load(asset, allowDownload: true)
                }
            }
        }

        garbageCollect(keeping: referenced.union(uploadedButUnconfirmed))
    }

    nonisolated static func localURL(for asset: PhotoAsset) -> URL? {
        guard isSafePathComponent(asset.directory), isSafePathComponent(asset.filename) else { return nil }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PhotoStore", isDirectory: true)
            .appendingPathComponent(asset.directory, isDirectory: true)
            .appendingPathComponent(asset.filename, isDirectory: false)
    }

    private func garbageCollect(keeping referenced: Set<PhotoKey>) {
        let fileManager = FileManager.default
        let root = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PhotoStore", isDirectory: true)
        guard let directories = try? fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        for directoryURL in directories {
            guard (try? directoryURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
                try? fileManager.removeItem(at: directoryURL)
                continue
            }
            let directory = directoryURL.lastPathComponent
            guard let files = try? fileManager.contentsOfDirectory(
                at: directoryURL,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

            for fileURL in files where !referenced.contains(PhotoKey(directory: directory, filename: fileURL.lastPathComponent)) {
                try? fileManager.removeItem(at: fileURL)
            }
            if (try? fileManager.contentsOfDirectory(atPath: directoryURL.path).isEmpty) == true {
                try? fileManager.removeItem(at: directoryURL)
            }
        }
    }

    nonisolated private static func remoteURL(baseURL: String, directory: String, filename: String) -> URL? {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard var components = URLComponents(string: trimmed), components.scheme != nil, components.host != nil else {
            return nil
        }
        let basePath = components.percentEncodedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let segments = [basePath, "photos", encodedPathSegment(directory), encodedPathSegment(filename)]
            .filter { !$0.isEmpty }
        components.percentEncodedPath = "/" + segments.joined(separator: "/")
        return components.url
    }

    nonisolated private static func encodedPathSegment(_ value: String) -> String {
        value.addingPercentEncoding(
            withAllowedCharacters: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        ) ?? value
    }

    nonisolated private static func isSafePathComponent(_ value: String) -> Bool {
        !value.isEmpty && value != "." && value != ".." &&
            !value.contains("/") && !value.contains("\\") && !value.contains("\0")
    }

    nonisolated private static func persist(_ data: Data, to fileURL: URL) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: fileURL, options: .atomic)
    }
}
