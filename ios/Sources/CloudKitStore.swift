import CloudKit
import Foundation
import os
#if os(macOS)
import Security
#endif

/// The real `CloudStore`: plain CloudKit calls by record id on the private database of
/// `iCloud.com.jadenkwek.watchcollection`, zone `Collection`. Records are built and read by `CloudRecords`; errors
/// come out as `CloudFailure` per the table in docs/icloud-plan.md section 8. Only `live()` (and the DEBUG check
/// harness, with its own entitlement check) makes one: a CKContainer made without the entitlement ends the process.
final class CloudKitStore: CloudStore, @unchecked Sendable {
    static let containerID = "iCloud.com.jadenkwek.watchcollection"
    static let zoneID = CKRecordZone.ID(zoneName: "Collection", ownerName: CKCurrentUserDefaultName)
    static let log = Logger(subsystem: "com.jadenkwek.watchcollection", category: "cloud-sync")

    static let requestTimeout: TimeInterval = 30
    /// Uploads and downloads of photo bytes.
    static let photoTimeout: TimeInterval = 120
    /// Names asked about in one existence check.
    static let presenceBatch = 100

    /// The store for this launch, or nil: in a build without `WC_CLOUDKIT`, on a simulator, under XCTest, with
    /// `-WCNoCloud`, in a DEBUG run without `-WCDataRoot`, and on the Mac without the container entitlement. Nothing
    /// constructs CKContainer before this gate passes.
    static func live() -> CloudKitStore? {
        guard builtWithICloud, !isSimulator else { return nil }
        let process = ProcessInfo.processInfo
        if process.environment["XCTestConfigurationFilePath"] != nil || process.arguments.contains("-WCNoCloud") { return nil }
        #if DEBUG
        // A debug run never reaches his data: only a run given its own data folder syncs.
        guard let root = UserDefaults.standard.string(forKey: "WCDataRoot"), !root.isEmpty else { return nil }
        #endif
        #if os(macOS)
        guard hasContainerEntitlement() else {
            log.notice("cloud sync off: this build is not signed with \(containerID, privacy: .public)")
            return nil
        }
        #endif
        return CloudKitStore(container: CKContainer(identifier: containerID))
    }

    /// Set by the build that adds the iCloud container to the entitlements (`WC_CLOUDKIT` in
    /// SWIFT_ACTIVE_COMPILATION_CONDITIONS). Until then no CloudKit object is made at all.
    private static var builtWithICloud: Bool {
        #if WC_CLOUDKIT
        return true
        #else
        return false
        #endif
    }

    private static var isSimulator: Bool {
        #if targetEnvironment(simulator)
        return true
        #else
        return false
        #endif
    }

    #if os(macOS)
    /// Whether the running app is signed with the container, read from its own signature. The iOS SDK has no
    /// public SecTask API; there the compile flag, added together with the entitlement, is the guard.
    static func hasContainerEntitlement() -> Bool {
        guard let task = SecTaskCreateFromSelf(nil),
              let value = SecTaskCopyValueForEntitlement(task, "com.apple.developer.icloud-container-identifiers" as CFString, nil),
              let containers = value as? [String] else { return false }
        return containers.contains(containerID)
    }
    #endif

    let zone: CKRecordZone.ID
    private let container: CKContainer
    private let database: CKDatabase

    /// Only `live()` and the DEBUG check harness call this, each after its own gate.
    init(container: CKContainer, zone: CKRecordZone.ID = CloudKitStore.zoneID) {
        self.container = container
        self.database = container.privateCloudDatabase
        self.zone = zone
    }

    private var collectionID: CKRecord.ID { CloudRecords.collectionID(in: zone) }
    private var statusIDs: [CKRecord.ID] { CloudRecords.statusNames.map { CloudRecords.statusID($0, in: zone) } }

    // MARK: CloudStore

    func account() async throws -> String {
        let status: CKAccountStatus
        do {
            status = try await container.configuredWith(configuration: Self.configuration(Self.requestTimeout)) {
                try await $0.accountStatus()
            }
        } catch {
            throw fail("account", error)
        }
        // No account, restricted, could not determine, temporarily unavailable: the link sleeps.
        guard status == .available else {
            Self.log.notice("account: not available, status \(status.rawValue)")
            throw CloudFailure.noAccount
        }
        do {
            let user = try await container.configuredWith(configuration: Self.configuration(Self.requestTimeout)) {
                try await $0.userRecordID()
            }
            Self.log.notice("account: available")
            return user.recordName
        } catch {
            throw fail("account", error)
        }
    }

