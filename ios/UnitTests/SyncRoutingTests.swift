import XCTest
@testable import WatchCollection

/// P4's wiring rules (docs/icloud-plan.md sections 1, 3, 4, 5 and 9), apart from `AppStore` so each is driven
/// directly: which link a tick runs (`SyncRoute`), `contentVersion` (`SyncVersions`), answers going back to the link
/// that asked (`SyncConflictSet`), and the caller's side of a cloud pass (`CloudSyncSession`) on the fake iCloud.
@MainActor
final class SyncRoutingTests: XCTestCase {
    private var root: URL!
    private var clock: TestClock!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("SyncRoutingTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        clock = TestClock()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: Which link runs

    func testRoutingForEveryCombination() {
        for joined in [false, true] {
            for preferHub in [false, true] {
                // No iCloud link on this device: today's hub sync, whatever else is set.
                XCTAssertEqual(SyncRoute.plan(role: .phone, cloudLink: false, joined: joined, preferHub: preferHub), .hubOnly)
                XCTAssertEqual(SyncRoute.plan(role: .mac, cloudLink: false, joined: joined, preferHub: preferHub), .hubOnly)
                // The Mac is the bridge: both links, the hub first. The phone's flags mean nothing there.
                XCTAssertEqual(SyncRoute.plan(role: .mac, cloudLink: true, joined: joined, preferHub: preferHub), .hubThenCloud)
            }
        }
        XCTAssertEqual(SyncRoute.plan(role: .phone, cloudLink: true, joined: false, preferHub: false), .cloudElseHub)
        XCTAssertEqual(SyncRoute.plan(role: .phone, cloudLink: true, joined: true, preferHub: false), .cloudOnly)
        XCTAssertEqual(SyncRoute.plan(role: .phone, cloudLink: true, joined: false, preferHub: true), .hubOnly)
        XCTAssertEqual(SyncRoute.plan(role: .phone, cloudLink: true, joined: true, preferHub: true), .hubOnly,
                       "the switch takes a joined phone back to the hub")

        XCTAssertEqual(SyncRoute.hubOnly.active, .hub)
        XCTAssertEqual(SyncRoute.cloudElseHub.active, .hub, "until it joins, the hub carries the phone")
        XCTAssertEqual(SyncRoute.cloudOnly.active, .cloud)
        XCTAssertEqual(SyncRoute.hubThenCloud.active, .hub)
    }

    func testWhatEachTickRuns() {
        XCTAssertEqual(tick(.hubOnly, nil), [.hub])
        XCTAssertEqual(tick(.cloudOnly, .upToDate), [.cloud])
        XCTAssertEqual(tick(.cloudElseHub, .waiting(.noDocument)), [.cloud, .hub], "no document yet: the hub as today")
        XCTAssertEqual(tick(.cloudElseHub, .waiting(.offline)), [.cloud, .hub])
        XCTAssertEqual(tick(.cloudElseHub, .installed(sample, wroteCloud: false)), [.cloud], "joined: no hub")
        XCTAssertEqual(tick(.cloudElseHub, .conflicts([])), [.cloud])
        XCTAssertEqual(tick(.cloudElseHub, .waiting(.sendingPhotos(done: 1, of: 3))), [.cloud])
        XCTAssertEqual(tick(.hubThenCloud, .upToDate), [.hub, .cloud])
        XCTAssertEqual(tick(.hubThenCloud, .waiting(.needsHubFirst)), [.hub, .cloud])
        XCTAssertEqual(tick(.hubThenCloud, .installed(sample, wroteCloud: true)), [.hub, .cloud, .hub],
                       "what came from iCloud goes on to the hub in the same tick")
    }

    /// C1 8: once a cloud pass has written the document in any round (one it then dropped for an edit, or whose
    /// later step failed), the phone does not run the hub in that tick.
    func testThePhoneNeverRunsTheHubAfterAPassThatWrote() {
        for wait in [CloudWait.busy, .failed("x"), .offline] {
            XCTAssertEqual(tick(.cloudElseHub, cloud: CloudTick(.waiting(wait), wrote: true)), [.cloud], "\(wait)")
            XCTAssertEqual(tick(.cloudElseHub, cloud: CloudTick(.waiting(wait))), [.cloud, .hub],
                           "\(wait), nothing written")
        }
    }

    /// C1 9: the Mac runs the hub again only after a cloud pass that brought something in, not after one that only
    /// sent the Mac's own collection up.
    func testTheMacRunsTheHubAgainOnlyAfterARealInstall() {
        XCTAssertEqual(tick(.hubThenCloud, cloud: CloudTick(.installed(sample, wroteCloud: true), installed: false)),
                       [.hub, .cloud])
        XCTAssertEqual(tick(.hubThenCloud, cloud: CloudTick(.installed(sample, wroteCloud: true), installed: true)),
                       [.hub, .cloud, .hub])
        XCTAssertEqual(tick(.hubThenCloud, cloud: CloudTick(.installed(sample, wroteCloud: false))),
                       [.hub, .cloud, .hub])
    }

    /// D10, C1 5 and C1 7: what a cloud pass does to the sync notice and to the hub's waiting changes.
    func testWhatACloudPassMeansForTheNoticeAndTheHub() {
        func notice(_ outcome: CloudOutcome, joined: Bool = true, speaks: Bool = true) -> CloudPassEffects.Notice {
            CloudPassEffects.of(outcome, role: .phone, joinedBefore: joined, speaksForCloud: speaks).notice
        }
        XCTAssertEqual(notice(.waiting(.noDocument)), .record(.other(CloudSyncCopy.missing)),
                       "a joined phone whose document is gone says so once it lasts")
        XCTAssertEqual(notice(.waiting(.noDocument), joined: false, speaks: false), .keep,
                       "a phone not joined yet keeps using the hub, as today")
        XCTAssertEqual(notice(.waiting(.offline)), .record(.offline))
        XCTAssertEqual(notice(.waiting(.failed("x"))), .record(.other("x")))
        XCTAssertEqual(notice(.waiting(.busy)), .keep, "a pass cut short or throttled is not a failure")
        XCTAssertEqual(notice(.upToDate), .clear)
        XCTAssertEqual(notice(.installed(sample, wroteCloud: false)), .clear)
        XCTAssertEqual(notice(.waiting(.offline), speaks: false), .keep, "only the link the screens speak for")
        let mac = CloudPassEffects.of(.waiting(.failed("x")), role: .mac, joinedBefore: false, speaksForCloud: false)
        XCTAssertEqual(mac.notice, .keep)
        XCTAssertFalse(mac.joins)

        let join = CloudPassEffects.of(.upToDate, role: .phone, joinedBefore: false, speaksForCloud: false)
        XCTAssertTrue(join.joins)
        XCTAssertTrue(join.clearsHubConflicts, "the join's merge asks again about anything real")
        let again = CloudPassEffects.of(.upToDate, role: .phone, joinedBefore: true, speaksForCloud: true)
        XCTAssertFalse(again.joins)
        XCTAssertFalse(again.clearsHubConflicts)
        let asked = CloudPassEffects.of(.conflicts([]), role: .phone, joinedBefore: false, speaksForCloud: false)
        XCTAssertFalse(asked.joins)
    }

    /// D5: the link that becomes active when the switch flips owes a pass with no base; a flip that leaves the same
    /// link active (a phone not joined yet) owes none.
    func testTheLinkThatBecomesActiveAfterTheSwitchMergesWithNoBase() {
        func route(joined: Bool, preferHub: Bool) -> SyncRoute {
            SyncRoute.plan(role: .phone, cloudLink: true, joined: joined, preferHub: preferHub)
        }
        XCTAssertEqual(SyncRoute.baselessAfterFlip(from: route(joined: true, preferHub: false),
                                                   to: route(joined: true, preferHub: true)), .hub)
        XCTAssertEqual(SyncRoute.baselessAfterFlip(from: route(joined: true, preferHub: true),
                                                   to: route(joined: true, preferHub: false)), .cloud)
        XCTAssertNil(SyncRoute.baselessAfterFlip(from: route(joined: false, preferHub: false),
                                                 to: route(joined: false, preferHub: true)))
    }

    /// Section 1, Rejected: two live links on the phone make a cycle. In no tick does the phone run the hub after a
    /// cloud pass that installed, wrote, asked or sent anything; and it never runs the hub first.
    func testThePhoneNeverRunsBothLinksInOneTick() {
        for joined in [false, true] {
            for preferHub in [false, true] {
                for cloudLink in [false, true] {
                    let route = SyncRoute.plan(role: .phone, cloudLink: cloudLink, joined: joined, preferHub: preferHub)
                    XCTAssertNotEqual(route, .hubThenCloud)
                    for outcome in allOutcomes {
                        let links = tick(route, outcome)
                        XCTAssertEqual(Set(links).count, links.count, "\(route) \(outcome): no link runs twice on the phone")
                        guard links.count > 1 else { continue }
                        XCTAssertEqual(links, [.cloud, .hub], "\(route) \(outcome): the hub only ever follows a cloud pass")
                        XCTAssertTrue(Self.changedNothing(outcome),
                                      "\(route) \(outcome): the hub ran after a cloud pass that did something")
                    }
                }
            }
        }
    }

    func testTheFirstSettledCloudPassJoins() {
        XCTAssertTrue(SyncRoute.joins(.installed(sample, wroteCloud: false)))
        XCTAssertTrue(SyncRoute.joins(.upToDate))
        XCTAssertFalse(SyncRoute.joins(.conflicts([])))
        for outcome in allOutcomes where Self.isWait(outcome) {
            XCTAssertFalse(SyncRoute.joins(outcome), "\(outcome)")
        }
    }

    // MARK: contentVersion

    func testContentVersionMovesOnlyWhenTheSyncedProjectionDoes() {
        var versions = SyncVersions()
        var data = sample
        XCTAssertTrue(versions.note(CloudLink.projection(data)))
        XCTAssertEqual(versions.content, 1)
        XCTAssertFalse(versions.note(CloudLink.projection(data)), "the same collection again")

        // This device's own settings and the derived stats never sync, so they move nothing.
        data.settings.autoBackup.toggle()
        data.settings.lastBackup = "2026-11-16T22:00:00Z"
        data.settings.backupRemote = nil
        data.headlineStats = ["price": HeadlineStatsPayload(count: 3, total: 300, mean: 100, median: 100, iqr: 0,
                                                            min: 100, max: 100, stdDev: 0, skewness: 0)]
        XCTAssertFalse(versions.note(CloudLink.projection(data)))
        // An empty wear log is the same as none (normalize drops it).
        data.watches[0].wearSessions = []
        XCTAssertFalse(versions.note(CloudLink.projection(data)))
        XCTAssertEqual(versions.content, 1)

        data.watches[0].story = "serviced"
        XCTAssertTrue(versions.note(CloudLink.projection(data)))
        data.settings.wrist.inches = 7
        XCTAssertTrue(versions.note(CloudLink.projection(data)), "the wrist profile syncs")
        XCTAssertEqual(versions.content, 3)
    }

    /// Hub -> Mac -> iCloud and back: an install by one link leaves the other with something to send, and the
    /// second link's pass, finding nothing new, moves nothing (no ping-pong).
    func testAnInstallByOneLinkMakesTheOtherDue() {
        var versions = SyncVersions()
        var data = sample
        versions.note(CloudLink.projection(data))
        versions.settle(.hub)
        versions.settle(.cloud)
        XCTAssertTrue(versions.isCurrent(.hub) && versions.isCurrent(.cloud))

        // The hub link installs a change made through the hub.
        data.wishlist.append(item("i9", "Nine"))
        versions.note(CloudLink.projection(data))
        versions.settle(.hub)
        XCTAssertTrue(versions.isCurrent(.hub))
        XCTAssertFalse(versions.isCurrent(.cloud), "the hub's change is due to go up to iCloud")

        // The cloud link carries it up; iCloud hands back the same collection, so nothing moves.
        versions.note(CloudLink.projection(data))
        versions.settle(.cloud)
        XCTAssertTrue(versions.isCurrent(.hub) && versions.isCurrent(.cloud), "nothing goes back to the hub")

        // The reverse: the cloud link installs the phone's edit.
        data.watches[1].story = "phone note"
        versions.note(CloudLink.projection(data))
        versions.settle(.cloud)
        XCTAssertFalse(versions.isCurrent(.hub), "the phone's edit is due to go to the hub")
        XCTAssertTrue(versions.isCurrent(.cloud))
    }

    // MARK: Conflicts per link

    func testAnswersGoBackToTheLinkThatAsked() throws {
        var set = SyncConflictSet()
        set.set([try hubConflict("h1"), try hubConflict("h2")], for: .hub)
        let merge = CollectionMerge.Conflict(id: "c1", path: ["watches", "w1", "story"], local: .string("phone"),
                                             remote: .string("mac"), localDeleted: false, remoteDeleted: false)
        set.set([SyncConflict(merge)], for: .cloud)
        XCTAssertEqual(set.all.map(\.id), ["h1", "h2", "c1"])
        XCTAssertEqual(set.all.map(\.link), [.hub, .hub, .cloud])

        XCTAssertNil(set.resolve("h1", choice: "local"), "one of the hub's two still waits")
        XCTAssertEqual(set.resolve("c1", choice: "remote"), .cloud, "the cloud link's only question is answered")
        XCTAssertEqual(set.resolutions(for: .cloud), ["c1": "remote"])
        XCTAssertEqual(set.resolutions(for: .hub), ["h1": "local"], "the hub is sent only its own answers")
        XCTAssertEqual(set.resolve("h2", choice: "remote"), .hub)
        XCTAssertEqual(set.resolutions, ["h1": "local", "h2": "remote", "c1": "remote"])
        XCTAssertNil(set.resolve("nope", choice: "local"))

        // The cloud link settles: its questions and answers go, the hub's stay.
        set.clear(.cloud)
        XCTAssertEqual(set.all.map(\.id), ["h1", "h2"])
        XCTAssertEqual(set.resolutions, ["h1": "local", "h2": "remote"])
        // The hub asks again: answers already given are kept, as today.
        set.set([try hubConflict("h1"), try hubConflict("h2")], for: .hub)
        XCTAssertEqual(set.resolutions(for: .hub), ["h1": "local", "h2": "remote"])
    }

    func testACloudConflictReadsLikeAHubOne() {
        let merge = CollectionMerge.Conflict(id: "c1", path: ["watches", "w1", "price"], local: .number(42),
                                             remote: nil, localDeleted: false, remoteDeleted: true)
        let conflict = SyncConflict(merge)
        XCTAssertEqual(conflict.link, .cloud)
        XCTAssertEqual(conflict.localText, "42")
        XCTAssertEqual(conflict.remoteText, "Deleted")
        XCTAssertEqual(conflict.title, "watches / w1 / price")
        let list = SyncConflict(CollectionMerge.Conflict(id: "c2", path: ["categories"],
                                                         local: .array([.string("Dive"), .bool(true)]),
                                                         remote: .object(["a": .null]), localDeleted: false,
                                                         remoteDeleted: false))
        XCTAssertEqual(list.localText, "Dive, Yes")
        XCTAssertEqual(list.remoteText, "a: Empty")
    }

    // MARK: The caller's side of a pass (section 4 steps 8 and 9, section 9 step 2)

    func testTheCopyBeforeICloudIsMadeOnceBeforeTheFirstCloudWrite() async throws {
        let store = makeStore()
        var data = sample
        data.watches[0].photos = ["a.jpg"]
        let mac = try makeHarness(.mac, store, data)
        try mac.photos.put("w1/a.jpg", Data("photo a".utf8))
        let syncBytes = Data("{\"sync\":\"json as it was\"}".utf8)
        try syncBytes.write(to: mac.files.syncURL)

        // The first thing to go up is the photo: by then the copy is on disk.
        let files = mac.files
        let seen = CopyCount()
        await store.onUpload(1) { seen.set(files.preCloudCopies.count) }
        mac.hubSettledAt = mac.generation
        let created = await mac.pass()
        XCTAssertEqual(created.wroteCloud, true)
        XCTAssertEqual(seen.value, 1, "made before the first cloud write")
        XCTAssertEqual(mac.files.preCloudCopies.count, 1)
        XCTAssertEqual(try Data(contentsOf: mac.files.preCloudCopies[0]), syncBytes,
                       "a copy of sync.json as it was before iCloud sync began")
        XCTAssertEqual(mac.mirrors, 1, "the JSON mirror once, whatever autoBackup says")
        // The creation only sent the Mac's own collection up: nothing to install (C1 9). Before the P8 fix round a
        // no-op install followed, which this line recorded as ["mirror", "install"].
        XCTAssertEqual(mac.events, ["mirror"])

        mac.edit { $0.watches[0].story = "edited" }
        mac.hubSettledAt = mac.generation
        let wrote = await mac.pass()
        XCTAssertEqual(wrote.wroteCloud, true)
        XCTAssertEqual(mac.files.preCloudCopies.count, 1, "once only")
        XCTAssertEqual(mac.mirrors, 1)

        // A new launch over the same folder finds the copy: still one, never deleted.
        let relaunched = try makeHarness(.mac, store, mac.data, folder: mac.files.folder)
        _ = await relaunched.pass()
        XCTAssertEqual(relaunched.files.preCloudCopies.count, 1)
        XCTAssertEqual(relaunched.mirrors, 0)
    }

    func testAPhoneWithNoCollectionHasNothingToCopy() async throws {
        let store = makeStore()
        let mac = try makeHarness(.mac, store, sample)
        mac.hubSettledAt = mac.generation
        _ = await mac.pass()
        let phone = try makeHarness(.phone, store, nil)
        let joined = await phone.pass()
        XCTAssertNotNil(joined.installedData)
        XCTAssertTrue(phone.files.preCloudCopies.isEmpty, "a phone that had nothing has nothing to keep")
        XCTAssertEqual(phone.mirrors, 0)
    }

    /// Step 9: the data is saved before the book. When the install runs, `cloud.json` still holds the old book.
    func testAnInstallSavesTheDataBeforeTheBook() async throws {
        let (store, mac, phone) = try await joined()
        let before = phone.files.loadBook()
        mac.edit { $0.watches[1].story = "mac edit" }
        _ = await mac.pass()

        let outcome = await phone.pass()
        XCTAssertNotNil(outcome.installedData)
        XCTAssertEqual(phone.bookTagAtInstall.last, before.tag, "the book on disk was the old one while the data was saved")
        let head = await store.currentHead
        XCTAssertEqual(phone.files.loadBook().tag, head?.tag, "and the new one after")
        XCTAssertEqual(story(phone.data, "w2"), "mac edit")
    }

    /// Step 8: an edit lands while the pass runs. That pass installs nothing and saves no book; the next round
    /// merges the edit with what iCloud has, and both survive.
    func testAPassOvertakenByAnEditInstallsNothingAndGoesRoundAgain() async throws {
        let (store, mac, phone) = try await joined()
        mac.edit { $0.watches[1].story = "mac edit" }
        _ = await mac.pass()
        let bookBefore = try Data(contentsOf: phone.files.bookURL)
        let installsBefore = phone.installs

        await store.onNextDocument { @Sendable [phone] in
            await MainActor.run { phone.edit { $0.watches[0].story = "typed during the pass" } }
        }
        let outcome = await phone.pass()
        XCTAssertEqual(phone.installs, installsBefore + 1, "only the round after the edit installed")
        XCTAssertEqual(phone.bookTagAtInstall.count, phone.installs)
        XCTAssertEqual(outcome.wroteCloud, true, "the edit went up in the second round")
        XCTAssertEqual(story(phone.data, "w1"), "typed during the pass")
        XCTAssertEqual(story(phone.data, "w2"), "mac edit")
        let cloud = try await cloudData(store)
        XCTAssertEqual(story(cloud, "w1"), "typed during the pass")
        XCTAssertNotEqual(try Data(contentsOf: phone.files.bookURL), bookBefore)
    }

    func testAPassOvertakenInEveryRoundKeepsNothing() async throws {
        let (store, mac, phone) = try await joined()
        mac.edit { $0.watches[1].story = "mac edit" }
        _ = await mac.pass()
        let bookBefore = try Data(contentsOf: phone.files.bookURL)
        let dataBefore = phone.data
        let installsBefore = phone.installs

        // Every document fetch, an edit lands (one that does not touch the synced fields, so only the generation moves).
        let fetchesBefore = await store.count(.document)
        await EditEveryFetch(store: store, phone: phone).arm()
        let outcome = await phone.pass()
        XCTAssertEqual(outcome.wait, .busy, "the next tick tries again")
        XCTAssertEqual(phone.installs, installsBefore, "nothing installed")
        XCTAssertEqual(try Data(contentsOf: phone.files.bookURL), bookBefore, "no book saved")
        XCTAssertEqual(story(phone.data, "w2"), story(dataBefore, "w2"))
        let fetchesAfter = await store.count(.document)
        XCTAssertEqual(fetchesAfter - fetchesBefore, CloudLink.maxRounds, "one fetch a round, every round dropped")
        XCTAssertEqual(phone.files.loadReport()?.outcome, "waiting(busy)")
    }

    /// An `.upToDate` can carry a newer book (the same content under a new change tag): it is saved.
    func testTheBookIsSavedAfterAnUpToDateThatChangedIt() async throws {
        let (store, _, phone) = try await joined()
        let current = await store.currentHead
        let head = try XCTUnwrap(current)
        let stored = try await store.body()
        let body = try XCTUnwrap(stored)
        await store.setDocument(body.canonicalData, epoch: head.epoch)
        let after = await store.currentHead
        let moved = try XCTUnwrap(after)
        XCTAssertNotEqual(moved.tag, head.tag)
        let installsBefore = phone.installs

        let outcome = await phone.pass()
        XCTAssertTrue(outcome.isUpToDate)
        XCTAssertEqual(phone.installs, installsBefore)
        XCTAssertEqual(phone.files.loadBook().tag, moved.tag, "the newer tag is on disk")
        XCTAssertEqual(phone.session.book.tag, moved.tag)

        // So the next pass is a head fetch alone.
        let fetches = await store.count(.document)
        let again = await phone.pass()
        XCTAssertTrue(again.isUpToDate)
        let fetchesAfter = await store.count(.document)
        XCTAssertEqual(fetchesAfter, fetches)
    }

    /// The hub link's install on the Mac makes the cloud link due, and the change goes up; the phone's edit that
    /// comes back makes the hub due.
    func testAHubInstallOnTheMacGoesUpToICloud() async throws {
        let (store, mac, phone) = try await joined()
        // The Mac's hub link installs a wishlist add made through the hub.
        mac.data?.wishlist.append(item("i9", "Nine"))
        mac.versions.note(CloudLink.projection(mac.data!))
        mac.versions.settle(.hub)
        XCTAssertFalse(mac.versions.isCurrent(.cloud))
        let up = await mac.pass()
        XCTAssertEqual(up.wroteCloud, true)
        let cloud = try await cloudData(store)
        XCTAssertTrue(cloud.wishlist.contains { $0.id == "i9" })

        _ = await phone.pass()
        XCTAssertTrue(phone.data?.wishlist.contains { $0.id == "i9" } == true)
        phone.edit { $0.watches[2].story = "phone note" }
        _ = await phone.pass()
        let back = await mac.pass()
        XCTAssertNotNil(back.installedData)
        XCTAssertFalse(mac.versions.isCurrent(.hub), "the phone's edit is due to go to the hub")
        XCTAssertEqual(story(mac.data, "w3"), "phone note")
    }

    func testCloudStatusReportIsWrittenEachPass() async throws {
        let (_, mac, phone) = try await joined()
        let report = try XCTUnwrap(phone.files.loadReport())
        XCTAssertEqual(report.role, "phone")
        XCTAssertEqual(report.outcome, "installed")
        XCTAssertTrue(report.joined)
        XCTAssertEqual(report.epoch, phone.session.book.epoch)
        XCTAssertEqual(report.revision, phone.session.book.revision)
        XCTAssertNotNil(report.statuses["status-mac"])
        _ = await mac.pass()
        XCTAssertEqual(mac.files.loadReport()?.outcome, "upToDate")
    }

    // MARK: The book of a fresh document (docs/icloud-fixes.md D1)

    /// C1 2 (B2): he deletes a watch on the Mac while its creating pass is sending photos. The round is dropped for
    /// the edit, but its book is kept (it only sent this Mac's own collection up), so the next round merges against
    /// the document it made and the delete goes up instead of coming back.
    func testADeleteDuringTheCreatingPassSurvives() async throws {
        let store = makeStore()
        var data = sample
        data.watches[0].photos = ["a.jpg"]
        let mac = try makeHarness(.mac, store, data)
        try mac.photos.put("w1/a.jpg", Data("photo a".utf8))
        await store.onUpload(1) { @Sendable [mac] in
            await MainActor.run { mac.edit { $0.watches.removeAll { $0.id == "w2" } } }
        }
        mac.hubSettledAt = mac.generation

        let outcome = await mac.pass()
        XCTAssertNil(outcome.conflictList, "\(outcome)")
        XCTAssertFalse(mac.data?.watches.contains { $0.id == "w2" } ?? true, "the delete made during the pass holds")
        let cloud = try await cloudData(store)
        XCTAssertFalse(cloud.watches.contains { $0.id == "w2" }, "and went up in the next round")
        let head = await store.currentHead
        XCTAssertEqual(mac.session.book.epoch, head?.epoch)
        XCTAssertEqual(mac.session.book.tag, head?.tag)
    }

    /// The same with a field: he is not asked to choose between his own old and new value.
    func testAnEditDuringTheCreatingPassIsNotAskedAbout() async throws {
        let store = makeStore()
        var data = sample
        data.watches[0].photos = ["a.jpg"]
        let mac = try makeHarness(.mac, store, data)
        try mac.photos.put("w1/a.jpg", Data("photo a".utf8))
        await store.onUpload(1) { @Sendable [mac] in
            await MainActor.run { mac.edit { $0.watches[1].story = "typed during the first sync" } }
        }
        mac.hubSettledAt = mac.generation

        let outcome = await mac.pass()
        XCTAssertNil(outcome.conflictList, "\(outcome)")
        let cloud = try await cloudData(store)
        XCTAssertEqual(story(cloud, "w2"), "typed during the first sync")
        XCTAssertEqual(story(mac.data, "w2"), "typed during the first sync")
    }

    /// B2: the creation lands but its answer is lost. The next pass still knows the document it made (its epoch and
    /// body were kept before the save), so a hub delete and edit that follow go up as such: no question, no
    /// resurrection.
    func testACreationWhoseAnswerIsLostKeepsItsBase() async throws {
        let store = makeStore()
        let mac = try makeHarness(.mac, store, sample)
        mac.hubSettledAt = mac.generation
        await store.loseNextWriteResponse()

        let lost = await mac.pass()
        XCTAssertEqual(lost.wait, .offline)
        let made = await store.currentHead
        let head = try XCTUnwrap(made, "the document landed")
        mac.edit {
            $0.watches.removeAll { $0.id == "w3" }
            $0.watches[1].story = "hub edit"
        }

        let next = await mac.pass()
        XCTAssertNil(next.conflictList, "\(next)")
        XCTAssertEqual(next.wroteCloud, true)
        let cloud = try await cloudData(store)
        XCTAssertEqual(Set(cloud.watches.map(\.id)), ["w1", "w2"], "the hub's delete is not undone")
        XCTAssertEqual(story(cloud, "w2"), "hub edit")
        XCTAssertEqual(mac.session.book.epoch, head.epoch)
    }

    /// B2: the creation's answer is lost and the next launch starts from what the pass left on disk. (The book saved
    /// before the save, with nothing saved after it, is `testTheBookWithThePendingEpochIsOnDiskWhenTheCreationLands`.)
    func testACreationThatLandsBeforeTheProcessDiesKeepsItsBaseOnDisk() async throws {
        let store = makeStore()
        let mac = try makeHarness(.mac, store, sample)
        mac.hubSettledAt = mac.generation
        await store.loseNextWriteResponse()
        _ = await mac.pass()

        var after = try XCTUnwrap(mac.data)
        after.watches.removeAll { $0.id == "w3" }
        after.watches[1].story = "hub edit"
        let relaunched = try makeHarness(.mac, store, after, folder: mac.files.folder)
        let next = await relaunched.pass()
        XCTAssertNil(next.conflictList, "\(next)")
        let cloud = try await cloudData(store)
        XCTAssertEqual(Set(cloud.watches.map(\.id)), ["w1", "w2"])
        XCTAssertEqual(story(cloud, "w2"), "hub edit")
    }

    /// C1 6: the one-time copy is taken right before this device's first cloud write or install, not on a pass that
    /// finds nothing to do (a phone whose build arrived before the Mac's document, a Mac waiting for its hub).
    func testThePreCloudCopyWaitsForTheFirstCloudWriteOrInstall() async throws {
        let store = makeStore()
        let phone = try makeHarness(.phone, store, sample)
        let none = await phone.pass()
        XCTAssertEqual(none.wait, .noDocument)
        XCTAssertTrue(phone.files.preCloudCopies.isEmpty, "a pass that finds no document changes nothing here")
        XCTAssertEqual(phone.mirrors, 0)

        let mac = try makeHarness(.mac, store, sample)
        let early = await mac.pass()
        XCTAssertEqual(early.wait, .needsHubFirst)
        XCTAssertTrue(mac.files.preCloudCopies.isEmpty)
        mac.hubSettledAt = mac.generation
        let created = await mac.pass()
        XCTAssertEqual(created.wroteCloud, true)
        XCTAssertEqual(mac.files.preCloudCopies.count, 1)

        let joined = await phone.pass()
        XCTAssertTrue(joined.isUpToDate, "\(joined)")
        XCTAssertTrue(phone.files.preCloudCopies.isEmpty, "nothing written or installed yet")
        mac.edit { $0.watches[0].story = "mac edit" }
        _ = await mac.pass()
        let installed = await phone.pass()
        XCTAssertNotNil(installed.installedData)
        XCTAssertEqual(phone.files.preCloudCopies.count, 1, "taken right before the phone's first install")
        XCTAssertEqual(phone.mirrors, 1)
        XCTAssertEqual(phone.events, ["mirror", "install"])
    }

    /// C1 9: a pass that only sent this device's own collection up installs nothing (no `sync.json` rewrite, no
    /// redraw); one that brought something in installs it.
    func testAPurePushIsNotInstalledAgain() async throws {
        let (_, mac, phone) = try await joined()
        mac.edit { $0.watches[1].story = "mac edit" }
        let installs = mac.installs
        let up = await mac.pass()
        XCTAssertEqual(up.wroteCloud, true)
        XCTAssertEqual(mac.installs, installs, "nothing came in: nothing to install")
        XCTAssertTrue(mac.session.lastPassWrote)
        XCTAssertFalse(mac.session.lastPassInstalled)
        XCTAssertEqual(story(mac.data, "w2"), "mac edit")

        let down = await phone.pass()
        XCTAssertNotNil(down.installedData)
        XCTAssertTrue(phone.session.lastPassInstalled)
        XCTAssertFalse(phone.session.lastPassWrote)
    }

    /// B6 / C1 11: a throttle met by a pass that an edit then overtook still holds: the next tick waits for it.
    func testAThrottleMetDuringAnEditIsKept() async throws {
        let (store, mac, phone) = try await joined()
        mac.edit { $0.watches[1].story = "mac edit" }
        _ = await mac.pass()
        phone.edit { $0.watches[2].story = "phone edit" }
        await store.onNextDocument { @Sendable [phone, store] in
            await MainActor.run { phone.edit { $0.watches[0].story = "typed during the pass" } }
            await store.setRetryAfter(120)
        }

        let throttled = await phone.pass()
        XCTAssertEqual(throttled.wait, .busy)
        XCTAssertNotNil(phone.session.book.notBefore, "the throttle is kept with the dropped result")
        XCTAssertNotNil(phone.files.loadBook().notBefore, "and saved")
        await store.setRetryAfter(nil)
        let heads = await store.count(.head)
        let waited = await phone.pass()
        XCTAssertEqual(waited.wait, .busy)
        let headsAfter = await store.count(.head)
        XCTAssertEqual(headsAfter, heads, "iCloud is not asked again before the throttle ends")
        clock.advance(121)
        let sent = await phone.pass()
        XCTAssertNotNil(sent.installedData, "\(sent)")
        XCTAssertEqual(story(phone.data, "w1"), "typed during the pass")
    }

    /// D4 (C1 1): the narrowed drop rule holds only while iCloud can answer for the photos. Without a document behind
    /// the book, signed out, or erased, the hub exchange drops what is gone on both sides, as before iCloud.
    func testTheNarrowedDropRuleAppliesOnlyWhileICloudCanAnswer() async throws {
        let store = makeStore()
        let mac = try makeHarness(.mac, store, sample)
        var names = await mac.session.namesNotInCloud()
        XCTAssertNil(names, "no document behind the book yet")
        let early = await mac.pass()
        XCTAssertEqual(early.wait, .needsHubFirst)
        names = await mac.session.namesNotInCloud()
        XCTAssertNil(names, "waiting for a hub pass: the hub pass must not wait for iCloud in turn")

        mac.hubSettledAt = mac.generation
        _ = await mac.pass()
        names = await mac.session.namesNotInCloud()
        XCTAssertEqual(names, [])

        await store.signIn(nil)
        let signedOut = await mac.pass()
        XCTAssertEqual(signedOut.wait, .noAccount)
        names = await mac.session.namesNotInCloud()
        XCTAssertNil(names, "signed out")
        await store.signIn("account-A")
        _ = await mac.pass()
        names = await mac.session.namesNotInCloud()
        XCTAssertEqual(names, [])

        await store.deleteZone()
        mac.hubSettledAt = nil
        let gone = await mac.pass()
        XCTAssertEqual(gone.wait, .needsHubFirst)
        names = await mac.session.namesNotInCloud()
        XCTAssertNil(names, "the document has gone: its marks speak for nothing")

        mac.hubSettledAt = mac.generation
        _ = await mac.pass()
        await store.eraseByUser()
        let erased = await mac.pass()
        XCTAssertEqual(erased.wait, .erased)
        names = await mac.session.namesNotInCloud()
        XCTAssertNil(names, "erased")
    }

    /// C1 10: a phone syncing with the hub asks iCloud for the photos it lacks before an exchange; the exchange then
    /// drops only what iCloud does not have, and with iCloud signed out the rule is today's.
    func testAPhoneOnTheHubAsksICloudBeforeDroppingAPhoto() async throws {
        let (store, _, phone) = try await joined()
        try await store.putPhoto("w1/there.jpg", Data("there".utf8))
        await phone.session.fetch(["w1/there.jpg", "w1/never.jpg"])
        XCTAssertTrue(phone.photos.exists("w1/there.jpg"))
        var names = await phone.session.namesNotInCloud()
        XCTAssertEqual(names, ["w1/never.jpg"])
        XCTAssertEqual(Array(phone.files.loadMarks().notInCloud.keys), ["w1/never.jpg"], "saved")

        await store.signIn(nil)
        await phone.session.fetch(["w1/other.jpg"])
        names = await phone.session.namesNotInCloud()
        XCTAssertNil(names, "signed out: as before iCloud")
    }

    /// D5 through the session: the host's `noBase` reaches the link.
    func testTheSessionHandsTheBaselessPassToTheLink() async throws {
        let (_, mac, phone) = try await joined()
        mac.edit { $0.watches.removeAll { $0.id == "w3" } }
        _ = await mac.pass()
        phone.noBase = true
        let union = await phone.pass()
        XCTAssertNil(union.conflictList, "\(union)")
        XCTAssertEqual(Set(phone.data?.watches.map(\.id) ?? []), ["w1", "w2", "w3"], "nothing deleted without a base")
    }

    /// C2 7 through the session: the host's hub count reaches `status-mac`.
    func testTheMacsStatusCountsItsHubChoices() async throws {
        let (store, mac, _) = try await joined()
        mac.hubConflicts = 1
        _ = await mac.pass()
        let status = await store.status("status-mac")
        XCTAssertEqual(status?.conflicts, 1)
    }

    // MARK: Files and settings (C2 10, C1 3, polish 3 and 6)

    /// C2 10: the copy is written whole under a hidden name and linked into place; nothing else is left behind, and
    /// a hidden file a stopped process left never counts as the copy.
    func testThePreCloudCopyIsWrittenWhole() throws {
        let folder = root.appendingPathComponent("copy", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let files = CloudFiles(folder: folder)
        let bytes = Data("{\"sync\":\"as it was\"}".utf8)
        try bytes.write(to: files.syncURL)
        try Data("trunc".utf8).write(to: folder.appendingPathComponent(".\(CloudFiles.preCloudPrefix)left.partial"))
        XCTAssertTrue(files.preCloudCopies.isEmpty, "a partial file never counts as made")

        let copy = try files.writePreCloudCopy(of: sample, at: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(try Data(contentsOf: copy), bytes)
        XCTAssertEqual(files.preCloudCopies, [copy])
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        XCTAssertEqual(names.filter { $0.hasSuffix(".partial") }, [".\(CloudFiles.preCloudPrefix)left.partial"],
                       "this write left nothing of its own")
        let second = try files.writePreCloudCopy(of: sample, at: Date(timeIntervalSince1970: 0))
        XCTAssertNotEqual(second, copy, "never over an earlier copy")
    }

    /// C1 3: a run with its own data root keeps its hub address, sync switch, box trials and backup apart from his
    /// real ones; `-WCHub` without a data root is ignored.
    func testADataRootRunKeepsItsSettingsApart() throws {
        let rootPath = root.appendingPathComponent("data-root", isDirectory: true).path
        let defaults = UserDefaults.standard
        try withArguments(["WCDataRoot": rootPath]) {
            for key in ["syncAddress", "syncEnabled", "cloudJoinedOnce", "cloudPreferHub", "cloudSwitchBaseless"] {
                XCTAssertNotEqual(AppPaths.defaultsKey(key), key)
            }
            XCTAssertNotEqual(BoxTrial.storageKey, BoxTrial.defaultsKey)
            XCTAssertTrue(try AppPaths.backupFolder().path.hasPrefix(rootPath), "the backup stays in the root")

            let key = AppPaths.defaultsKey("syncAddress")
            defaults.set("http://127.0.0.1:9", forKey: key)
            defaults.set(false, forKey: AppPaths.defaultsKey("syncEnabled"))
            defer {
                defaults.removeObject(forKey: key)
                defaults.removeObject(forKey: AppPaths.defaultsKey("syncEnabled"))
            }
            XCTAssertEqual(AppStore.initialSyncAddress, "http://127.0.0.1:9")
            XCTAssertFalse(AppStore.initialSyncEnabled)

            let suite = try XCTUnwrap(UserDefaults(suiteName: "SyncRoutingTests-\(UUID().uuidString)"))
            BoxTrial(["black": ["0": "nomos"]]).save(to: suite)
            XCTAssertNil(suite.object(forKey: BoxTrial.defaultsKey), "the real trials key is untouched")
            XCTAssertEqual(BoxTrial.load(from: suite), BoxTrial(["black": ["0": "nomos"]]))
        }
        XCTAssertEqual(AppPaths.defaultsKey("syncAddress"), "syncAddress", "without a root, the real keys")
        XCTAssertEqual(BoxTrial.storageKey, BoxTrial.defaultsKey)
        XCTAssertFalse(try AppPaths.backupFolder().path.hasPrefix(rootPath))

        try withArguments(["WCHub": "http://127.0.0.1:9"]) {
            XCTAssertNil(AppPaths.hub, "a throwaway hub never reaches his real sync.json")
        }
        try withArguments(["WCHub": "http://127.0.0.1:9", "WCDataRoot": rootPath]) {
            XCTAssertEqual(AppPaths.hub, "http://127.0.0.1:9")
            XCTAssertEqual(AppStore.initialSyncAddress, "http://127.0.0.1:9")
        }
    }

    /// Polish 3: a bridge tick does not rewrite the JSON mirror at launch; its installs mirror what they install.
    func testABridgeTickMirrorsOnlyWhatItInstalls() {
        XCTAssertTrue(AppStore.mirrorsAtLaunch(autoBackup: true, bridge: false), "the app as today")
        XCTAssertFalse(AppStore.mirrorsAtLaunch(autoBackup: true, bridge: true))
        XCTAssertFalse(AppStore.mirrorsAtLaunch(autoBackup: false, bridge: false))
    }

    /// Polish 6: a bridge tick starts on the hub's fast path when `sync.json` was last written by a settled hub pass
    /// for this address; anything else (the app, an edit, an iCloud install) writes no revision.
    func testABridgeTickStartsOnTheHubFastPathWhenNothingMoved() throws {
        let settled = SyncCheckpoint(data: sample, base: sample, server: "http://127.0.0.1:9", lastSuccess: nil,
                                     revision: "r7")
        XCTAssertEqual(AppStore.hubRevisionAtLaunch(settled, address: "http://127.0.0.1:9", bridge: true), "r7")
        XCTAssertNil(AppStore.hubRevisionAtLaunch(settled, address: "http://127.0.0.1:9", bridge: false),
                     "the app as today")
        XCTAssertNil(AppStore.hubRevisionAtLaunch(settled, address: "http://127.0.0.1:10", bridge: true))
        XCTAssertNil(AppStore.hubRevisionAtLaunch(nil, address: "http://127.0.0.1:9", bridge: true))
        let other = SyncCheckpoint(data: sample, base: sample, server: "http://127.0.0.1:9", lastSuccess: nil)
        XCTAssertNil(AppStore.hubRevisionAtLaunch(other, address: "http://127.0.0.1:9", bridge: true))

        // A sync.json from before the field reads as no revision.
        let old = try JSONEncoder().encode(other)
        let read = try JSONDecoder().decode(SyncCheckpoint.self, from: old)
        XCTAssertNil(read.revision)
        let round = try JSONDecoder().decode(SyncCheckpoint.self, from: try JSONEncoder().encode(settled))
        XCTAssertEqual(round.revision, "r7")
    }

    // MARK: The narrowed drop rule (section 5)

    /// With iCloud on, a file gone here and on the hub is not dropped while iCloud may still have it: the exchange
    /// is skipped before anything is sent. The address answers nothing, so reaching the network would throw.
    func testTheHubExchangeWaitsForAPhotoICloudMayStillHave() async throws {
        var local = sample
        local.watches[0].photos = ["missing-\(UUID().uuidString).jpg"]
        let keys = CollectionSyncClient.uploads(from: local, hub: sample, hubFiles: []).map { "\($0.directory)/\($0.filename)" }
        XCTAssertEqual(keys.count, 1)
        let client = try CollectionSyncClient(address: "http://127.0.0.1:9")
        let remote = SyncSnapshot(data: sample, revision: "r1", photos: [], conflicts: [])

        XCTAssertEqual(CollectionSyncClient.goneFiles(local: local, remote: remote), keys,
                       "what the phone asks iCloud for")
        let skipped = try await client.exchange(base: sample, local: local, resolutions: [:], remote: remote, dropping: [])
        XCTAssertNil(skipped, "skipped for this tick, before anything is sent")

        // Once iCloud has said it does not have the file (or with iCloud off), the exchange goes ahead as before.
        for dropping in [Set(keys), nil] {
            do {
                _ = try await client.exchange(base: sample, local: local, resolutions: [:], remote: remote, dropping: dropping)
                XCTFail("expected the exchange to reach for the hub")
            } catch {
                XCTAssertNotNil(error as? URLError, "\(error)")
            }
        }

        // Polish 2 item 8: a file the cloud link has given up on is kept, not waited on: the exchange goes ahead.
        do {
            _ = try await client.exchange(base: sample, local: local, resolutions: [:], remote: remote, dropping: [],
                                          keeping: Set(keys))
            XCTFail("expected the exchange to reach for the hub")
        } catch {
            XCTAssertNotNil(error as? URLError, "\(error)")
        }
    }

    /// Polish 2 item 8: the drop rule's plan. A name given up on is kept (held back from the hub only) and never makes
    /// the exchange wait; the rest is dropped or waited on as before. With nothing kept it is the old rule.
    func testThePhotoPlanKeepsAGivenUpNameAndDropsOrWaitsOnTheRest() {
        typealias Plan = (drop: Set<String>, keep: Set<String>)
        func plan(_ gone: Set<String>, _ dropping: Set<String>?, _ keeping: Set<String>) -> Plan? {
            CollectionSyncClient.photoPlan(gone: gone, dropping: dropping, keeping: keeping)
        }
        func same(_ a: Plan?, _ b: Plan?, _ note: String, line: UInt = #line) {
            XCTAssertEqual(a?.drop, b?.drop, note, line: line)
            XCTAssertEqual(a?.keep, b?.keep, note, line: line)
            XCTAssertEqual(a == nil, b == nil, note, line: line)
        }
        let gone: Set<String> = ["w1/a.jpg", "w1/b.jpg"]
        // Keeping nothing: today's rule.
        same(plan(gone, nil, []), (gone, []), "nil drops everything gone")
        same(plan(gone, [], []), nil, "nothing iCloud lacks: wait")
        same(plan(gone, ["w1/a.jpg"], []), nil, "one iCloud may still have: wait")
        same(plan(gone, gone.union(["w9/z.jpg"]), []), (gone, []), "a superset drops them all")
        same(plan([], [], []), ([], []), "nothing gone: nothing to do")
        // Kept names never make it wait, with `dropping` nil too.
        same(plan(gone, [], gone), ([], gone), "all kept")
        same(plan(gone, nil, gone), ([], gone), "all kept, iCloud unable to answer")
        same(plan(gone, nil, ["w1/a.jpg"]), (["w1/b.jpg"], ["w1/a.jpg"]), "one kept, the other dropped as before")
        same(plan(gone, ["w1/b.jpg"], ["w1/a.jpg"]), (["w1/b.jpg"], ["w1/a.jpg"]), "one kept, the other iCloud lacks")
        same(plan(gone, [], ["w1/a.jpg"]), nil, "one kept, the other iCloud may still have: wait")
        same(plan(["w1/a.jpg"], [], ["w1/a.jpg", "w9/z.jpg"]), ([], ["w1/a.jpg"]), "only gone names are kept")
    }

    // MARK: PhotoStore's iCloud source (section 5)

    func testPhotoStoreFetchesAFileItLacksFromICloudByName() async throws {
        let store = makeStore()
        let dir = "wl-test-\(UUID().uuidString.prefix(8))"
        let present = PhotoAsset(directory: dir, filename: "a.jpg", remoteURL: nil)
        let absent = PhotoAsset(directory: dir, filename: "b.jpg", remoteURL: nil)
        try await store.putPhoto("\(dir)/a.jpg", Data("bytes of a".utf8))
        defer {
            if let folder = PhotoStore.localURL(for: present)?.deletingLastPathComponent() {
                try? FileManager.default.removeItem(at: folder)
            }
        }
        await PhotoStore.shared.configure(cloud: store, hubActive: false)
        addTeardownBlock { await PhotoStore.shared.configure(cloud: nil, hubActive: true) }

        let none = await PhotoStore.shared.load(present, allowDownload: false)
        XCTAssertNil(none, "nothing is fetched unless the screen allows it")
        let fetched = await PhotoStore.shared.load(present, allowDownload: true)
        XCTAssertEqual(fetched, Data("bytes of a".utf8))
        XCTAssertNotNil(PhotoStore.existingLocalURL(for: present), "kept on disk")

        let missing = await PhotoStore.shared.load(absent, allowDownload: true)
        XCTAssertNil(missing, "a placeholder")
        let missingAgain = await PhotoStore.shared.load(absent, allowDownload: true)
        XCTAssertNil(missingAgain)
        let downloads = await store.count(.download)
        XCTAssertEqual(downloads, 2, "iCloud said it does not have b.jpg: not asked again at once")
    }

    // MARK: Round 3 (docs/icloud-fixes.md R1 to R4)

    /// R1 / C1 1: an ordinary push overtaken by more typing in the same field. The round's write is confirmed, so its
    /// book is kept with the round's collection as base: he is never asked to choose between his own two values.
    func testAnOrdinaryPushOvertakenByMoreTypingAsksNothing() async throws {
        let (store, mac, _) = try await joined()
        mac.edit { $0.watches[1].story = "x" }
        await store.onNextDocument { @Sendable [mac] in
            await MainActor.run { mac.edit { $0.watches[1].story = "xy" } }
        }
        let outcome = await mac.pass()
        XCTAssertNil(outcome.conflictList, "\(outcome)")
        let cloud = try await cloudData(store)
        XCTAssertEqual(story(cloud, "w2"), "xy")
        XCTAssertEqual(story(mac.data, "w2"), "xy")
        let head = await store.currentHead
        XCTAssertEqual(mac.session.book.tag, head?.tag)
    }

    /// R1 / B P7: a joined phone meets a new epoch and merges with no base (a union that also carries the Mac's new
    /// watch), and its write is confirmed; a delete made during that pass then holds. Before R1 only a pure push kept
    /// its book, so the next round was a union again and w2 came back.
    func testADeleteDuringThePhonesFirstPassAfterAnEpochChangeHolds() async throws {
        let (store, mac, phone) = try await joined()
        phone.edit { $0.watches.append(self.watch("w4", "Delta")) }
        await store.deleteZone()
        mac.edit { $0.watches.append(self.watch("w5", "Echo")) }
        mac.hubSettledAt = mac.generation
        let made = await mac.pass()
        XCTAssertEqual(made.wroteCloud, true)
        let current = await store.currentHead
        let epoch = try XCTUnwrap(current?.epoch)
        XCTAssertNotEqual(phone.session.book.epoch, epoch, "a new epoch")

        await store.onNextDocument { @Sendable [phone] in
            await MainActor.run { phone.edit { $0.watches.removeAll { $0.id == "w2" } } }
        }
        let outcome = await phone.pass()
        XCTAssertNil(outcome.conflictList, "\(outcome)")
        XCTAssertEqual(Set(phone.data?.watches.map(\.id) ?? []), ["w1", "w3", "w4", "w5"], "the delete made during the pass holds")
        let cloud = try await cloudData(store)
        XCTAssertEqual(Set(cloud.watches.map(\.id)), ["w1", "w3", "w4", "w5"])
        XCTAssertEqual(phone.session.book.epoch, epoch)
    }

    /// R1 / B F3: the Mac joins a document it did not make (no base: a union with a watch of each side's), and a
    /// delete made during that pass holds.
    func testADeleteDuringTheMacsJoinOfAnExistingDocumentHolds() async throws {
        let store = makeStore()
        var there = sample
        there.watches.append(watch("w5", "Echo"))
        let body = CollectionMerge.normalize(try JSONValue(encoding: there)).canonicalData
        await store.setDocument(body, epoch: "made-elsewhere")
        var here = sample
        here.watches.append(watch("w4", "Delta"))
        let mac = try makeHarness(.mac, store, here)
        await store.onNextDocument { @Sendable [mac] in
            await MainActor.run { mac.edit { $0.watches.removeAll { $0.id == "w2" } } }
        }

        let outcome = await mac.pass()
        XCTAssertNil(outcome.conflictList, "\(outcome)")
        XCTAssertEqual(Set(mac.data?.watches.map(\.id) ?? []), ["w1", "w3", "w4", "w5"], "the delete made during the pass holds")
        let cloud = try await cloudData(store)
        XCTAssertEqual(Set(cloud.watches.map(\.id)), ["w1", "w3", "w4", "w5"])
        XCTAssertEqual(mac.session.book.epoch, "made-elsewhere")
    }

    /// R2 / C1 5: D5's merge with no base covers only the rounds before one confirms a write. Its first round here is
    /// a union that writes (the phone's w4 up, the Mac's w5 in); a delete typed during it then holds in the next round.
    func testADeleteDuringABaselessPassHolds() async throws {
        let (store, mac, phone) = try await joined()
        mac.edit { $0.watches.append(self.watch("w5", "Echo")) }
        _ = await mac.pass()
        phone.edit { $0.watches.append(self.watch("w4", "Delta")) }
        phone.noBase = true
        await store.onNextDocument { @Sendable [phone] in
            await MainActor.run { phone.edit { $0.watches.removeAll { $0.id == "w1" } } }
        }

        let outcome = await phone.pass()
        XCTAssertNil(outcome.conflictList, "\(outcome)")
        XCTAssertEqual(Set(phone.data?.watches.map(\.id) ?? []), ["w2", "w3", "w4", "w5"], "the delete typed during the pass holds")
        XCTAssertTrue(phone.session.lastPassConfirmedWrite, "AppStore clears D5's flag on this (R2 across passes)")
        let cloud = try await cloudData(store)
        XCTAssertEqual(Set(cloud.watches.map(\.id)), ["w2", "w3", "w4", "w5"])
    }

    /// R1, the other side: a round whose write may not have landed (here it failed before reaching iCloud) is not a
    /// confirmed write. Its book is dropped as before, so the phone's own new watch is never read as a delete from
    /// iCloud; once the network is back it goes up with the edit made meanwhile.
    func testAnOvertakenRoundWhoseWriteIsNotConfirmedKeepsTheOldBook() async throws {
        let (store, _, phone) = try await joined()
        let before = phone.session.book
        phone.edit { $0.watches.append(self.watch("w4", "Delta")) }
        await store.fail(.write, with: .network)
        await store.onNextDocument { @Sendable [phone] in
            await MainActor.run { phone.edit { $0.watches[0].story = "typed during the pass" } }
        }

        let failed = await phone.pass()
        XCTAssertEqual(failed.wait, .offline)
        XCTAssertFalse(phone.session.lastPassConfirmedWrite, "a write that may only have landed spends no D5 flag")
        XCTAssertEqual(phone.session.book.tag, before.tag, "the old book stands")
        XCTAssertEqual(phone.session.book.base.map(CloudLink.projection), before.base.map(CloudLink.projection))
        let writes = await store.writes
        XCTAssertEqual(writes, ["mac"], "nothing landed")

        await store.fail(.write, with: nil)
        let sent = await phone.pass()
        XCTAssertEqual(sent.wroteCloud, true, "\(sent)")
        XCTAssertEqual(Set(phone.data?.watches.map(\.id) ?? []), ["w1", "w2", "w3", "w4"])
        let cloud = try await cloudData(store)
        XCTAssertEqual(Set(cloud.watches.map(\.id)), ["w1", "w2", "w3", "w4"], "the new watch went up")
        XCTAssertEqual(story(cloud, "w1"), "typed during the pass")
    }

    /// R3 / C1 2 / B F4: the book carrying the pending epoch is on disk at the moment the creation lands. The process
    /// dies right there (the bridge's watchdog), so `cloud.json` is exactly what it was then; the next launch still
    /// merges against the document it made: a hub delete and edit go up, with no question and nothing back.
    func testTheBookWithThePendingEpochIsOnDiskWhenTheCreationLands() async throws {
        let store = makeStore()
        let mac = try makeHarness(.mac, store, sample)
        mac.hubSettledAt = mac.generation
        let bookURL = mac.files.bookURL
        let atLanding = DataStash()
        await store.onNextWrite { atLanding.set(try? Data(contentsOf: bookURL)) }

        let created = await mac.pass()
        XCTAssertEqual(created.wroteCloud, true)
        let current = await store.currentHead
        let head = try XCTUnwrap(current)
        let bytes = try XCTUnwrap(atLanding.value, "cloud.json was on disk when the document landed")
        try bytes.write(to: bookURL)
        let saved = mac.files.loadBook()
        XCTAssertEqual(saved.pendingEpoch, head.epoch)
        XCTAssertNil(saved.tag, "saved before the save answered")

        var after = try XCTUnwrap(mac.data)
        after.watches.removeAll { $0.id == "w3" }
        after.watches[1].story = "hub edit"
        let relaunched = try makeHarness(.mac, store, after, folder: mac.files.folder)
        let next = await relaunched.pass()
        XCTAssertNil(next.conflictList, "\(next)")
        let cloud = try await cloudData(store)
        XCTAssertEqual(Set(cloud.watches.map(\.id)), ["w1", "w2"], "the hub's delete is not undone")
        XCTAssertEqual(story(cloud, "w2"), "hub edit")
        XCTAssertEqual(relaunched.session.book.epoch, head.epoch)
    }

    /// R4: a held photo the hub exchange cannot read is not gone. Whatever iCloud's drop rule says, the exchange
    /// stops before sending anything (the readable photo before it included) and drops nothing; once the file reads
    /// again the exchange goes ahead. The address answers nothing, so reaching the network would throw `URLError`.
    func testTheHubExchangeStopsAtAHeldPhotoItCannotRead() async throws {
        let id = "r4-\(UUID().uuidString.prefix(8))"
        var local = sample
        local.wishlist.append(WishlistItem(id: id, name: "Held", brand: "Brand", priceNote: "", notes: "", status: "radar",
                                           added: "2026-11-01", photos: ["a.jpg", "b.jpg"]))
        let assets = CollectionSyncClient.uploads(from: local, hub: sample, hubFiles: [])
        XCTAssertEqual(assets.map(\.filename), ["a.jpg", "b.jpg"])
        let a = try XCTUnwrap(PhotoStore.localURL(for: assets[0]))
        let b = try XCTUnwrap(PhotoStore.localURL(for: assets[1]))
        let folder = a.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: b.path)
            try? FileManager.default.removeItem(at: folder)
        }
        try Data("a".utf8).write(to: a)
        try Data("b".utf8).write(to: b)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: b.path)
        let client = try CollectionSyncClient(address: "http://127.0.0.1:9")
        let remote = SyncSnapshot(data: sample, revision: "r1", photos: [], conflicts: [])
        XCTAssertEqual(CollectionSyncClient.goneFiles(local: local, remote: remote), [], "held, so not gone")

        for dropping: Set<String>? in [nil, [], ["wl-\(id)/b.jpg"]] {
            do {
                _ = try await client.exchange(base: sample, local: local, resolutions: [:], remote: remote, dropping: dropping)
                XCTFail("the exchange went ahead past a photo it could not read")
            } catch let error as UnreadablePhotoError {
                XCTAssertEqual(error.name, "wl-\(id)/b.jpg")
                XCTAssertEqual(error.owner, "Held", "named by its watch (polish 2 item 9)")
                XCTAssertEqual(error.localizedDescription, "A photo of Held on this device could not be read. Sync will retry.")
            } catch {
                XCTFail("\(String(describing: dropping)): reached for the hub instead of stopping: \(error)")
            }
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: b.path))
        XCTAssertNotNil(SyncFailure.classify(UnreadablePhotoError(name: "x/b.jpg")), "a failure the notice can show")
        XCTAssertEqual(UnreadablePhotoError(name: "_box/e.jpg").localizedDescription,
                       "A photo on this device could not be read. Sync will retry.", "no owner: the old words")

        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: b.path)
        do {
            _ = try await client.exchange(base: sample, local: local, resolutions: [:], remote: remote, dropping: nil)
            XCTFail("expected the exchange to reach for the hub")
        } catch {
            XCTAssertNotNil(error as? URLError, "\(error)")
        }
    }

    /// R4: a held file whose read fails during the exchange itself (here a folder where the photo should be, which
    /// passes the check before sending) is not dropped either.
    func testTheHubExchangeKeepsAHeldFileWhoseReadFails() async throws {
        let id = "r4-\(UUID().uuidString.prefix(8))"
        var local = sample
        local.wishlist.append(WishlistItem(id: id, name: "Held", brand: "Brand", priceNote: "", notes: "", status: "radar",
                                           added: "2026-11-01", photos: ["c.jpg"]))
        let assets = CollectionSyncClient.uploads(from: local, hub: sample, hubFiles: [])
        let c = try XCTUnwrap(PhotoStore.localURL(for: try XCTUnwrap(assets.first)))
        let folder = c.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: c, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let client = try CollectionSyncClient(address: "http://127.0.0.1:9")
        let remote = SyncSnapshot(data: sample, revision: "r1", photos: [], conflicts: [])
        do {
            _ = try await client.exchange(base: sample, local: local, resolutions: [:], remote: remote, dropping: nil)
            XCTFail("the exchange went ahead past a photo it could not read")
        } catch let error as UnreadablePhotoError {
            XCTAssertEqual(error.name, "wl-\(id)/c.jpg")
            XCTAssertEqual(error.owner, "Held")
        } catch {
            XCTFail("dropped the reference and reached for the hub: \(error)")
        }
    }

    // MARK: Polish round 2 (docs/icloud-polish2-spec.md)

    /// Item 15: flipping the phone's switch clears the questions and answers of the link it leaves (no pass of that
    /// link runs to send them); the other link's stay. A flip that leaves the same link active clears nothing.
    func testAFlipClearsTheQuestionsOfTheLinkItLeaves() throws {
        func route(joined: Bool, preferHub: Bool) -> SyncRoute {
            SyncRoute.plan(role: .phone, cloudLink: true, joined: joined, preferHub: preferHub)
        }
        func waiting() throws -> SyncConflictSet {
            var set = SyncConflictSet()
            set.set([try hubConflict("h1"), try hubConflict("h2")], for: .hub)
            let merge = CollectionMerge.Conflict(id: "c1", path: ["watches", "w1", "story"], local: .string("phone"),
                                                 remote: .string("mac"), localDeleted: false, remoteDeleted: false)
            set.set([SyncConflict(merge)], for: .cloud)
            set.resolve("h1", choice: "local")
            return set
        }

        let toHub = SyncRoute.linkLeft(from: route(joined: true, preferHub: false), to: route(joined: true, preferHub: true))
        XCTAssertEqual(toHub, .cloud)
        var set = try waiting()
        if let left = toHub { set.clear(left) }
        XCTAssertEqual(set.all.map(\.id), ["h1", "h2"], "the hub, now active, keeps its questions")
        XCTAssertEqual(set.resolutions, ["h1": "local"])

        let toCloud = SyncRoute.linkLeft(from: route(joined: true, preferHub: true), to: route(joined: true, preferHub: false))
        XCTAssertEqual(toCloud, .hub)
        set = try waiting()
        if let left = toCloud { set.clear(left) }
        XCTAssertEqual(set.all.map(\.id), ["c1"], "the hub's questions and its answer go")
        XCTAssertEqual(set.resolutions, [:])

        XCTAssertNil(SyncRoute.linkLeft(from: route(joined: false, preferHub: false), to: route(joined: false, preferHub: true)),
                     "a phone not joined yet: the hub stays active, nothing is cleared")
        XCTAssertNil(SyncRoute.linkLeft(from: .hubThenCloud, to: .hubThenCloud))
    }

    /// Item 5: a run on its own data root never falls back to the real hub. With `-WCHub` it uses that hub; without,
    /// only the address saved for that root, else none. A run on the real data keeps today's chain.
    func testARunOnItsOwnDataNeverFallsBackToTheRealHub() {
        let real = "http://127.0.0.1:8931"
        XCTAssertEqual(AppStore.initialAddress(hub: nil, ownData: true, saved: nil, legacy: "http://legacy:1", fallback: real), "")
        XCTAssertEqual(AppStore.initialAddress(hub: nil, ownData: true, saved: "http://127.0.0.1:9", legacy: "http://legacy:1",
                                               fallback: real), "http://127.0.0.1:9")
        XCTAssertEqual(AppStore.initialAddress(hub: "http://127.0.0.1:7", ownData: true, saved: "http://127.0.0.1:9",
                                               legacy: nil, fallback: real), "http://127.0.0.1:7")
        XCTAssertEqual(AppStore.initialAddress(hub: "", ownData: true, saved: "http://127.0.0.1:9", legacy: nil, fallback: real),
                       "", "an empty -WCHub is no hub for this run")
        // Today's chain on the real data.
        XCTAssertEqual(AppStore.initialAddress(hub: nil, ownData: false, saved: nil, legacy: nil, fallback: real), real)
        XCTAssertEqual(AppStore.initialAddress(hub: nil, ownData: false, saved: nil, legacy: "http://legacy:1", fallback: real),
                       "http://legacy:1")
        XCTAssertEqual(AppStore.initialAddress(hub: nil, ownData: false, saved: "http://saved:1", legacy: "http://legacy:1",
                                               fallback: real), "http://saved:1")
    }

    /// Items 13 and 14 (C1 probe 3): a relaunch has no memory of iCloud yet. Asked for a file gone on both sides,
    /// the session asks iCloud first, and a document that has gone (or a sign-out) since the last launch leaves the
    /// hub exchange today's rule, not a narrowed rule speaking for marks of nothing.
    func testAFreshLaunchAsksICloudBeforeNarrowingTheDropRule() async throws {
        let store = makeStore()
        let folder = root.appendingPathComponent("mac-relaunch", isDirectory: true)
        let mac = try makeHarness(.mac, store, sample, folder: folder)
        mac.hubSettledAt = mac.generation
        let created = await mac.pass()
        XCTAssertEqual(created.wroteCloud, true)
        await store.deleteZone()

        let relaunched = try makeHarness(.mac, store, sample, folder: folder)
        let unasked = await relaunched.session.namesNotInCloud()
        XCTAssertEqual(unasked, [], "nothing gone: the book is trusted as it was")
        var names = await relaunched.session.namesNotInCloud(gone: true)
        XCTAssertNil(names, "the document has gone since the last launch")

        let signedOutStore = makeStore()
        let signedOutFolder = root.appendingPathComponent("mac-relaunch-signed-out", isDirectory: true)
        let before = try makeHarness(.mac, signedOutStore, sample, folder: signedOutFolder)
        before.hubSettledAt = before.generation
        _ = await before.pass()
        await signedOutStore.signIn(nil)
        let after = try makeHarness(.mac, signedOutStore, sample, folder: signedOutFolder)
        names = await after.session.namesNotInCloud(gone: true)
        XCTAssertNil(names, "signed out since the last launch")
    }

    /// Item 13: iCloud is asked only when a file is gone on both sides, at most once every 10 minutes; a pass in
    /// between counts as an answer and restarts the 10 minutes.
    func testTheGateIsAskedOnlyForAGoneFileAndAtMostEveryTenMinutes() async throws {
        let store = makeStore()
        let folder = root.appendingPathComponent("mac-gate", isDirectory: true)
        let mac = try makeHarness(.mac, store, sample, folder: folder)
        mac.hubSettledAt = mac.generation
        _ = await mac.pass()
        let relaunched = try makeHarness(.mac, store, sample, folder: folder)
        let session = relaunched.session
        let start = await store.count(.head)

        _ = await session.namesNotInCloud()
        _ = await session.namesNotInCloud(gone: false)
        var heads = await store.count(.head)
        XCTAssertEqual(heads, start, "nothing gone: iCloud is not asked")

        var names = await session.namesNotInCloud(gone: true)
        XCTAssertEqual(names, [])
        heads = await store.count(.head)
        XCTAssertEqual(heads, start + 1, "asked once")
        clock.advance(9 * 60)
        names = await session.namesNotInCloud(gone: true)
        XCTAssertEqual(names, [])
        heads = await store.count(.head)
        XCTAssertEqual(heads, start + 1, "not again within 10 minutes")
        clock.advance(2 * 60)
        _ = await session.namesNotInCloud(gone: true)
        heads = await store.count(.head)
        XCTAssertEqual(heads, start + 2, "again after")

        clock.advance(9 * 60)
        _ = await relaunched.pass()
        let afterPass = await store.count(.head)
        clock.advance(2 * 60)
        _ = await session.namesNotInCloud(gone: true)
        heads = await store.count(.head)
        XCTAssertEqual(heads, afterPass, "the pass 2 minutes ago is the answer")
        clock.advance(9 * 60)
        _ = await session.namesNotInCloud(gone: true)
        heads = await store.count(.head)
        XCTAssertEqual(heads, afterPass + 1, "10 minutes after the pass")
    }

    /// Item 13: iCloud that cannot be reached says nothing against the narrowed rule: the photo waits, as today.
    func testAnUnreachableICloudKeepsTheNarrowedRule() async throws {
        let store = makeStore()
        let folder = root.appendingPathComponent("mac-offline", isDirectory: true)
        let mac = try makeHarness(.mac, store, sample, folder: folder)
        mac.hubSettledAt = mac.generation
        _ = await mac.pass()
        await store.setOffline(true)
        let relaunched = try makeHarness(.mac, store, sample, folder: folder)
        let accounts = await store.count(.account)
        let names = await relaunched.session.namesNotInCloud(gone: true)
        XCTAssertEqual(names, [], "offline relaunch: the narrowed rule holds")
        let asked = await store.count(.account)
        XCTAssertEqual(asked, accounts + 1, "it did try")
    }

    /// Item 14 (C1 probe 4): the phone's fetch this hub pass reached iCloud signed in, so an older sign-out no longer
    /// holds. A fetch that failed for the network leaves the name out of the set, and the exchange waits for it.
    func testAFetchThatReachedForICloudOutranksAnOldSignOut() async throws {
        let (store, _, phone) = try await joined()
        await store.signIn(nil)
        let signedOut = await phone.pass()
        XCTAssertEqual(signedOut.wait, .noAccount)
        await store.signIn("account-A")
        await store.fail(.download, with: .network)
        await phone.session.fetch(["w1/gone.jpg"])
        let names = await phone.session.namesNotInCloud(gone: true)
        let dropping = try XCTUnwrap(names, "nil would drop the photo everywhere")
        XCTAssertFalse(dropping.contains("w1/gone.jpg"))
        XCTAssertNil(CollectionSyncClient.photoPlan(gone: ["w1/gone.jpg"], dropping: names, keeping: []),
                     "the exchange waits for it")

        // Signed out again; the next hub pass has nothing to fetch, so what this one's fetch learnt does not carry over.
        await store.signIn(nil)
        let again = await phone.pass()
        XCTAssertEqual(again.wait, .noAccount)
        await phone.session.fetch([])
        let later = await phone.session.namesNotInCloud(gone: true)
        XCTAssertNil(later, "the sign-out holds again")
    }

    /// Item 11 (C1 probe 6 turned round): a phone on the hub whose iCloud copy of a photo is damaged waits for it
    /// before the hour, and after the hour keeps it (given up on, reference kept) instead of waiting for ever.
    func testAPhoneOnTheHubStopsWaitingOnADamagedPhoto() async throws {
        let (store, _, phone) = try await joined()
        let name = "w1/damaged.jpg"
        try await store.putPhoto(name, Data("damaged one".utf8))
        try await store.damagePhoto(name)
        var minutes = 0
        var plan: (drop: Set<String>, keep: Set<String>)?
        while minutes <= 120 {
            await phone.session.fetch([name])
            let dropping = await phone.session.namesNotInCloud(gone: true)
            let keeping = await phone.session.namesKeptWithoutFile()
            plan = CollectionSyncClient.photoPlan(gone: [name], dropping: dropping, keeping: keeping)
            if plan != nil { break }
            clock.advance(11 * 60)
            minutes += 11
        }
        XCTAssertEqual(minutes, 66, "waits before the hour, keeps after it")
        XCTAssertEqual(plan?.keep, [name])
        XCTAssertEqual(plan?.drop, [])
        XCTAssertFalse(phone.photos.exists(name))
        XCTAssertTrue(phone.files.loadMarks().kept.contains(name), "saved in cloud-photos.json")
    }

    /// Review F1, the phone: it gave up on w1/k.jpg through iCloud, then flipped to the hub, which served it the
    /// file. No cloud pass runs on the hub link, so the mark stays. The Mac deletes k and the hub answers without it:
    /// the delete sticks here, and nothing sends k back.
    func testAHubDeleteOfAKeptPhotoThePhoneHoldsSticks() async throws {
        let dataRoot = root.appendingPathComponent("phone-data", isDirectory: true)
        let saved = addLaunchArguments(["WCDataRoot": dataRoot.path])
        defer { restoreLaunchArguments(saved) }
        let store = makeStore()
        let mac = try makeHarness(.mac, store, sample)
        mac.hubSettledAt = mac.generation
        _ = await mac.pass()
        let phone = try makeHarness(.phone, store, nil, folder: dataRoot)
        _ = await phone.pass()
        XCTAssertEqual(phone.photos.root.standardizedFileURL.path, AppPaths.photoRoot.standardizedFileURL.path,
                       "the exchange and the cloud link look at one photo folder, as in the app")

        let k = "w1/k.jpg"
        try await store.putPhoto(k, Data("k".utf8))
        try await store.damagePhoto(k)
        for _ in 0..<12 where !phone.files.loadMarks().kept.contains(k) {
            await phone.session.fetch([k])
            if !phone.files.loadMarks().kept.contains(k) { clock.advance(11 * 60) }
        }
        XCTAssertTrue(phone.files.loadMarks().kept.contains(k), "given up on after the hour")
        try phone.photos.put("w1/a.jpg", Data("a".utf8))
        try phone.photos.put(k, Data("k".utf8))   // from the hub
        let keeping = await phone.session.namesKeptWithoutFile()
        XCTAssertFalse(keeping.contains(k), "its file is here: an ordinary photo to the hub")
        XCTAssertTrue(phone.files.loadMarks().kept.contains(k), "the mark itself stays")

        var local = try XCTUnwrap(phone.data)
        local.watches[0].photos = ["a.jpg", "k.jpg"]
        var hub = local
        hub.watches[0].photos = ["a.jpg"]   // the Mac deleted k: the hub has neither it nor its file
        let remote = SyncSnapshot(data: hub, revision: "r2", photos: ["w1/a.jpg"], conflicts: [])
        let gone = CollectionSyncClient.goneFiles(local: local, remote: remote)
        XCTAssertEqual(gone, [])
        let dropping = await phone.session.namesNotInCloud(gone: !Set(gone).subtracting(keeping).isEmpty)
        StubHub.reset { _ in hub }   // the hub's merge: base [a, k], sent [a, k], hub [a] answers [a]
        let client = try CollectionSyncClient(address: "http://127.0.0.1:9", protocolClasses: [StubHub.self])
        let exchanged = try await client.exchange(base: local, local: local, resolutions: [:], remote: remote,
                                                  dropping: dropping, keeping: keeping)
        let result = try XCTUnwrap(exchanged)
        XCTAssertEqual(result.heldBack, [])
        XCTAssertEqual(StubHub.uploads, [k], "its file goes up as any photo's would")
        XCTAssertEqual(StubHub.lastSentCollection?.watches[0].photos, ["a.jpg", "k.jpg"])
        let installed = CollectionSyncClient.restoringPhotos(result.heldBack, from: local, into: result.answer.data)
        XCTAssertEqual(installed.watches[0].photos, ["a.jpg"], "the Mac's delete sticks")

        // The exchange's half alone: told k is kept although its file is here, it holds back nothing.
        let toldExchange = try await client.exchange(base: local, local: local, resolutions: [:], remote: remote,
                                                     dropping: dropping, keeping: [k])
        let told = try XCTUnwrap(toldExchange)
        XCTAssertEqual(told.heldBack, [])
        XCTAssertEqual(CollectionSyncClient.restoringPhotos(told.heldBack, from: local, into: told.answer.data)
            .watches[0].photos, ["a.jpg"])
    }

    /// Review F1, the Mac: it gave up on w1/k.jpg, later got the file from the hub, and its cloud pass cannot reach
    /// the photo push (signed out), so the mark stays. A delete of k made on the phone through the hub sticks here.
    func testAHubDeleteOfAKeptPhotoTheMacHoldsSticks() async throws {
        let dataRoot = root.appendingPathComponent("mac-data", isDirectory: true)
        let saved = addLaunchArguments(["WCDataRoot": dataRoot.path])
        defer { restoreLaunchArguments(saved) }
        let store = makeStore()
        let mac = try makeHarness(.mac, store, sample, folder: dataRoot)
        mac.hubSettledAt = mac.generation
        _ = await mac.pass()
        let phone = try makeHarness(.phone, store, nil)
        _ = await phone.pass()
        XCTAssertEqual(mac.photos.root.standardizedFileURL.path, AppPaths.photoRoot.standardizedFileURL.path)

        let k = "w1/k.jpg"
        try phone.photos.put(k, Data("k".utf8))
        phone.edit { $0.watches[0].photos = ["k.jpg"] }
        let up = await phone.pass()
        XCTAssertEqual(up.wroteCloud, true)
        try await store.damagePhoto(k)
        var installed = false
        for _ in 0..<12 where !installed {
            installed = await mac.pass().installedData != nil
            if !installed { clock.advance(11 * 60) }
        }
        XCTAssertTrue(installed, "given up on after the hour")
        XCTAssertTrue(mac.files.loadMarks().kept.contains(k))
        try mac.photos.put(k, Data("k".utf8))   // from the hub
        await store.signIn(nil)
        let signedOut = await mac.pass()
        XCTAssertEqual(signedOut.wait, .noAccount)
        XCTAssertTrue(mac.files.loadMarks().kept.contains(k), "no photo push ran: the mark stays")
        let keeping = await mac.session.namesKeptWithoutFile()
        XCTAssertFalse(keeping.contains(k))

        let local = try XCTUnwrap(mac.data)
        XCTAssertEqual(local.watches[0].photos, ["k.jpg"])
        var hub = local
        hub.watches[0].photos = []   // deleted on the phone through the hub
        let remote = SyncSnapshot(data: hub, revision: "r2", photos: [], conflicts: [])
        let gone = CollectionSyncClient.goneFiles(local: local, remote: remote)
        let dropping = await mac.session.namesNotInCloud(gone: !Set(gone).subtracting(keeping).isEmpty)
        StubHub.reset { _ in hub }
        let client = try CollectionSyncClient(address: "http://127.0.0.1:9", protocolClasses: [StubHub.self])
        let exchanged = try await client.exchange(base: local, local: local, resolutions: [:], remote: remote,
                                                  dropping: dropping, keeping: keeping)
        let result = try XCTUnwrap(exchanged)
        XCTAssertEqual(result.heldBack, [])
        let restored = CollectionSyncClient.restoringPhotos(result.heldBack, from: local, into: result.answer.data)
        XCTAssertEqual(restored.watches[0].photos, [], "the phone's delete sticks")
    }

    // MARK: Fixtures

    private var allOutcomes: [CloudOutcome] {
        let waits: [CloudWait] = [.noAccount, .noDocument, .needsHubFirst, .erased, .full, .newerFormat, .offline, .busy,
                                  .failed("x"), .sendingPhotos(done: 1, of: 2)]
        return [.upToDate, .installed(sample, wroteCloud: false), .installed(sample, wroteCloud: true), .conflicts([])]
            + waits.map { .waiting($0) }
    }

    /// A cloud pass that left this device and iCloud as they were: no install, no document, no photos sent, no
    /// question asked.
    private static func changedNothing(_ outcome: CloudOutcome) -> Bool {
        if case let .waiting(wait) = outcome, case .sendingPhotos = wait { return false }
        return isWait(outcome)
    }

    private static func isWait(_ outcome: CloudOutcome) -> Bool {
        if case .waiting = outcome { return true }
        return false
    }

    /// The links a tick on this route runs, its cloud pass returning `outcome` (installed and wrote read from it).
    private func tick(_ route: SyncRoute, _ outcome: CloudOutcome?) -> [SyncLinkKind] {
        tick(route, cloud: outcome.map { CloudTick($0) })
    }

    /// The links a tick on this route runs, its cloud pass doing `cloud`.
    private func tick(_ route: SyncRoute, cloud: CloudTick?) -> [SyncLinkKind] {
        var ran: [SyncLinkKind] = []
        var seen: CloudTick?
        while let link = route.next(after: ran, cloud: seen) {
            if link == .cloud { seen = cloud }
            ran.append(link)
            if ran.count > 5 { XCTFail("a tick that does not end"); break }
        }
        return ran
    }

    /// Runs `body` with these launch arguments (`-Key value`) added to the argument domain, then puts it back.
    private func withArguments(_ arguments: [String: String], _ body: () throws -> Void) throws {
        let defaults = UserDefaults.standard
        let domain = UserDefaults.argumentDomain
        let saved = defaults.volatileDomain(forName: domain)
        defaults.setVolatileDomain(saved.merging(arguments) { $1 }, forName: domain)
        defer { defaults.setVolatileDomain(saved, forName: domain) }
        try body()
    }

    private func hubConflict(_ id: String) throws -> SyncConflict {
        let json = #"{"id":"\#(id)","path":["watches","w1","name"],"local":"a","remote":"b","localDeleted":false,"remoteDeleted":false}"#
        return try JSONDecoder().decode(SyncConflict.self, from: Data(json.utf8))
    }

    private var sample: CollectionData {
        CollectionData(
            settings: CollectionSettings(autoBackup: false, backupRemote: "gdrive:backups", autoImage: true,
                                         wrist: WristProfile(inches: 6.75, sweetSpotMin: 38, sweetSpotMax: 41, perfect: 39, lugMax: 48)),
            watches: [watch("w1", "Alpha"), watch("w2", "Bravo"), watch("w3", "Charlie")],
            categories: ["Dive", "Dress"], wishlist: [item("i1", "One")], brandWatchlist: [],
            dialColors: ["Black"], materials: ["Steel"]
        )
    }

    private func watch(_ id: String, _ name: String) -> Watch {
        Watch(id: id, name: name, story: "", purchasedText: "", price: 100, status: "owned", statusNote: "", photos: [])
    }

    private func item(_ id: String, _ name: String) -> WishlistItem {
        WishlistItem(id: id, name: name, brand: "Brand", priceNote: "", notes: "", status: "radar", added: "2026-11-01", photos: [])
    }

    private func story(_ data: CollectionData?, _ id: String) -> String? {
        data?.watches.first { $0.id == id }?.story
    }

    private func makeStore() -> FakeCloudStore {
        FakeCloudStore(folder: root.appendingPathComponent("cloud-\(UUID().uuidString)", isDirectory: true))
    }

    private func makeHarness(_ role: CloudRole, _ store: FakeCloudStore, _ data: CollectionData?,
                             folder: URL? = nil) throws -> Harness {
        let folder = folder ?? root.appendingPathComponent("\(role)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let files = CloudFiles(folder: folder)
        let photos = TempPhotoFiles(root: folder.appendingPathComponent("PhotoStore", isDirectory: true))
        let clock = self.clock!
        let link = CloudLink(store: store, files: photos, marks: files.loadMarks(), role: role, device: "\(role)",
                             now: { clock.now() }, build: "test")
        let session = CloudSyncSession(link: link, role: role, files: files, book: files.loadBook(), now: { clock.now() })
        return Harness(session: session, store: store, files: files, photos: photos, data: data)
    }

    /// The Mac makes the document; a phone with no collection joins it.
    private func joined() async throws -> (store: FakeCloudStore, mac: Harness, phone: Harness) {
        let store = makeStore()
        let mac = try makeHarness(.mac, store, sample)
        mac.hubSettledAt = mac.generation
        let created = await mac.pass()
        XCTAssertEqual(created.wroteCloud, true)
        let phone = try makeHarness(.phone, store, nil)
        let joined = await phone.pass()
        XCTAssertNotNil(joined.installedData)
        XCTAssertTrue(phone.joined)
        return (store, mac, phone)
    }

    private func cloudData(_ store: FakeCloudStore) async throws -> CollectionData {
        let body = try await store.body()
        return try CloudLink.installable(try XCTUnwrap(body), local: nil)
    }
}

