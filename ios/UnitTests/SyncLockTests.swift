import XCTest
@testable import WatchCollection

/// The lock between the Mac app and its headless bridge (docs/icloud-plan.md section 11 P5).
final class SyncLockTests: XCTestCase {
    private var folder: URL!
    private var url: URL { folder.appendingPathComponent("WatchCollection/sync.lock") }

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("SyncLockTests-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        if let savedArguments {
            UserDefaults.standard.setVolatileDomain(savedArguments, forName: UserDefaults.argumentDomain)
            self.savedArguments = nil
        }
        try? FileManager.default.removeItem(at: folder)
    }

    /// The launch arguments as they were before `useOwnDataRoot`, put back in teardown.
    private var savedArguments: [String: Any]?

    /// A holder that polls `isWanted`, as the bridge does between steps, and steps aside when it reads true.
    private func pollForWant(_ holder: SyncLock, every interval: TimeInterval = 0.02, gaveUp: XCTestExpectation) {
        DispatchQueue.global().async {
            let deadline = Date().addingTimeInterval(5)
            while Date() < deadline {
                if holder.isWanted {
                    holder.unlock()
                    gaveUp.fulfill()
                    return
                }
                Thread.sleep(forTimeInterval: interval)
            }
        }
    }

    // MARK: The plan's three

    func testLockTakenTwiceInOneProcessFailsTheSecondTimeWithoutBlocking() throws {
        let first = SyncLock(url: url)
        let second = SyncLock(url: url)
        XCTAssertTrue(try first.tryLock())
        let start = Date()
        XCTAssertFalse(try second.tryLock())
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.5)
        XCTAssertTrue(first.isHeld)
        XCTAssertFalse(second.isHeld)
        // Asking again from the holder is not a second taking.
        XCTAssertTrue(try first.tryLock())
    }

    func testReleasedOnClose() throws {
        let first = SyncLock(url: url)
        XCTAssertTrue(try first.tryLock())
        first.unlock()
        XCTAssertFalse(first.isHeld)
        let second = SyncLock(url: url)
        XCTAssertTrue(try second.tryLock())
        second.unlock()

        // A lock that goes away closes its file, which releases it.
        do {
            let scoped = SyncLock(url: url)
            XCTAssertTrue(try scoped.tryLock())
        }
        XCTAssertTrue(try SyncLock(url: url).tryLock())
    }

    func testWantMakesAHolderThatPollsItGiveUp() throws {
        let holder = SyncLock(url: url)
        XCTAssertTrue(try holder.tryLock())
        XCTAssertFalse(holder.isWanted)
        let gaveUp = expectation(description: "the holder stepped aside")
        pollForWant(holder, gaveUp: gaveUp)

        let waiter = SyncLock(url: url)
        let start = Date()
        XCTAssertTrue(try waiter.acquire(patience: 5))
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
        wait(for: [gaveUp], timeout: 1)
        XCTAssertTrue(waiter.isHeld)
        // Once it has the lock the waiter takes its want down.
        XCTAssertFalse(FileManager.default.fileExists(atPath: waiter.wantURL.path))
        XCTAssertFalse(holder.isWanted)
    }

    // MARK: The want

    func testAWaiterThatRunsOutOfPatienceStaysWantedUntilItLetsGo() throws {
        let holder = SyncLock(url: url)
        XCTAssertTrue(try holder.tryLock())
        let waiter = SyncLock(url: url)
        let start = Date()
        XCTAssertFalse(try waiter.acquire(patience: 0.2))
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
        XCTAssertTrue(holder.isWanted)
        waiter.unlock()
        XCTAssertFalse(holder.isWanted)
    }

    func testAWantFileLeftByAWaiterThatEndedIsNotAWant() throws {
        let holder = SyncLock(url: url)
        XCTAssertTrue(try holder.tryLock())
        // What a waiter that crashed leaves: the file, with nobody holding it.
        FileManager.default.createFile(atPath: holder.wantURL.path, contents: Data())
        XCTAssertFalse(holder.isWanted)
        // Reading it changes nothing, and a new waiter raises it again over the old file.
        XCTAssertFalse(holder.isWanted)
        let waiter = SyncLock(url: url)
        XCTAssertFalse(try waiter.acquire(patience: 0.1))
        XCTAssertTrue(holder.isWanted)
    }

    // MARK: The app (docs/icloud-fixes.md D9)

    func testTheAppTakesAFreeLockAtOnce() async throws {
        let app = SyncLock(url: url)
        XCTAssertEqual(app.holdForApp(), .held)
        XCTAssertTrue(app.isHeld)
        XCTAssertFalse(try SyncLock(url: url).tryLock())
        let ready = await app.whenReady()
        XCTAssertEqual(ready, .held)
    }

    func testTheAppAsksAgainEveryHalfSecond() {
        XCTAssertEqual(SyncLock.appRetry, 0.5)
    }

    func testTheAppCarriesOnWhenTheLockFileCannotBeOpened() async throws {
        // A file where the folder should be: neither the folder nor the lock can be made.
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let blocked = folder.appendingPathComponent("WatchCollection")
        FileManager.default.createFile(atPath: blocked.path, contents: Data("not a folder".utf8))
        let app = SyncLock(url: url)
        let start = Date()
        guard case .unavailable = app.holdForApp() else { return XCTFail("expected .unavailable") }
        XCTAssertLessThan(Date().timeIntervalSince(start), 1)
        XCTAssertFalse(app.isHeld)
        // The library opens at once, without the lock.
        guard case .unavailable = await app.whenReady() else { return XCTFail("expected .unavailable") }
    }

    /// The `.late` path is gone: while a tick has the lock the app never opens the library, however long it takes,
    /// keeps its want up the whole time, and opens it as soon as the lock is its.
    func testTheAppNeverOpensTheLibraryWithoutTheLock() throws {
        let bridge = SyncLock(url: url)
        XCTAssertTrue(try bridge.tryLock())
        let app = SyncLock(url: url)
        let start = Date()
        XCTAssertEqual(app.holdForApp(retry: 0.05), .waiting)
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.5, "the window is not held up")
        let hold = HoldBox()
        Task { hold.value = await app.whenReady() }
        // Past the old 5 s patience, after which the old code opened the library anyway.
        Thread.sleep(forTimeInterval: 6)
        XCTAssertNil(hold.value, "the library stays closed while the tick has the lock")
        XCTAssertFalse(app.isHeld)
        XCTAssertTrue(bridge.isWanted, "still asking: a tick that starts now leaves at once")
        // A new tick in the meantime reads the want and leaves.
        bridge.unlock()
        let newTick = SyncLock(url: url)
        if try newTick.tryLock() {
            XCTAssertTrue(newTick.isWanted)
            newTick.unlock()
        }
        let deadline = Date().addingTimeInterval(3)
        while hold.value == nil, Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        XCTAssertEqual(hold.value, .held)
        XCTAssertTrue(app.isHeld)
        XCTAssertFalse(FileManager.default.fileExists(atPath: app.wantURL.path))
        XCTAssertFalse(try SyncLock(url: url).tryLock())
    }

    /// Everyone waiting goes on together, and a late caller returns at once.
    func testEveryWaiterOpensOnceTheLockIsHeld() throws {
        let bridge = SyncLock(url: url)
        XCTAssertTrue(try bridge.tryLock())
        let app = SyncLock(url: url)
        XCTAssertEqual(app.holdForApp(retry: 0.05), .waiting)
        let both = expectation(description: "both opened")
        both.expectedFulfillmentCount = 2
        for _ in 0..<2 {
            Task {
                if await app.whenReady() == .held { both.fulfill() }
            }
        }
        Thread.sleep(forTimeInterval: 0.2)
        bridge.unlock()
        wait(for: [both], timeout: 3)
        let late = expectation(description: "a late caller")
        Task {
            if await app.whenReady() == .held { late.fulfill() }
        }
        wait(for: [late], timeout: 1)
    }

    /// The lock file goes while the app waits: it carries on without it, as it does when it cannot open it at launch.
    func testTheAppCarriesOnIfTheLockFileGoesWhileItWaits() throws {
        let bridge = SyncLock(url: url)
        XCTAssertTrue(try bridge.tryLock())
        let app = SyncLock(url: url)
        XCTAssertEqual(app.holdForApp(retry: 0.05), .waiting)
        let opened = expectation(description: "the library opened")
        let hold = HoldBox()
        Task {
            hold.value = await app.whenReady()
            opened.fulfill()
        }
        let lockFolder = url.deletingLastPathComponent()
        try FileManager.default.removeItem(at: lockFolder)
        FileManager.default.createFile(atPath: lockFolder.path, contents: Data("not a folder".utf8))
        wait(for: [opened], timeout: 3)
        guard case .unavailable? = hold.value else { return XCTFail("expected .unavailable, got \(String(describing: hold.value))") }
        XCTAssertFalse(app.isHeld)
        bridge.unlock()
    }

    // MARK: The store holds the gate (polish 2 item 16)

    /// While a bridge tick has the library, `start()` reads nothing: no `sync.json`, no collection shown. Once the
    /// tick lets go, the same call loads it.
    @MainActor
    func testTheStoreReadsNothingUntilItHoldsTheLibrary() async throws {
        try useOwnDataRoot()
        try SyncDisk.save(SyncCheckpoint(data: sample, base: nil, server: Self.deadHub, lastSuccess: nil))
        let bridge = SyncLock(url: SyncLock.appURL)
        XCTAssertTrue(try bridge.tryLock())
        let app = SyncLock(url: SyncLock.appURL)
        defer { app.unlock() }
        XCTAssertEqual(app.holdForApp(retry: 0.02), .waiting)
        let store = AppStore(library: app)
        let starting = Task { @MainActor in await store.start() }

        try await waitUntil { app.asks >= 20 }
        XCTAssertFalse(store.hasStarted)
        XCTAssertNil(store.data)
        bridge.unlock()
        await starting.value
        XCTAssertTrue(app.isHeld)
        XCTAssertTrue(store.hasStarted)
        XCTAssertEqual(store.data?.watches.map(\.id), ["w1", "w2"])
        try await waitForQuiet(store)
    }

    /// A restore writes the library, so it waits for the same lock (and then for the store's own load).
    @MainActor
    func testARestoreWaitsForTheLibraryToo() async throws {
        try useOwnDataRoot()
        try SyncDisk.save(SyncCheckpoint(data: sample, base: nil, server: Self.deadHub, lastSuccess: nil))
        let before = try Data(contentsOf: SyncDisk.url)
        let bridge = SyncLock(url: SyncLock.appURL)
        XCTAssertTrue(try bridge.tryLock())
        let app = SyncLock(url: SyncLock.appURL)
        defer { app.unlock() }
        XCTAssertEqual(app.holdForApp(retry: 0.02), .waiting)
        let store = AppStore(library: app)
        var restored = sample
        restored.watches.append(watch("w9", "Restored"))
        let imported = CollectionImport(data: restored, photos: [], sourceName: "test", includesPhotoArchive: false)
        let restoring = Task { @MainActor in await store.restore(imported) }

        try await waitUntil { app.asks >= 20 }
        XCTAssertEqual(try Data(contentsOf: SyncDisk.url), before, "nothing written while the tick has the library")
        XCTAssertFalse(store.hasStarted)
        bridge.unlock()
        let done = await restoring.value
        XCTAssertTrue(done)
        XCTAssertEqual(SyncDisk.load()?.data.watches.map(\.id), ["w1", "w2", "w9"], "the restore is in")
        try await waitForQuiet(store)
    }

    // MARK: Fixtures

    /// A hub address nothing listens on (never the real hub).
    private static let deadHub = "http://127.0.0.1:9"

    /// Points the app's folders at a data root inside this test's folder, with a hub nothing answers on, through
    /// the `-WCDataRoot` and `-WCHub` launch arguments; teardown puts them back.
    @MainActor
    private func useOwnDataRoot() throws {
        let root = folder.appendingPathComponent("root", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let defaults = UserDefaults.standard
        let saved = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        savedArguments = saved
        defaults.setVolatileDomain(saved.merging(["WCDataRoot": root.path, "WCHub": Self.deadHub]) { $1 },
                                   forName: UserDefaults.argumentDomain)
        XCTAssertEqual(AppPaths.collectionFolder.standardizedFileURL.path,
                       root.appendingPathComponent("WatchCollection").standardizedFileURL.path)
        XCTAssertEqual(AppStore.initialSyncAddress, Self.deadHub)
    }

    @MainActor
    private func waitUntil(timeout: TimeInterval = 10, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { return XCTFail("timed out") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    /// The sync a restore starts runs out before teardown puts the folders back.
    @MainActor
    private func waitForQuiet(_ store: AppStore) async throws {
        try await Task.sleep(for: .milliseconds(100))
        try await waitUntil { !store.status.isSyncing }
    }

    private var sample: CollectionData {
        CollectionData(
            settings: CollectionSettings(autoBackup: false, backupRemote: nil, autoImage: true,
                                         wrist: WristProfile(inches: 6.75, sweetSpotMin: 38, sweetSpotMax: 41, perfect: 39, lugMax: 48)),
            watches: [watch("w1", "Alpha"), watch("w2", "Bravo")],
            categories: ["Dive"], wishlist: [], brandWatchlist: [], dialColors: ["Black"], materials: ["Steel"]
        )
    }

    private func watch(_ id: String, _ name: String) -> Watch {
        Watch(id: id, name: name, story: "", purchasedText: "", price: 100, status: "owned", statusNote: "", photos: [])
    }
}

/// Carries a hold out of a task, for the tests.
private final class HoldBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: SyncLock.Hold?
    var value: SyncLock.Hold? {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}
