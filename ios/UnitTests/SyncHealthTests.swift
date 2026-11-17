import XCTest
@testable import WatchCollection

final class SyncHealthTests: XCTestCase {
    private let tailscale = "http://100.105.187.11:8931"
    private let now = Date(timeIntervalSince1970: 1_794_000_000)

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Toronto")!
        return calendar
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    /// Conflicts as the Mac sends them, with ids "c0", "c1", and so on.
    private func conflicts(_ count: Int) -> [SyncConflict] {
        (0..<count).map { index in
            let json = #"{"id":"c\#(index)","path":["watches","w\#(index)","name"],"localDeleted":false,"remoteDeleted":false}"#
            return try! JSONDecoder().decode(SyncConflict.self, from: Data(json.utf8))
        }
    }

    private func health(
        enabled: Bool = true,
        address: String? = nil,
        conflicts count: Int = 0,
        resolutions: [String: String] = [:],
        failure: SyncFailure? = nil,
        lastSync: Date? = nil
    ) -> SyncHealth {
        SyncHealth.evaluate(
            enabled: enabled, address: address ?? tailscale, conflicts: conflicts(count), resolutions: resolutions,
            failure: failure, lastSync: lastSync, now: now
        )
    }

    // MARK: Classifying the error

    func testNoAnswerFromTheMacIsUnreachable() {
        let codes: [URLError.Code] = [.cannotConnectToHost, .timedOut, .networkConnectionLost, .cannotFindHost, .dnsLookupFailed]
        for code in codes {
            XCTAssertEqual(SyncFailure.classify(URLError(code)), .unreachable, "\(code)")
        }
    }

    func testNoConnectionAtAllIsOffline() {
        XCTAssertEqual(SyncFailure.classify(URLError(.notConnectedToInternet)), .offline)
        XCTAssertEqual(SyncFailure.classify(URLError(.dataNotAllowed)), .offline)
    }

