import Foundation

// iCloud sync: the types shared by the cloud link (CloudLink, tested against a fake) and the real
// CloudKit store. This file never imports CloudKit. See docs/icloud-plan.md sections 2, 4 and 8.

/// What a head fetch says about the cloud document, without its body.
struct CloudHead: Equatable, Sendable {
    var tag: String        // the record's change tag
    var revision: String   // fingerprint of the body
    var epoch: String      // UUID made when the document was created
    var format: Int
}

/// The whole `Collection` record.
struct CloudDocument: Sendable {
    var head: CloudHead
    var origin: String
    var body: Data         // canonical JSON
    var systemFields: Data // archived CKRecord system fields, for the next save
    var device: String
    var writtenAt: Date
}

/// A device's `Status` record (`status-mac`, `status-iphone`).
struct CloudStatus: Codable, Equatable, Sendable {
    var name: String
    var build: String
    var revision: String
    var at: Date
    var hubAt: Date?
    var hubRevision: String?
    var conflicts: Int
    var note: String
}

enum CloudFailure: Error, Equatable, Sendable {
    case noAccount
    case changed              // serverRecordChanged on the document
    case purged               // userDeletedZone
    case quotaFull
    case retryAfter(TimeInterval)
    case network
    case misconfigured(String) // missing entitlement, bad container, permission failure
    case photoFileMissing      // assetFileNotFound: the local file under a photo upload is gone; drop its mark
    case other(String)
}

protocol CloudStore: Sendable {
    /// The iCloud user record name. Throws `.noAccount` when there is none.
    func account() async throws -> String
    /// The document's head (nil when there is no document) and every device's status.
    func head() async throws -> (document: CloudHead?, statuses: [String: CloudStatus])
    func document() async throws -> CloudDocument?
    /// `over: nil` creates the document (and the zone). Throws `.changed` when the server record moved on.
    func write(body: Data, revision: String, epoch: String, origin: String, device: String, over systemFields: Data?) async throws -> CloudDocument
    func photosPresent(_ names: [String]) async throws -> Set<String>
    /// false = a photo of that name is already there with other bytes.
    func uploadPhoto(_ name: String, file: URL, sha256: String, bytes: Int) async throws -> Bool
    /// false = not in iCloud.
    func downloadPhoto(_ name: String, to file: URL) async throws -> Bool
    func writeStatus(_ key: String, _ status: CloudStatus) async throws
}

/// The photo folder as the cloud link sees it. Names are "dir/file".
protocol PhotoFiles: Sendable {
    func url(_ name: String) -> URL?
    func exists(_ name: String) -> Bool
}
