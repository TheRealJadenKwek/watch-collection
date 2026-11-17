#if DEBUG
import CloudKit
import CoreGraphics
import Foundation
import ImageIO
import Security
import UniformTypeIdentifiers

/// Debug builds only: `-WCCloudKitCheck <folder>` proves the Mac app reaches `iCloud.com.jadenkwek.watchcollection`
/// before anything syncs. It opens no window and no collection and never touches the `Collection` zone: it saves a
/// zone of its own (`CollectionCheck`), writes a `Collection` (every field, a 1 KB body), a `Photo` named
/// `photo/_box/empty-black-0123abcd.jpg` (a 16 px JPEG) and `status-mac` and `status-iphone` (every field set)
/// through `CloudKitStore`, which builds them with `CloudRecords`; reads each back by id and compares fields and
/// asset bytes; checks that a head fetch brings no asset, that `photosPresent` finds exactly the photo that exists,
/// and that a save from stale system fields comes back `.changed`. Then it deletes the zone, writes
/// `<folder>/cloudkit-check.json` and exits, 0 when all of it held and 1 otherwise, within 60 seconds. The app is
/// sandboxed, so the folder sits in its own container. In Development the run also creates the schema: every field
/// of all three types is saved at least once.
enum CloudKitCheck {
    static var folder: URL? {
        UserDefaults.standard.string(forKey: "WCCloudKitCheck").map { URL(filePath: $0, directoryHint: .isDirectory) }
    }

    static let zoneID = CKRecordZone.ID(zoneName: "CollectionCheck", ownerName: CKCurrentUserDefaultName)
    static let timeout: TimeInterval = 60
    /// Its record name, `photo/_box/empty-black-0123abcd.jpg`, proves `/` in a name and a part starting with `_`.
    static let photoName = "_box/empty-black-0123abcd.jpg"
    static let madeUpPhotoName = "_box/empty-black-ffffffff.jpg"

    struct Report: Encodable {
        /// The signed app's `com.apple.developer.icloud-container-environment`, or nil when it has none.
        var environment: String?
        var account: String?
        var saved = false
        var roundTrip = false
        var conflictSeen = false
        var error: String?