    func testAnNSErrorFromTheURLDomainIsClassifiedLikeAURLError() {
        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)
        XCTAssertEqual(SyncFailure.classify(error), .unreachable)
    }

    func testAnAttemptCutShortIsNotAFailure() {
        XCTAssertNil(SyncFailure.classify(CancellationError()))
        XCTAssertNil(SyncFailure.classify(URLError(.cancelled)))
    }

    func testTheSyncErrorsOfTheClient() {
        XCTAssertEqual(SyncFailure.classify(CollectionSyncError.invalidAddress), .invalidAddress)
        XCTAssertEqual(SyncFailure.classify(CollectionSyncError.server("Busy")), .hub("Busy"))
        guard case .hub = SyncFailure.classify(CollectionSyncError.missingPhoto) else { return XCTFail("missing photo") }
        guard case .hub = SyncFailure.classify(URLError(.badServerResponse)) else { return XCTFail("bad response") }
    }

    func testAReplyThatCannotBeReadCameFromTheMac() {
        let error = DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "bad"))
        guard case .hub = SyncFailure.classify(error) else { return XCTFail() }
    }

    func testAnythingElseKeepsItsOwnWords() {
        struct Odd: LocalizedError { var errorDescription: String? { "Odd" } }
        XCTAssertEqual(SyncFailure.classify(Odd()), .other("Odd"))
    }

    // MARK: Healthy or not

    func testHealthyWhenTheLastAttemptWorked() {
        XCTAssertEqual(health(lastSync: now.addingTimeInterval(-40)), .healthy)
        // Hours since the last sync are not a problem by themselves: the phone was shut, and the attempt
        // that runs as it opens has not failed.
        XCTAssertEqual(health(lastSync: now.addingTimeInterval(-11 * 3600)), .healthy)
        XCTAssertEqual(health(lastSync: nil), .healthy)
    }

    func testAFailureSoonAfterAGoodSyncStaysQuiet() {
        XCTAssertEqual(health(failure: .unreachable, lastSync: now.addingTimeInterval(-60)), .healthy)
        XCTAssertEqual(health(failure: .unreachable, lastSync: now.addingTimeInterval(-179)), .healthy)
    }

    func testAFailureThreeMinutesAfterTheLastGoodSyncIsStale() {
        let last = now.addingTimeInterval(-180)
        XCTAssertEqual(health(failure: .unreachable, lastSync: last), .stale(.unreachable, since: last))
        let morning = now.addingTimeInterval(-11 * 3600)
        XCTAssertEqual(health(failure: .offline, lastSync: morning), .stale(.offline, since: morning))
    }

    func testAFailureWithNoSyncEverIsStaleAtOnce() {
        XCTAssertEqual(health(failure: .unreachable, lastSync: nil), .stale(.unreachable, since: nil))
    }

    func testAClockSetBackDoesNotRaiseTheNotice() {
        XCTAssertEqual(health(failure: .unreachable, lastSync: now.addingTimeInterval(600)), .healthy)
    }

    func testOffAndNoAddressComeBeforeEverythingElse() {
        XCTAssertEqual(health(enabled: false, conflicts: 2, failure: .unreachable), .off)
        XCTAssertEqual(health(address: "", failure: .unreachable), .noAddress)
        XCTAssertEqual(health(address: "  ", failure: .unreachable), .noAddress)
        XCTAssertEqual(health(enabled: false, address: ""), .off)
    }

    func testABadAddressDoesNotWaitOutTheThreeMinutes() {
        XCTAssertEqual(health(failure: .invalidAddress, lastSync: now.addingTimeInterval(-5)), .badAddress)
    }

    func testConflictsShowHoweverRecentTheLastSync() {
        XCTAssertEqual(health(conflicts: 3, lastSync: now.addingTimeInterval(-5)), .conflicts(3))
        XCTAssertEqual(health(conflicts: 1, failure: .unreachable, lastSync: nil), .conflicts(1))
    }

    func testOnlyConflictsWaitingForAChoiceAreCounted() {
        XCTAssertEqual(health(conflicts: 3, resolutions: ["c1": "local"], lastSync: now.addingTimeInterval(-5)), .conflicts(2))
        // A choice for a conflict the Mac no longer lists counts for nothing.
        XCTAssertEqual(health(conflicts: 2, resolutions: ["gone": "remote"]), .conflicts(2))
    }

    func testOnceEveryConflictHasAChoiceTheRealFailureShows() {
        let all = ["c0": "local", "c1": "remote"]
        let old = now.addingTimeInterval(-600)
        XCTAssertEqual(health(conflicts: 2, resolutions: all, failure: .unreachable, lastSync: old), .stale(.unreachable, since: old))
        XCTAssertEqual(health(conflicts: 2, resolutions: all, lastSync: old), .healthy)
        XCTAssertNotEqual(notice(health(conflicts: 2, resolutions: all, failure: .unreachable, lastSync: old))?.actionLabel, "Choose")
    }

    // MARK: When the failure is set and cleared

    func testAFailureOfThisSessionIsKept() {
        var log = SyncFailureLog()
        log.startSession()
        log.failed(URLError(.timedOut), in: log.session)
        XCTAssertEqual(log.failure, .unreachable)
    }

    func testComingToTheFrontClearsAnEarlierFailure() {
        var log = SyncFailureLog()
        // The overnight refresh, run while the phone was in the background, could not reach the Mac.
        log.failed(URLError(.timedOut), in: log.session)
        XCTAssertEqual(log.failure, .unreachable)
        log.startSession()
        XCTAssertNil(log.failure)
        // Nothing shows before an attempt of this visit fails, however old the last good sync.
        XCTAssertEqual(
            SyncHealth.evaluate(
                enabled: true, address: tailscale, conflicts: [], resolutions: [:],
                failure: log.failure, lastSync: now.addingTimeInterval(-11 * 3600), now: now
            ),
            .healthy
        )
    }

    func testAnAttemptStillRunningFromBeforeCannotBringTheFailureBack() {
        var log = SyncFailureLog()
        // An attempt begins (the connection monitor's, or the overnight refresh), then the phone comes to the front
        // while it runs; the timer's first attempt is turned away as a duplicate.
        let before = log.session
        log.startSession()
        log.failed(URLError(.cannotConnectToHost), in: before)
        XCTAssertNil(log.failure)
        // The next attempt is this visit's, and its failure shows.
        log.failed(URLError(.cannotConnectToHost), in: log.session)
        XCTAssertEqual(log.failure, .unreachable)
    }

    func testChangingTheSettingsStartsAgain() {
        var log = SyncFailureLog()
        log.failed(CollectionSyncError.invalidAddress, in: log.session)
        XCTAssertEqual(log.failure, .invalidAddress)
        let oldAddress = log.session
        log.startSession()
        XCTAssertNil(log.failure)
        log.failed(URLError(.timedOut), in: oldAddress)
        XCTAssertNil(log.failure)
    }

    func testReachingTheMacClearsTheFailure() {
        var log = SyncFailureLog()
        log.startSession()
        log.failed(URLError(.timedOut), in: log.session)
        XCTAssertEqual(log.failure, .unreachable)
        // The snapshot came back: the attempt may still run out of rounds without throwing, and the failure is gone.
        log.reachedMac()
        XCTAssertNil(log.failure)
        XCTAssertEqual(
            SyncHealth.evaluate(
                enabled: true, address: tailscale, conflicts: [], resolutions: [:],
                failure: log.failure, lastSync: now.addingTimeInterval(-600), now: now
            ),
            .healthy
        )
    }

    func testAnAttemptCutShortLeavesTheFailureAsItWas() {
        var log = SyncFailureLog()
        log.failed(URLError(.timedOut), in: log.session)
        log.failed(CancellationError(), in: log.session)
        log.failed(URLError(.cancelled), in: log.session)
        XCTAssertEqual(log.failure, .unreachable)
        log.reachedMac()
        log.failed(CancellationError(), in: log.session)
        XCTAssertNil(log.failure)
    }

    // MARK: Tailscale addresses

    func testTailscaleAddresses() {
        XCTAssertTrue(SyncHealth.isTailscale("http://100.105.187.11:8931"))
        XCTAssertTrue(SyncHealth.isTailscale("http://100.64.0.1:8931"))
        XCTAssertTrue(SyncHealth.isTailscale("http://100.127.255.254:8931"))
        XCTAssertTrue(SyncHealth.isTailscale("http://my-mac.tail1234.ts.net:8931"))
    }

    func testAMagicDNSShortNameIsTailscale() {
        XCTAssertTrue(SyncHealth.isTailscale("http://my-mac:8931"))
        XCTAssertTrue(SyncHealth.isTailscale("https://my-mac"))
        XCTAssertTrue(SyncHealth.isTailscale("http://My-Mac:8931"))
        XCTAssertTrue(SyncHealth.isTailscale("  http://studio:8931  "))
        // This device, not the Mac.
        XCTAssertFalse(SyncHealth.isTailscale("http://localhost:8931"))
        XCTAssertFalse(SyncHealth.isTailscale("http://localhost.:8931"))
    }

    func testTailscaleIPv6Addresses() {
        XCTAssertTrue(SyncHealth.isTailscale("http://[fd7a:115c:a1e0::1]:8931"))
        XCTAssertTrue(SyncHealth.isTailscale("http://[fd7a:115c:a1e0:ab12:4843:cd96:6258:b240]:8931"))
        XCTAssertTrue(SyncHealth.isTailscale("http://[FD7A:115C:A1E0:AB12::B240]:8931"))
        XCTAssertTrue(SyncHealth.isTailscale("http://[fd7a:115c:a1e0:0000::1]"))
        XCTAssertTrue(SyncHealth.isTailscale("http://[fd7a:115c:a1e0:ffff:ffff:ffff:ffff:ffff]:8931"))
    }

    func testOtherIPv6AddressesAreNotTailscale() {
        // The /48 ends at the third group.
        XCTAssertFalse(SyncHealth.isTailscale("http://[fd7a:115c:a1e1::1]:8931"))
        XCTAssertFalse(SyncHealth.isTailscale("http://[fd7a:115c::1]:8931"))
        XCTAssertFalse(SyncHealth.isTailscale("http://[fd7b:115c:a1e0::1]:8931"))
        XCTAssertFalse(SyncHealth.isTailscale("http://[::1]:8931"))
        XCTAssertFalse(SyncHealth.isTailscale("http://[fe80::1]:8931"))
        XCTAssertFalse(SyncHealth.isTailscale("http://[2001:db8::1]:8931"))
        // Not a URL with an IPv6 host at all.
        XCTAssertFalse(SyncHealth.isTailscale("http://fd7a:115c:a1e0::1:8931"))
    }

    func testAFullyQualifiedNameWithItsTrailingDot() {
        XCTAssertTrue(SyncHealth.isTailscale("http://my-mac.tail1234.ts.net.:8931"))
        XCTAssertTrue(SyncHealth.isTailscale("http://100.64.0.1.:8931"))
        XCTAssertFalse(SyncHealth.isTailscale("http://my-mac.local.:8931"))
        XCTAssertFalse(SyncHealth.isTailscale("http://ts.net:8931"))
    }

    func testOtherAddressesAreNotTailscale() {
        XCTAssertFalse(SyncHealth.isTailscale("http://100.63.0.1:8931"))
        XCTAssertFalse(SyncHealth.isTailscale("http://100.128.0.1:8931"))
        XCTAssertFalse(SyncHealth.isTailscale("http://192.168.1.20:8931"))
        XCTAssertFalse(SyncHealth.isTailscale("http://127.0.0.1:8931"))
        XCTAssertFalse(SyncHealth.isTailscale("http://my-mac.local:8931"))
        XCTAssertFalse(SyncHealth.isTailscale("http://100.64.1:8931"))
        XCTAssertFalse(SyncHealth.isTailscale("http://100.64.0.1.5:8931"))
        XCTAssertFalse(SyncHealth.isTailscale("http://99.64.0.1:8931"))
        XCTAssertFalse(SyncHealth.isTailscale("http://my-mac.example.com:8931"))
        XCTAssertFalse(SyncHealth.isTailscale(""))
        XCTAssertFalse(SyncHealth.isTailscale("not an address"))
    }

    // MARK: The words

    /// The notice in US English, Toronto time. The system sets a narrow no-break space before AM and PM; the
    /// tests read it as a plain space.
    private func notice(_ health: SyncHealth, address: String? = nil, now: Date? = nil) -> SyncNotice? {
        guard var shown = health.notice(
            address: address ?? tailscale, device: "iPhone", now: now ?? self.now,
            calendar: calendar, locale: Locale(identifier: "en_US")
        ) else { return nil }
        let plain = shown.message.replacingOccurrences(of: "\u{202F}", with: " ").replacingOccurrences(of: "\u{00A0}", with: " ")
        shown.message = plain
        return shown
    }

    func testHealthySaysNothing() {
        XCTAssertNil(notice(.healthy))
    }

    func testUnreachableOverTailscaleNamesTailscaleAndTheMac() {
        let evening = date(2026, 11, 16, 21, 30)
        let shown = notice(.stale(.unreachable, since: date(2026, 11, 16, 10, 22)), now: evening)
        XCTAssertEqual(shown?.headline, "Can't reach your Mac")
        XCTAssertEqual(shown?.message, "Last synced at 10:22 AM. Turn on Tailscale on this iPhone and check your Mac is awake.")
        XCTAssertEqual(shown?.action, .retry)
        XCTAssertEqual(shown?.actionLabel, "Try again")
        XCTAssertEqual(shown?.urgent, true)
    }

    func testUnreachableOnTheLocalNetworkDoesNotMentionTailscale() {
        let shown = notice(.stale(.unreachable, since: nil), address: "http://192.168.1.20:8931")
        XCTAssertEqual(shown?.message, "Not synced with your Mac yet. Check your Mac is awake and on the same network as this iPhone.")
    }

    func testOfflineAndUnfinishedSyncs() {
        let evening = date(2026, 11, 16, 21, 30)
        let offline = notice(.stale(.offline, since: date(2026, 11, 15, 18, 5)), now: evening)
        XCTAssertEqual(offline?.headline, "iPhone is offline")
        XCTAssertEqual(offline?.message, "Last synced yesterday at 6:05 PM. Sync picks up again when this iPhone is back online.")
        let hub = notice(.stale(.hub("503"), since: date(2026, 11, 2, 9, 0)), now: evening)
        XCTAssertEqual(hub?.headline, "Sync did not finish")
        XCTAssertEqual(hub?.message, "Last synced on Nov 2. Your Mac answered but could not finish. It will keep trying.")
        XCTAssertEqual(notice(.stale(.other("x"), since: nil))?.message, "Not synced with your Mac yet. It will keep trying.")
    }

    func testConflictsOpenSettings() {
        let one = notice(.conflicts(1))
        XCTAssertEqual(one?.headline, "Sync paused")
        XCTAssertEqual(one?.message, "1 change was made on both devices. Choose which one to keep.")
        XCTAssertEqual(one?.action, .settings)
        XCTAssertEqual(one?.actionLabel, "Choose")
        XCTAssertEqual(notice(.conflicts(3))?.message, "3 changes were made on both devices. Choose which to keep.")
    }

    func testOffAndNotSetUpAreQuietAndOpenSettings() {
        let off = notice(.off)
        XCTAssertEqual(off?.headline, "Sync is off")
        XCTAssertEqual(off?.message, "Changes stay on this iPhone until you turn sync on.")
        XCTAssertEqual(off?.urgent, false)
        XCTAssertEqual(off?.action, .settings)
        let none = notice(.noAddress)
        XCTAssertEqual(none?.headline, "Sync not set up")
        XCTAssertEqual(none?.message, "Add your Mac's address to share changes with it.")
        XCTAssertEqual(none?.urgent, false)
        XCTAssertEqual(notice(.badAddress)?.action, .settings)
        XCTAssertEqual(notice(.badAddress)?.urgent, true)
    }

    /// The client takes any port and https too, so the sentence shows the usual address without demanding it.
    func testABadAddressShowsWhatOneLooksLike() {
        let shown = notice(.badAddress)
        XCTAssertEqual(shown?.headline, "Sync not set up")
        XCTAssertEqual(shown?.message, "The Mac's address should look like http://your-mac:8931.")
    }

    /// The app's copy rules: no em-dashes, and the watchmaker is never named.
    func testCopyRules() {
        let all: [SyncHealth] = [
            .off, .noAddress, .badAddress, .conflicts(1), .conflicts(4),
            .stale(.offline, since: nil), .stale(.unreachable, since: now), .stale(.hub("x"), since: now),
            .stale(.other("x"), since: nil),
        ]
        for health in all {
            for address in [tailscale, "http://192.168.1.20:8931"] {
                guard let shown = notice(health, address: address) else { return XCTFail("\(health)") }
                checkCopyRules("\(shown.headline) \(shown.message) \(shown.actionLabel)")
                XCTAssertFalse(shown.headline.isEmpty || shown.message.isEmpty || shown.actionLabel.isEmpty)
            }
        }
    }

    private func checkCopyRules(_ words: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(words.contains("\u{2014}"), words, file: file, line: line)
        XCTAssertFalse(words.contains("\u{2013}"), words, file: file, line: line)
        XCTAssertFalse(words.localizedCaseInsensitiveContains("rolex"), words, file: file, line: line)
        XCTAssertFalse(words.unicodeScalars.contains { $0.properties.isEmojiPresentation }, words, file: file, line: line)
    }
}

