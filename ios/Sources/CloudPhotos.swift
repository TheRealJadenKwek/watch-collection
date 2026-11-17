import Foundation
import os

// iCloud sync: photos (docs/icloud-plan.md section 5). Bytes travel unchanged and a `Photo` record never changes,
// so a name means the same bytes everywhere. Photos go up before any document that names them; the phone fetches
// what it lacks after it installs, the Mac before.

/// `cloud-photos.json`: what this device has learned about photos in iCloud. A cache: losing it costs one existence
/// check. It holds only for the account and the document epoch it names.
struct CloudPhotoMarks: Codable, Equatable, Sendable {
    var account: String?
    var epoch: String?
    /// Confirmed in iCloud: sent, found there, or fetched from there.
    var inCloud: Set<String> = []
    /// iCloud said it does not have these, and when.
    var notInCloud: [String: Date] = [:]
    /// iCloud holds other bytes under these names. Both copies are kept as they are; never sent again.
    var mismatched: Set<String> = []
    /// Mac: fetches that handed over bytes not matching their record (docs/icloud-fixes.md D3). Retried on later
    /// passes, and the install waits for them meanwhile.
    var damaged: [String: CloudPhotoStrikes] = [:]
    /// Mac: given up on after `CloudLink.damagedStrikes` such fetches over at least `CloudLink.damagedSpan`. The
    /// install goes ahead without them, and they count as not in iCloud for the drop rule.
    var unreadable: [String: Date] = [:]

    /// Whether iCloud has said it does not have this photo (the Mac's narrowed drop rule, section 5).
    func saysMissing(_ name: String) -> Bool {
        notInCloud[name] != nil
    }

    /// The names the narrowed drop rule may let go: not in iCloud, or given up on as unreadable (D3).
    var lost: Set<String> {
        Set(notInCloud.keys).union(unreadable.keys)
    }

    mutating func confirm(_ name: String) {
        inCloud.insert(name)
        notInCloud[name] = nil
        damaged[name] = nil
        unreadable[name] = nil
    }

    mutating func noteMissing(_ name: String, at date: Date) {
        notInCloud[name] = date
        inCloud.remove(name)
        damaged[name] = nil
        unreadable[name] = nil
    }

    mutating func noteMismatch(_ name: String) {
        mismatched.insert(name)
        inCloud.remove(name)
    }

    /// A fetch of this photo handed over bytes that do not match its record. Returns the strikes so far.
    @discardableResult
    mutating func strike(_ name: String, at date: Date) -> CloudPhotoStrikes {
        var strikes = damaged[name] ?? CloudPhotoStrikes(first: date, last: date, count: 0)
        strikes.last = date
        strikes.count += 1
        damaged[name] = strikes
        return strikes
    }

    /// Given up on: iCloud has this photo, but never once handed it over whole.
    mutating func noteUnreadable(_ name: String, at date: Date) {
        unreadable[name] = date
        damaged[name] = nil
        inCloud.remove(name)
    }

    /// The file under a name is gone from this device: whatever was learned about sending it no longer applies.
    mutating func forget(_ name: String) {
        inCloud.remove(name)
        notInCloud[name] = nil
        mismatched.remove(name)
        damaged[name] = nil
        unreadable[name] = nil
    }
}

extension CloudPhotoMarks {
    private enum CodingKeys: String, CodingKey {
        case account, epoch, inCloud, notInCloud, mismatched, damaged, unreadable
    }

    /// Every field but the account and epoch may be absent (a file from an earlier build): it reads as empty.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        account = try container.decodeIfPresent(String.self, forKey: .account)
        epoch = try container.decodeIfPresent(String.self, forKey: .epoch)
        inCloud = try container.decodeIfPresent(Set<String>.self, forKey: .inCloud) ?? []
        notInCloud = try container.decodeIfPresent([String: Date].self, forKey: .notInCloud) ?? [:]
        mismatched = try container.decodeIfPresent(Set<String>.self, forKey: .mismatched) ?? []
        damaged = try container.decodeIfPresent([String: CloudPhotoStrikes].self, forKey: .damaged) ?? [:]
        unreadable = try container.decodeIfPresent([String: Date].self, forKey: .unreadable) ?? [:]
    }
}

