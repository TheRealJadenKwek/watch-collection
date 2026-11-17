import CloudKit
import CryptoKit
import Foundation

/// The three record types of iCloud sync (`Collection`, `Photo`, `Status`), their names, and the CloudKit error
/// table, as pure functions. CKRecord and CKAsset are made offline, so the unit tests use the real types.
/// See docs/icloud-plan.md sections 2 and 8. Nothing here talks to the network.
enum CloudRecords {
    /// The record format this build writes and fully understands.
    static let format = 1

    enum RecordType {
        static let collection = "Collection"
        static let photo = "Photo"
        static let status = "Status"
    }

    enum Field {
        static let format = "format"
        // Collection
        static let epoch = "epoch"
        static let origin = "origin"
        static let revision = "revision"   // also Status
        static let document = "document"
        static let device = "device"
        static let writtenAt = "writtenAt"
        // Photo
        static let dir = "dir"
        static let file = "file"
        static let bytes = "bytes"
        static let sha256 = "sha256"
        static let data = "data"
        // Status
        static let name = "name"
        static let build = "build"
        static let at = "at"
        static let hubAt = "hubAt"
        static let hubRevision = "hubRevision"
        static let conflicts = "conflicts"
        static let note = "note"
    }

    static let collectionName = "collection"
    static let statusNames = ["status-mac", "status-iphone"]

    /// What a head fetch asks for: every field of `Collection` and `Status` except the `document` asset.
    static let headKeys: [CKRecord.FieldKey] = [
        Field.format, Field.epoch, Field.origin, Field.revision, Field.device, Field.writtenAt,
        Field.name, Field.build, Field.at, Field.hubAt, Field.hubRevision, Field.conflicts, Field.note,
    ]

    /// Wait this long after a throttle that names no time of its own.
    static let defaultRetryAfter: TimeInterval = 30

    // MARK: Record names

    static func collectionID(in zone: CKRecordZone.ID) -> CKRecord.ID {
        CKRecord.ID(recordName: collectionName, zoneID: zone)
    }

    static func statusID(_ key: String, in zone: CKRecordZone.ID) -> CKRecord.ID {
        CKRecord.ID(recordName: key, zoneID: zone)
    }

    /// "dir/file" split in two, or nil when either part fails the check PhotoStore applies to every path it touches
    /// (`../x`, `a/b/c`, empty parts).
    static func photoParts(_ name: String) -> (dir: String, file: String)? {
        let parts = name.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2 else { return nil }
        // PhotoStore.asset runs PhotoStore's own path check on both parts; with wishlist false the directory is the
        // first part unchanged.
        guard PhotoStore.asset(itemID: parts[0], filename: parts[1], wishlist: false, baseURL: nil) != nil else { return nil }
        return (parts[0], parts[1])
    }

    /// The record id for the photo "dir/file": `photo/<dir>/<file>`. Record names may not start with an underscore
    /// and `_box` does, hence the prefix. If CloudKit ever refuses `/`, the separator changes here and only here.
    static func photoID(_ name: String, in zone: CKRecordZone.ID) -> CKRecord.ID? {
        guard let parts = photoParts(name) else { return nil }
        return CKRecord.ID(recordName: "photo/\(parts.dir)/\(parts.file)", zoneID: zone)
    }

    // MARK: Collection

    /// The document record. Built over the archived system fields when they belong to this record, so an
    /// `ifServerRecordUnchanged` save updates exactly the version that was fetched; otherwise a new record, which
    /// the same policy refuses when one already exists.
    static func collectionRecord(
        body: URL, revision: String, epoch: String, origin: String, device: String, writtenAt: Date,
        in zone: CKRecordZone.ID, over systemFields: Data?
    ) -> CKRecord {
        let id = collectionID(in: zone)
        let known = systemFields.flatMap(record(fromSystemFields:))
            .flatMap { $0.recordID == id && $0.recordType == RecordType.collection ? $0 : nil }
        let record = known ?? CKRecord(recordType: RecordType.collection, recordID: id)
        record[Field.format] = Int64(format)
        record[Field.epoch] = epoch
        record[Field.origin] = origin
        record[Field.revision] = revision
        record[Field.document] = CKAsset(fileURL: body)
        record[Field.device] = device
        record[Field.writtenAt] = writtenAt
        return record
    }