// MARK: iCloud (docs/icloud-plan.md section 7)

extension SyncHealthTests {
    private func cloud(_ wait: CloudWait? = nil, role: CloudRole = .phone, active: SyncLinkKind = .cloud,
                       otherConflicts: Int = 0) -> CloudDisplay {
        CloudDisplay(role: role, active: active, joined: active == .cloud, preferHub: false, wait: wait,
                     lastSync: now.addingTimeInterval(-120), macHubAt: nil, otherConflicts: otherConflicts)
    }

    private func cloudHealth(_ display: CloudDisplay, address: String = "", conflicts count: Int = 0,
                             failure: SyncFailure? = nil, lastSync: Date? = nil, enabled: Bool = true) -> SyncHealth {
        SyncHealth.evaluate(enabled: enabled, address: address, conflicts: conflicts(count), resolutions: [:],
                            failure: failure, lastSync: lastSync, now: now, cloud: display)
    }

    private func plain(_ text: String?) -> String? {
        text?.replacingOccurrences(of: "\u{202F}", with: " ").replacingOccurrences(of: "\u{00A0}", with: " ")
    }

    /// Every line of section 7, word for word.
    func testTheICloudLinesReadAsSectionSevenHasThem() {
        XCTAssertEqual(CloudSyncCopy.carrier(device: "iPhone"), "Syncs with your Mac through iCloud.")
        XCTAssertEqual(CloudSyncCopy.lastSynced(now.addingTimeInterval(-120), now: now), "Last synced 2 min ago")
        XCTAssertNil(CloudSyncCopy.lastSynced(nil, now: now))
        XCTAssertEqual(CloudSyncCopy.phoneSeen(now.addingTimeInterval(-120), now: now), "iPhone, 2 min ago")
        XCTAssertEqual(CloudSyncCopy.sending(120, of: 260), "Sending 120 of 260 photos to iCloud.")
        XCTAssertEqual(CloudSyncCopy.signedOut(device: "iPhone"), "Sign in to iCloud to sync with your Mac.")
        XCTAssertEqual(CloudSyncCopy.full(device: "iPhone"), "iCloud storage is full, so changes stay on this iPhone.")
        XCTAssertEqual(CloudSyncCopy.choiceWaiting(1, device: "iPhone"), "1 change needs your choice on your Mac.")
        XCTAssertEqual(CloudSyncCopy.choiceWaiting(3, device: "iPhone"), "3 changes need your choice on your Mac.")
        XCTAssertEqual(CloudSyncCopy.newerFormat(device: "iPhone"), "Update Watch Collection on this iPhone to keep syncing.")
        XCTAssertEqual(CloudSyncCopy.erased(device: "Mac"), "The iCloud copy was erased. Nothing on this Mac was removed.")
        XCTAssertEqual(CloudSyncCopy.erased(device: "iPhone"),
                       "The iCloud copy was erased. Nothing on this iPhone was removed. Open Watch Collection on your Mac to start iCloud sync again.")
        XCTAssertEqual(CloudSyncCopy.restartButton, "Sync through iCloud again")
        // The Mac's own lines name the phone.
        XCTAssertEqual(CloudSyncCopy.signedOut(device: "Mac"), "Sign in to iCloud to sync with your iPhone.")
        XCTAssertEqual(CloudSyncCopy.choiceWaiting(1, device: "Mac"), "1 change needs your choice on your iPhone.")
    }

