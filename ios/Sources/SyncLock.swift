import Foundation
import os

/// One writer at a time for this device's library (`sync.json`, the cloud files, the photo folder): the Mac app and
/// its headless bridge (docs/icloud-plan.md section 11 P5). An exclusive `flock` on `WatchCollection/sync.lock`.
///
/// - The app takes it before it reads `sync.json` and holds it for as long as it runs (`holdForApp`). While it waits
///   it leaves `sync.lock.want` and holds a lock on that file too, so the want reads as live only while a waiter is
///   alive: a waiter that died leaves a file nobody holds, which reads as not wanted.
/// - The bridge only ever tries (`tryLock`), never waits: it leaves at once when the lock is taken, and stops between
///   steps when `isWanted` says the app is waiting.
///
/// `flock` belongs to the open file, not the process, so two `SyncLock`s on one file in one process exclude each
/// other too, and the kernel releases both locks when the file is closed or the process ends, however it ends.
final class SyncLock: @unchecked Sendable {
    enum Failure: Error, Equatable, CustomStringConvertible {
        case folder(path: String, reason: String)
        case open(path: String, errno: Int32)
        case lock(errno: Int32)

        var description: String {
            switch self {
            case let .folder(path, reason): return "cannot make \(path): \(reason)"
            case let .open(path, code): return "cannot open \(path): \(String(cString: strerror(code)))"
            case let .lock(code): return "flock failed: \(String(cString: strerror(code)))"
            }
        }
    }

    /// What `holdForApp` came to.
    enum Hold: Equatable {
        /// The lock is the app's.
        case held
        /// A bridge tick kept it past the app's patience. The app carries on, still asking, and takes it once free.
        case late
        /// The lock file could not be opened. The app carries on without it.
        case unavailable(String)
    }

    /// The app's lock, in the folder `sync.json` is in (a DEBUG `-WCDataRoot` run has its own).
    static var appURL: URL { AppPaths.collectionFolder.appendingPathComponent("sync.lock") }
    /// How long the app waits at launch for a bridge tick to step aside. A tick checks every 200 ms.
    static let appPatience: TimeInterval = 5
    static let log = Logger(subsystem: "com.jadenkwek.watchcollection", category: "sync-lock")

    let url: URL
    /// `sync.lock.want`: a waiter is here.
    var wantURL: URL { url.appendingPathExtension("want") }

    private let state = NSLock()
    private var descriptor: Int32 = -1
    private var wantDescriptor: Int32 = -1

    init(url: URL) {
        self.url = url
    }

    deinit {
        unlock()
    }

    /// This lock holds the file now.
    var isHeld: Bool {
        state.lock()
        defer { state.unlock() }
        return descriptor >= 0
    }

    /// Takes the lock if it is free, never waiting. false when someone else holds it; throws when the file cannot be
    /// opened. Taking it ends this lock's own want.
    @discardableResult
    func tryLock() throws -> Bool {
        state.lock()
        defer { state.unlock() }
        if descriptor >= 0 { return true }
        let folder = url.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            throw Failure.folder(path: folder.path, reason: error.localizedDescription)
        }
        let fd = open(url.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
        guard fd >= 0 else { throw Failure.open(path: url.path, errno: errno) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            close(fd)
            if code == EWOULDBLOCK { return false }
            throw Failure.lock(errno: code)
        }
        descriptor = fd
        lowerWantLocked()
        return true
    }

    /// Waits up to `patience` for the lock, leaving the want while it waits so a holder that polls `isWanted` steps
    /// aside. false when patience ran out; the want then stays up until the lock is taken or `unlock()`.
    func acquire(patience: TimeInterval, poll: TimeInterval = 0.05) throws -> Bool {
        if try tryLock() { return true }
        let deadline = Date().addingTimeInterval(patience)
        repeat {
            raiseWant()
            Thread.sleep(forTimeInterval: poll)
            if try tryLock() { return true }
        } while Date() < deadline
        return false
    }

    /// Gives the lock back (closing the file is what releases it), and the want with it.
    func unlock() {
        state.lock()
        defer { state.unlock() }
        if descriptor >= 0 {
            close(descriptor)
            descriptor = -1
        }
        lowerWantLocked()
    }

    /// Someone alive is waiting for this lock: the want file exists and its waiter still holds it. Asks without
    /// waiting and leaves nothing behind.
    var isWanted: Bool {
        let fd = open(wantURL.path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        guard flock(fd, LOCK_SH | LOCK_NB) != 0 else { return false }
        return errno == EWOULDBLOCK
    }

    /// The app at launch, before anything reads `sync.json`: takes the lock and keeps it for the life of the process.
    /// If a bridge tick has it, the want makes the tick stop at its next step; past `patience` (a tick that cannot
    /// stop) the app carries on and keeps asking every `retry` until it gets it. If the file cannot be opened the app
    /// carries on without it. Either way it is logged: a lock problem never stops him using the app.
    @discardableResult
    func holdForApp(patience: TimeInterval = SyncLock.appPatience, retry: TimeInterval = 0.5) -> Hold {
        do {
            if try acquire(patience: patience) { return .held }
        } catch {
            Self.log.error("sync lock unavailable, the app carries on without it: \(String(describing: error), privacy: .public)")
            return .unavailable(String(describing: error))
        }
        Self.log.error("a bridge tick still held the sync lock after \(patience, privacy: .public) s; the app carries on and takes it once free")
        keepAsking(every: retry, on: DispatchQueue(label: "watch-collection.sync-lock", qos: .utility))
        return .late
    }

    private func keepAsking(every retry: TimeInterval, on queue: DispatchQueue) {
        queue.asyncAfter(deadline: .now() + retry) { [self] in
            raiseWant()
            do {
                if try tryLock() {
                    Self.log.notice("the app took the sync lock")
                } else {
                    keepAsking(every: retry, on: queue)
                }
            } catch {
                lowerWant()
                Self.log.error("sync lock unavailable, the app carries on without it: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// Leaves the want file and holds a lock on it. A probe that holds it at this moment makes this a no-op; the
    /// waiter's next round raises it again.
    private func raiseWant() {
        state.lock()
        defer { state.unlock() }
        guard descriptor < 0, wantDescriptor < 0 else { return }
        let fd = open(wantURL.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
        guard fd >= 0 else { return }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            return
        }
        wantDescriptor = fd
    }

    private func lowerWant() {
        state.lock()
        defer { state.unlock() }
        lowerWantLocked()
    }

    /// Removes the file before letting go of it, so no probe sees it unheld on the way out.
    private func lowerWantLocked() {
        guard wantDescriptor >= 0 else { return }
        unlink(wantURL.path)
        close(wantDescriptor)
        wantDescriptor = -1
    }
}