/// One device as `AppStore` drives its `CloudSyncSession`: an edit moves the generation and the version, an install
/// takes this device's own settings, rewrites `sync.json` and settles the cloud link.
@MainActor
final class Harness {
    let session: CloudSyncSession
    let store: FakeCloudStore
    let files: CloudFiles
    let photos: TempPhotoFiles
    var data: CollectionData?
    var generation = 0
    var versions = SyncVersions()
    var hubSettledAt: Int?
    var joined = false
    var noBase = false
    var hubConflicts = 0
    private(set) var installs = 0
    private(set) var mirrors = 0
    /// "mirror" and "install", in the order the session called them.
    private(set) var events: [String] = []
    /// The book's tag in `cloud.json` at the moment each install saved the data.
    private(set) var bookTagAtInstall: [String?] = []

    init(session: CloudSyncSession, store: FakeCloudStore, files: CloudFiles, photos: TempPhotoFiles,
         data: CollectionData?) {
        self.session = session
        self.store = store
        self.files = files
        self.photos = photos
        self.data = data
        if let data { versions.note(CloudLink.projection(data)) }
    }

    func edit(_ change: (inout CollectionData) -> Void) {
        guard var current = data else { return }
        change(&current)
        data = current
        generation += 1
        versions.note(CloudLink.projection(current))
    }