    /// `status-mac.hubAt`, as plain information: a time today, "yesterday at", else the day.
    func testTheMacsLibraryCheckInIsATimeNotAWarning() {
        let locale = Locale(identifier: "en_US")
        XCTAssertEqual(plain(CloudSyncCopy.macCheckedIn(date(2026, 11, 6, 9, 41), now: now, calendar: calendar, locale: locale)),
                       "Mac's library checked in 9:41 AM")
        XCTAssertEqual(plain(CloudSyncCopy.macCheckedIn(date(2026, 11, 5, 21, 41), now: now, calendar: calendar, locale: locale)),
                       "Mac's library checked in yesterday at 9:41 PM")
        XCTAssertEqual(plain(CloudSyncCopy.macCheckedIn(date(2026, 11, 3, 21, 41), now: now, calendar: calendar, locale: locale)),
                       "Mac's library checked in on Nov 3")
        XCTAssertNil(CloudSyncCopy.macCheckedIn(nil, now: now, calendar: calendar, locale: locale))
    }

    func testAgoReadsInPlainUnits() {
        XCTAssertEqual(CloudSyncCopy.ago(now.addingTimeInterval(-30), now: now), "just now")
        XCTAssertEqual(CloudSyncCopy.ago(now.addingTimeInterval(30), now: now), "just now", "a clock set back")
        XCTAssertEqual(CloudSyncCopy.ago(now.addingTimeInterval(-59 * 60), now: now), "59 min ago")
        XCTAssertEqual(CloudSyncCopy.ago(now.addingTimeInterval(-3 * 3600 - 59), now: now), "3 hr ago")
        XCTAssertEqual(CloudSyncCopy.ago(now.addingTimeInterval(-25 * 3600), now: now), "1 day ago")
        XCTAssertEqual(CloudSyncCopy.ago(now.addingTimeInterval(-3 * 86400), now: now), "3 days ago")
    }

