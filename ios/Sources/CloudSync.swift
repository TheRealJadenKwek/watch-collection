import CryptoKit
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
    case photoFileMissing      // assetFileNotFound: the local file under a photo upload could not be read
    /// The bytes iCloud handed over for a photo do not match its record (size or sha256), or the record could not be
    /// read: the Mac retries it, and gives up on it only after `CloudLink.damagedStrikes` over `damagedSpan`.
    case damagedPhoto(String)
    /// The call was cancelled (the app left the screen, a background task ran out): quiet, never a failure.
    case cancelled
    case other(String)
}

protocol CloudStore: Sendable {
    /// The iCloud user record name. Throws `.noAccount` when there is none.
    func account() async throws -> String
    /// The document's head (nil when there is no document) and every device's status.
    func head() async throws -> (document: CloudHead?, statuses: [String: CloudStatus])
    func document() async throws -> CloudDocument?
    /// `over: nil` creates the document: the record is saved first, and the zone only when it is missing (never one
    /// he erased: that throws `.purged`). Throws `.changed` when the server record moved on.
    func write(body: Data, revision: String, epoch: String, origin: String, device: String, over systemFields: Data?) async throws -> CloudDocument
    func photosPresent(_ names: [String]) async throws -> Set<String>
    /// false = a photo of that name is already there with other bytes.
    func uploadPhoto(_ name: String, file: URL, sha256: String, bytes: Int) async throws -> Bool
    /// false = not in iCloud. Throws `.damagedPhoto` when the bytes do not match the record. `bulk` is the phone's
    /// background fill, which never uses a cellular connection.
    func downloadPhoto(_ name: String, to file: URL, bulk: Bool) async throws -> Bool
    func writeStatus(_ key: String, _ status: CloudStatus) async throws
    /// Saves the `Collection` zone, which brings back a zone he erased. Only `CloudLink.restartAfterErase` (the
    /// Mac's "Sync through iCloud again") calls it: an erased zone is never made again on the app's own say.
    func prepareZone() async throws
}

extension CloudStore {
    /// A fetch a screen or a sync step needs now, over any connection.
    func downloadPhoto(_ name: String, to file: URL) async throws -> Bool {
        try await downloadPhoto(name, to: file, bulk: false)
    }
}

/// The photo folder as the cloud link sees it. Names are "dir/file".
protocol PhotoFiles: Sendable {
    func url(_ name: String) -> URL?
    func exists(_ name: String) -> Bool
}

// MARK: - The cloud link (docs/icloud-plan.md sections 4, 5, 6 and 8)

enum CloudRole: Sendable {
    case phone, mac

    /// The `Status` record this device writes.
    var statusKey: String { self == .mac ? "status-mac" : "status-iphone" }
}

/// Why a pass stopped short of a settled document. Nothing local is ever removed for any of these.
enum CloudWait: Equatable, Sendable {
    /// Signed out, restricted, or the account could not be read: the link sleeps.
    case noAccount
    /// Phone: there is no cloud document yet, so it keeps its hub link.
    case noDocument
    /// Mac: no document, and no clean hub pass this tick to make it from.
    case needsHubFirst
    /// He erased the app's iCloud data: paused until a document with a new epoch appears (or the Mac's button).
    case erased
    /// iCloud storage is full: the link tries again no sooner than 10 minutes later.
    case full
    /// The document was written by a newer build: this device stops syncing through iCloud.
    case newerFormat
    /// A network failure: quiet, the next tick tries again.
    case offline
    /// Throttled (`notBefore`), or the document kept moving under three saves in a row: the next tick tries again.
    case busy
    /// A document that fails its checksum or does not decode, a build problem (the link then stays off for this
    /// launch), or any other error. Nothing was installed or written.
    case failed(String)
    /// The document waits on photos still going up. The next pass carries on from the marks.
    case sendingPhotos(done: Int, of: Int)
}