    @discardableResult
    func pass() async -> CloudOutcome {
        let files = self.files
        let host = CloudSyncSession.Host(
            local: { [unowned self] in self.data },
            generation: { [unowned self] in self.generation },
            changed: { [unowned self] in !self.versions.isCurrent(.cloud) },
            hubSettledAt: hubSettledAt,
            joinedBefore: joined,
            noBase: noBase,
            hubConflicts: hubConflicts,
            activeLink: joined ? .cloud : .hub,
            install: { [unowned self] installed, local in
                self.events.append("install")
                self.bookTagAtInstall.append(files.loadBook().tag)
                var merged = BoxModel.installing(installed, hubSupportsBoxes: true, local: local)
                if let local { merged.settings.autoBackup = local.settings.autoBackup }
                guard let bytes = try? JSONEncoder().encode(merged), (try? bytes.write(to: files.syncURL)) != nil else {
                    return false
                }
                self.data = merged
                self.versions.note(CloudLink.projection(merged))
                self.versions.settle(.cloud)
                self.installs += 1
                return true
            },
            mirror: { [unowned self] _ in
                self.events.append("mirror")
                self.mirrors += 1
            }
        )
        let outcome = await session.pass(host)
        switch outcome {
        case .installed, .upToDate:
            versions.settle(.cloud)
            if session.role == .phone { joined = true }
        case .conflicts, .waiting:
            break
        }
        return outcome
    }
}

