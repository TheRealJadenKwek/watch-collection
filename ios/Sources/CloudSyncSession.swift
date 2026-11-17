import Foundation

/// The caller's side of a cloud pass, kept apart from `AppStore` so it is tested on the fake iCloud
/// (docs/icloud-plan.md section 4 steps 8 and 9, section 9 step 2):
/// - Right before this device's first cloud write or install (a photo, the document, or installing iCloud's
///   collection): a copy of `sync.json` as `sync-before-icloud-<time>.json`, and the JSON mirror once whatever
///   `autoBackup` says. Never deleted. A pass that writes and installs nothing makes none.
/// - An edit that lands while a pass runs: nothing is installed and the pass goes round again. If that round's
///   document write was confirmed (`.installed` with `wroteCloud`: the store answered with the new record), its book
///   is kept (epoch, tag, back-off) with its base set to the round's own local collection, the ancestor of both what
///   is here now and what iCloud now holds (docs/icloud-fixes.md R1; a pure push is the case where the two are
///   equal). Otherwise the round's result and book are dropped, and the dropped book still hands on its throttle,
///   full and erase state. A merge with no base (D5) holds only until a round's write is confirmed (R2).
/// - An install saves the data (`sync.json`) first and the book (`cloud.json`) second. An install that would change
///   nothing here (the pass only sent this device's own edits up) is skipped.
/// - The book is saved after every pass that keeps it (an `.upToDate` can carry a newer one), and before the
///   document is created; the marks after every pass and fill, and `cloud-status.json` is rewritten each pass.
@MainActor
final class CloudSyncSession {
    /// What `AppStore` lends one pass. The closures are read again at each round, so a round after an edit sees it.
    struct Host {
        /// This device's collection now.
        var local: () -> CollectionData?
        /// Moves on every local edit (`editGeneration`).
        var generation: () -> Int
        /// The synced projection moved since the cloud link last settled (`contentVersion`).
        var changed: () -> Bool
        /// The generation at which this tick's hub pass finished clean (the Mac); nil when it did not.
        var hubSettledAt: Int? = nil
        /// The phone's hub checkpoint base for its current address.
        var hubBase: CollectionData? = nil
        var joinedBefore = false
        var resolutions: [String: String] = [:]
        var hubAt: Date? = nil
        var hubRevision: String? = nil
        /// D5: the first pass after the phone's switch made iCloud its link again merges with no base, until one of
        /// its rounds confirms a write (R2).
        var noBase = false
        /// The hub link's changes waiting for a choice here, for this device's `Status` (C2 7).
        var hubConflicts = 0
        /// For `cloud-status.json`.
        var activeLink: SyncLinkKind = .cloud
        /// Installs a merged collection (`.installed`'s, before `BoxModel.installing` and this device's own
        /// settings), given the local collection it was merged from: saves `sync.json`, then shows it. false when
        /// it could not be saved, and then the book is not saved either.
        var install: (_ installed: CollectionData, _ mergedFrom: CollectionData?) -> Bool
        /// The JSON mirror (`LocalBackup.mirrorJSON`), whatever `autoBackup` says.
        var mirror: (CollectionData) -> Void
    }

    let link: CloudLink
    let role: CloudRole
    let files: CloudFiles
    private let now: () -> Date
    /// `cloud.json` as last saved (or as kept in memory when saving it failed after an install).
    private(set) var book: CloudBook
    private var preCloudCopyMade: Bool
    /// The last pass wrote the document, or tried to and cannot know whether it landed (C1 8).
    private(set) var lastPassWrote = false
    /// A round of the last pass confirmed a document write (R1), whether or not an edit overtook it: from then on the
    /// book holds a base, so a pending D5 merge with no base is spent (R2, across passes).
    private(set) var lastPassConfirmedWrite = false
    /// The last pass installed a collection that changed something here (C1 9).
    private(set) var lastPassInstalled = false
    /// Why the last pass stopped short; nil when it settled, asked, or none has run this launch.
    private(set) var lastWait: CloudWait?
    /// What stopped the phone's last fetch before a hub exchange; nil when nothing did.
    private var fetchFailure: CloudFailure?
    /// The round in flight, for the hooks the link calls mid-pass.
    private var roundHost: Host?
    private var roundLocal: CollectionData?

    init(link: CloudLink, role: CloudRole, files: CloudFiles, book: CloudBook, now: @escaping () -> Date = Date.init) {
        self.link = link
        self.role = role
        self.files = files
        self.book = book
        self.now = now
        preCloudCopyMade = !files.preCloudCopies.isEmpty
    }