    /// The head of a `Collection` record (whole, or fetched with `headKeys`). nil when it is not readable.
    static func head(_ record: CKRecord) -> CloudHead? {
        guard record.recordType == RecordType.collection,
              let format = int(record[Field.format]),
              let revision = record[Field.revision] as? String,
              let epoch = record[Field.epoch] as? String else { return nil }
        return CloudHead(tag: record.recordChangeTag ?? "", revision: revision, epoch: epoch, format: format)
    }

    /// The whole document, its body read out of the asset now (CloudKit may remove the asset's file later).
    static func document(_ record: CKRecord) -> CloudDocument? {
        guard let url = (record[Field.document] as? CKAsset)?.fileURL,
              let body = try? Data(contentsOf: url) else { return nil }
        return document(record, body: body)
    }

    static func document(_ record: CKRecord, body: Data) -> CloudDocument? {
        guard let head = head(record),
              let origin = record[Field.origin] as? String,
              let device = record[Field.device] as? String,
              let writtenAt = record[Field.writtenAt] as? Date else { return nil }
        return CloudDocument(
            head: head, origin: origin, body: body, systemFields: systemFields(record), device: device, writtenAt: writtenAt
        )
    }

    // MARK: Photo

    /// A `Photo` record as read back.
    struct Photo: Equatable {
        var format: Int
        var dir: String
        var file: String
        var bytes: Int
        var sha256: String
        /// The asset's local file, when the record was fetched with its asset.
        var data: URL?

        var name: String { "\(dir)/\(file)" }
    }

    /// The record for the photo "dir/file", its asset pointing at the file as it is. nil for a hostile name.
    static func photoRecord(_ name: String, file: URL, sha256: String, bytes: Int, in zone: CKRecordZone.ID) -> CKRecord? {
        guard let parts = photoParts(name), let id = photoID(name, in: zone) else { return nil }
        let record = CKRecord(recordType: RecordType.photo, recordID: id)
        record[Field.format] = Int64(format)
        record[Field.dir] = parts.dir
        record[Field.file] = parts.file
        record[Field.bytes] = Int64(bytes)
        record[Field.sha256] = sha256
        record[Field.data] = CKAsset(fileURL: file)
        return record
    }

    static func photo(_ record: CKRecord) -> Photo? {
        guard record.recordType == RecordType.photo,
              let format = int(record[Field.format]),
              let dir = record[Field.dir] as? String,
              let file = record[Field.file] as? String,
              let bytes = int(record[Field.bytes]),
              let sha256 = record[Field.sha256] as? String else { return nil }
        return Photo(format: format, dir: dir, file: file, bytes: bytes, sha256: sha256, data: (record[Field.data] as? CKAsset)?.fileURL)
    }

    /// After a photo save came back `serverRecordChanged`: true when the server's copy has these bytes (already
    /// there, adopted), false when it has other bytes, nil when the error does not carry the server's record.
    static func photoAlreadyThere(_ error: Error, sha256: String) -> Bool? {
        guard let error = error as? CKError, error.code == .serverRecordChanged,
              let server = error.serverRecord.flatMap(photo) else { return nil }
        return server.sha256.lowercased() == sha256.lowercased()
    }

    // MARK: Status

    /// The whole record, every key set (absent optionals cleared): `Status` is saved with `.allKeys`.
    static func statusRecord(_ key: String, _ status: CloudStatus, in zone: CKRecordZone.ID) -> CKRecord {
        let record = CKRecord(recordType: RecordType.status, recordID: statusID(key, in: zone))
        record[Field.format] = Int64(format)
        record[Field.name] = status.name
        record[Field.build] = status.build
        record[Field.at] = status.at
        record[Field.revision] = status.revision
        record[Field.hubAt] = status.hubAt
        record[Field.hubRevision] = status.hubRevision
        record[Field.conflicts] = Int64(status.conflicts)
        record[Field.note] = status.note
        return record
    }