    /// The sync line's sentence for each state of the link; a pause the next tick deals with says nothing.
    func testTheSyncLineSaysOneSentencePerState() {
        XCTAssertEqual(CloudSyncCopy.sentence(cloud(.noAccount), device: "iPhone"), "Sign in to iCloud to sync with your Mac.")
        XCTAssertEqual(CloudSyncCopy.sentence(cloud(.full), device: "iPhone"), "iCloud storage is full, so changes stay on this iPhone.")
        XCTAssertEqual(CloudSyncCopy.sentence(cloud(.newerFormat), device: "iPhone"),
                       "Update Watch Collection on this iPhone to keep syncing.")
        XCTAssertEqual(CloudSyncCopy.sentence(cloud(.erased, role: .mac, active: .hub), device: "Mac"),
                       "The iCloud copy was erased. Nothing on this Mac was removed.")
        XCTAssertEqual(CloudSyncCopy.sentence(cloud(.sendingPhotos(done: 120, of: 260), role: .mac, active: .hub), device: "Mac"),
                       "Sending 120 of 260 photos to iCloud.")
        XCTAssertEqual(CloudSyncCopy.sentence(cloud(.needsHubFirst, role: .mac, active: .hub), device: "Mac"),
                       "iCloud sync starts once this Mac reaches its library.")
        XCTAssertEqual(CloudSyncCopy.sentence(cloud(otherConflicts: 1), device: "iPhone"), "1 change needs your choice on your Mac.")
        for quiet: CloudWait? in [nil, .noDocument, .offline, .busy, .failed("x")] {
            XCTAssertNil(CloudSyncCopy.sentence(cloud(quiet), device: "iPhone"), "\(String(describing: quiet))")
        }
    }

