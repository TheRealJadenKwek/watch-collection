import CloudKit
import XCTest
@testable import WatchCollection

/// The record types and the error table of iCloud sync, offline: real CKRecord and CKAsset, no container.
final class CloudRecordsTests: XCTestCase {
    private let zone = CKRecordZone.ID(zoneName: "Collection", ownerName: CKCurrentUserDefaultName)
    private let writtenAt = Date(timeIntervalSince1970: 1_794_000_123)
    private let checkedAt = Date(timeIntervalSince1970: 1_794_000_456)
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("cloud-records-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func file(_ name: String, _ data: Data) throws -> URL {
        let url = folder.appendingPathComponent(name, isDirectory: false)
        try data.write(to: url)
        return url
    }

    private func collection(revision: String = "rev-1", in zone: CKRecordZone.ID? = nil, over systemFields: Data? = nil) throws -> CKRecord {
        CloudRecords.collectionRecord(
            body: try file("body-\(UUID().uuidString).json", Data(#"{"watches":[],"wishlist":[]}"#.utf8)),
            revision: revision, epoch: "E-1", origin: "hub", device: "Mac", writtenAt: writtenAt,
            in: zone ?? self.zone, over: systemFields
        )
    }

    private var fullStatus: CloudStatus {
        CloudStatus(
            name: "Mac", build: "1.0 (1)", revision: "rev-9", at: checkedAt, hubAt: writtenAt, hubRevision: "hub-rev-9",
            conflicts: 2, note: "photos 3 of 4"
        )
    }

    // MARK: Collection

    func testCollectionRoundTripsEveryField() throws {
        let body = Data(#"{"settings":{"wrist":17},"watches":[{"id":"w1"}],"wishlist":[]}"#.utf8)
        let record = CloudRecords.collectionRecord(
            body: try file("body.json", body), revision: "rev-1", epoch: "E-1", origin: "hub", device: "Mac",
            writtenAt: writtenAt, in: zone, over: nil
        )
        XCTAssertEqual(record.recordType, "Collection")
        XCTAssertEqual(record.recordID.recordName, "collection")
        XCTAssertEqual(record.recordID.zoneID, zone)
        XCTAssertEqual(Set(record.allKeys()), ["format", "epoch", "origin", "revision", "document", "device", "writtenAt"])
        XCTAssertNotNil(record["document"] as? CKAsset)

        let document = try XCTUnwrap(CloudRecords.document(record))
        XCTAssertEqual(document.head, CloudHead(tag: "", revision: "rev-1", epoch: "E-1", format: 1))
        XCTAssertEqual(document.origin, "hub")
        XCTAssertEqual(document.device, "Mac")
        XCTAssertEqual(document.writtenAt, writtenAt)
        XCTAssertEqual(document.body, body)
        let restored = try XCTUnwrap(CloudRecords.record(fromSystemFields: document.systemFields))
        XCTAssertEqual(restored.recordID, record.recordID)
        XCTAssertEqual(restored.recordType, "Collection")
    }

    func testDocumentBodyIsCopiedOutOfTheAsset() throws {
        let record = try collection()
        let document = try XCTUnwrap(CloudRecords.document(record))
        // CloudKit may remove an asset's file once the call returns; the body must not depend on it.
        try FileManager.default.removeItem(at: try XCTUnwrap((record["document"] as? CKAsset)?.fileURL))
        XCTAssertEqual(document.body, Data(#"{"watches":[],"wishlist":[]}"#.utf8))
    }

    func testCollectionBuiltOverItsSystemFieldsKeepsThatRecord() throws {
        let first = try collection()
        let second = try collection(revision: "rev-2", over: CloudRecords.systemFields(first))
        XCTAssertEqual(second.recordID, first.recordID)
        XCTAssertEqual(second.recordType, "Collection")
        XCTAssertEqual(CloudRecords.head(second)?.revision, "rev-2")

        // System fields of another record, another zone, or none readable: a new record of the right id.
        let status = CloudRecords.statusRecord("status-mac", fullStatus, in: zone)
        let otherZone = CKRecordZone.ID(zoneName: "CollectionCheck", ownerName: CKCurrentUserDefaultName)
        for fields in [CloudRecords.systemFields(status), CloudRecords.systemFields(try collection(in: otherZone)), Data("junk".utf8)] {
            let record = try collection(over: fields)
            XCTAssertEqual(record.recordID, CloudRecords.collectionID(in: zone))
            XCTAssertEqual(record.recordType, "Collection")
        }
    }

    func testHeadReadsARecordFetchedWithoutItsDocument() throws {
        let record = CKRecord(recordType: "Collection", recordID: CloudRecords.collectionID(in: zone))
        record["format"] = Int64(2)
        record["epoch"] = "E-2"
        record["revision"] = "rev-3"
        record["origin"] = "hub"
        record["device"] = "iPhone"
        record["writtenAt"] = writtenAt
        // A newer format is read as it is; deciding what to do about it is the link's job.
        XCTAssertEqual(CloudRecords.head(record), CloudHead(tag: "", revision: "rev-3", epoch: "E-2", format: 2))
        XCTAssertNil(CloudRecords.document(record), "no asset, no document")
    }

    func testHeadKeysAreEveryFieldButTheDocument() throws {
        let keys = Set(CloudRecords.headKeys)
        XCTAssertFalse(keys.contains("document"))
        XCTAssertEqual(Set(try collection().allKeys()).subtracting(keys), ["document"])
        XCTAssertTrue(Set(CloudRecords.statusRecord("status-mac", fullStatus, in: zone).allKeys()).isSubset(of: keys))
    }

    // MARK: Photo

    func testBoxTilePhotoRoundTrips() throws {
        try assertPhotoRoundTrips("_box/empty-black-1a2b3c4d.jpg", dir: "_box", file: "empty-black-1a2b3c4d.jpg")
    }

    func testWishlistPhotoRoundTrips() throws {
        try assertPhotoRoundTrips("wl-abc/3f9a1c2e-5b7d-4e1f-9a0b-1c2d3e4f5a6b.jpg", dir: "wl-abc", file: "3f9a1c2e-5b7d-4e1f-9a0b-1c2d3e4f5a6b.jpg")
    }

    func testWatchTilePhotoRoundTrips() throws {
        try assertPhotoRoundTrips("w42/box-walnut-0123abcd.png", dir: "w42", file: "box-walnut-0123abcd.png")
    }

    private func assertPhotoRoundTrips(_ name: String, dir: String, file name2: String) throws {
        let bytes = Data((0..<2048).map { UInt8($0 % 251) })
        let url = try file("photo-\(UUID().uuidString)", bytes)
        let sha = CloudRecords.sha256(bytes)
        let record = try XCTUnwrap(CloudRecords.photoRecord(name, file: url, sha256: sha, bytes: bytes.count, in: zone))
        XCTAssertEqual(record.recordType, "Photo")
        XCTAssertEqual(record.recordID.recordName, "photo/\(dir)/\(name2)")
        XCTAssertEqual(record.recordID, CloudRecords.photoID(name, in: zone))
        XCTAssertFalse(record.recordID.recordName.hasPrefix("_"), "record names may not start with an underscore")
        XCTAssertEqual(Set(record.allKeys()), ["format", "dir", "file", "bytes", "sha256", "data"])

        let photo = try XCTUnwrap(CloudRecords.photo(record))
        XCTAssertEqual(photo.format, 1)
        XCTAssertEqual(photo.dir, dir)
        XCTAssertEqual(photo.file, name2)
        XCTAssertEqual(photo.name, name)
        XCTAssertEqual(photo.bytes, bytes.count)
        XCTAssertEqual(photo.sha256, sha)
        // The asset points at the file in the photo folder as it is: no copy, no recompression.
        XCTAssertEqual(photo.data, url)
        XCTAssertEqual(try Data(contentsOf: try XCTUnwrap(photo.data)), bytes)
    }

    func testHostilePhotoNamesAreRefused() throws {
        let url = try file("x.jpg", Data([1, 2, 3]))
        let hostile = ["../x", "a/b/c", "", "/", "//", "/x", "x/", "x", "./x", "a/.", "a/..", "../..", #"a\b/c"#, "a/b\u{0}"]
        for name in hostile {
            XCTAssertNil(CloudRecords.photoParts(name), name)
            XCTAssertNil(CloudRecords.photoID(name, in: zone), name)
            XCTAssertNil(CloudRecords.photoRecord(name, file: url, sha256: "00", bytes: 3, in: zone), name)
        }
        // The same check as PhotoStore's: a part PhotoStore refuses is refused here on either side of the slash.
        for part in ["", ".", "..", "a/b", #"a\b"#, "a\u{0}b"] {
            XCTAssertNil(PhotoStore.asset(itemID: part, filename: "f.jpg", wishlist: false, baseURL: nil), part)
            XCTAssertNil(CloudRecords.photoID("\(part)/f.jpg", in: zone), part)
            XCTAssertNil(CloudRecords.photoID("d/\(part)", in: zone), part)
        }
    }

    func testPhotoAlreadyThereComparesTheServersBytes() throws {
        let sha = CloudRecords.sha256(Data("tile".utf8))
        let server = try XCTUnwrap(CloudRecords.photoRecord(
            "_box/empty-black-1a2b3c4d.jpg", file: try file("server.jpg", Data("tile".utf8)), sha256: sha, bytes: 4, in: zone
        ))
        let changed = CKError(.serverRecordChanged, userInfo: [CKRecordChangedErrorServerRecordKey: server])
        XCTAssertEqual(CloudRecords.photoAlreadyThere(changed, sha256: sha), true)
        XCTAssertEqual(CloudRecords.photoAlreadyThere(changed, sha256: sha.uppercased()), true)
        XCTAssertEqual(CloudRecords.photoAlreadyThere(changed, sha256: CloudRecords.sha256(Data("other".utf8))), false)
        XCTAssertNil(CloudRecords.photoAlreadyThere(CKError(.serverRecordChanged), sha256: sha), "no server record to compare")
        XCTAssertNil(CloudRecords.photoAlreadyThere(CKError(.networkFailure), sha256: sha))
    }

    func testSHA256IsLowercaseHex() {
        XCTAssertEqual(CloudRecords.sha256(Data("abc".utf8)), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    // MARK: Status

    func testStatusRoundTripsEveryField() {
        let record = CloudRecords.statusRecord("status-mac", fullStatus, in: zone)
        XCTAssertEqual(record.recordType, "Status")
        XCTAssertEqual(record.recordID, CloudRecords.statusID("status-mac", in: zone))
        XCTAssertEqual(record.recordID.recordName, "status-mac")
        XCTAssertEqual(Set(record.allKeys()), ["format", "name", "build", "at", "revision", "hubAt", "hubRevision", "conflicts", "note"])
        XCTAssertEqual(CloudRecords.status(record), fullStatus)
    }

    func testStatusWithoutAHubReadsBackWithoutOne() {
        var status = fullStatus
        status.hubAt = nil
        status.hubRevision = nil
        status.conflicts = 0
        status.note = ""
        let record = CloudRecords.statusRecord("status-iphone", status, in: zone)
        XCTAssertEqual(record.recordID.recordName, "status-iphone")
        XCTAssertNil(record["hubAt"])
        XCTAssertNil(record["hubRevision"])
        XCTAssertEqual(CloudRecords.status(record), status)
    }

    // MARK: Readers refuse what they cannot use

    func testReadersRefuseOtherTypesAndMissingFields() throws {
        let photo = try XCTUnwrap(CloudRecords.photoRecord("_box/a.jpg", file: try file("a.jpg", Data([1])), sha256: "00", bytes: 1, in: zone))
        let status = CloudRecords.statusRecord("status-mac", fullStatus, in: zone)
        XCTAssertNil(CloudRecords.head(photo))
        XCTAssertNil(CloudRecords.head(status))
        XCTAssertNil(CloudRecords.photo(status))
        XCTAssertNil(CloudRecords.status(photo))

        for key in ["format", "epoch", "revision"] {
            let record = try collection()
            record[key] = nil
            XCTAssertNil(CloudRecords.head(record), key)
        }
        for key in ["origin", "device", "writtenAt", "document"] {
            let record = try collection()
            record[key] = nil
            XCTAssertNotNil(CloudRecords.head(record), key)
            XCTAssertNil(CloudRecords.document(record), key)
        }
        for key in ["format", "dir", "file", "bytes", "sha256"] {
            let record = try XCTUnwrap(CloudRecords.photoRecord("_box/a.jpg", file: try file("b.jpg", Data([1])), sha256: "00", bytes: 1, in: zone))
            record[key] = nil
            XCTAssertNil(CloudRecords.photo(record), key)
        }
        for key in ["name", "build", "revision", "at"] {
            let record = CloudRecords.statusRecord("status-mac", fullStatus, in: zone)
            record[key] = nil
            XCTAssertNil(CloudRecords.status(record), key)
        }
    }

    // MARK: System fields

    func testSystemFieldsArchiveAndRestore() throws {
        let records = [
            try collection(),
            try XCTUnwrap(CloudRecords.photoRecord("_box/a.jpg", file: try file("c.jpg", Data([1])), sha256: "00", bytes: 1, in: zone)),
            CloudRecords.statusRecord("status-iphone", fullStatus, in: zone),
        ]
        for record in records {
            let restored = try XCTUnwrap(CloudRecords.record(fromSystemFields: CloudRecords.systemFields(record)))
            XCTAssertEqual(restored.recordID, record.recordID)
            XCTAssertEqual(restored.recordType, record.recordType)
            XCTAssertEqual(restored.recordChangeTag, record.recordChangeTag)
            XCTAssertTrue(restored.allKeys().isEmpty, "system fields carry no values")
            // And again: what was restored archives to the same thing.
            XCTAssertEqual(CloudRecords.record(fromSystemFields: CloudRecords.systemFields(restored))?.recordID, record.recordID)
        }
        XCTAssertNil(CloudRecords.record(fromSystemFields: Data()))
        XCTAssertNil(CloudRecords.record(fromSystemFields: Data("not an archive".utf8)))
    }

    // MARK: The error table (section 8)

    func testEveryCodeInTheTableMapsAsItSays() {
        let table: [(CKError.Code, CloudFailure)] = [
            // No account, restricted: the link sleeps.
            (.notAuthenticated, .noAccount),
            (.accountTemporarilyUnavailable, .noAccount),
            (.managedAccountRestricted, .noAccount),
            (.quotaExceeded, .quotaFull),
            (.userDeletedZone, .purged),
            (.serverRecordChanged, .changed),
            (.requestRateLimited, .retryAfter(CloudRecords.defaultRetryAfter)),
            (.zoneBusy, .retryAfter(CloudRecords.defaultRetryAfter)),
            (.serviceUnavailable, .retryAfter(CloudRecords.defaultRetryAfter)),
            (.networkUnavailable, .network),
            (.networkFailure, .network),
            (.serverResponseLost, .network),
            (.missingEntitlement, .misconfigured("missingEntitlement")),
            (.badContainer, .misconfigured("badContainer")),
            (.permissionFailure, .misconfigured("permissionFailure")),
            (.badDatabase, .misconfigured("badDatabase")),
            // Turned into results by the store (no document, not in iCloud, a smaller batch) or retried next pass.
            (.zoneNotFound, .other("zoneNotFound")),
            (.unknownItem, .other("unknownItem")),
            (.assetFileNotFound, .photoFileMissing),
            (.limitExceeded, .other("limitExceeded")),
            (.internalError, .other("internalError")),
        ]
        for (code, expected) in table {
            XCTAssertEqual(CloudRecords.failure(CKError(code)), expected, CloudRecords.name(code))
        }
    }

    /// C1 7: a cancelled call (the app left the screen, a background task ran out) is `.cancelled`, which the link
    /// reads as a quiet `.busy`, never a failure; in a partial failure it says the least.
    func testACancelledCallIsCancelledNotAFailure() {
        XCTAssertEqual(CloudRecords.failure(CKError(.operationCancelled)), .cancelled)
        XCTAssertEqual(CloudRecords.failure(CancellationError()), .cancelled)
        XCTAssertEqual(CloudRecords.failure(URLError(.cancelled)), .cancelled)
        XCTAssertEqual(CloudRecords.failure(URLError(.timedOut)), .network)
        XCTAssertEqual(CloudLink.failure(CancellationError()), .cancelled)
        XCTAssertEqual(CloudRecords.failure(partial([.operationCancelled, .networkFailure])), .network)
    }

    /// D12: "could not determine" is a passing failure to ask, like the network (quiet until it lasts); the states
    /// that need him read as no account.
    func testAccountStatesMapAsD12Says() {
        XCTAssertNil(CloudRecords.accountFailure(.available))
        XCTAssertEqual(CloudRecords.accountFailure(.couldNotDetermine), .network)
        XCTAssertEqual(CloudRecords.accountFailure(.noAccount), .noAccount)
        XCTAssertEqual(CloudRecords.accountFailure(.restricted), .noAccount)
        XCTAssertEqual(CloudRecords.accountFailure(.temporarilyUnavailable), .noAccount)
    }

    func testThrottlesWaitAsLongAsCloudKitSays() {
        for code in [CKError.Code.requestRateLimited, .zoneBusy, .serviceUnavailable] {
            let error = CKError(code, userInfo: [CKErrorRetryAfterKey: 7.5])
            XCTAssertEqual(CloudRecords.failure(error), .retryAfter(7.5), CloudRecords.name(code))
        }
    }

    func testMissingRecordOrZoneIsNoDocumentNeverErased() {
        XCTAssertTrue(CloudRecords.isMissing(CKError(.zoneNotFound)))
        XCTAssertTrue(CloudRecords.isMissing(CKError(.unknownItem)))
        // He erased it: paused, never read as "no document", so nothing is uploaded again on our own.
        XCTAssertFalse(CloudRecords.isMissing(CKError(.userDeletedZone)))
        XCTAssertFalse(CloudRecords.isMissing(CKError(.networkFailure)))
        XCTAssertFalse(CloudRecords.isMissing(URLError(.notConnectedToInternet)))

        XCTAssertTrue(CloudRecords.isZoneMissing(CKError(.zoneNotFound)))
        XCTAssertFalse(CloudRecords.isZoneMissing(CKError(.userDeletedZone)))
        XCTAssertFalse(CloudRecords.isZoneMissing(CKError(.unknownItem)))

        XCTAssertTrue(CloudRecords.isMissing(partial([.unknownItem, .batchRequestFailed])))
        XCTAssertTrue(CloudRecords.isMissing(partial([.unknownItem, .zoneNotFound])))
        XCTAssertFalse(CloudRecords.isMissing(partial([.unknownItem, .networkFailure])))
        XCTAssertFalse(CloudRecords.isMissing(partial([.batchRequestFailed])))
        XCTAssertTrue(CloudRecords.isZoneMissing(partial([.zoneNotFound, .batchRequestFailed])))
    }

    func testPartialFailureGivesItsMostTellingItem() {
        XCTAssertEqual(CloudRecords.failure(partial([.networkFailure, .quotaExceeded, .batchRequestFailed])), .quotaFull)
        XCTAssertEqual(CloudRecords.failure(partial([.serverRecordChanged, .batchRequestFailed])), .changed)
        XCTAssertEqual(CloudRecords.failure(partial([.userDeletedZone, .networkFailure])), .purged)
        XCTAssertEqual(CloudRecords.failure(partial([.missingEntitlement, .notAuthenticated])), .misconfigured("missingEntitlement"))
        XCTAssertEqual(CloudRecords.failure(partial([.batchRequestFailed])), .other("partialFailure"))

        let a = CKRecord.ID(recordName: "photo/_box/a.jpg", zoneID: zone)
        let b = CKRecord.ID(recordName: "photo/_box/b.jpg", zoneID: zone)
        let throttled = CKError(.partialFailure, userInfo: [CKPartialErrorsByItemIDKey: [
            a: CKError(.requestRateLimited, userInfo: [CKErrorRetryAfterKey: 5.0]),
            b: CKError(.zoneBusy, userInfo: [CKErrorRetryAfterKey: 20.0]),
        ]])
        XCTAssertEqual(CloudRecords.failure(throttled), .retryAfter(20), "the longest wait")

        let mixed = CKError(.partialFailure, userInfo: [CKPartialErrorsByItemIDKey: [
            a: CKError(.serverRecordChanged), b: CKError(.batchRequestFailed),
        ]])
        XCTAssertEqual((CloudRecords.itemError(mixed, for: a) as? CKError)?.code, .serverRecordChanged)
        XCTAssertEqual((CloudRecords.itemError(mixed, for: b) as? CKError)?.code, .batchRequestFailed)
        let unnamed = CKRecord.ID(recordName: "collection", zoneID: zone)
        XCTAssertEqual((CloudRecords.itemError(mixed, for: unnamed) as? CKError)?.code, .partialFailure)
        XCTAssertEqual((CloudRecords.itemError(CKError(.networkFailure), for: a) as? CKError)?.code, .networkFailure)
    }

    func testErrorsFromOutsideCloudKit() {
        XCTAssertEqual(CloudRecords.failure(URLError(.timedOut)), .network)
        XCTAssertEqual(CloudRecords.failure(URLError(.notConnectedToInternet)), .network)
        XCTAssertEqual(CloudRecords.failure(CloudFailure.quotaFull), .quotaFull, "already mapped: passes through")
        XCTAssertEqual(CloudRecords.failure(CocoaError(.fileReadNoSuchFile)), .other("NSCocoaErrorDomain 260"))
    }

    func testLogDescriptionsCarryCodesNotMessages() {
        let error = CKError(.quotaExceeded, userInfo: [NSLocalizedDescriptionKey: "secret body text"])
        XCTAssertEqual(CloudRecords.describe(error), "CKError 25 quotaExceeded")
        XCTAssertEqual(CloudRecords.describe(partial([.unknownItem, .batchRequestFailed])), "CKError 2 partialFailure [11 unknownItem]")
    }

    /// A partial failure with one item per code.
    private func partial(_ codes: [CKError.Code]) -> CKError {
        var items: [CKRecord.ID: Error] = [:]
        for (index, code) in codes.enumerated() {
            items[CKRecord.ID(recordName: "photo/_box/\(index).jpg", zoneID: zone)] = CKError(code)
        }
        return CKError(.partialFailure, userInfo: [CKPartialErrorsByItemIDKey: items])
    }
}
