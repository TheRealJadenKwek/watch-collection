import Foundation

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

    /// Whether iCloud has said it does not have this photo (the Mac's narrowed drop rule, section 5).
    func saysMissing(_ name: String) -> Bool {
        notInCloud[name] != nil
    }

    mutating func confirm(_ name: String) {
        inCloud.insert(name)
        notInCloud[name] = nil
    }

    mutating func noteMissing(_ name: String, at date: Date) {
        notInCloud[name] = date
        inCloud.remove(name)
    }

    mutating func noteMismatch(_ name: String) {
        mismatched.insert(name)
        inCloud.remove(name)
    }

    /// The file under a name is gone from this device: whatever was learned about sending it no longer applies.
    mutating func forget(_ name: String) {
        inCloud.remove(name)
        notInCloud[name] = nil
        mismatched.remove(name)
    }
}

/// How far step 5 got.
struct CloudPhotoPush: Equatable, Sendable {
    /// Held photos now in iCloud (or there with other bytes), of all the held photos the document names.
    var done: Int
    var of: Int
    /// Every held photo is up; the document may be written.
    var finished: Bool
}

extension CloudLink {
    /// Uploads between two existence checks, so two devices sending the same set take turns instead of both
    /// sending everything.
    static let uploadBatch = 10
    /// Photos fetched at once by the phone's fill.
    static let fillWidth = 3

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
    func pushPhotos(_ names: [String], trustMarks: Bool, deadline: Date) async throws -> CloudPhotoPush {
        let held = names.filter { files.url($0) != nil && files.exists($0) }
        var of = held.count
        var pending = held.filter { !marks.mismatched.contains($0) && !(trustMarks && marks.inCloud.contains($0)) }
        var done = of - pending.count
        guard !pending.isEmpty else { return CloudPhotoPush(done: done, of: of, finished: true) }

        let present = try await store.photosPresent(pending)
        for name in pending where present.contains(name) {
            marks.confirm(name)
            done += 1
        }
        pending.removeAll { present.contains($0) }

        var askedAlready = true
        while !pending.isEmpty {
            if Task.isCancelled || now() >= deadline { return CloudPhotoPush(done: done, of: of, finished: false) }
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
                    return CloudPhotoPush(done: done, of: of, finished: false)
                }
                guard let file = files.url(name), let bytes = try? Data(contentsOf: file) else {
                    // Gone since it was listed: no longer held, so it no longer holds the document up.
                    marks.forget(name)
                    of -= 1
                    continue
                }
                do {
                    if try await store.uploadPhoto(name, file: file, sha256: Self.sha256(bytes), bytes: bytes.count) {
                        marks.confirm(name)
                    } else {
                        marks.noteMismatch(name)
                    }
                    done += 1
                } catch CloudFailure.photoFileMissing {
                    marks.forget(name)
                    of -= 1
                }
            }
        }
        return CloudPhotoPush(done: done, of: of, finished: true)
    }

    // MARK: Down

    /// Step 6, Mac only: every named photo the Mac lacks, before it installs. A failure that a retry can fix (the
    /// network, the account, a throttle) throws, so nothing is installed and the next pass tries again. "Not in
    /// iCloud" is noted and does not hold the install up; nor does a photo whose record does not match its bytes.
    func pullPhotos(_ names: [String]) async throws {
        let at = now()
        for name in names where !files.exists(name) {
            guard let file = files.url(name), wantsDownload(name, at: at) else { continue }
            do {
                if try await store.downloadPhoto(name, to: file) {
                    marks.confirm(name)
                } else {
                    marks.noteMissing(name, at: at)
                }
            } catch CloudFailure.other {
                unreadable[name] = at
            }
        }
    }

    /// Phone, after an install: fetch the named photos it lacks, 3 at a time. With `allowBulk` false (an expensive
    /// or constrained network) nothing is fetched here; screens fetch what they show. Stops at the first failure a
    /// retry can fix.
    func fillPhotos(for data: CollectionData, allowBulk: Bool) async {
        guard allowBulk, disabled == nil else { return }
        let at = now()
        var queue = Self.photoNames(in: data)
            .filter { files.url($0) != nil && !files.exists($0) && wantsDownload($0, at: at) }[...]
        guard !queue.isEmpty else { return }
        let scope = (account: marks.account, epoch: marks.epoch)
        let store = store, files = files
        var results: [(name: String, result: Result<Bool, CloudFailure>)] = []
        await withTaskGroup(of: (name: String, result: Result<Bool, CloudFailure>).self) { group in
            for _ in 0..<Self.fillWidth {
                guard let name = queue.popFirst() else { break }
                group.addTask { await Self.fetch(name, store: store, files: files) }
            }
            var stopped = false
            while let finished = await group.next() {
                results.append(finished)
                if case let .failure(failure) = finished.result, Self.stopsFill(failure) { stopped = true }
                if !stopped, let name = queue.popFirst() {
                    group.addTask { await Self.fetch(name, store: store, files: files) }
                }
            }
        }
        // A pass moved the marks to another account or document meanwhile: these results speak for the old one.
        guard marks.account == scope.account, marks.epoch == scope.epoch else { return }
        for (name, result) in results {
            switch result {
            case .success(true): marks.confirm(name)
            case .success(false): marks.noteMissing(name, at: at)
            case .failure(.other): unreadable[name] = at
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

    /// Not asked about lately with no luck.
    func wantsDownload(_ name: String, at date: Date) -> Bool {
        if let when = marks.notInCloud[name], date.timeIntervalSince(when) < Self.missingRecheck { return false }
        if let when = unreadable[name], date.timeIntervalSince(when) < Self.missingRecheck { return false }
        return true
    }

    private static func fetch(_ name: String, store: CloudStore,
                              files: PhotoFiles) async -> (name: String, result: Result<Bool, CloudFailure>) {
        guard let file = files.url(name) else { return (name, .failure(.other("unsafe photo name"))) }
        do {
            return (name, .success(try await store.downloadPhoto(name, to: file)))
        } catch {
            return (name, .failure((error as? CloudFailure) ?? .other(String(describing: error))))
        }
    }

    /// Failures that will fail the next fetch too.
    private static func stopsFill(_ failure: CloudFailure) -> Bool {
        switch failure {
        case .other, .photoFileMissing, .changed: return false
        case .noAccount, .purged, .quotaFull, .retryAfter, .network, .misconfigured: return true
        }
    }
}