/// The fetches of one photo whose bytes did not match its record.
struct CloudPhotoStrikes: Codable, Equatable, Sendable {
    var first: Date
    var last: Date
    var count: Int
}

/// How far step 5 got.
struct CloudPhotoPush: Equatable, Sendable {
    /// Held photos now in iCloud (or there with other bytes), of all the held photos the document names.
    var done: Int
    var of: Int
    /// Every held photo is up; the document may be written.
    var finished: Bool
    /// Held photos whose file is here but could not be read (D2). They hold the document back this pass.
    var unreadable: [String] = []

    static let unreadableReason = "a photo on this device could not be read; sync will try it again"

    /// Why the document cannot be written yet; nil once every held photo is up.
    var wait: CloudWait? {
        if finished { return nil }
        if !unreadable.isEmpty, done + unreadable.count >= of { return .failed(Self.unreadableReason) }
        return .sendingPhotos(done: done, of: of)
    }
}

extension CloudLink {
    /// Uploads between two existence checks, so two devices sending the same set take turns instead of both
    /// sending everything.
    static let uploadBatch = 10
    /// Photos fetched at once by the phone's fill.
    static let fillWidth = 3
    /// D3: a photo whose bytes keep failing their check is given up on after this many fetches...
    static let damagedStrikes = 3
    /// ...spread over at least this long.
    static let damagedSpan: TimeInterval = 60 * 60

    static let photoLog = Logger(subsystem: "com.jadenkwek.watchcollection", category: "icloud-photos")

    /// Every photo file a collection names, as "dir/file", once each, in the order `PhotoStore` lists them.
    static func photoNames(in data: CollectionData) -> [String] {
        var seen = Set<String>()
        return PhotoStore.assets(in: data, baseURL: nil)
            .map { "\($0.directory)/\($0.filename)" }
            .filter { seen.insert($0).inserted }
    }

    // MARK: Up (step 5)

    /// Sends every named photo this device holds and iCloud lacks. A photo it does not hold never blocks and is
    /// never dropped. "Already there" is success; a name iCloud holds with other bytes is marked and never retried.
    /// Stops early, unfinished, at `deadline` or when the task is cancelled; the marks carry the progress over.
    /// `trustMarks: false` asks iCloud about every held photo, as before a new document.
    ///
    /// A held file that cannot be read (or that CloudKit says it cannot read) counts as gone only when it is no
    /// longer there; otherwise it holds the document back this pass (D2).
    func pushPhotos(_ names: [String], trustMarks: Bool, deadline: Date) async throws -> CloudPhotoPush {
        let held = names.filter { files.url($0) != nil && files.exists($0) }
        var of = held.count
        var pending = held.filter { !marks.mismatched.contains($0) && !(trustMarks && marks.inCloud.contains($0)) }
        var done = of - pending.count
        var unreadable: [String] = []
        guard !pending.isEmpty else { return CloudPhotoPush(done: done, of: of, finished: true) }

        /// Gone since it was listed: no longer held, so it no longer holds the document up. Otherwise it stays.
        func goneOrHeld(_ name: String) {
            if files.exists(name) {
                unreadable.append(name)
            } else {
                marks.forget(name)
                of -= 1
            }
        }

        let present = try await store.photosPresent(pending)
        for name in pending where present.contains(name) {
            marks.confirm(name)
            done += 1
        }
        pending.removeAll { present.contains($0) }

        var askedAlready = true
        while !pending.isEmpty {
            if Task.isCancelled || now() >= deadline {
                return CloudPhotoPush(done: done, of: of, finished: false, unreadable: unreadable)
            }
            let batch = Array(pending.prefix(Self.uploadBatch))
            pending.removeFirst(batch.count)
            var absent = batch
            if !askedAlready {
                // Asked again before each batch: another device may have sent some of these meanwhile.
                let there = try await store.photosPresent(batch)
                for name in batch where there.contains(name) {
                    marks.confirm(name)
                    done += 1
                }
                absent = batch.filter { !there.contains($0) }
            }
            askedAlready = false
            for (index, name) in absent.enumerated() {
                if index > 0, Task.isCancelled || now() >= deadline {
                    return CloudPhotoPush(done: done, of: of, finished: false, unreadable: unreadable)
                }
                guard let file = files.url(name) else { continue }
                let bytes: Data
                do {
                    bytes = try Data(contentsOf: file)
                } catch {
                    goneOrHeld(name)
                    continue
                }
                try await clearToWrite()
                do {
                    if try await store.uploadPhoto(name, file: file, sha256: Self.sha256(bytes), bytes: bytes.count) {
                        marks.confirm(name)
                    } else {
                        marks.noteMismatch(name)
                    }
                    done += 1
                } catch CloudFailure.photoFileMissing {
                    goneOrHeld(name)
                }
            }
        }
        return CloudPhotoPush(done: done, of: of, finished: unreadable.isEmpty, unreadable: unreadable)
    }