    /// The session for this launch's real iCloud, or nil wherever `CloudKitStore.live()` is (simulators, tests, a
    /// build without the entitlement, DEBUG without `-WCDataRoot`): then the app syncs exactly as it did before.
    static func live(role: CloudRole, files: CloudFiles = .app) -> CloudSyncSession? {
        guard let store = CloudKitStore.live() else { return nil }
        let link = CloudLink(store: store, files: AppPhotoFiles(), marks: files.loadMarks(), role: role,
                             device: role == .mac ? "Mac" : "iPhone", now: { Date() })
        return CloudSyncSession(link: link, role: role, files: files, book: files.loadBook())
    }

    /// The store under the link, for `PhotoStore`'s cloud source.
    nonisolated var store: CloudStore { link.store }

    /// One cloud pass, with the caller's steps around it. Returns the outcome it kept (an edit during every round
    /// leaves `.waiting(.busy)`, for the next tick).
    func pass(_ host: Host) async -> CloudOutcome {
        lastPassWrote = false
        lastPassConfirmedWrite = false
        lastPassInstalled = false
        roundHost = host
        defer {
            roundHost = nil
            roundLocal = nil
        }
        let hooks = CloudHooks(
            beforeWrite: { [weak self] in await self?.copyBeforeWrite() ?? false },
            persist: { [weak self] book in await self?.persist(book) ?? false }
        )
        // R2: D5's merge with no base holds only until a round of this pass confirms a write; later rounds use the
        // book that round kept.
        var noBase = host.noBase
        for _ in 0..<CloudLink.maxRounds {
            let generation = host.generation()
            let local = host.local()
            roundLocal = local
            let input = CloudInput(local: local, book: book, hubBase: host.hubBase,
                                   hubSettledNow: host.hubSettledAt == generation, joinedBefore: host.joinedBefore,
                                   resolutions: host.resolutions, changedSinceLastPass: host.changed(),
                                   hubAt: host.hubAt, hubRevision: host.hubRevision, noBase: noBase,
                                   hubConflicts: host.hubConflicts, hooks: hooks)
            let (outcome, next) = await link.pass(input)
            if await link.wroteDocument { lastPassWrote = true }
            if case .installed(_, wroteCloud: true) = outcome { lastPassConfirmedWrite = true }
            files.saveMarks(await link.marks)
            // Step 8: an edit landed while the pass ran.
            guard host.generation() == generation else {
                if case .installed(_, wroteCloud: true) = outcome, let local, let base = CloudLink.projected(local) {
                    // R1: a confirmed write. iCloud holds the merge of this round's collection with what it had, so
                    // this round's collection is an ancestor of both that document and what is here now. Its book is
                    // kept (epoch, tag, back-off) with that collection as its base; nothing is installed. For a pure
                    // push the two are the same (D1). A write that may only have landed never gets here: it throws,
                    // and the round ends as `.waiting`.
                    var kept = next
                    kept.base = base
                    keep(kept)
                    noBase = false
                    continue
                }
                // Otherwise its result and its book are both dropped (iCloud may already hold that result; the kept
                // book's base is still an ancestor of it), but what it learned about waiting stands (C1 11). A pass
                // that settled or asked goes round again with the edit; one that waited has nothing to redo, and the
                // next tick tries again.
                var kept = book
                kept.takeBackOff(from: next)
                keep(kept)
                if case .waiting = outcome {
                    await report(outcome, host)
                    return outcome
                }
                continue
            }
            if case let .installed(installed, _) = outcome {
                if local == nil || CloudLink.projection(installed) != CloudLink.projection(local!) {
                    // Step 9: the data first, then the book. A crash between them leaves an older base, still an
                    // ancestor. The copy made before iCloud first changes anything here comes before both.
                    guard copyBeforeWrite() else {
                        let failed = CloudOutcome.waiting(.failed("the copy made before iCloud sync could not be saved"))
                        await report(failed, host)
                        return failed
                    }
                    guard host.install(installed, local) else {
                        let failed = CloudOutcome.waiting(.failed("this collection could not be saved"))
                        await report(failed, host)
                        return failed
                    }
                    lastPassInstalled = true
                }
                // Else the pass only sent this device's collection up: the data here already is the new base.
            }
            keep(next)
            await report(outcome, host)
            return outcome
        }
        let outcome = CloudOutcome.waiting(.busy)
        await report(outcome, host)
        return outcome
    }