enum CloudOutcome: Sendable {
    /// Nothing to install. The returned book may still be newer (a new tag for the same content): save it.
    case upToDate
    /// The merged collection, before `BoxModel.installing` and this device's own settings are laid on by the caller.
    case installed(CollectionData, wroteCloud: Bool)
    /// Nothing was written; answer them by id in `CloudInput.resolutions`.
    case conflicts([CollectionMerge.Conflict])
    case waiting(CloudWait)
}

/// Why a device has stopped writing to iCloud on its own.
enum CloudPause: String, Codable, Sendable {
    /// He erased the app's iCloud data (`userDeletedZone`). Nothing goes up again on the app's own say; only the
    /// head is read, and a document with a new epoch resumes the device (section 8).
    case erased
    /// The Mac's "Sync through iCloud again" saved the zone again: its next pass after a clean hub pass sends the
    /// photos and makes a new document, new epoch. Erased again before that, the device goes back to `erased`.
    case restarting
}

/// `cloud.json`: what this device knows about the cloud document. Kept apart from `sync.json` on purpose, so an
/// older build ignores it and a rollback and re-upgrade finds a base that is still a true ancestor.
struct CloudBook: Codable, Sendable {
    static let currentFormat = 1

    var format = CloudBook.currentFormat
    /// The iCloud user record name the rest of the book belongs to.
    var account: String?
    var epoch: String?
    /// The collection both this device and iCloud last agreed on, for this `epoch`: the next merge's base.
    var base: CollectionData?
    var systemFields: Data?
    var tag: String?
    var revision: String?
    var lastSuccess: Date?
    var paused: CloudPause?
    var quotaFullAt: Date?
    var notBefore: Date?
    /// A document this device is making (docs/icloud-fixes.md D1): its epoch, and exactly the collection it writes.
    /// Kept on disk before the save, so a save whose answer is lost, or a process that dies after it, still finds
    /// its base: the next pass that sees this epoch takes `pendingBase` as its base; any other answer drops both.
    var pendingEpoch: String?
    var pendingBase: CollectionData?

    /// The book's side of the Mac's "Sync through iCloud again", once the zone is saved again: the Mac never
    /// borrows a base, so everything about the old document goes. Only `CloudLink.restartAfterErase` calls it.
    fileprivate mutating func restartAfterErase() {
        paused = .restarting
        epoch = nil
        base = nil
        systemFields = nil
        tag = nil
        revision = nil
        pendingEpoch = nil
        pendingBase = nil
    }

    /// When a pass's result is dropped (an edit overtook it), what it learned about waiting still holds: a throttle,
    /// a full iCloud, an erase. Everything else stays as this book has it.
    mutating func takeBackOff(from next: CloudBook) {
        notBefore = next.notBefore
        quotaFullAt = next.quotaFullAt
        paused = next.paused
    }
}

/// Steps the caller runs in the middle of a pass, before the link writes anything (`CloudSyncSession`).
struct CloudHooks: Sendable {
    /// Right before this device's first cloud write of the pass (a photo or the document): the one-time copy of
    /// `sync.json` (section 9 step 2). false: it could not be made, and nothing is written.
    var beforeWrite: @Sendable () async -> Bool = { true }
    /// D1: saves this book (with `pendingEpoch` and `pendingBase`) before the document is created. false: it could
    /// not be saved, and the document is not created.
    var persist: @Sendable (CloudBook) async -> Bool = { _ in true }
}

struct CloudInput: Sendable {
    /// This device's collection; nil when it has none (it then installs iCloud's as it is).
    var local: CollectionData?
    var book: CloudBook
    /// The phone's hub checkpoint base for its current address (section 6). The Mac's is never used.
    var hubBase: CollectionData?
    /// Mac: this tick's hub pass finished clean, with no conflicts and no edit since.
    var hubSettledNow: Bool
    /// Phone: it has installed from iCloud before (`cloudJoinedOnce`).
    var joinedBefore: Bool
    var resolutions: [String: String]
    /// The synced projection of the data changed since this link last settled.
    var changedSinceLastPass: Bool
    /// For `status-mac`: when this Mac last finished a hub pass, and the revision it took from it.
    var hubAt: Date? = nil
    var hubRevision: String? = nil
    /// D5: the phone's switch just made iCloud its link again: this pass merges with no base (union, nothing
    /// deleted, differing fields ask).
    var noBase = false
    /// The hub link's changes still waiting for a choice on this device, counted into its `Status` (C2 7).
    var hubConflicts = 0
    var hooks = CloudHooks()
}