    func head() async throws -> (document: CloudHead?, statuses: [String: CloudStatus]) {
        do {
            let results = try await fetch([collectionID] + statusIDs, keys: CloudRecords.headKeys, timeout: Self.requestTimeout)
            var document: CloudHead?
            switch results[collectionID] {
            case .success(let record)?:
                guard let head = CloudRecords.head(record) else { throw CloudFailure.other("unreadable Collection record") }
                document = head
            case .failure(let error)?:
                guard CloudRecords.isMissing(error) else { throw error }
            case nil:
                throw CloudFailure.other("no result for the Collection record")
            }
            var statuses: [String: CloudStatus] = [:]
            for id in statusIDs {
                switch results[id] {
                case .success(let record)?:
                    statuses[id.recordName] = CloudRecords.status(record)
                case .failure(let error)?:
                    guard CloudRecords.isMissing(error) else { throw error }
                case nil:
                    break
                }
            }
            Self.log.notice("head: document \(document == nil ? "none" : "present", privacy: .public), statuses \(statuses.count)")
            return (document, statuses)
        } catch {
            throw fail("head", error)
        }
    }

    func document() async throws -> CloudDocument? {
        do {
            let results = try await fetch([collectionID], keys: nil, timeout: Self.requestTimeout)
            switch results[collectionID] {
            case .success(let record)?:
                guard let document = CloudRecords.document(record) else { throw CloudFailure.other("unreadable Collection record") }
                Self.log.notice("document: fetched, body \(document.body.count) bytes")
                return document
            case .failure(let error)?:
                guard CloudRecords.isMissing(error) else { throw error }
                Self.log.notice("document: none")
                return nil
            case nil:
                throw CloudFailure.other("no result for the Collection record")
            }
        } catch {
            throw fail("document", error)
        }
    }

    func write(body: Data, revision: String, epoch: String, origin: String, device: String, over systemFields: Data?) async throws -> CloudDocument {
        let creating = systemFields == nil
        // The asset needs a file; it lives only for this call.
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("wc-cloud-\(UUID().uuidString).json", isDirectory: false)
        defer { try? FileManager.default.removeItem(at: temp) }
        do {
            try body.write(to: temp, options: .atomic)
            if creating { try await saveZone() }
            let writtenAt = Date()
            let record = CloudRecords.collectionRecord(
                body: temp, revision: revision, epoch: epoch, origin: origin, device: device, writtenAt: writtenAt,
                in: zone, over: systemFields
            )
            let saved = try await save(record, policy: .ifServerRecordUnchanged, timeout: Self.requestTimeout)
            Self.log.notice("write: \(creating ? "created" : "updated", privacy: .public), body \(body.count) bytes")
            return CloudDocument(
                head: CloudHead(tag: saved.recordChangeTag ?? "", revision: revision, epoch: epoch, format: CloudRecords.format),
                origin: origin, body: body, systemFields: CloudRecords.systemFields(saved), device: device, writtenAt: writtenAt
            )
        } catch {
            let failure = fail("write", error)
            // Saving over a version whose record or zone has since gone: the link fetches again and finds no
            // document, which is how section 8 treats a missing zone.
            if !creating, CloudRecords.isMissing(error) { throw CloudFailure.changed }
            throw failure
        }
    }

    func photosPresent(_ names: [String]) async throws -> Set<String> {
        do {
            var byID: [CKRecord.ID: String] = [:]
            for name in Set(names) {
                if let id = CloudRecords.photoID(name, in: zone) { byID[id] = name }
            }
            let ids = byID.keys.sorted { $0.recordName < $1.recordName }
            var present = Set<String>()
            for start in stride(from: 0, to: ids.count, by: Self.presenceBatch) {
                let batch = Array(ids[start..<min(start + Self.presenceBatch, ids.count)])
                present.formUnion(try await presentIDs(batch).compactMap { byID[$0] })
            }
            Self.log.notice("photosPresent: asked \(names.count), present \(present.count)")
            return present
        } catch {
            throw fail("photosPresent", error)
        }
    }