/// What a store hook saw, read back on the test's side.
final class CopyCount: @unchecked Sendable {
    private let lock = NSLock()
    private var seen: Int?

    var value: Int? {
        lock.lock()
        defer { lock.unlock() }
        return seen
    }

    func set(_ count: Int) {
        lock.lock()
        seen = count
        lock.unlock()
    }
}

/// Bytes a store hook read, read back on the test's side.
final class DataStash: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Data?

    var value: Data? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func set(_ data: Data?) {
        lock.lock()
        stored = data
        lock.unlock()
    }
}

/// Moves the phone's edit generation inside every document fetch, as an edit typed during each round would.
final class EditEveryFetch: Sendable {
    let store: FakeCloudStore
    let phone: Harness

    init(store: FakeCloudStore, phone: Harness) {
        self.store = store
        self.phone = phone
    }

    func arm() async {
        await store.onNextDocument { [self] in
            await MainActor.run { self.phone.generation += 1 }
            await self.arm()
        }
    }
}

/// A hub answered in-process, for `CollectionSyncClient(address:protocolClasses:)`: it keeps what each request sent,
/// takes every photo upload, and answers `api/sync` with `answer` given the collection that was sent. One at a time:
/// `reset` before each use.
final class StubHub: URLProtocol {
    struct Sent {
        var path: String
        /// For `api/sync`: the collection sent (`SyncRequest.local`).
        var local: CollectionData?
    }