/// One device's link to the cloud document. It knows nothing about `AppStore` or the disk: it is handed the
/// collection, the book and the photo folder (`PhotoFiles`), and hands back an outcome, a book and `marks`.
///
/// The caller's side of a pass (P4):
/// - Save the returned book after every pass. On `.installed`, save the data first and the book second (section 4
///   step 9): a crash between them leaves an older base, which still merges cleanly.
/// - If edits landed while the pass ran, drop the result and the book together and run again (step 8). iCloud may
///   already hold the dropped result; the old book's base is still an ancestor of it.
/// - Save `marks` after each pass and each fill. One pass at a time; a second call while one runs returns `.busy`.
actor CloudLink {
    /// After `quotaExceeded`, no retry for this long.
    static let quotaRetry: TimeInterval = 10 * 60
    /// A device's `Status` is rewritten at most this often unless its revision or conflict count changed.
    static let statusInterval: TimeInterval = 5 * 60
    /// A photo iCloud said it does not have (or could not hand over whole) is asked about again after this long.
    static let missingRecheck: TimeInterval = 10 * 60
    /// Saves of the document per pass when someone else keeps writing in between.
    static let maxRounds = 3
    /// The document's `origin` when the Mac makes it from its hub-synced collection.
    static let hubOrigin = "hub"

    let store: CloudStore
    let files: PhotoFiles
    let role: CloudRole
    let device: String
    let build: String
    /// How long a pass spends sending photos before it returns `.sendingPhotos` and leaves the rest to the next.
    let photoBudget: TimeInterval
    let now: @Sendable () -> Date

    /// `cloud-photos.json`. Read it back and save it after each pass and fill.
    var marks: CloudPhotoMarks
    /// The phone's fetches that failed lately other than for want of a network (bytes that do not match their
    /// record, a server error), and when: not asked again at once. For this launch only; the Mac never uses it.
    var failedLately: [String: Date] = [:]
    /// Every device's `Status` as the last head fetch returned it (and this device's own, once written).
    private(set) var statuses: [String: CloudStatus] = [:]
    /// The last failure, for `cloud-status.json`; nil once a pass settles.
    private(set) var lastFailure: CloudFailure?
    /// Set by a build problem (missing entitlement, bad container): the link stays off for this launch.
    private(set) var disabled: String?
    /// The last pass saved the document, or tried to and cannot know whether it landed (C1 8).
    private(set) var wroteDocument = false
    private var running = false
    /// The pass's `CloudInput.hooks`, and whether `beforeWrite` has run in it.
    private var passHooks = CloudHooks()
    private var writesCleared = false

    init(store: CloudStore, files: PhotoFiles, marks: CloudPhotoMarks, role: CloudRole, device: String,
         now: @escaping @Sendable () -> Date, build: String = CloudLink.currentBuild, photoBudget: TimeInterval = 40) {
        self.store = store
        self.files = files
        self.marks = marks
        self.role = role
        self.device = device
        self.now = now
        self.build = build
        self.photoBudget = photoBudget
    }

    static var currentBuild: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let number = info?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(number))"
    }

    // MARK: One pass (section 4)

    func pass(_ input: CloudInput) async -> (outcome: CloudOutcome, book: CloudBook) {
        var book = input.book
        if let disabled { return (.waiting(.failed(disabled)), book) }
        guard !running else { return (.waiting(.busy), book) }
        let start = now()
        if let notBefore = book.notBefore, start < notBefore { return (.waiting(.busy), book) }
        if let full = book.quotaFullAt, start.timeIntervalSince(full) < Self.quotaRetry { return (.waiting(.full), book) }
        book.notBefore = nil
        book.quotaFullAt = nil
        running = true
        wroteDocument = false
        passHooks = input.hooks
        writesCleared = false
        defer {
            running = false
            passHooks = CloudHooks()
        }
        do {
            let outcome = try await run(input, book: &book, deadline: start.addingTimeInterval(photoBudget))
            switch outcome {
            case .upToDate, .installed: lastFailure = nil
            case .conflicts, .waiting: break
            }
            return (outcome, book)
        } catch {
            let failure = Self.failure(error)
            lastFailure = failure
            return (.waiting(settle(failure, book: &book)), book)
        }
    }

    /// A thrown error as the link reads it. A Swift cancellation is a cancelled call, not a failure.
    static func failure(_ error: Error) -> CloudFailure {
        if let failure = error as? CloudFailure { return failure }
        if error is CancellationError { return .cancelled }
        return .other(String(describing: error))
    }

    /// Whether a save that threw this may still have landed, its answer lost: a network failure, a cancelled call, or
    /// anything unexpected. A refusal (signed out, full, throttled, erased, not set up) never saved anything.
    static func mayHaveLanded(_ error: Error) -> Bool {
        switch failure(error) {
        case .noAccount, .changed, .purged, .quotaFull, .retryAfter, .misconfigured: return false
        case .network, .photoFileMissing, .damagedPhoto, .cancelled, .other: return true
        }
    }

    /// Runs the caller's `beforeWrite` once per pass, before the first photo or document goes up.
    func clearToWrite() async throws {
        guard !writesCleared else { return }
        guard await passHooks.beforeWrite() else {
            throw CloudFailure.other("the copy made before iCloud sync could not be saved")
        }
        writesCleared = true
    }

    // MARK: Restart after an erase (sections 7 and 8)

    /// The Mac's "Sync through iCloud again", after he erased the app's iCloud data. The one call that saves the
    /// zone he erased: Apple's rule is that the app never makes it again on its own, so no pass calls
    /// `prepareZone`. With the zone back, the next pass after a clean hub pass sends the photos, then makes a new
    /// document under a new epoch. Returns nil when the restart is under way, else why it did not start; the book
    /// then stays paused as it was, so the button stays. Save the returned book either way.
    func restartAfterErase(_ book: CloudBook) async -> (failure: CloudWait?, book: CloudBook) {
        var book = book
        if let disabled { return (.failed(disabled), book) }
        guard role == .mac else { return (.failed("only the Mac starts iCloud sync again"), book) }
        guard book.paused != nil else { return (nil, book) }   // not paused: nothing to restart
        guard !running else { return (.busy, book) }
        running = true
        defer { running = false }
        do {
            // A book for another account says nothing about this one's zone; the next pass starts it afresh.
            guard try await store.account() == book.account else { return (.busy, book) }
            try await store.prepareZone()
        } catch {
            let failure = Self.failure(error)
            lastFailure = failure
            return (settle(failure, book: &book), book)
        }
        book.restartAfterErase()
        lastFailure = nil
        return (nil, book)
    }

    private func run(_ input: CloudInput, book: inout CloudBook, deadline: Date) async throws -> CloudOutcome {
        // 1. Gate: the account. Another account's book and marks say nothing about this one's database.
        let account = try await store.account()
        if book.account != account {
            if book.account != nil { book = CloudBook() }
            book.account = account
        }
        if marks.account != account { marks = CloudPhotoMarks(account: account) }

        // 2. Head. An erased zone throws `.purged` here, restarting or not: only `restartAfterErase` saves it again.
        let fetched = try await store.head()
        let head = fetched.document
        statuses = fetched.statuses
        if book.paused == .erased {
            // Paused: only the head is read. A document under a new epoch resumes, joining it with no base.
            guard let head, head.epoch != book.epoch else { return .waiting(.erased) }
            book.paused = nil
        }
        adoptPending(head, book: &book)
        if let head {
            guard head.format <= CloudRecords.format else { return .waiting(.newerFormat) }
            adoptMarks(epoch: head.epoch)
            if isSettled(head, input, book) {
                book.lastSuccess = now()
                await noteStatus(input, book, conflicts: 0)
                return .upToDate
            }
        }

        // 3 to 7, again from the fetch when someone else saved in between.
        var knownMissing = head == nil
        for _ in 0..<Self.maxRounds {
            let fetched = knownMissing ? nil : try await store.document()
            knownMissing = false
            guard let document = fetched else {
                // Section 6. A missing document never deletes anything on a device.
                guard role == .mac else { return .waiting(.noDocument) }
                guard input.hubSettledNow, let local = input.local else { return .waiting(.needsHubFirst) }
                if let outcome = try await create(from: local, input, book: &book, deadline: deadline) { return outcome }
                continue   // a document appeared meanwhile: merge with it
            }

            // 3. The fetched body must match its revision and decode; otherwise it is a failed fetch.
            guard document.head.format <= CloudRecords.format else { return .waiting(.newerFormat) }
            guard Self.sha256(document.body) == document.head.revision.lowercased() else {
                return unusable("the iCloud document does not match its revision")
            }
            guard let remote = try? JSONDecoder().decode(JSONValue.self, from: document.body), remote.objectValue != nil,
                  (try? Self.installable(remote, local: input.local)) != nil else {
                return unusable("the iCloud document does not decode")
            }
            adoptMarks(epoch: document.head.epoch)

            // 4. Base and merge.
            let output: JSONValue
            if let local = input.local {
                let ancestor = try base(for: document.head.epoch, input, book).map { try JSONValue(encoding: $0) }
                let merged = CollectionMerge.merge(base: ancestor, local: try JSONValue(encoding: local), remote: remote,
                                                   resolutions: input.resolutions)
                guard merged.conflicts.isEmpty else {
                    await noteStatus(input, book, conflicts: merged.conflicts.count)
                    return .conflicts(merged.conflicts)
                }
                output = merged.output
            } else {
                output = remote
            }
            guard let installed = try? Self.installable(output, local: input.local) else {
                return unusable("the merged collection does not decode")
            }
            let changesCloud = CollectionMerge.fingerprint(output) != CollectionMerge.fingerprint(remote)
            let names = Self.photoNames(in: installed)

            // 5. Photos up. The document is not written while any held one is outstanding.
            let push = try await pushPhotos(names, trustMarks: true, deadline: deadline)
            if changesCloud, let wait = push.wait { return .waiting(wait) }

            // 6. Mac: the photos it lacks come down before it installs.
            if role == .mac { try await pullPhotos(names) }

            // 7. Write, only over the version merged with.
            var settled = document
            if changesCloud {
                let body = output.canonicalData
                try await clearToWrite()
                do {
                    settled = try await store.write(body: body, revision: Self.sha256(body), epoch: document.head.epoch,
                                                    origin: document.origin, device: device, over: document.systemFields)
                } catch CloudFailure.changed {
                    continue
                } catch {
                    if Self.mayHaveLanded(error) { wroteDocument = true }
                    throw error
                }
                wroteDocument = true
            }

            // 9. The book that goes with the installed data.
            record(settled, base: installed, in: &book)
            await noteStatus(input, book, conflicts: 0)
            if !changesCloud, let local = input.local, let mine = Self.projection(local), mine == Self.projection(installed) {
                return .upToDate
            }
            return .installed(installed, wroteCloud: changesCloud)
        }
        return .waiting(.busy)
    }

    /// Section 6: the Mac makes the document from its own collection, photos first. nil when a document appeared
    /// meanwhile, so the caller merges with it instead.
    private func create(from local: CollectionData, _ input: CloudInput, book: inout CloudBook,
                        deadline: Date) async throws -> CloudOutcome? {
        let body = CollectionMerge.normalize(try JSONValue(encoding: local))
        guard let installed = try? Self.installable(body, local: local) else {
            return unusable("this collection does not decode from its own projection")
        }
        // Marks made for a document that has gone prove nothing about a new one; and none is trusted here.
        if marks.epoch != nil { marks = CloudPhotoMarks(account: marks.account) }
        let push = try await pushPhotos(Self.photoNames(in: installed), trustMarks: false, deadline: deadline)
        if let wait = push.wait { return .waiting(wait) }
        let bytes = body.canonicalData
        // D1: the epoch is chosen here and kept on disk with the body as its base before the save. Whatever happens
        // to the answer (lost, the process gone, the book not saved), the next pass that sees this epoch knows the
        // document is this collection.
        let epoch = UUID().uuidString
        var pending = book
        pending.pendingEpoch = epoch
        pending.pendingBase = installed
        try await clearToWrite()
        guard await passHooks.persist(pending) else {
            return unusable("this device's iCloud book could not be saved")
        }
        book = pending
        marks.epoch = epoch
        let document: CloudDocument
        do {
            document = try await store.write(body: bytes, revision: Self.sha256(bytes), epoch: epoch,
                                             origin: Self.hubOrigin, device: device, over: nil)
        } catch CloudFailure.changed {
            return nil
        } catch {
            if Self.mayHaveLanded(error) { wroteDocument = true }
            throw error
        }
        wroteDocument = true
        record(document, base: installed, in: &book)
        await noteStatus(input, book, conflicts: 0)
        return .installed(installed, wroteCloud: true)
    }

    /// D1: a document this device was making when its last pass ended. If the head shows that epoch, it landed, and
    /// its body is the base; any other answer (another epoch, no document) means it did not, and normal rules apply.
    private func adoptPending(_ head: CloudHead?, book: inout CloudBook) {
        guard let pending = book.pendingEpoch else { return }
        if head?.epoch == pending, let base = book.pendingBase {
            book.epoch = pending
            book.base = base
            book.tag = nil
            book.systemFields = nil
            book.revision = nil
        }
        book.pendingEpoch = nil
        book.pendingBase = nil
    }

    /// The base for the first merge with a document of this epoch (section 6's table).
    private func base(for epoch: String, _ input: CloudInput, _ book: CloudBook) -> CollectionData? {
        // D5: the first pass after the phone's switch made iCloud its link again merges with none.
        if input.noBase { return nil }
        if book.epoch == epoch, let base = book.base { return base }
        // The Mac never borrows a base. The phone borrows its hub base only on its very first join; after an epoch
        // change, or with no hub base, it merges with none: union, nothing deleted, differing fields ask.
        guard role == .phone, !input.joinedBefore, book.epoch == nil else { return nil }
        return input.hubBase
    }

    /// Step 2's fast path: same tag and epoch as the book, nothing changed here since, no photo work left.
    private func isSettled(_ head: CloudHead, _ input: CloudInput, _ book: CloudBook) -> Bool {
        guard head.tag == book.tag, head.epoch == book.epoch, book.paused == nil, !input.changedSinceLastPass,
              input.resolutions.isEmpty, let local = input.local, let base = book.base,
              let mine = Self.projection(local), mine == Self.projection(base) else { return false }
        return !hasPhotoWork(local)
    }

    private func record(_ document: CloudDocument, base: CollectionData, in book: inout CloudBook) {
        book.epoch = document.head.epoch
        book.tag = document.head.tag
        book.revision = document.head.revision
        book.systemFields = document.systemFields
        book.base = base
        book.lastSuccess = now()
        book.paused = nil
        book.pendingEpoch = nil
        book.pendingBase = nil
    }

    /// Marks hold only for the document epoch they were made under.
    private func adoptMarks(epoch: String) {
        if marks.epoch != epoch { marks = CloudPhotoMarks(account: marks.account, epoch: epoch) }
    }

    private func unusable(_ reason: String) -> CloudOutcome {
        lastFailure = .other(reason)
        return .waiting(.failed(reason))
    }

    /// Section 8: what a failure does to the book.
    private func settle(_ failure: CloudFailure, book: inout CloudBook) -> CloudWait {
        switch failure {
        case .noAccount:
            return .noAccount
        case .purged:
            // Also when restarting: erased again before the new document was made, the button is needed again.
            book.paused = .erased
            // Its photos went with the zone.
            marks = CloudPhotoMarks(account: marks.account)
            return .erased
        case .quotaFull:
            book.quotaFullAt = now()
            return .full
        case let .retryAfter(seconds):
            book.notBefore = now().addingTimeInterval(seconds)
            return .busy
        case .network:
            return .offline
        case .changed:
            return .busy
        case let .misconfigured(code):
            let reason = "iCloud is not set up for this build (\(code))"
            disabled = reason
            return .failed(reason)
        case .photoFileMissing:
            return .failed("a photo file went missing while it was sent")
        case let .damagedPhoto(reason):
            return .failed(reason)
        case .cancelled:
            // Cut short (the app left the screen): says nothing about iCloud; the next tick carries on.
            return .busy
        case let .other(reason):
            return .failed(reason)
        }
    }

    // MARK: Status (section 2)

    /// Writes this device's `Status` when it is due: none yet, a new revision or conflict count, or 5 minutes on.
    /// The count is this merge's questions plus the hub link's still waiting here. Information only: a failure here
    /// never fails the pass.
    private func noteStatus(_ input: CloudInput, _ book: CloudBook, conflicts merged: Int) async {
        let conflicts = merged + max(0, input.hubConflicts)
        let key = role.statusKey
        let at = now()
        let revision = book.revision ?? ""
        if let last = statuses[key], last.revision == revision, last.conflicts == conflicts,
           at.timeIntervalSince(last.at) < Self.statusInterval { return }
        let status = CloudStatus(name: device, build: build, revision: revision, at: at, hubAt: input.hubAt,
                                 hubRevision: input.hubRevision, conflicts: conflicts,
                                 note: conflicts > 0 ? "\(conflicts) waiting for a choice" : "")
        do {
            try await store.writeStatus(key, status)
            statuses[key] = status
        } catch {
            return
        }
    }

    // MARK: Helpers

    /// A document as this device installs it: its own device-only settings laid into `settings` (or false, nil,
    /// nil), because `CollectionSettings.autoBackup` is not optional, then decoded.
    static func installable(_ document: JSONValue, local: CollectionData?) throws -> CollectionData {
        var fields = document.objectValue ?? [:]
        var settings = fields["settings"]?.objectValue ?? [:]
        settings["autoBackup"] = .bool(local?.settings.autoBackup ?? false)
        settings["backupRemote"] = local?.settings.backupRemote.map { JSONValue.string($0) }
        settings["lastBackup"] = local?.settings.lastBackup.map { JSONValue.string($0) }
        fields["settings"] = .object(settings)
        return try JSONValue.object(fields).decoded(CollectionData.self)
    }

    /// The fingerprint of a collection's synced projection, or nil if it does not encode. Two collections with the
    /// same projection sync the same.
    static func projection(_ data: CollectionData) -> String? {
        guard let value = try? JSONValue(encoding: data) else { return nil }
        return CollectionMerge.fingerprint(CollectionMerge.normalize(value))
    }

    /// Lower-case hex SHA-256, the form `revision` and a photo's `sha256` hold.
    static func sha256(_ data: Data) -> String {
        let digits = Array("0123456789abcdef".utf8)
        var hex: [UInt8] = []
        hex.reserveCapacity(64)
        for byte in SHA256.hash(data: data) {
            hex.append(digits[Int(byte >> 4)])
            hex.append(digits[Int(byte & 0xF)])
        }
        return String(decoding: hex, as: UTF8.self)
    }
}
