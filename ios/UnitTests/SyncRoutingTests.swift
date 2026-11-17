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

    func testTheCopyBeforeICloudIsMadeOnceBeforeTheFirstCloudPass() async throws {
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
                       "a copy of sync.json as it was before the install rewrote it")
        XCTAssertEqual(mac.mirrors, 1, "the JSON mirror once, whatever autoBackup says")
        XCTAssertEqual(mac.events, ["mirror", "install"])

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

    /// The links a tick on this route runs, its cloud pass returning `outcome`.
    private func tick(_ route: SyncRoute, _ outcome: CloudOutcome?) -> [SyncLinkKind] {
        var ran: [SyncLinkKind] = []
        var seen: CloudOutcome?
        while let link = route.next(after: ran, cloud: seen) {
            if link == .cloud { seen = outcome }
            ran.append(link)
            if ran.count > 5 { XCTFail("a tick that does not end"); break }
        }
        return ran
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
