import Foundation

/// The caller's side of a cloud pass, kept apart from `AppStore` so it is tested on the fake iCloud
/// (docs/icloud-plan.md section 4 steps 8 and 9, section 9 step 2):
/// - Before this device's first cloud pass (so before its first cloud write or install): a copy of `sync.json` as
///   `sync-before-icloud-<time>.json`, and the JSON mirror once whatever `autoBackup` says. Never deleted.
/// - An edit that lands while a pass runs drops that pass's result and its book, and the pass goes round again.
/// - An install saves the data (`sync.json`) first and the book (`cloud.json`) second.
/// - The book is saved after every pass that keeps it (an `.upToDate` can carry a newer one), the marks after every
///   pass and fill, and `cloud-status.json` is rewritten each pass.
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
        if !preCloudCopyMade, let local = host.local() {
            do {
                try files.writePreCloudCopy(of: local, at: now())
            } catch {
                let outcome = CloudOutcome.waiting(.failed("the copy made before iCloud sync could not be saved"))
                await report(outcome, host)
                return outcome
            }
            preCloudCopyMade = true
            host.mirror(local)
        }
        for _ in 0..<CloudLink.maxRounds {
            let generation = host.generation()
            let local = host.local()
            let input = CloudInput(local: local, book: book, hubBase: host.hubBase,
                                   hubSettledNow: host.hubSettledAt == generation, joinedBefore: host.joinedBefore,
                                   resolutions: host.resolutions, changedSinceLastPass: host.changed(),
                                   hubAt: host.hubAt, hubRevision: host.hubRevision)
            let (outcome, next) = await link.pass(input)
            files.saveMarks(await link.marks)
            // Step 8: an edit landed while the pass ran. Its result and its book are both dropped (iCloud may already
            // hold that result; the kept book's base is still an ancestor of it). A pass that settled or asked goes
            // round again with the edit; one that waited has nothing to redo, and the next tick tries again.
            guard host.generation() == generation else {
                if case .waiting = outcome {
                    await report(outcome, host)
                    return outcome
                }
                continue
            }
            if case let .installed(installed, _) = outcome {
                // Step 9: the data first, then the book. A crash between them leaves an older base, still an ancestor.
                guard host.install(installed, local) else {
                    let failed = CloudOutcome.waiting(.failed("this collection could not be saved"))
                    await report(failed, host)
                    return failed
                }
            }
            keep(next)
            await report(outcome, host)
            return outcome
        }
        let outcome = CloudOutcome.waiting(.busy)
        await report(outcome, host)
        return outcome
    }

    /// The Mac's "Sync through iCloud again". nil when the restart is under way, else why it did not start.
    func restartAfterErase() async -> CloudWait? {
        let (failure, next) = await link.restartAfterErase(book)
        keep(next)
        return failure
    }

    /// Phone, after an install: fetch what is still missing, unless the network is expensive or constrained.
    func fill(_ data: CollectionData, allowBulk: Bool) async {
        await link.fillPhotos(for: data, allowBulk: allowBulk)
        files.saveMarks(await link.marks)
    }

    /// Every device's `Status` as the last head fetch returned it.
    func statuses() async -> [String: CloudStatus] {
        await link.statuses
    }

    /// The names iCloud has said it does not have (the Mac's narrowed drop rule).
    func namesNotInCloud() async -> Set<String> {
        Set(await link.marks.notInCloud.keys)
    }

    private func keep(_ next: CloudBook) {
        book = next
        // Kept in memory even if the file cannot be written: the data on disk then sits with an older book, which
        // is what a crash between the two writes leaves, and merges cleanly.
        try? files.saveBook(next)
    }

    private func report(_ outcome: CloudOutcome, _ host: Host) async {
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
                          notInCloud: marks.notInCloud.count, mismatched: marks.mismatched.count),
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