    // MARK: Down

    /// Step 6, Mac only: every named photo the Mac lacks, before it installs (D3). Only "not in iCloud" lets the
    /// install go ahead without the photo. Bytes that do not match their record are fetched again on later passes
    /// (no sooner than `missingRecheck`), and the install waits; after `damagedStrikes` such fetches over at least
    /// `damagedSpan` the photo is given up on as unreadable. Every other failure throws, so nothing is installed and
    /// the next pass tries again.
    func pullPhotos(_ names: [String]) async throws {
        for name in names where !files.exists(name) {
            let at = now()
            guard let file = files.url(name), wantsDownload(name, at: at) else { continue }
            if let strikes = marks.damaged[name], at.timeIntervalSince(strikes.last) < Self.missingRecheck {
                throw CloudFailure.damagedPhoto(Self.damagedReason)
            }
            do {
                if try await store.downloadPhoto(name, to: file) {
                    marks.confirm(name)
                } else {
                    marks.noteMissing(name, at: at)
                }
            } catch CloudFailure.damagedPhoto {
                let strikes = marks.strike(name, at: at)
                guard strikes.count >= Self.damagedStrikes,
                      strikes.last.timeIntervalSince(strikes.first) >= Self.damagedSpan else {
                    // One wording for every pass it holds up (the store has logged which check failed).
                    throw CloudFailure.damagedPhoto(Self.damagedReason)
                }
                marks.noteUnreadable(name, at: at)
                Self.photoLog.error("""
                    gave up on \(name, privacy: .public) after \(strikes.count) fetches whose bytes did not match \
                    its record; installing without it, and the hub may drop its reference
                    """)
            }
        }
    }

    static let damagedReason = "a photo from iCloud did not match its record; sync will try it again"

    /// Phone, after an install: fetch the named photos it lacks, 3 at a time. With `allowBulk` false (an expensive
    /// or constrained network) nothing is fetched here; screens fetch what they show.
    func fillPhotos(for data: CollectionData, allowBulk: Bool) async {
        guard allowBulk else { return }
        await fillPhotos(for: data, while: { true })
    }

    /// The fill, asking `allowed` (the network is neither expensive nor constrained) before each fetch it starts,
    /// and stopping when it says no, when the task is cancelled, or at the first failure a retry can fix. Its
    /// fetches never use a cellular connection (C1 4).
    func fillPhotos(for data: CollectionData, while allowed: @escaping @Sendable () async -> Bool) async {
        guard disabled == nil else { return }
        let start = now()
        var queue = Self.photoNames(in: data)
            .filter { files.url($0) != nil && !files.exists($0) && wantsDownload($0, at: start) }[...]
        guard !queue.isEmpty, await allowed() else { return }
        let scope = (account: marks.account, epoch: marks.epoch)
        let store = store, files = files, now = now
        var results: [Fetched] = []
        await withTaskGroup(of: Fetched.self) { group in
            for _ in 0..<Self.fillWidth {
                guard let name = queue.popFirst() else { break }
                group.addTask { await Self.fetch(name, store: store, files: files, bulk: true, now: now) }
            }
            var stopped = false
            while let finished = await group.next() {
                results.append(finished)
                if case let .failure(failure) = finished.result, Self.stopsFill(failure) { stopped = true }
                guard !stopped, !queue.isEmpty else { continue }
                guard !Task.isCancelled, await allowed() else {
                    stopped = true
                    continue
                }
                if let name = queue.popFirst() {
                    group.addTask { await Self.fetch(name, store: store, files: files, bulk: true, now: now) }
                }
            }
        }
        note(results, scope: scope)
    }