    func uploadPhoto(_ name: String, file: URL, sha256: String, bytes: Int) async throws -> Bool {
        do {
            guard let record = CloudRecords.photoRecord(name, file: file, sha256: sha256, bytes: bytes, in: zone) else {
                throw CloudFailure.other("unsafe photo name")
            }
            guard FileManager.default.fileExists(atPath: file.path) else { throw CloudFailure.photoFileMissing }
            do {
                // Photos go up before the document that creates the zone, so the first one may make it.
                _ = try await saveMakingZone(record, policy: .ifServerRecordUnchanged, timeout: Self.photoTimeout)
                Self.log.notice("uploadPhoto \(name, privacy: .public): saved, \(bytes) bytes")
                return true
            } catch where CloudRecords.codes(error) == [.serverRecordChanged] {
                // A photo record never changes: the name exists, so compare the bytes it holds.
                let same = try await photoAlreadyThere(error, id: record.recordID, sha256: sha256)
                Self.log.notice("uploadPhoto \(name, privacy: .public): \(same ? "already there" : "mismatch, server holds other bytes", privacy: .public)")
                return same
            }
        } catch {
            throw fail("uploadPhoto \(name)", error)
        }
    }

    func downloadPhoto(_ name: String, to file: URL) async throws -> Bool {
        do {
            guard let id = CloudRecords.photoID(name, in: zone) else { throw CloudFailure.other("unsafe photo name") }
            let results = try await fetch([id], keys: nil, timeout: Self.photoTimeout)
            switch results[id] {
            case .success(let record)?:
                guard let photo = CloudRecords.photo(record), photo.name == name, let source = photo.data else {
                    throw CloudFailure.other("unreadable Photo record")
                }
                // Copied out of the asset's URL before returning: CloudKit may remove that file at any time.
                let data = try Data(contentsOf: source)
                guard data.count == photo.bytes, CloudRecords.sha256(data) == photo.sha256.lowercased() else {
                    throw CloudFailure.other("photo bytes differ from their record")
                }
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: file, options: .atomic)
                Self.log.notice("downloadPhoto \(name, privacy: .public): \(data.count) bytes")
                return true
            case .failure(let error)?:
                guard CloudRecords.isMissing(error) else { throw error }
                Self.log.notice("downloadPhoto \(name, privacy: .public): not in iCloud")
                return false
            case nil:
                throw CloudFailure.other("no result for the Photo record")
            }
        } catch {
            throw fail("downloadPhoto \(name)", error)
        }
    }

    func writeStatus(_ key: String, _ status: CloudStatus) async throws {
        do {
            let record = CloudRecords.statusRecord(key, status, in: zone)
            _ = try await saveMakingZone(record, policy: .allKeys, timeout: Self.requestTimeout)
            Self.log.notice("writeStatus \(key, privacy: .public): saved")
        } catch {
            throw fail("writeStatus \(key)", error)
        }
    }

    /// Saves the zone, which brings back one he erased. Only the Mac's "Sync through iCloud again" calls this.
    func prepareZone() async throws {
        do {
            try await saveZone()
        } catch {
            throw fail("prepareZone", error)
        }
    }

    // MARK: Calls

    private static func configuration(_ timeout: TimeInterval) -> CKOperation.Configuration {
        let configuration = CKOperation.Configuration()
        configuration.qualityOfService = .userInitiated
        configuration.timeoutIntervalForRequest = timeout
        // Bounds the whole call too, so a pass never waits on CloudKit's own long retries.
        configuration.timeoutIntervalForResource = timeout
        return configuration
    }

    /// A by-id fetch with one result per id. A partial failure becomes per-id failures, and a missing zone for the
    /// whole call becomes "missing" for every id, so callers read both the same way.
    private func fetch(_ ids: [CKRecord.ID], keys: [CKRecord.FieldKey]?, timeout: TimeInterval) async throws -> [CKRecord.ID: Result<CKRecord, Error>] {
        do {
            return try await database.configuredWith(configuration: Self.configuration(timeout)) {
                try await $0.records(for: ids, desiredKeys: keys)
            }
        } catch {
            if let ck = error as? CKError, ck.code == .partialFailure, let items = ck.partialErrorsByItemID {
                var results: [CKRecord.ID: Result<CKRecord, Error>] = [:]
                for (key, item) in items {
                    if let id = key as? CKRecord.ID { results[id] = .failure(item) }
                }
                return results
            }
            if CloudRecords.isMissing(error) {
                return Dictionary(uniqueKeysWithValues: ids.map { ($0, Result<CKRecord, Error>.failure(error)) })
            }
            throw error
        }
    }

    /// Saves one record and returns the server's copy, or throws that record's own error.
    private func save(_ record: CKRecord, policy: CKModifyRecordsOperation.RecordSavePolicy, timeout: TimeInterval) async throws -> CKRecord {
        let results: [CKRecord.ID: Result<CKRecord, Error>]
        do {
            results = try await database.configuredWith(configuration: Self.configuration(timeout)) {
                try await $0.modifyRecords(saving: [record], deleting: [], savePolicy: policy, atomically: true).saveResults
            }
        } catch {
            throw CloudRecords.itemError(error, for: record.recordID)
        }
        switch results[record.recordID] {
        case .success(let saved)?: return saved
        case .failure(let error)?: throw error
        case nil: throw CloudFailure.other("no result for \(record.recordID.recordName)")
        }
    }

    /// `save`, and when the zone is not there (never when he erased it), make the zone and save once more.
    private func saveMakingZone(_ record: CKRecord, policy: CKModifyRecordsOperation.RecordSavePolicy, timeout: TimeInterval) async throws -> CKRecord {
        do {
            return try await save(record, policy: policy, timeout: timeout)
        } catch where CloudRecords.isZoneMissing(error) {
            try await saveZone()
            return try await save(record, policy: policy, timeout: timeout)
        }
    }

    private func saveZone() async throws {
        let results = try await database.configuredWith(configuration: Self.configuration(Self.requestTimeout)) {
            try await $0.modifyRecordZones(saving: [CKRecordZone(zoneID: self.zone)], deleting: []).saveResults
        }
        if case .failure(let error)? = results[zone] { throw error }
        Self.log.notice("zone \(self.zone.zoneName, privacy: .public): saved")
    }

    /// The ids among `ids` that exist, asked with no fields. `limitExceeded` halves the batch.
    private func presentIDs(_ ids: [CKRecord.ID]) async throws -> [CKRecord.ID] {
        do {
            let results = try await fetch(ids, keys: [], timeout: Self.requestTimeout)
            var present: [CKRecord.ID] = []
            for id in ids {
                switch results[id] {
                case .success?: present.append(id)
                case .failure(let error)?: guard CloudRecords.isMissing(error) else { throw error }
                case nil: throw CloudFailure.other("no result for a Photo record")
                }
            }
            return present
        } catch where ids.count > 1 && CloudRecords.codes(error) == [.limitExceeded] {
            let half = ids.count / 2
            return try await presentIDs(Array(ids[..<half])) + presentIDs(Array(ids[half...]))
        }
    }

    /// Whether the server's copy of a photo that came back `serverRecordChanged` has these bytes. Reads the
    /// server's record from the error, or fetches its `sha256` when the error does not carry it.
    private func photoAlreadyThere(_ error: Error, id: CKRecord.ID, sha256: String) async throws -> Bool {
        if let same = CloudRecords.photoAlreadyThere(error, sha256: sha256) { return same }
        let results = try await fetch([id], keys: [CloudRecords.Field.sha256], timeout: Self.requestTimeout)
        guard case .success(let record)? = results[id], let server = record[CloudRecords.Field.sha256] as? String else {
            throw CloudFailure.other("photo exists but its checksum could not be read")
        }
        return server.lowercased() == sha256.lowercased()
    }

    /// Maps the error and writes the call's one log line: the code, never contents.
    private func fail(_ call: String, _ error: Error) -> CloudFailure {
        let failure = CloudRecords.failure(error)
        Self.log.error("\(call, privacy: .public) failed: \(CloudRecords.describe(error), privacy: .public)")
        return failure
    }
}