    /// Once iCloud carries the phone, the notice speaks for it: the hub's address means nothing.
    func testTheNoticeSpeaksForICloudWhenItCarriesThePhone() {
        XCTAssertEqual(cloudHealth(cloud(), address: ""), .healthy, "no address is not a problem")
        XCTAssertEqual(cloudHealth(cloud(), address: "not an address"), .healthy)
        XCTAssertEqual(cloudHealth(cloud(.erased)), .cloudErased)
        XCTAssertEqual(cloudHealth(cloud(.newerFormat)), .cloudNewerFormat)
        XCTAssertEqual(cloudHealth(cloud(.noAccount)), .cloudSignedOut)
        XCTAssertEqual(cloudHealth(cloud(.full)), .cloudFull)
        XCTAssertEqual(cloudHealth(cloud(otherConflicts: 2)), .choiceOnOtherDevice(2))
        XCTAssertEqual(cloudHealth(cloud(.sendingPhotos(done: 1, of: 2))), .healthy)
        // Order: off, then this device's own choices, then the link's state.
        XCTAssertEqual(cloudHealth(cloud(.erased), enabled: false), .off)
        XCTAssertEqual(cloudHealth(cloud(.erased), conflicts: 2), .conflicts(2))
        XCTAssertEqual(cloudHealth(cloud(.erased, otherConflicts: 1)), .cloudErased)
        XCTAssertEqual(cloudHealth(cloud(.full, otherConflicts: 1)), .cloudFull)
        // A quiet failure shows only after the usual three minutes.
        XCTAssertEqual(cloudHealth(cloud(.offline), failure: .offline, lastSync: now.addingTimeInterval(-60)), .healthy)
        XCTAssertEqual(cloudHealth(cloud(.offline), failure: .offline, lastSync: now.addingTimeInterval(-3600)),
                       .stale(.offline, since: now.addingTimeInterval(-3600)))
    }