    /// Section 9 step 2: the one-time copy of `sync.json`, and the mirror, right before the first cloud write or
    /// install on this device. true when it is made (or there is no collection to copy).
    private func copyBeforeWrite() -> Bool {
        guard !preCloudCopyMade, let local = roundLocal ?? roundHost?.local() else { return true }
        do {
            try files.writePreCloudCopy(of: local, at: now())
        } catch {
            return false
        }
        preCloudCopyMade = true
        roundHost?.mirror(local)
        return true
    }

    /// D1: the book carrying the document about to be created, saved before the save goes out.
    private func persist(_ pending: CloudBook) -> Bool {
        book = pending
        do {
            try files.saveBook(pending)
            return true
        } catch {
            return false
        }
    }

    /// The Mac's "Sync through iCloud again". nil when the restart is under way, else why it did not start.
    func restartAfterErase() async -> CloudWait? {
        let (failure, next) = await link.restartAfterErase(book)
        keep(next)
        return failure
    }

    /// Phone, after an install: fetch what is still missing while `allowed` says the network is neither expensive
    /// nor constrained, asked before each fetch. With `picturesOnly`, the covers and the box tiles alone.
    @discardableResult
    func fill(_ data: CollectionData, picturesOnly: Bool = false,
              while allowed: @escaping @Sendable () async -> Bool) async -> CloudLink.FillResult {
        let result = await link.fillPhotos(for: data, picturesOnly: picturesOnly, while: allowed)
        files.saveMarks(await link.marks)
        return result
    }

    /// Phone, before a hub exchange: fetch these missing photos from iCloud now (C1 10). A phone on the hub runs no
    /// cloud pass, so what stops this fetch is what it knows of the account.
    func fetch(_ names: [String]) async {
        guard !names.isEmpty else { return }
        fetchFailure = await link.fetchPhotos(names)
        files.saveMarks(await link.marks)
    }

    /// Every device's `Status` as the last head fetch returned it.
    func statuses() async -> [String: CloudStatus] {
        await link.statuses
    }

    /// The narrowed drop rule's names (docs/icloud-fixes.md D4): those iCloud has said it does not have, and those
    /// given up on as unreadable. nil when the cloud link cannot answer (turned off for this launch, signed out,
    /// paused, a newer format, or no document behind the book), and then the hub exchange drops what is gone on both
    /// sides, as it did before iCloud.
    func namesNotInCloud() async -> Set<String>? {
        guard await link.disabled == nil, book.paused == nil, book.epoch != nil else { return nil }
        switch lastWait {
        case .noAccount?, .newerFormat?, .erased?, .noDocument?, .needsHubFirst?:
            return nil
        default:
            break
        }
        switch fetchFailure {
        case .noAccount?, .purged?, .misconfigured?:
            return nil
        default:
            return await link.marks.lost
        }
    }

    private func keep(_ next: CloudBook) {
        book = next
        // Kept in memory even if the file cannot be written: the data on disk then sits with an older book, which
        // is what a crash between the two writes leaves, and merges cleanly.
        try? files.saveBook(next)
    }

    private func report(_ outcome: CloudOutcome, _ host: Host) async {
        if case let .waiting(wait) = outcome { lastWait = wait } else { lastWait = nil }
        let marks = await link.marks
        let names = host.local().map(CloudLink.photoNames) ?? []
        let held = names.filter { link.files.exists($0) }.count
        let failure = await link.lastFailure
        let report = CloudStatusReport(
            at: now(), role: role == .mac ? "mac" : "phone", build: link.build, outcome: Self.describe(outcome),
            activeLink: host.activeLink.rawValue, joined: host.joinedBefore || (role == .phone && SyncRoute.joins(outcome)),
            epoch: book.epoch, revision: book.revision, tag: book.tag, lastSuccess: book.lastSuccess,
            paused: book.paused?.rawValue,
            photos: .init(referenced: names.count, held: held, inCloud: marks.inCloud.count,
                          notInCloud: marks.notInCloud.count, mismatched: marks.mismatched.count,
                          unreadable: marks.unreadable.count),
            lastError: failure.map { String(describing: $0) }, statuses: await link.statuses
        )
        files.saveReport(report)
    }

    static func describe(_ outcome: CloudOutcome) -> String {
        switch outcome {
        case .upToDate: return "upToDate"
        case let .installed(_, wrote): return wrote ? "installed+wrote" : "installed"
        case let .conflicts(list): return "conflicts(\(list.count))"
        case let .waiting(wait): return "waiting(\(wait))"
        }
    }
}