    /// nil when it is not readable. A missing count or note reads as none: the record is information only.
    static func status(_ record: CKRecord) -> CloudStatus? {
        guard record.recordType == RecordType.status,
              let name = record[Field.name] as? String,
              let build = record[Field.build] as? String,
              let revision = record[Field.revision] as? String,
              let at = record[Field.at] as? Date else { return nil }
        return CloudStatus(
            name: name, build: build, revision: revision, at: at,
            hubAt: record[Field.hubAt] as? Date, hubRevision: record[Field.hubRevision] as? String,
            conflicts: int(record[Field.conflicts]) ?? 0, note: record[Field.note] as? String ?? ""
        )
    }

    // MARK: System fields

    static func systemFields(_ record: CKRecord) -> Data {
        let coder = NSKeyedArchiver(requiringSecureCoding: true)
        record.encodeSystemFields(with: coder)
        coder.finishEncoding()
        return coder.encodedData
    }

    static func record(fromSystemFields data: Data) -> CKRecord? {
        guard let coder = try? NSKeyedUnarchiver(forReadingFrom: data) else { return nil }
        coder.requiresSecureCoding = true
        defer { coder.finishDecoding() }
        return CKRecord(coder: coder)
    }

    // MARK: Errors (section 8)

    /// The error as the cloud link sees it. A partial failure gives its most telling item. Codes the store turns
    /// into results before they reach the link (`zoneNotFound` and `unknownItem`: no document, not in iCloud;
    /// `limitExceeded`: a smaller batch) come back as `.other` with the code's name. `assetFileNotFound` is
    /// `.photoFileMissing`.
    static func failure(_ error: Error) -> CloudFailure {
        if let failure = error as? CloudFailure { return failure }
        if let error = error as? CKError { return failure(ck: error) }
        let error = error as NSError
        if error.domain == NSURLErrorDomain { return .network }
        return .other("\(error.domain) \(error.code)")
    }

    private static func failure(ck error: CKError) -> CloudFailure {
        switch error.code {
        case .partialFailure:
            let items = itemErrors(error).map { failure(ck: $0) }
            return items.max(by: { precedes($0, $1) }) ?? .other(name(error.code))
        case .notAuthenticated, .accountTemporarilyUnavailable, .managedAccountRestricted:
            return .noAccount
        case .quotaExceeded:
            return .quotaFull
        case .userDeletedZone:
            return .purged
        case .serverRecordChanged:
            return .changed
        case .assetFileNotFound:
            return .photoFileMissing
        case .requestRateLimited, .zoneBusy, .serviceUnavailable:
            return .retryAfter(error.retryAfterSeconds ?? defaultRetryAfter)
        case .networkUnavailable, .networkFailure, .serverResponseLost:
            return .network
        case .missingEntitlement, .badContainer, .permissionFailure, .badDatabase:
            return .misconfigured(name(error.code))
        default:
            return .other(name(error.code))
        }
    }

    /// The CKError codes an error stands for: its own, or for a partial failure its items' (batch-failed items
    /// aside, they only say another item failed). Empty for an error that is not a CKError.
    static func codes(_ error: Error) -> Set<CKError.Code> {
        guard let error = error as? CKError else { return [] }
        guard error.code == .partialFailure else { return [error.code] }
        return Set(itemErrors(error).map(\.code))
    }

    /// The record, or its zone, is not there (`unknownItem`, `zoneNotFound`): no document, or not in iCloud.
    static func isMissing(_ error: Error) -> Bool {
        let codes = codes(error)
        return !codes.isEmpty && codes.isSubset(of: [.unknownItem, .zoneNotFound])
    }