        /// Every key always, null when unknown.
        private enum Keys: String, CodingKey { case environment, account, saved, roundTrip, conflictSeen, error }
        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: Keys.self)
            try container.encode(environment, forKey: .environment)
            try container.encode(account, forKey: .account)
            try container.encode(saved, forKey: .saved)
            try container.encode(roundTrip, forKey: .roundTrip)
            try container.encode(conflictSeen, forKey: .conflictSeen)
            try container.encode(error, forKey: .error)
        }

        mutating func add(_ problem: String) {
            error = [error, problem].compactMap { $0 }.joined(separator: "; ")
        }
    }

    /// The report so far, shared with the watchdog so a run that times out still says how far it got.
    private final class Run: @unchecked Sendable {
        private let lock = NSLock()
        private let exitLock = NSLock()
        private var report: Report

        init(_ report: Report) { self.report = report }

        func update(_ change: (inout Report) -> Void) {
            lock.lock()
            change(&report)
            lock.unlock()
        }

        /// Writes the report once and exits; a second caller waits on the exit lock until the process ends.
        func finish(in folder: URL, timedOut: Bool) -> Never {
            exitLock.lock()
            lock.lock()
            if timedOut { report.add("timed out after \(Int(CloudKitCheck.timeout)) s") }
            let passed = !timedOut && report.saved && report.roundTrip && report.conflictSeen
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try? encoder.encode(report).write(to: folder.appending(path: "cloudkit-check.json"), options: .atomic)
            exit(passed ? 0 : 1)
        }
    }

    /// Runs the check on the main queue and ends the process; the app itself never starts.
    static func runAndExit(_ folder: URL) -> Never {
        let run = Run(Report(environment: entitlement("com.apple.developer.icloud-container-environment") as? String))
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { run.finish(in: folder, timedOut: true) }
        Task { @MainActor in
            await check(run)
            run.finish(in: folder, timedOut: false)
        }
        dispatchMain()
    }

    private struct Problem: Error { let text: String }

    @MainActor private static func check(_ run: Run) async {
        // CKContainer ends the process when the app is not signed with the container, so this comes first.
        guard CloudKitStore.hasContainerEntitlement() else {
            run.update { $0.add("this build is not signed with \(CloudKitStore.containerID)") }
            return
        }
        guard zoneID != CloudKitStore.zoneID else {
            run.update { $0.add("refusing to run in the Collection zone") }
            return
        }
        let container = CKContainer(identifier: CloudKitStore.containerID)
        let database = container.privateCloudDatabase
        let store = CloudKitStore(container: container, zone: zoneID)
        let files = FileManager.default.temporaryDirectory
            .appending(path: "watchcollection-cloudkit-check-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: files) }
        var zoneSaved = false
        do {
            let account = name(try await container.accountStatus())
            run.update { $0.account = account }
            guard account == "available" else {
                run.update { $0.add("no iCloud account to check with") }
                return
            }
            // A run cut off by its watchdog leaves the zone and its `Collection` behind, and saving the zone again
            // keeps them, so this run's first save would come back `.changed`. Start from no zone at all.
            try await deleteZone(in: database, missingIsFine: true)
            let zones = try await database.modifyRecordZones(saving: [CKRecordZone(zoneID: zoneID)], deleting: []).saveResults
            if case .failure(let error)? = zones[zoneID] { throw error }
            zoneSaved = true

            // What goes up. CloudKit keeps dates to the millisecond; whole seconds compare exactly.
            try FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)
            let now = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
            let body = Self.body(1024)
            let revision = CloudRecords.sha256(body)
            let epoch = UUID().uuidString
            let device = "CloudKit check"
            let tile = try jpeg(red: 0.08, green: 0.08, blue: 0.09)
            let tileURL = files.appending(path: "tile.jpg")
            try tile.write(to: tileURL)
            let build = [Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString"), Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion")]
                .compactMap { $0 as? String }.joined(separator: " ")
            let mac = CloudStatus(
                name: "CloudKit check Mac", build: build, revision: revision, at: now, hubAt: now.addingTimeInterval(-60),
                hubRevision: "hub-\(revision)", conflicts: 1, note: "CloudKit check"
            )
            let iphone = CloudStatus(
                name: "CloudKit check iPhone", build: build, revision: revision, at: now.addingTimeInterval(-5),
                hubAt: now.addingTimeInterval(-120), hubRevision: "hub-old", conflicts: 2, note: "CloudKit check, other device"
            )

            // Saves, each built by CloudRecords inside the store, each with every field of its type.
            let written = try await store.write(body: body, revision: revision, epoch: epoch, origin: "hub", device: device, over: nil)
            guard try await store.uploadPhoto(photoName, file: tileURL, sha256: CloudRecords.sha256(tile), bytes: tile.count) else {
                throw Problem(text: "the photo name already held other bytes")
            }
            try await store.writeStatus("status-mac", mac)
            try await store.writeStatus("status-iphone", iphone)
            run.update { $0.saved = true }

            var problems: [String] = []

            // Back by id, whole, read by CloudRecords: fields and asset bytes.
            guard let photoID = CloudRecords.photoID(photoName, in: zoneID) else { throw Problem(text: "photo name refused") }
            let collectionID = CloudRecords.collectionID(in: zoneID)
            let macID = CloudRecords.statusID("status-mac", in: zoneID)
            let iphoneID = CloudRecords.statusID("status-iphone", in: zoneID)
            let whole = try await database.records(for: [collectionID, photoID, macID, iphoneID])
            func fetched(_ id: CKRecord.ID) throws -> CKRecord {
                switch whole[id] {
                case .success(let record)?: return record
                case .failure(let error)?: throw error
                case nil: throw Problem(text: "no result for \(id.recordName)")
                }
            }
            if let back = CloudRecords.document(try fetched(collectionID)) {
                if back.head != written.head { problems.append("collection head") }
                if back.origin != "hub" || back.device != device { problems.append("collection fields") }
                if abs(back.writtenAt.timeIntervalSince(written.writtenAt)) > 0.001 { problems.append("collection writtenAt") }
                if back.body != body { problems.append("document bytes") }
            } else {
                problems.append("collection unreadable")
            }
            if let back = CloudRecords.photo(try fetched(photoID)) {
                if back.name != photoName || back.bytes != tile.count || back.sha256 != CloudRecords.sha256(tile)
                    || back.format != CloudRecords.format { problems.append("photo fields") }
                if back.data.flatMap({ try? Data(contentsOf: $0) }) != tile { problems.append("photo bytes") }
            } else {
                problems.append("photo unreadable")
            }
            if CloudRecords.status(try fetched(macID)) != mac { problems.append("status-mac") }
            if CloudRecords.status(try fetched(iphoneID)) != iphone { problems.append("status-iphone") }

            // A head fetch with the desired keys brings no asset.
            let heads = try await database.records(for: [collectionID], desiredKeys: CloudRecords.headKeys)
            if case .success(let record)? = heads[collectionID] {
                if record["document"] != nil { problems.append("head fetch brought the document") }
                if CloudRecords.head(record) != written.head { problems.append("head fetch fields") }
            } else {
                problems.append("head fetch failed")
            }

            // The same through the store, as the link will call it.
            let head = try await store.head()
            if head.document != written.head { problems.append("store head") }
            if head.statuses != ["status-mac": mac, "status-iphone": iphone] { problems.append("store statuses") }
            let document = try await store.document()
            if document?.body != body || document?.head != written.head { problems.append("store document") }
            let downloaded = files.appending(path: "downloaded.jpg")
            let found = try await store.downloadPhoto(photoName, to: downloaded)
            if !found || (try? Data(contentsOf: downloaded)) != tile { problems.append("photo download") }
            let present = try await store.photosPresent([photoName, madeUpPhotoName])
            if present != [photoName] { problems.append("photosPresent gave \(present.sorted())") }

            run.update {
                $0.roundTrip = problems.isEmpty
                if !problems.isEmpty { $0.add("came back different: " + problems.joined(separator: ", ")) }
            }

            // One update over the first save's system fields, then another over the same, now stale, fields.
            let second = Self.body(1100)
            let updated = try await store.write(
                body: second, revision: CloudRecords.sha256(second), epoch: epoch, origin: "hub", device: device, over: written.systemFields
            )
            if updated.head.tag == written.head.tag { run.update { $0.add("the update kept the change tag") } }
            do {
                let third = Self.body(1200)
                _ = try await store.write(
                    body: third, revision: CloudRecords.sha256(third), epoch: epoch, origin: "hub", device: device, over: written.systemFields
                )
                run.update { $0.add("a save from stale system fields was accepted") }
            } catch CloudFailure.changed {
                run.update { $0.conflictSeen = true }
            }
        } catch {
            run.update { $0.add(describe(error)) }
        }
        if zoneSaved {
            do {
                try await deleteZone(in: database, missingIsFine: false)
            } catch {
                run.update { $0.add("zone not deleted: \(describe(error))") }
            }
        }
    }

    /// Deletes `CollectionCheck`, never any other zone. At the start a zone that is not there is fine.
    private static func deleteZone(in database: CKDatabase, missingIsFine: Bool) async throws {
        do {
            let deleted = try await database.modifyRecordZones(saving: [], deleting: [zoneID]).deleteResults
            if case .failure(let error)? = deleted[zoneID] { throw error }
        } catch let error as CKError where missingIsFine && error.code == .zoneNotFound {
            return
        }
    }

    /// A JSON body of `size` bytes.
    private static func body(_ size: Int) -> Data {
        let head = #"{"check":""#, tail = #""}"#
        return Data((head + String(repeating: "x", count: max(0, size - head.count - tail.count)) + tail).utf8)
    }

    /// A 16 px square of one colour as a JPEG.
    private static func jpeg(red: CGFloat, green: CGFloat, blue: CGFloat) throws -> Data {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: 16, height: 16, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { throw Problem(text: "no JPEG context") }
        context.setFillColor(CGColor(srgbRed: red, green: green, blue: blue, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
        let data = NSMutableData()
        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw Problem(text: "no JPEG destination")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw Problem(text: "JPEG not written") }
        return data as Data
    }

    private static func entitlement(_ key: String) -> Any? {
        guard let task = SecTaskCreateFromSelf(nil) else { return nil }
        return SecTaskCopyValueForEntitlement(task, key as CFString, nil)
    }

    private static func name(_ status: CKAccountStatus) -> String {
        switch status {
        case .available: "available"
        case .noAccount: "noAccount"
        case .restricted: "restricted"
        case .couldNotDetermine: "couldNotDetermine"
        case .temporarilyUnavailable: "temporarilyUnavailable"
        @unknown default: "unknown \(status.rawValue)"
        }
    }

    /// The check's own report may carry the message too: it is debug output read by the lead, not a log line.
    private static func describe(_ error: Error) -> String {
        if let problem = error as? Problem { return problem.text }
        if let error = error as? CKError { return "\(CloudRecords.describe(error)): \(error.localizedDescription)" }
        return CloudRecords.describe(error)
    }
}
#endif
