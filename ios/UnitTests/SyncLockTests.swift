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
        try? FileManager.default.removeItem(at: folder)
    }

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

    // MARK: The app

    func testTheAppTakesAFreeLockAtOnce() throws {
        let app = SyncLock(url: url)
        XCTAssertEqual(app.holdForApp(patience: 1), .held)
        XCTAssertTrue(app.isHeld)
        XCTAssertFalse(try SyncLock(url: url).tryLock())
    }

    func testTheAppCarriesOnWhenTheLockFileCannotBeOpened() throws {
        // A file where the folder should be: neither the folder nor the lock can be made.
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let blocked = folder.appendingPathComponent("WatchCollection")
        FileManager.default.createFile(atPath: blocked.path, contents: Data("not a folder".utf8))
        let app = SyncLock(url: url)
        let start = Date()
        guard case .unavailable = app.holdForApp(patience: 5) else { return XCTFail("expected .unavailable") }
        XCTAssertLessThan(Date().timeIntervalSince(start), 1)
        XCTAssertFalse(app.isHeld)
    }

    func testTheAppCarriesOnPastItsPatienceAndTakesTheLockOnceFree() throws {
        let bridge = SyncLock(url: url)
        XCTAssertTrue(try bridge.tryLock())
        let app = SyncLock(url: url)
        XCTAssertEqual(app.holdForApp(patience: 0.2, retry: 0.05), .late)
        XCTAssertFalse(app.isHeld)
        // Still asking: a bridge tick that gets in now reads the want and leaves.
        XCTAssertTrue(bridge.isWanted)
        bridge.unlock()
        let deadline = Date().addingTimeInterval(3)
        while !app.isHeld, Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        XCTAssertTrue(app.isHeld)
        XCTAssertFalse(FileManager.default.fileExists(atPath: app.wantURL.path))
        XCTAssertFalse(try SyncLock(url: url).tryLock())
    }
}