    /// The zone is not there and was not erased by him (`zoneNotFound`, never `userDeletedZone`).
    static func isZoneMissing(_ error: Error) -> Bool {
        codes(error) == [.zoneNotFound]
    }

    /// The error for one record: its own item when a partial failure names it, else the error itself.
    static func itemError(_ error: Error, for id: CKRecord.ID) -> Error {
        guard let ck = error as? CKError, ck.code == .partialFailure, let item = ck.partialErrorsByItemID?[id] else { return error }
        return item
    }

    /// For log lines: the code and its name, never a message.
    static func describe(_ error: Error) -> String {
        if let failure = error as? CloudFailure { return "\(failure)" }
        if let error = error as? CKError {
            if error.code == .partialFailure {
                return "CKError 2 partialFailure [" + codes(error).map { "\($0.rawValue) \(name($0))" }.sorted().joined(separator: ", ") + "]"
            }
            return "CKError \(error.code.rawValue) \(name(error.code))"
        }
        let error = error as NSError
        return "\(error.domain) \(error.code)"
    }

    static func name(_ code: CKError.Code) -> String {
        switch code {
        case .internalError: "internalError"
        case .partialFailure: "partialFailure"
        case .networkUnavailable: "networkUnavailable"
        case .networkFailure: "networkFailure"
        case .badContainer: "badContainer"
        case .serviceUnavailable: "serviceUnavailable"
        case .requestRateLimited: "requestRateLimited"
        case .missingEntitlement: "missingEntitlement"
        case .notAuthenticated: "notAuthenticated"
        case .permissionFailure: "permissionFailure"
        case .unknownItem: "unknownItem"
        case .invalidArguments: "invalidArguments"
        case .serverRecordChanged: "serverRecordChanged"
        case .serverRejectedRequest: "serverRejectedRequest"
        case .assetFileNotFound: "assetFileNotFound"
        case .assetFileModified: "assetFileModified"
        case .incompatibleVersion: "incompatibleVersion"
        case .operationCancelled: "operationCancelled"
        case .batchRequestFailed: "batchRequestFailed"
        case .zoneBusy: "zoneBusy"
        case .badDatabase: "badDatabase"
        case .quotaExceeded: "quotaExceeded"
        case .zoneNotFound: "zoneNotFound"
        case .limitExceeded: "limitExceeded"
        case .userDeletedZone: "userDeletedZone"
        case .managedAccountRestricted: "managedAccountRestricted"
        case .serverResponseLost: "serverResponseLost"
        case .assetNotAvailable: "assetNotAvailable"
        case .accountTemporarilyUnavailable: "accountTemporarilyUnavailable"
        default: "CKError \(code.rawValue)"
        }
    }

    // MARK: Helpers

    /// Lowercase hex SHA-256, the form the `sha256` field holds.
    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func int(_ value: CKRecordValue?) -> Int? {
        (value as? NSNumber)?.intValue
    }

    private static func itemErrors(_ error: CKError) -> [CKError] {
        (error.partialErrorsByItemID ?? [:]).values.compactMap { $0 as? CKError }.filter { $0.code != .batchRequestFailed }
    }

    /// Which of two failures from one partial failure tells the link more. The order of the items is not fixed,
    /// so ties break on the retry time, then on the text.
    private static func precedes(_ a: CloudFailure, _ b: CloudFailure) -> Bool {
        func rank(_ failure: CloudFailure) -> Int {
            switch failure {
            case .misconfigured: 7
            case .noAccount: 6
            case .purged: 5
            case .quotaFull: 4
            case .retryAfter: 3
            case .changed: 2
            case .photoFileMissing, .network: 1
            case .other: 0
            }
        }
        if rank(a) != rank(b) { return rank(a) < rank(b) }
        switch (a, b) {
        case let (.retryAfter(x), .retryAfter(y)): return x < y
        case let (.other(x), .other(y)), let (.misconfigured(x), .misconfigured(y)): return x < y
        default: return false
        }
    }
}
