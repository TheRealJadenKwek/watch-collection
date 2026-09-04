import Foundation

enum LocalBackup {
    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    static func mirrorJSON(from data: CollectionData) throws -> URL {
        let folder = try backupFolder()
        let destination = folder.appendingPathComponent("watches.json")
        try encoder.encode(data).write(to: destination, options: .atomic)
        return destination
    }

    static func createFullBackup(from data: CollectionData) throws -> URL {
        let folder = try backupFolder()
        _ = try mirrorJSON(from: data)
        let photoDestination = folder.appendingPathComponent("photos", isDirectory: true)
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: photoDestination, withIntermediateDirectories: true)

        let assets = PhotoStore.assets(in: data, baseURL: nil)
        let referenced = Set(assets.map(\.key))
        for asset in assets {
            guard let source = PhotoStore.localURL(for: asset), fileManager.fileExists(atPath: source.path) else { continue }
            let destination = photoDestination
                .appendingPathComponent(asset.directory, isDirectory: true)
                .appendingPathComponent(asset.filename)
            try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fileManager.fileExists(atPath: destination.path) {
                let sourceValues = try source.resourceValues(forKeys: [.fileSizeKey])
                let destinationValues = try destination.resourceValues(forKeys: [.fileSizeKey])
                if sourceValues.fileSize == destinationValues.fileSize { continue }
                try fileManager.removeItem(at: destination)
            }
            try fileManager.copyItem(at: source, to: destination)
        }
        removeUnreferencedPhotos(in: photoDestination, keeping: referenced)
        return folder
    }

    private static func backupFolder() throws -> URL {
        let documents = try FileManager.default.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let folder = documents.appendingPathComponent("Watch Collection Backup", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private static func removeUnreferencedPhotos(in root: URL, keeping referenced: Set<PhotoKey>) {
        let fileManager = FileManager.default
        guard let directories = try? fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        for directoryURL in directories {
            let directory = directoryURL.lastPathComponent
            guard let files = try? fileManager.contentsOfDirectory(
                at: directoryURL,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            for file in files where !referenced.contains(PhotoKey(directory: directory, filename: file.lastPathComponent)) {
                try? fileManager.removeItem(at: file)
            }
            if (try? fileManager.contentsOfDirectory(atPath: directoryURL.path).isEmpty) == true {
                try? fileManager.removeItem(at: directoryURL)
            }
        }
    }
}