    /// Phone, before a hub exchange: fetch these photos it lacks now, over any connection, so the exchange never
    /// drops a photo iCloud has (C1 10). What fails is left for the narrowed drop rule, which keeps it. Returns the
    /// failure that stopped it, if one did.
    @discardableResult
    func fetchPhotos(_ names: [String]) async -> CloudFailure? {
        guard disabled == nil else { return nil }
        let start = now()
        let wanted = names.filter { files.url($0) != nil && !files.exists($0) && wantsDownload($0, at: start) }
        guard !wanted.isEmpty else { return nil }
        let scope = (account: marks.account, epoch: marks.epoch)
        var results: [Fetched] = []
        var stoppedBy: CloudFailure?
        for name in wanted {
            if Task.isCancelled { break }
            let fetched = await Self.fetch(name, store: store, files: files, bulk: false, now: now)
            results.append(fetched)
            if case let .failure(failure) = fetched.result, Self.stopsFill(failure) {
                stoppedBy = failure
                break
            }
        }
        note(results, scope: scope)
        return stoppedBy
    }

    /// One fetch's answer, and when it came.
    typealias Fetched = (name: String, result: Result<Bool, CloudFailure>, at: Date)

    private func note(_ results: [Fetched], scope: (account: String?, epoch: String?)) {
        // A pass moved the marks to another account or document meanwhile: these results speak for the old one.
        guard marks.account == scope.account, marks.epoch == scope.epoch else { return }
        for (name, result, at) in results {
            switch result {
            case .success(true): marks.confirm(name)
            case .success(false): marks.noteMissing(name, at: at)
            case .failure(.other), .failure(.damagedPhoto): failedLately[name] = at
            case .failure: break
            }
        }
    }

    // MARK: Helpers

    /// Step 2's "photo work left": a held photo not yet confirmed in iCloud, or on the Mac a named photo it lacks
    /// that iCloud has not lately said it does not have.
    func hasPhotoWork(_ data: CollectionData) -> Bool {
        let at = now()
        return Self.photoNames(in: data).contains { name in
            guard files.url(name) != nil else { return false }
            if files.exists(name) { return !marks.inCloud.contains(name) && !marks.mismatched.contains(name) }
            return role == .mac && wantsDownload(name, at: at)
        }
    }

    /// Not asked about lately with no luck, and not given up on.
    func wantsDownload(_ name: String, at date: Date) -> Bool {
        if marks.unreadable[name] != nil { return false }
        if let when = marks.notInCloud[name], date.timeIntervalSince(when) < Self.missingRecheck { return false }
        if let when = failedLately[name], date.timeIntervalSince(when) < Self.missingRecheck { return false }
        return true
    }

    private static func fetch(_ name: String, store: CloudStore, files: PhotoFiles, bulk: Bool,
                              now: @Sendable () -> Date) async -> Fetched {
        guard let file = files.url(name) else { return (name, .failure(.other("unsafe photo name")), now()) }
        do {
            let found = try await store.downloadPhoto(name, to: file, bulk: bulk)
            return (name, .success(found), now())
        } catch {
            return (name, .failure(failure(error)), now())
        }
    }

    /// Failures that will fail the next fetch too.
    private static func stopsFill(_ failure: CloudFailure) -> Bool {
        switch failure {
        case .other, .photoFileMissing, .changed, .damagedPhoto: return false
        case .noAccount, .purged, .quotaFull, .retryAfter, .network, .misconfigured, .cancelled: return true
        }
    }
}