    private struct Request: Decodable {
        var local: CollectionData
    }

    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var sent: [Sent] = []
        var answer: (CollectionData) -> CollectionData = { $0 }
    }

    private static let state = State()

    /// Forgets what was sent, and answers `api/sync` with `answer` from now on (the collection sent, unchanged, when
    /// not given: a hub with nothing of its own to merge).
    static func reset(answer: @escaping (CollectionData) -> CollectionData = { $0 }) {
        state.lock.lock()
        state.sent = []
        state.answer = answer
        state.lock.unlock()
    }

    static var sent: [Sent] {
        state.lock.lock()
        defer { state.lock.unlock() }
        return state.sent
    }

    /// The collection the last `api/sync` sent.
    static var lastSentCollection: CollectionData? { sent.last { $0.local != nil }?.local }

    /// The photo uploads, as "dir/file".
    static var uploads: [String] {
        sent.compactMap { sent in sent.path.range(of: "/api/sync/photos/").map { String(sent.path[$0.upperBound...]) } }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let path = request.url?.path ?? ""
        let body = request.httpBody ?? request.httpBodyStream.map(Self.read)
        var reply = Data("{}".utf8)
        var status = 200
        if path.hasSuffix("/api/sync"), let body, let sent = try? JSONDecoder().decode(Request.self, from: body) {
            Self.state.lock.lock()
            Self.state.sent.append(Sent(path: path, local: sent.local))
            let answer = Self.state.answer
            Self.state.lock.unlock()
            if let data = try? JSONEncoder().encode(answer(sent.local)) {
                reply = Data(#"{"revision":"stub","photos":[],"conflicts":[],"features":["boxes"],"data":"#.utf8) + data
                    + Data("}".utf8)
            } else {
                status = 500
            }
        } else {
            Self.state.lock.lock()
            Self.state.sent.append(Sent(path: path, local: nil))
            Self.state.lock.unlock()
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func read(_ stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

/// Adds launch arguments (`-Key value`) to the argument domain; returns what to put back with `restoreLaunchArguments`.
func addLaunchArguments(_ arguments: [String: String]) -> [String: Any] {
    let defaults = UserDefaults.standard
    let saved = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
    defaults.setVolatileDomain(saved.merging(arguments) { $1 }, forName: UserDefaults.argumentDomain)
    return saved
}

func restoreLaunchArguments(_ saved: [String: Any]) {
    UserDefaults.standard.setVolatileDomain(saved, forName: UserDefaults.argumentDomain)
}