    /// The Mac, and a phone the hub still carries: the hub's rules, unchanged, whatever iCloud is doing.
    func testTheHubsRulesStandWhereTheHubCarriesTheScreens() {
        for display in [cloud(.erased, role: .mac, active: .hub), cloud(.full, role: .phone, active: .hub)] {
            XCTAssertEqual(cloudHealth(display, address: ""), .noAddress)
            XCTAssertEqual(cloudHealth(display, address: tailscale), .healthy)
            XCTAssertEqual(cloudHealth(display, address: tailscale, failure: .invalidAddress), .badAddress)
            XCTAssertEqual(cloudHealth(display, address: tailscale, conflicts: 1), .conflicts(1))
        }
    }

    func testTheICloudNotices() {
        let signedOut = notice(.cloudSignedOut)
        XCTAssertEqual(signedOut?.headline, "Signed out of iCloud")
        XCTAssertEqual(signedOut?.message, "Sign in to iCloud to sync with your Mac.")
        XCTAssertEqual(signedOut?.action, .retry)
        XCTAssertEqual(signedOut?.actionLabel, "Try again")

        let expected: [(SyncHealth, String, String)] = [
            (.cloudFull, "iCloud is full", "iCloud storage is full, so changes stay on this iPhone."),
            (.choiceOnOtherDevice(1), "Choice waiting", "1 change needs your choice on your Mac."),
            (.choiceOnOtherDevice(4), "Choice waiting", "4 changes need your choice on your Mac."),
            (.cloudNewerFormat, "Update needed", "Update Watch Collection on this iPhone to keep syncing."),
            (.cloudErased, "iCloud copy erased",
             "The iCloud copy was erased. Nothing on this iPhone was removed. Open Watch Collection on your Mac to start iCloud sync again."),
        ]
        for (health, headline, message) in expected {
            let shown = notice(health)
            XCTAssertEqual(shown?.headline, headline)
            XCTAssertEqual(shown?.message, message)
            XCTAssertNil(shown?.action, "nothing to do on this iPhone: no pill")
            XCTAssertEqual(shown?.urgent, true)
        }
    }

    func testTheICloudCopyKeepsTheCopyRules() {
        let health: [SyncHealth] = [.cloudSignedOut, .cloudFull, .choiceOnOtherDevice(1), .choiceOnOtherDevice(3),
                                    .cloudNewerFormat, .cloudErased]
        var words = health.compactMap { notice($0) }.map { "\($0.headline) \($0.message) \($0.actionLabel)" }
        XCTAssertEqual(words.count, health.count)
        for device in ["iPhone", "Mac"] {
            words += [CloudSyncCopy.carrier(device: device), CloudSyncCopy.erased(device: device),
                      CloudSyncCopy.signedOut(device: device), CloudSyncCopy.full(device: device),
                      CloudSyncCopy.newerFormat(device: device), CloudSyncCopy.choiceWaiting(2, device: device)]
        }
        words += [CloudSyncCopy.restartButton, CloudSyncCopy.needsHubFirst, CloudSyncCopy.sending(1, of: 2),
                  "Sync directly with the Mac instead", "Waiting for your collection from iCloud\u{2026}"]
        for line in words { checkCopyRules(line) }
    }
}
