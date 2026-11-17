import XCTest
@testable import WatchCollection

/// `CloudLink` (docs/icloud-plan.md sections 4, 5, 6 and 8) against `FakeCloudStore`: two or three devices on one
/// fake iCloud, each with its own temp photo folder, all on one hand-moved clock. `Device` does what P4's caller will:
/// it builds `CloudInput`, installs an `.installed` result (data first, then the book) and keeps the book.
/// Tests 01 to 19 are the plan's list, in its order. 20 and 24: the restart after an erase; 21: `Status`; 22: the
/// throttle; 23: a build problem.
final class CloudLinkTests: XCTestCase {
    private var root: URL!
    private var clock: TestClock!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("CloudLinkTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        clock = TestClock()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: 1 to 2: who makes the document

    func test01MacCreatesOnlyAfterACleanHubPassAndAfterItsPhotos() async throws {
        let store = makeStore()
        var data = sample
        data.watches[0].photos = ["a.jpg", "b.jpg"]
        data.emptyBoxTiles = ["black": "empty-black-1a2b3c4d.jpg"]
        let mac = makeDevice(.mac, store, data)
        for name in ["w1/a.jpg", "w1/b.jpg", "_box/empty-black-1a2b3c4d.jpg"] { try mac.files.put(name, bytes(name)) }

        let early = await mac.pass()
        XCTAssertEqual(early.wait, .needsHubFirst)
        let earlyLog = await store.log
        XCTAssertEqual(earlyLog, [], "nothing goes up before a clean hub pass, photos included")

        mac.hubSettledNow = true
        let created = await mac.pass()
        XCTAssertEqual(created.wroteCloud, true)
        let log = await store.log
        XCTAssertEqual(log.last, "document mac")
        XCTAssertEqual(Set(log.dropLast()), ["photo w1/a.jpg", "photo w1/b.jpg", "photo _box/empty-black-1a2b3c4d.jpg"])

        let head = try await XCTUnwrapAsync(await store.currentHead)
        XCTAssertEqual(mac.book.epoch, head.epoch)
        XCTAssertEqual(mac.book.tag, head.tag)
        XCTAssertEqual(mac.book.revision, head.revision)
        XCTAssertNotNil(mac.book.base)
        let body = try await store.body()
        XCTAssertEqual(body, CollectionMerge.normalize(try JSONValue(encoding: data)), "the body is the Mac's synced projection")
        let marks = await mac.link.marks
        XCTAssertEqual(marks.epoch, head.epoch)
        XCTAssertEqual(marks.inCloud, ["w1/a.jpg", "w1/b.jpg", "_box/empty-black-1a2b3c4d.jpg"])
    }

    func test02PhoneNeverCreatesTheDocument() async throws {
        let store = makeStore()
        let phone = makeDevice(.phone, store, sample)
        phone.hubBase = sample
        phone.hubSettledNow = true
        try phone.files.put("w1/a.jpg", bytes("a"))
        phone.edit { $0.watches[0].photos = ["a.jpg"] }

        let outcome = await phone.pass()
        XCTAssertEqual(outcome.wait, .noDocument)
        let head = await store.currentHead
        let calls = await store.calls
        XCTAssertNil(head)
        XCTAssertEqual(calls[.write, default: 0] + calls[.upload, default: 0] + calls[.presence, default: 0], 0)
        XCTAssertNil(phone.book.epoch)
    }

    // MARK: 3 to 6: what base a device joins with

    func test03StalePhoneJoinsWithItsHubBase() async throws {
        let hub0 = sample
        var hub1 = hub0                      // the Mac's library, 11 hours on
        hub1.watches.append(watch("w4", "Delta"))
        hub1.watches[1].story = "serviced"
        hub1.wishlist.removeAll { $0.id == "i2" }
        hub1.watches[2].name = "Charlie (Mac)"
        var offline = hub0                   // the phone's own edits since its last hub sync
        offline.watches[0].story = "phone note"
        offline.wishlist.append(item("i3", "Three"))
        offline.watches[2].name = "Charlie (phone)"

        let store = makeStore()
        let mac = makeDevice(.mac, store, hub1)
        mac.hubSettledNow = true
        _ = await mac.pass()
        let phone = makeDevice(.phone, store, offline)
        phone.hubBase = hub0

        let asked = await phone.pass()
        let conflicts = try XCTUnwrap(asked.conflictList)
        XCTAssertEqual(conflicts.map(\.path), [["watches", "w3", "name"]], "only the field changed on both sides asks")
        XCTAssertEqual(conflicts.first?.local, .string("Charlie (phone)"))
        XCTAssertEqual(conflicts.first?.remote, .string("Charlie (Mac)"))
        let writesAfterAsk = await store.writes
        XCTAssertEqual(writesAfterAsk, ["mac"])

        phone.resolutions[conflicts[0].id] = "local"
        let joined = await phone.pass()
        XCTAssertEqual(joined.wroteCloud, true)
        let data = try XCTUnwrap(phone.data)
        XCTAssertEqual(watchIDs(data), ["w1", "w2", "w3", "w4"], "the Mac's add arrives")
        XCTAssertEqual(story(data, "w2"), "serviced", "the Mac's edit arrives")
        XCTAssertEqual(wishlistIDs(data), ["i1", "i3"], "the Mac's delete holds and the phone's add stays")
        XCTAssertEqual(story(data, "w1"), "phone note")
        XCTAssertEqual(data.watches.first { $0.id == "w3" }?.name, "Charlie (phone)")

        let cloud = try await cloudData(store)
        XCTAssertEqual(story(cloud, "w1"), "phone note", "the phone's edits go up")
        XCTAssertEqual(wishlistIDs(cloud), ["i1", "i3"], "the deleted item is not resurrected")

        let macTakes = await mac.pass()
        XCTAssertEqual(macTakes.wroteCloud, false)
        XCTAssertNil(macTakes.conflictList)
        XCTAssertEqual(story(mac.data, "w1"), "phone note")
        XCTAssertEqual(wishlistIDs(mac.data), ["i1", "i3"])
        XCTAssertEqual(mac.data?.watches.first { $0.id == "w3" }?.name, "Charlie (phone)")

        let phoneAgain = await phone.pass()
        let macAgain = await mac.pass()
        XCTAssertTrue(phoneAgain.isUpToDate, "asked once: nothing more")
        XCTAssertTrue(macAgain.isUpToDate)
        let writes = await store.writes
        XCTAssertEqual(writes, ["mac", "phone"])
    }

    func test04PhoneAheadOfICloudWritesNothingAboutThoseFieldsAndConverges() async throws {
        let hub0 = sample                    // what the Mac made the document from
        var hub1 = hub0                      // the hub moved on; the phone saw it, the bridge not yet
        hub1.watches[0].story = "v1"
        var phoneData = hub1
        phoneData.watches[1].story = "phone edit"

        let store = makeStore()
        let mac = makeDevice(.mac, store, hub0)
        mac.hubSettledNow = true
        _ = await mac.pass()
        let phone = makeDevice(.phone, store, phoneData)
        phone.hubBase = hub1

        let join = await phone.pass()
        XCTAssertEqual(join.wroteCloud, true, "its own edit goes up")
        var cloud = try await cloudData(store)
        XCTAssertEqual(story(cloud, "w1"), "", "nothing written about w1: iCloud keeps what it had")
        XCTAssertEqual(story(cloud, "w2"), "phone edit")
        XCTAssertEqual(story(phone.data, "w1"), "", "briefly the older value")

        // The Mac's hub pass brings it up to the hub, then its cloud pass.
        mac.edit { $0.watches[0].story = "v1" }
        let macPass = await mac.pass()
        XCTAssertEqual(macPass.wroteCloud, true)
        XCTAssertEqual(story(mac.data, "w2"), "phone edit")

        let back = await phone.pass()
        XCTAssertNotNil(back.installedData)
        XCTAssertEqual(story(phone.data, "w1"), "v1", "the phone converges to the hub's value")
        XCTAssertEqual(story(phone.data, "w2"), "phone edit")
        cloud = try await cloudData(store)
        XCTAssertEqual(story(cloud, "w1"), "v1")
    }

    func test05MacJoiningAnExistingDocumentUsesNoBase() async throws {
        var cloudSide = sample
        cloudSide.watches[0].story = "from iCloud"
        cloudSide.watches.append(watch("w8", "Only in iCloud"))
        var hubSide = sample
        hubSide.watches[0].story = "hub, newer"
        hubSide.watches.append(watch("w9", "Only in the hub"))

        let store = makeStore()
        let body = CollectionMerge.normalize(try JSONValue(encoding: cloudSide)).canonicalData
        await store.setDocument(body, epoch: "epoch-1")
        let mac = makeDevice(.mac, store, hubSide)
        mac.hubSettledNow = true
        // Borrowed, this base would make "hub, newer" look unedited (iCloud's value would win) and w9 look deleted.
        mac.hubBase = hubSide

        let asked = await mac.pass()
        let conflicts = try XCTUnwrap(asked.conflictList)
        XCTAssertEqual(conflicts.map(\.path), [["watches", "w1", "story"]])
        let writes = await store.writes
        XCTAssertEqual(writes, [])

        mac.resolutions[conflicts[0].id] = "local"
        let answered = await mac.pass()
        XCTAssertEqual(answered.wroteCloud, true)
        let cloud = try await cloudData(store)
        XCTAssertEqual(story(cloud, "w1"), "hub, newer")
        XCTAssertEqual(watchIDs(cloud), ["w1", "w2", "w3", "w8", "w9"], "union: nothing deleted")
        XCTAssertEqual(mac.book.epoch, "epoch-1")
    }

    func test06EpochChangeMergesWithNoBaseAndDeletesNothing() async throws {
        let (store, mac, phone) = try await joined(sample)
        let firstEpoch = phone.book.epoch

        // The document goes (a Development reset), and the Mac makes a new one from a library without w2 and i1.
        await store.deleteZone()
        mac.edit {
            $0.watches.removeAll { $0.id == "w2" }
            $0.wishlist.removeAll { $0.id == "i1" }
            $0.watches.append(watch("w5", "Echo"))
        }
        let remade = await mac.pass()
        XCTAssertEqual(remade.wroteCloud, true)
        let secondEpoch = try XCTUnwrap(mac.book.epoch)
        XCTAssertNotEqual(firstEpoch, secondEpoch)

        let merged = await phone.pass()
        XCTAssertEqual(merged.wroteCloud, true)
        XCTAssertEqual(watchIDs(phone.data), ["w1", "w2", "w3", "w5"], "nothing deleted, the new watch arrives")
        XCTAssertEqual(wishlistIDs(phone.data), ["i1", "i2"])
        XCTAssertEqual(phone.book.epoch, secondEpoch)
        let cloud = try await cloudData(store)
        XCTAssertEqual(watchIDs(cloud), ["w1", "w2", "w3", "w5"])
    }

    // MARK: 7 to 9: passes

    func test07RoundTripBothWaysThenNothingMoves() async throws {
        let (store, mac, phone) = try await joined(sample)
        let fetchesAtJoin = await store.count(.document)
        let phoneIdle = await phone.pass()
        let macIdle = await mac.pass()
        XCTAssertTrue(phoneIdle.isUpToDate)
        XCTAssertTrue(macIdle.isUpToDate)
        let fetchesIdle = await store.count(.document)
        XCTAssertEqual(fetchesIdle, fetchesAtJoin, "a settled pass reads the head only")

        phone.edit { $0.watches[0].story = "worn today" }
        let up = await phone.pass()
        XCTAssertEqual(up.wroteCloud, true)
        let macTakes = await mac.pass()
        XCTAssertEqual(macTakes.wroteCloud, false)
        XCTAssertEqual(story(mac.data, "w1"), "worn today")

        mac.edit { $0.wishlist[0].notes = "price dropped" }
        let down = await mac.pass()
        XCTAssertEqual(down.wroteCloud, true)
        let phoneTakes = await phone.pass()
        XCTAssertEqual(phoneTakes.wroteCloud, false)
        XCTAssertEqual(phone.data?.wishlist.first { $0.id == "i1" }?.notes, "price dropped")

        let writes = await store.writes
        XCTAssertEqual(writes, ["mac", "phone", "mac"])
        let fetches = await store.count(.document)
        for _ in 0..<2 {
            let phoneAgain = await phone.pass()
            let macAgain = await mac.pass()
            XCTAssertTrue(phoneAgain.isUpToDate)
            XCTAssertTrue(macAgain.isUpToDate)
        }
        let writesAfter = await store.writes
        let fetchesAfter = await store.count(.document)
        XCTAssertEqual(writesAfter, writes, "no ping-pong")
        XCTAssertEqual(fetchesAfter, fetches)
    }

    func test08CompetingWriteIsMergedAgainAndWrittenOnce() async throws {
        let (store, mac, phone) = try await joined(sample)
        phone.edit { $0.watches[0].story = "phone" }
        mac.edit { $0.watches[1].story = "mac" }
        // The Mac saves between the phone's fetch and the phone's save.
        await store.onNextDocument { _ = await mac.pass() }

        let outcome = await phone.pass()
        XCTAssertEqual(outcome.wroteCloud, true)
        let writes = await store.writes
        let saves = await store.count(.write)
        XCTAssertEqual(writes, ["mac", "mac", "phone"], "the phone's one save that landed")
        XCTAssertEqual(saves, 4, "the phone's first save, over the version the Mac replaced, was refused")
        let cloud = try await cloudData(store)
        XCTAssertEqual(story(cloud, "w1"), "phone")
        XCTAssertEqual(story(cloud, "w2"), "mac")
        XCTAssertEqual(story(phone.data, "w2"), "mac")

        let macTakes = await mac.pass()
        XCTAssertNotNil(macTakes.installedData)
        XCTAssertEqual(story(mac.data, "w1"), "phone")
    }

    func test09ConflictWritesNothingUntilAnswered() async throws {
        let (store, mac, phone) = try await joined(sample)
        mac.edit { $0.watches[0].story = "mac" }
        _ = await mac.pass()
        phone.edit { $0.watches[0].story = "phone" }
        let writesBefore = await store.writes

        let asked = await phone.pass()
        let conflicts = try XCTUnwrap(asked.conflictList)
        XCTAssertEqual(conflicts.count, 1)
        XCTAssertEqual(conflicts.first?.path, ["watches", "w1", "story"])
        let writesAsked = await store.writes
        XCTAssertEqual(writesAsked, writesBefore, "a pass with conflicts writes nothing")
        XCTAssertEqual(story(phone.data, "w1"), "phone")
        let waitingStatus = await store.status("status-iphone")
        XCTAssertEqual(waitingStatus?.conflicts, 1)

        phone.resolutions[conflicts[0].id] = "local"
        let answered = await phone.pass()
        XCTAssertEqual(answered.wroteCloud, true)
        let cloud = try await cloudData(store)
        XCTAssertEqual(story(cloud, "w1"), "phone")
        let settledStatus = await store.status("status-iphone")
        XCTAssertEqual(settledStatus?.conflicts, 0)

        let macTakes = await mac.pass()
        XCTAssertNotNil(macTakes.installedData)
        XCTAssertEqual(story(mac.data, "w1"), "phone", "the other device takes the chosen value")
    }

    // MARK: 10 to 12: photos

    func test10aDocumentWaitsUntilHeldPhotosAreUp() async throws {
        let (store, _, phone) = try await joined(sample)
        for name in ["wl-i9/p1.jpg", "wl-i9/p2.jpg"] { try phone.files.put(name, bytes(name)) }
        phone.edit { $0.wishlist.append(item("i9", "Nine", photos: ["p1.jpg", "p2.jpg"])) }

        await store.fail(.upload, with: .network)
        let blocked = await phone.pass()
        XCTAssertEqual(blocked.wait, .offline)
        let writesBlocked = await store.writes
        XCTAssertEqual(writesBlocked, ["mac"])
        let cloudBlocked = try await cloudData(store)
        XCTAssertFalse(wishlistIDs(cloudBlocked).contains("i9"))

        await store.fail(.upload, with: nil)
        let sent = await phone.pass()
        XCTAssertEqual(sent.wroteCloud, true)
        let log = await store.log
        XCTAssertEqual(Array(log.suffix(3)), ["photo wl-i9/p1.jpg", "photo wl-i9/p2.jpg", "document phone"])
    }

    func test10bPhotoAlreadyThereIsAdoptedAndAMismatchIsNeverRetried() async throws {
        let (store, _, phone) = try await joined(sample)
        try await store.putPhoto("wl-i9/there.jpg", bytes("wl-i9/there.jpg"))
        try await store.putPhoto("wl-i9/race.jpg", bytes("wl-i9/race.jpg"))
        try await store.putPhoto("wl-i9/other.jpg", Data("someone else's bytes".utf8))
        // Sent by another device just after this one asked. The existence check answers by name only (section 4
        // step 5 asks with no fields), so other bytes under a name show only when an upload of it is refused.
        await store.hideFromPresence(["wl-i9/race.jpg", "wl-i9/other.jpg"])
        for name in ["there", "race", "other"] { try phone.files.put("wl-i9/\(name).jpg", bytes("wl-i9/\(name).jpg")) }
        phone.edit { $0.wishlist.append(item("i9", "Nine", photos: ["there.jpg", "race.jpg", "other.jpg"])) }

        let outcome = await phone.pass()
        XCTAssertEqual(outcome.wroteCloud, true, "a mismatch does not hold the document up")
        let calls = await store.uploadCalls
        let saves = await store.photoSaves
        XCTAssertEqual(calls, ["wl-i9/race.jpg": 1, "wl-i9/other.jpg": 1])
        XCTAssertEqual(saves, [], "nothing new was stored")
        let marks = await phone.link.marks
        XCTAssertTrue(marks.inCloud.isSuperset(of: ["wl-i9/there.jpg", "wl-i9/race.jpg"]))
        XCTAssertEqual(marks.mismatched, ["wl-i9/other.jpg"])

        phone.edit { $0.wishlist[$0.wishlist.count - 1].notes = "again" }
        let again = await phone.pass()
        XCTAssertEqual(again.wroteCloud, true)
        let callsAfter = await store.uploadCalls
        XCTAssertEqual(callsAfter["wl-i9/other.jpg"], 1, "never retried")
    }

    func test10cPhotoNotHeldNeitherBlocksNorIsDropped() async throws {
        let (store, _, phone) = try await joined(sample)
        try phone.files.put("wl-i9/have.jpg", bytes("have"))
        phone.edit { $0.wishlist.append(item("i9", "Nine", photos: ["have.jpg", "elsewhere.jpg"])) }

        let outcome = await phone.pass()
        XCTAssertEqual(outcome.wroteCloud, true)
        let cloud = try await cloudData(store)
        XCTAssertEqual(cloud.wishlist.first { $0.id == "i9" }?.photos, ["have.jpg", "elsewhere.jpg"])
        let saves = await store.photoSaves
        XCTAssertEqual(saves, ["wl-i9/have.jpg"])
    }

    func test10dTwoDevicesSendingTheSameSetSendEachPhotoOnce() async throws {
        let (store, mac, phone) = try await joined(sample)
        let names = (1...25).map { String(format: "p%02d.jpg", $0) }
        for device in [mac, phone] {
            for name in names { try device.files.put("wl-i9/\(name)", bytes(name)) }
            device.edit { $0.wishlist.append(item("i9", "Nine", photos: names)) }
        }
        // The Mac starts its pass once the phone has sent its first batch.
        await store.onUpload(CloudLink.uploadBatch) { _ = await mac.pass() }

        let phoneOutcome = await phone.pass()
        XCTAssertNil(phoneOutcome.wait)
        XCTAssertNil(phoneOutcome.conflictList)
        let calls = await store.uploadCalls
        let saves = await store.photoSaves
        XCTAssertEqual(calls.count, 25)
        XCTAssertEqual(Set(calls.values), [1], "each photo sent once")
        XCTAssertEqual(saves.count, 25)
        let cloud = try await cloudData(store)
        XCTAssertEqual(cloud.wishlist.first { $0.id == "i9" }?.photos, names)
    }

    func test10eLongSendReturnsProgressAndResumesFromTheMarks() async throws {
        let store = makeStore()
        var data = sample
        let names = (1...5).map { "p\($0).jpg" }
        data.watches[0].photos = names
        let mac = makeDevice(.mac, store, data, budget: 10)
        for name in names { try mac.files.put("w1/\(name)", bytes(name)) }
        mac.hubSettledNow = true
        let clock = clock!
        await store.onEveryUpload { clock.advance(6) }   // each photo takes 6 s to send

        let first = await mac.pass()
        XCTAssertEqual(first.wait, .sendingPhotos(done: 2, of: 5))
        let second = await mac.pass()
        XCTAssertEqual(second.wait, .sendingPhotos(done: 4, of: 5))
        let headBefore = await store.currentHead
        XCTAssertNil(headBefore, "no document while photos are outstanding")
        let third = await mac.pass()
        XCTAssertEqual(third.wroteCloud, true)
        let calls = await store.uploadCalls
        XCTAssertEqual(calls.count, 5)
        XCTAssertEqual(Set(calls.values), [1])
    }

    func test11MacInstallWaitsOnANetworkFailureAndGoesOnWhenICloudLacksThePhoto() async throws {
        let (store, mac, phone) = try await joined(sample)
        try phone.files.put("wl-i9/p1.jpg", bytes("p1"))
        phone.edit { $0.wishlist.append(item("i9", "Nine", photos: ["p1.jpg", "p2.jpg"])) }   // p2 is on no device
        _ = await phone.pass()
        let tagBefore = mac.book.tag

        await store.fail(.download, with: .network)
        let waiting = await mac.pass()
        XCTAssertEqual(waiting.wait, .offline)
        XCTAssertFalse(wishlistIDs(mac.data).contains("i9"), "not installed")
        XCTAssertEqual(mac.book.tag, tagBefore)

        await store.fail(.download, with: nil)
        let installed = await mac.pass()
        XCTAssertNotNil(installed.installedData)
        XCTAssertEqual(mac.data?.wishlist.first { $0.id == "i9" }?.photos, ["p1.jpg", "p2.jpg"])
        XCTAssertTrue(mac.files.exists("wl-i9/p1.jpg"))
        XCTAssertFalse(mac.files.exists("wl-i9/p2.jpg"))
        let marks = await mac.link.marks
        XCTAssertTrue(marks.saysMissing("wl-i9/p2.jpg"))
        XCTAssertFalse(marks.saysMissing("wl-i9/p1.jpg"))

        let downloadsBefore = await store.count(.download)
        let settled = await mac.pass()
        XCTAssertTrue(settled.isUpToDate, "a photo iCloud lacks is not asked about again at once")
        let downloadsAfter = await store.count(.download)
        XCTAssertEqual(downloadsAfter, downloadsBefore)
    }

    func test12PhoneInstallsFirstAndFillsPhotosLater() async throws {
        let store = makeStore()
        var data = sample
        let names = (1...7).map { "f\($0).jpg" }
        data.watches[0].photos = names
        let mac = makeDevice(.mac, store, data)
        for name in names { try mac.files.put("w1/\(name)", bytes(name)) }
        mac.hubSettledNow = true
        _ = await mac.pass()

        let phone = makeDevice(.phone, store, nil)
        let joined = await phone.pass()
        XCTAssertNotNil(joined.installedData, "the collection shows at once")
        XCTAssertFalse(names.contains { phone.files.exists("w1/\($0)") })
        let downloadsAtJoin = await store.downloads
        XCTAssertEqual(downloadsAtJoin, [])

        let installed = try XCTUnwrap(phone.data)
        await phone.link.fillPhotos(for: installed, allowBulk: false)
        let downloadsOnCellular = await store.downloads
        XCTAssertEqual(downloadsOnCellular, [], "nothing in bulk on an expensive path")

        await store.setDownloadDelay(milliseconds: 5)
        await phone.link.fillPhotos(for: installed, allowBulk: true)
        XCTAssertTrue(names.allSatisfy { phone.files.exists("w1/\($0)") })
        let downloads = await store.downloads
        let widest = await store.maxDownloadsInFlight
        XCTAssertEqual(downloads.count, names.count)
        XCTAssertLessThanOrEqual(widest, 3)
        let marks = await phone.link.marks
        XCTAssertTrue(marks.inCloud.isSuperset(of: Set(names.map { "w1/\($0)" })))
    }

    // MARK: 13 to 15: section 8

    func test13QuotaFullWaitsTenMinutesThenTheEditGoesUp() async throws {
        let (store, _, phone) = try await joined(sample)
        phone.edit { $0.watches[0].story = "kept on this iPhone" }
        await store.setQuotaFull(true)

        let full = await phone.pass()
        XCTAssertEqual(full.wait, .full)
        XCTAssertEqual(phone.book.quotaFullAt, clock.now())
        let callsAtFull = await totalCalls(store)

        clock.advance(5 * 60)
        let inside = await phone.pass()
        XCTAssertEqual(inside.wait, .full)
        await store.setQuotaFull(false)
        clock.advance(4 * 60)
        let stillInside = await phone.pass()
        XCTAssertEqual(stillInside.wait, .full)
        let callsInside = await totalCalls(store)
        XCTAssertEqual(callsInside, callsAtFull, "no retry inside 10 minutes")

        clock.advance(2 * 60)
        let after = await phone.pass()
        XCTAssertEqual(after.wroteCloud, true)
        XCTAssertNil(phone.book.quotaFullAt)
        let cloud = try await cloudData(store)
        XCTAssertEqual(story(cloud, "w1"), "kept on this iPhone")
    }

    func test14ErasedPausesUploadsNothingAndANewEpochResumesThePhone() async throws {
        let (store, mac, phone) = try await joined(sample)
        try phone.files.put("wl-i9/p1.jpg", bytes("p1"))
        phone.edit { $0.wishlist.append(item("i9", "Nine", photos: ["p1.jpg"])) }
        let phoneBefore = phone.data.flatMap(CloudLink.projection)
        let macBefore = mac.data.flatMap(CloudLink.projection)
        await store.eraseByUser()

        let erased = await phone.pass()
        XCTAssertEqual(erased.wait, .erased)
        XCTAssertEqual(phone.book.paused, .erased)
        let fetches = await store.count(.document)
        let again = await phone.pass()
        XCTAssertEqual(again.wait, .erased)
        let fetchesAfter = await store.count(.document)
        XCTAssertEqual(fetchesAfter, fetches, "paused: the head only")
        let macErased = await mac.pass()
        XCTAssertEqual(macErased.wait, .erased)
        XCTAssertEqual(mac.book.paused, .erased)
        let uploads = await store.uploadCalls
        let writes = await store.writes
        XCTAssertEqual(uploads, [:], "nothing uploaded")
        XCTAssertEqual(writes, ["mac"])
        XCTAssertEqual(phone.data.flatMap(CloudLink.projection), phoneBefore, "local data intact")
        XCTAssertEqual(mac.data.flatMap(CloudLink.projection), macBefore)

        // A document under a new epoch (the Mac's restart) resumes the phone, joining it with no base.
        let body = CollectionMerge.normalize(try JSONValue(encoding: try XCTUnwrap(mac.data))).canonicalData
        await store.setDocument(body, epoch: "epoch-after-erase", device: "mac")
        let resumed = await phone.pass()
        XCTAssertEqual(resumed.wroteCloud, true)
        XCTAssertNil(phone.book.paused)
        XCTAssertEqual(phone.book.epoch, "epoch-after-erase")
        XCTAssertTrue(wishlistIDs(phone.data).contains("i9"))
        let cloud = try await cloudData(store)
        XCTAssertTrue(wishlistIDs(cloud).contains("i9"))
        let saves = await store.photoSaves
        XCTAssertEqual(saves, ["wl-i9/p1.jpg"])
    }

    func test15AccountSwitchClearsBookAndMarksAndKeepsData() async throws {
        var data = sample
        data.watches[0].photos = ["a.jpg"]
        let store = makeStore()
        let mac = makeDevice(.mac, store, data)
        try mac.files.put("w1/a.jpg", bytes("a"))
        mac.hubSettledNow = true
        _ = await mac.pass()
        let phone = makeDevice(.phone, store, nil)
        _ = await phone.pass()
        await phone.link.fillPhotos(for: try XCTUnwrap(phone.data), allowBulk: true)
        let joinedBook = phone.book
        let projection = phone.data.flatMap(CloudLink.projection)

        await store.signIn(nil)
        let signedOut = await phone.pass()
        XCTAssertEqual(signedOut.wait, .noAccount)
        XCTAssertEqual(phone.book.tag, joinedBook.tag)
        XCTAssertNotNil(phone.book.base)

        await store.signIn("account-A")
        let fetches = await store.count(.document)
        let back = await phone.pass()
        XCTAssertTrue(back.isUpToDate, "the same account again: the book still holds")
        XCTAssertEqual(phone.book.epoch, joinedBook.epoch)
        let fetchesBack = await store.count(.document)
        XCTAssertEqual(fetchesBack, fetches)
        let marksBack = await phone.link.marks
        XCTAssertEqual(marksBack.inCloud, ["w1/a.jpg"])

        await store.signIn("account-B")
        let other = await phone.pass()
        XCTAssertEqual(other.wait, .noDocument)
        XCTAssertEqual(phone.book.account, "account-B")
        XCTAssertNil(phone.book.epoch)
        XCTAssertNil(phone.book.tag)
        XCTAssertNil(phone.book.base)
        XCTAssertNil(phone.book.systemFields)
        let marks = await phone.link.marks
        XCTAssertEqual(marks, CloudPhotoMarks(account: "account-B"))
        XCTAssertEqual(phone.data.flatMap(CloudLink.projection), projection, "all local data kept")
        XCTAssertTrue(phone.files.exists("w1/a.jpg"))
    }

    // MARK: 16 to 19: the document itself

    func test16UnknownKeysFromANewerBuildSurviveAnOlderOnesPass() async throws {
        let (store, mac, phone) = try await joined(sample)
        // A newer build rewrites the document with keys this build does not know.
        guard case var .object(top)? = try await store.body() else { return XCTFail("no document") }
        top["lenses"] = .object(["count": .number(3)])
        top["settings"] = edited(top["settings"]) { $0["theme"] = .string("dark") }
        top["watches"] = editedEntry(top["watches"], id: "w1") { $0["strapLog"] = .array([.string("nato")]) }
        top["wishlist"] = editedEntry(top["wishlist"], id: "i1") { $0["alerts"] = .bool(true) }
        let epoch = try await XCTUnwrapAsync(await store.currentHead).epoch
        await store.setDocument(JSONValue.object(top).canonicalData, epoch: epoch, device: "newer")

        phone.edit { $0.watches[1].story = "older build's edit" }
        let phonePass = await phone.pass()
        XCTAssertEqual(phonePass.wroteCloud, true)
        try await assertUnknownKeysKept(store)
        let afterPhone = try await cloudData(store)
        XCTAssertEqual(story(afterPhone, "w2"), "older build's edit")

        mac.edit { $0.watches[2].story = "another older build's edit" }
        let macPass = await mac.pass()
        XCTAssertEqual(macPass.wroteCloud, true)
        try await assertUnknownKeysKept(store)
        let afterMac = try await cloudData(store)
        XCTAssertEqual(story(afterMac, "w3"), "another older build's edit")
    }

    func test17BodyThatFailsItsChecksumIsNeitherInstalledNorOverwritten() async throws {
        let (store, mac, phone) = try await joined(sample)
        mac.edit { $0.watches[0].story = "mac" }
        _ = await mac.pass()
        await store.corruptRevision()
        phone.edit { $0.watches[1].story = "phone" }
        let tagBefore = phone.book.tag
        let writesBefore = await store.writes

        let outcome = await phone.pass()
        guard case .failed? = outcome.wait else { return XCTFail("expected a failed fetch, got \(outcome)") }
        XCTAssertEqual(story(phone.data, "w1"), "", "not installed")
        XCTAssertEqual(phone.book.tag, tagBefore)
        let writes = await store.writes
        XCTAssertEqual(writes, writesBefore, "not overwritten")
    }

    func test18NewerFormatStopsTheLinkAndWritesNothing() async throws {
        let (store, _, phone) = try await joined(sample)
        await store.setFormat(2)
        phone.edit { $0.watches[0].story = "phone" }
        let writesBefore = await store.writes

        let outcome = await phone.pass()
        XCTAssertEqual(outcome.wait, .newerFormat)
        let again = await phone.pass()
        XCTAssertEqual(again.wait, .newerFormat)
        let writes = await store.writes
        let uploads = await store.count(.upload)
        XCTAssertEqual(writes, writesBefore)
        XCTAssertEqual(uploads, 0)
    }

    func test19CrashBetweenDataAndBookConvergesWithNothingReverted() async throws {
        let (store, mac, phone) = try await joined(sample)
        mac.edit {
            $0.watches.append(watch("w4", "Delta"))
            $0.watches[0].story = "mac"
            $0.wishlist.removeAll { $0.id == "i1" }
        }
        _ = await mac.pass()
        phone.edit { $0.watches[1].story = "phone" }
        let staleTag = phone.book.tag

        // The data is saved, then the app dies before the book is.
        let crashed = await phone.pass(savingBook: false)
        XCTAssertEqual(crashed.wroteCloud, true)
        XCTAssertEqual(phone.book.tag, staleTag)
        phone.relaunch()

        let writes = await store.writes
        let after = await phone.pass()
        XCTAssertNil(after.wait)
        XCTAssertNil(after.conflictList)
        let writesAfter = await store.writes
        XCTAssertEqual(writesAfter, writes, "nothing to write: nothing reverted")
        XCTAssertEqual(watchIDs(phone.data), ["w1", "w2", "w3", "w4"])
        XCTAssertEqual(story(phone.data, "w1"), "mac")
        XCTAssertEqual(story(phone.data, "w2"), "phone")
        XCTAssertEqual(wishlistIDs(phone.data), ["i2"], "the Mac's delete is not undone")
        let head = await store.currentHead
        XCTAssertEqual(phone.book.tag, head?.tag)

        let macTakes = await mac.pass()
        XCTAssertNil(macTakes.wait)
        XCTAssertEqual(story(mac.data, "w1"), "mac")
        XCTAssertEqual(story(mac.data, "w2"), "phone")
        XCTAssertEqual(wishlistIDs(mac.data), ["i2"])
    }

    // MARK: More

    func test20MacRestartAfterEraseSavesTheZoneThenSendsPhotosThenTheDocument() async throws {
        var data = sample
        data.watches[0].photos = ["a.jpg"]
        let store = makeStore()
        let mac = makeDevice(.mac, store, data)
        try mac.files.put("w1/a.jpg", bytes("a"))
        mac.hubSettledNow = true
        _ = await mac.pass()
        let firstEpoch = mac.book.epoch
        let phone = makeDevice(.phone, store, nil)
        _ = await phone.pass()
        await store.eraseByUser()
        _ = await mac.pass()
        _ = await phone.pass()
        XCTAssertEqual(mac.book.paused, .erased)

        // The phone has no button: only the Mac starts iCloud sync again.
        let fromPhone = await phone.restartAfterErase()
        guard case .failed? = fromPhone else { return XCTFail("expected failed, got \(String(describing: fromPhone))") }
        XCTAssertEqual(phone.book.paused, .erased)

        // Pressed while the zone save fails: the book stays erased, so the button stays, and nothing went up.
        await store.fail(.zone, with: .network)
        let failed = await mac.restartAfterErase()
        XCTAssertEqual(failed, .offline)
        XCTAssertEqual(mac.book.paused, .erased)
        let zoneAfterFailure = await store.zone
        XCTAssertEqual(zoneAfterFailure, .erased)
        await store.fail(.zone, with: nil)

        let restart = await mac.restartAfterErase()
        XCTAssertNil(restart)
        XCTAssertEqual(mac.book.paused, .restarting)
        XCTAssertNil(mac.book.epoch)
        XCTAssertNil(mac.book.base)
        let zoneAfterRestart = await store.zone
        let logAtRestart = await store.log
        XCTAssertEqual(zoneAfterRestart, .present)
        XCTAssertEqual(logAtRestart.last, "zone")

        // As for the first document: it waits for a clean hub pass. The phone stays paused until it appears.
        mac.hubSettledNow = false
        let waits = await mac.pass()
        XCTAssertEqual(waits.wait, .needsHubFirst)
        XCTAssertEqual(mac.book.paused, .restarting)
        let phoneWaits = await phone.pass()
        XCTAssertEqual(phoneWaits.wait, .erased)

        mac.hubSettledNow = true
        let restarted = await mac.pass()
        XCTAssertEqual(restarted.wroteCloud, true)
        XCTAssertNil(mac.book.paused)
        XCTAssertNotEqual(mac.book.epoch, firstEpoch)
        let log = await store.log
        XCTAssertEqual(Array(log.suffix(3)), ["zone", "photo w1/a.jpg", "document mac"],
                       "the zone is saved before any photo goes up, the photos before the document")
        let zoneSaves = await store.count(.zone)
        XCTAssertEqual(zoneSaves, 2, "the failed press and the one that worked; no pass saved it")

        let resumed = await phone.pass()
        XCTAssertNil(resumed.wait)
        XCTAssertEqual(phone.book.epoch, mac.book.epoch)
        XCTAssertNil(phone.book.paused)
    }

    func test21StatusIsWrittenOnlyWhenDue() async throws {
        let (store, mac, _) = try await joined(sample)
        let atJoin = await store.statusWrites
        XCTAssertEqual(atJoin, ["status-mac", "status-iphone"])
        let written = await store.status("status-mac")
        XCTAssertEqual(written?.revision, mac.book.revision)
        XCTAssertEqual(written?.name, "mac")

        clock.advance(60)
        _ = await mac.pass()
        let quiet = await store.statusWrites
        XCTAssertEqual(quiet.count, 2, "not due within 5 minutes")

        clock.advance(5 * 60)
        _ = await mac.pass()
        let due = await store.statusWrites
        XCTAssertEqual(due.count, 3)

        mac.edit { $0.watches[0].story = "new revision" }
        _ = await mac.pass()
        let changed = await store.statusWrites
        let status = await store.status("status-mac")
        XCTAssertEqual(changed.count, 4, "a new revision is due at once")
        XCTAssertEqual(status?.revision, mac.book.revision)
    }

    func test22ThrottleWaitsUntilNotBefore() async throws {
        let (store, _, phone) = try await joined(sample)
        phone.edit { $0.watches[0].story = "phone" }
        await store.setRetryAfter(30)
        let throttled = await phone.pass()
        XCTAssertEqual(throttled.wait, .busy)
        XCTAssertEqual(phone.book.notBefore, clock.now().addingTimeInterval(30))
        await store.setRetryAfter(nil)
        let calls = await totalCalls(store)

        clock.advance(10)
        let early = await phone.pass()
        XCTAssertEqual(early.wait, .busy)
        let callsEarly = await totalCalls(store)
        XCTAssertEqual(callsEarly, calls)

        clock.advance(21)
        let after = await phone.pass()
        XCTAssertEqual(after.wroteCloud, true)
        XCTAssertNil(phone.book.notBefore)
    }

    func test23BuildProblemTurnsTheLinkOffForThisLaunch() async throws {
        let (store, _, phone) = try await joined(sample)
        await store.fail(.account, with: .misconfigured("missingEntitlement"))
        let first = await phone.pass()
        guard case .failed? = first.wait else { return XCTFail("expected failed, got \(first)") }
        await store.fail(.account, with: nil)
        let calls = await totalCalls(store)
        let second = await phone.pass()
        guard case .failed? = second.wait else { return XCTFail("expected failed, got \(second)") }
        let callsAfter = await totalCalls(store)
        XCTAssertEqual(callsAfter, calls, "off until the next launch")
    }

    func test24NoPassOnAnErasedZoneSavesItAgain() async throws {
        var data = sample
        data.watches[0].photos = ["a.jpg"]
        let store = makeStore()
        let mac = makeDevice(.mac, store, data)
        try mac.files.put("w1/a.jpg", bytes("a"))
        mac.hubSettledNow = true
        _ = await mac.pass()
        let phone = makeDevice(.phone, store, nil)
        _ = await phone.pass()
        await store.eraseByUser()
        let writes = await store.writes
        let uploads = await store.count(.upload)
        let statusWrites = await store.statusWrites

        // A Mac with a clean hub pass, a held photo and fresh edits, a phone with its own, and time passing.
        for round in 0..<3 {
            mac.edit { $0.watches[1].story = "mac \(round)" }
            phone.edit { $0.watches[2].story = "phone \(round)" }
            let macPass = await mac.pass()
            let phonePass = await phone.pass()
            XCTAssertEqual(macPass.wait, .erased)
            XCTAssertEqual(phonePass.wait, .erased)
            clock.advance(CloudLink.statusInterval + CloudLink.missingRecheck)
        }

        // Erased again after the button but before the new document was made: back to erased, the zone stays gone.
        mac.book.paused = .restarting
        let erasedAgain = await mac.pass()
        XCTAssertEqual(erasedAgain.wait, .erased)
        XCTAssertEqual(mac.book.paused, .erased)

        let zoneSaves = await store.count(.zone)
        let zone = await store.zone
        let writesAfter = await store.writes
        let uploadsAfter = await store.count(.upload)
        let statusWritesAfter = await store.statusWrites
        XCTAssertEqual(zoneSaves, 0, "only the Mac's button saves an erased zone")
        XCTAssertEqual(zone, .erased)
        XCTAssertEqual(writesAfter, writes)
        XCTAssertEqual(uploadsAfter, uploads)
        XCTAssertEqual(statusWritesAfter, statusWrites)
    }

    // MARK: P8 fix round (docs/icloud-fixes.md; the reviewers' probes, turned round)

    /// D3 (B3): the Mac installs past a failed download only when iCloud says it does not have the photo. Any other
    /// failure (a cancelled call, a server error, a disk that will not take the file) holds the install for a pass.
    func test25MacInstallWaitsOnEveryDownloadFailureButNotInICloud() async throws {
        let (store, mac, phone) = try await joined(sample)
        try phone.files.put("wl-i9/p1.jpg", bytes("p1"))
        phone.edit { $0.wishlist.append(item("i9", "Nine", photos: ["p1.jpg"])) }
        let up = await phone.pass()
        XCTAssertEqual(up.wroteCloud, true)
        let tagBefore = mac.book.tag

        for failure in [CloudFailure.cancelled, .other("operationCancelled"), .other("internalError"),
                        .other("NSCocoaErrorDomain 640")] {
            await store.fail(.download, with: failure)
            let waiting = await mac.pass()
            XCTAssertNil(waiting.installedData, "\(failure): installed although the photo did not come down")
            XCTAssertFalse(wishlistIDs(mac.data).contains("i9"))
            XCTAssertEqual(mac.book.tag, tagBefore)
            let marks = await mac.link.marks
            XCTAssertFalse(marks.saysMissing("wl-i9/p1.jpg"), "not marked: iCloud never said it lacks it")
        }

        await store.fail(.download, with: nil)
        let installed = await mac.pass()
        XCTAssertNotNil(installed.installedData, "the next pass that gets the photo installs")
        XCTAssertTrue(mac.files.exists("wl-i9/p1.jpg"))
    }

    /// D3: a photo whose bytes do not match its record is retried on later passes, and only after 3 failures spread
    /// over at least an hour does the Mac give up on it and install without it.
    func test26MacRetriesAPhotoThatFailsItsChecksumBeforeGivingUpOnIt() async throws {
        let (store, mac, phone) = try await joined(sample)
        try phone.files.put("wl-i9/p1.jpg", bytes("p1"))
        phone.edit { $0.wishlist.append(item("i9", "Nine", photos: ["p1.jpg"])) }
        _ = await phone.pass()
        try await store.damagePhoto("wl-i9/p1.jpg")

        let first = await mac.pass()
        XCTAssertNil(first.installedData, "a damaged photo holds the install up")
        XCTAssertEqual(first.wait, .failed(CloudLink.damagedReason))
        let afterFirst = await store.count(.download)

        // Asked again no sooner than 10 minutes on; meanwhile the install still waits.
        clock.advance(5 * 60)
        let soon = await mac.pass()
        XCTAssertNil(soon.installedData)
        let afterSoon = await store.count(.download)
        XCTAssertEqual(afterSoon, afterFirst, "not fetched again 5 minutes on")

        clock.advance(15 * 60)
        let second = await mac.pass()
        XCTAssertNil(second.installedData, "two failures")
        clock.advance(20 * 60)
        let third = await mac.pass()
        XCTAssertNil(third.installedData, "three failures, but not yet an hour")
        XCTAssertFalse(wishlistIDs(mac.data).contains("i9"))
        let struck = await mac.link.marks
        XCTAssertEqual(struck.damaged["wl-i9/p1.jpg"]?.count, 3)
        XCTAssertEqual(mac.savedMarks.damaged["wl-i9/p1.jpg"]?.count, 3, "kept in cloud-photos.json across launches")

        clock.advance(21 * 60)
        let gaveUp = await mac.pass()
        XCTAssertNotNil(gaveUp.installedData, "after an hour of failures the Mac installs without it")
        XCTAssertEqual(mac.data?.wishlist.first { $0.id == "i9" }?.photos, ["p1.jpg"], "the reference is kept")
        XCTAssertFalse(mac.files.exists("wl-i9/p1.jpg"))
        let marks = await mac.link.marks
        XCTAssertNotNil(marks.unreadable["wl-i9/p1.jpg"])
        XCTAssertFalse(marks.saysMissing("wl-i9/p1.jpg"), "iCloud has it; it just never came down whole")
        XCTAssertTrue(marks.lost.contains("wl-i9/p1.jpg"), "for the drop rule it counts as not in iCloud")

        // Given up on: not fetched again.
        let afterGiveUp = await store.count(.download)
        clock.advance(30 * 60)
        _ = await mac.pass()
        let later = await store.count(.download)
        XCTAssertEqual(later, afterGiveUp)
    }

    /// D3: a damaged photo that comes down whole on a later try is installed with its file, and its strikes go.
    func test26bADamagedPhotoThatComesDownWholeIsInstalled() async throws {
        let (store, mac, phone) = try await joined(sample)
        try phone.files.put("wl-i9/p1.jpg", bytes("p1"))
        phone.edit { $0.wishlist.append(item("i9", "Nine", photos: ["p1.jpg"])) }
        _ = await phone.pass()
        try await store.damagePhoto("wl-i9/p1.jpg")
        let first = await mac.pass()
        XCTAssertNil(first.installedData)

        try await store.repairPhoto("wl-i9/p1.jpg", bytes("p1"))
        clock.advance(11 * 60)
        let installed = await mac.pass()
        XCTAssertNotNil(installed.installedData)
        XCTAssertTrue(mac.files.exists("wl-i9/p1.jpg"))
        let marks = await mac.link.marks
        XCTAssertNil(marks.damaged["wl-i9/p1.jpg"])
        XCTAssertTrue(marks.inCloud.contains("wl-i9/p1.jpg"))
    }

    /// D2 (B1): a held photo that cannot be read when it is sent does not count as gone while the file is still
    /// there. The document waits for it, so it never goes up naming a photo iCloud lacks (which the Mac's drop rule
    /// would then remove everywhere).
    func test27HeldPhotoThatCannotBeReadHoldsTheDocumentBack() async throws {
        let (store, mac, phone) = try await joined(sample)
        try phone.files.put("wl-i9/p1.jpg", bytes("p1"))
        let file = try XCTUnwrap(phone.files.url("wl-i9/p1.jpg"))
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: file.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path) }
        XCTAssertTrue(phone.files.exists("wl-i9/p1.jpg"), "still held")
        phone.edit { $0.wishlist.append(item("i9", "Nine", photos: ["p1.jpg"])) }

        let held = await phone.pass()
        XCTAssertNil(held.wroteCloud, "the document went up while a held photo was not sent: \(held)")
        let writes = await store.writes
        XCTAssertEqual(writes, ["mac"])
        let macPass = await mac.pass()
        XCTAssertNil(macPass.installedData)
        let macMarks = await mac.link.marks
        XCTAssertFalse(macMarks.saysMissing("wl-i9/p1.jpg"))

        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        let sent = await phone.pass()
        XCTAssertEqual(sent.wroteCloud, true)
        let inCloud = await store.photoNames()
        XCTAssertTrue(inCloud.contains("wl-i9/p1.jpg"))
        let macTakes = await mac.pass()
        XCTAssertNotNil(macTakes.installedData)
        XCTAssertTrue(mac.files.exists("wl-i9/p1.jpg"))
        XCTAssertEqual(mac.data?.wishlist.first { $0.id == "i9" }?.photos, ["p1.jpg"])
    }

    /// D2: CloudKit's `assetFileNotFound` while the file is still there is a read failure like any other.
    func test28AssetFileNotFoundOnAPhotoStillHeldHoldsTheDocumentBack() async throws {
        let (store, _, phone) = try await joined(sample)
        try phone.files.put("wl-i9/p1.jpg", bytes("p1"))
        phone.edit { $0.wishlist.append(item("i9", "Nine", photos: ["p1.jpg"])) }
        await store.fail(.upload, with: .photoFileMissing)

        let held = await phone.pass()
        XCTAssertNil(held.wroteCloud, "\(held)")
        let writes = await store.writes
        XCTAssertEqual(writes, ["mac"])

        await store.fail(.upload, with: nil)
        let sent = await phone.pass()
        XCTAssertEqual(sent.wroteCloud, true)
        let saves = await store.photoSaves
        XCTAssertEqual(saves, ["wl-i9/p1.jpg"])
    }

    /// A held photo really deleted while the others are sent is no longer held: it no longer holds the document up,
    /// and it is not dropped from it.
    func test29APhotoDeletedWhileSendingNoLongerHoldsTheDocument() async throws {
        let (store, _, phone) = try await joined(sample)
        for name in ["wl-i9/p1.jpg", "wl-i9/p2.jpg"] { try phone.files.put(name, bytes(name)) }
        phone.edit { $0.wishlist.append(item("i9", "Nine", photos: ["p1.jpg", "p2.jpg"])) }
        let files = phone.files
        await store.onUpload(1) { try? files.remove("wl-i9/p2.jpg") }

        let sent = await phone.pass()
        XCTAssertEqual(sent.wroteCloud, true)
        let saves = await store.photoSaves
        XCTAssertEqual(saves, ["wl-i9/p1.jpg"])
        let cloud = try await cloudData(store)
        XCTAssertEqual(cloud.wishlist.first { $0.id == "i9" }?.photos, ["p1.jpg", "p2.jpg"])
    }

    /// D6 (B5): he erases the app's iCloud data while the Mac is making the document. The document save answers
    /// `.purged`, so the zone stays erased and no photo is thought to be in iCloud; after the button the photo goes up
    /// again before the new document.
    func test30AnEraseDuringTheCreationIsNotUndone() async throws {
        let store = makeStore()
        var data = sample
        data.watches[0].photos = ["a.jpg"]
        let mac = makeDevice(.mac, store, data)
        try mac.files.put("w1/a.jpg", bytes("a"))
        mac.hubSettledNow = true
        await store.onUpload(1) { await store.eraseByUser() }

        let created = await mac.pass()
        XCTAssertEqual(created.wait, .erased)
        let zone = await store.zone
        let head = await store.currentHead
        XCTAssertEqual(zone, .erased, "the zone he erased stays erased")
        XCTAssertNil(head)
        XCTAssertEqual(mac.book.paused, .erased)
        let marks = await mac.link.marks
        XCTAssertFalse(marks.inCloud.contains("w1/a.jpg"))

        let restart = await mac.restartAfterErase()
        XCTAssertNil(restart)
        let remade = await mac.pass()
        XCTAssertEqual(remade.wroteCloud, true)
        let photos = await store.photoNames()
        XCTAssertTrue(photos.contains("w1/a.jpg"), "sent again before the new document")
    }

    /// D5: the first pass after the phone's switch made iCloud its link again merges with no base: a union, so
    /// nothing is deleted on either side's word, and a field that differs asks.
    func test31APassWithNoBaseIsAUnion() async throws {
        let (_, mac, phone) = try await joined(sample)
        mac.edit {
            $0.watches.removeAll { $0.id == "w3" }
            $0.watches[0].story = "mac"
        }
        _ = await mac.pass()
        phone.edit { $0.watches.removeAll { $0.id == "w2" } }
        phone.noBase = true

        let asked = await phone.pass()
        let conflicts = try XCTUnwrap(asked.conflictList, "\(asked)")
        XCTAssertEqual(conflicts.map(\.path), [["watches", "w1", "story"]], "only the field that differs asks")
        phone.resolutions[conflicts[0].id] = "remote"
        let merged = await phone.pass()
        XCTAssertNotNil(merged.installedData, "\(merged)")
        XCTAssertEqual(watchIDs(phone.data), ["w1", "w2", "w3"], "nothing deleted on either side's word")
        XCTAssertEqual(story(phone.data, "w1"), "mac")

        // With its base, the same pass takes both deletes and the edit without asking.
        let (_, mac2, phone2) = try await joined(sample)
        mac2.edit {
            $0.watches.removeAll { $0.id == "w3" }
            $0.watches[0].story = "mac"
        }
        _ = await mac2.pass()
        phone2.edit { $0.watches.removeAll { $0.id == "w2" } }
        let based = await phone2.pass()
        XCTAssertNotNil(based.installedData, "\(based)")
        XCTAssertEqual(watchIDs(phone2.data), ["w1"])
    }

    /// C1 4: the phone's fill asks before each fetch whether the network still allows bulk fetches, and stops when
    /// it does not; its fetches never use a cellular connection.
    func test32TheFillStopsWhenTheNetworkTurnsExpensive() async throws {
        let names = (1...9).map { "p\($0).jpg" }
        let store = makeStore()
        var data = sample
        data.wishlist[0].photos = names
        let mac = makeDevice(.mac, store, data)
        for name in names { try mac.files.put("wl-i1/\(name)", bytes(name)) }
        mac.hubSettledNow = true
        _ = await mac.pass()
        let phone = makeDevice(.phone, store, nil)
        let joined = await phone.pass()
        let installed = try XCTUnwrap(joined.installedData)

        let asked = CopyCount()
        asked.set(0)
        await phone.link.fillPhotos(for: installed, while: {
            let count = (asked.value ?? 0) + 1
            asked.set(count)
            return count <= 2   // the first check, then one fetch more: then he walks out of Wi-Fi
        })
        let downloads = await store.downloads
        XCTAssertEqual(downloads.count, CloudLink.fillWidth + 1, "the first batch, then one more, then nothing")
        let bulk = await store.bulkDownloads
        XCTAssertEqual(Set(bulk), Set(downloads), "every fill fetch is a bulk one: never over cellular")

        // A screen's own fetch is not a bulk one.
        let file = try XCTUnwrap(phone.files.url("wl-i1/p9.jpg"))
        try? FileManager.default.removeItem(at: file)
        _ = try await store.downloadPhoto("wl-i1/p9.jpg", to: file)
        let bulkAfter = await store.bulkDownloads
        XCTAssertEqual(bulkAfter.count, bulk.count)

        // On an expensive network from the start, nothing is fetched at all.
        let before = await store.downloads.count
        await phone.link.fillPhotos(for: installed, while: { false })
        let after = await store.downloads.count
        XCTAssertEqual(after, before, "a gate that says no fetches nothing")
    }

    /// C2 7: changes the Mac's hub link is waiting on count into `status-mac.conflicts`, so the phone can say
    /// a choice waits on the Mac.
    func test33HubConflictsCountIntoTheMacsStatus() async throws {
        let (store, mac, _) = try await joined(sample)
        mac.hubConflicts = 2
        let settled = await mac.pass()
        XCTAssertTrue(settled.isUpToDate, "\(settled)")
        let status = await store.status("status-mac")
        XCTAssertEqual(status?.conflicts, 2)
        XCTAssertEqual(status?.note, "2 waiting for a choice")

        mac.hubConflicts = 0
        _ = await mac.pass()
        let cleared = await store.status("status-mac")
        XCTAssertEqual(cleared?.conflicts, 0)
    }

    /// C1 10: before a hub exchange the phone fetches the photos it lacks from iCloud, and learns which iCloud
    /// does not have, so the exchange drops only those.
    func test34ThePhoneFetchesWhatItLacksBeforeAHubExchange() async throws {
        let (store, _, phone) = try await joined(sample)
        try await store.putPhoto("wl-i1/there.jpg", bytes("there"))
        let failures = await phone.link.fetchPhotos(["wl-i1/there.jpg", "wl-i1/never.jpg"])
        XCTAssertNil(failures)
        XCTAssertTrue(phone.files.exists("wl-i1/there.jpg"))
        let marks = await phone.link.marks
        XCTAssertTrue(marks.saysMissing("wl-i1/never.jpg"))
        XCTAssertEqual(marks.lost, ["wl-i1/never.jpg"])

        await store.signIn(nil)
        let stopped = await phone.link.fetchPhotos(["wl-i1/other.jpg"])
        XCTAssertEqual(stopped, .noAccount)
    }

    /// C1 7: a cancelled pass is quiet. It is `.busy` (the next tick carries on), never a failure.
    func test35ACancelledPassIsQuiet() async throws {
        let (store, mac, phone) = try await joined(sample)
        mac.edit { $0.watches[0].story = "mac" }
        _ = await mac.pass()
        await store.fail(.document, with: .cancelled)
        let cut = await phone.pass()
        XCTAssertEqual(cut.wait, .busy)
        await store.fail(.document, with: nil)
        let next = await phone.pass()
        XCTAssertNotNil(next.installedData)
    }

    /// B6 / C1 11 at the link: a throttle sets `notBefore` on the book it returns, which the caller keeps even when
    /// the rest of the result is dropped (`CloudBook.takeBackOff`).
    func test36BackOffFieldsTravelOnTheirOwn() {
        var kept = CloudBook()
        kept.epoch = "kept"
        var next = CloudBook()
        next.epoch = "dropped"
        next.notBefore = Date(timeIntervalSince1970: 100)
        next.quotaFullAt = Date(timeIntervalSince1970: 50)
        next.paused = .erased
        kept.takeBackOff(from: next)
        XCTAssertEqual(kept.epoch, "kept")
        XCTAssertEqual(kept.notBefore, next.notBefore)
        XCTAssertEqual(kept.quotaFullAt, next.quotaFullAt)
        XCTAssertEqual(kept.paused, .erased)
    }

    /// The marks file of an earlier build (no strikes, nothing unreadable) still reads.
    func test37MarksFromAnEarlierBuildStillRead() throws {
        let json = #"{"account":"a","epoch":"e","inCloud":["x/a.jpg"],"notInCloud":{},"mismatched":[]}"#
        let marks = try JSONDecoder().decode(CloudPhotoMarks.self, from: Data(json.utf8))
        XCTAssertEqual(marks.inCloud, ["x/a.jpg"])
        XCTAssertTrue(marks.damaged.isEmpty)
        XCTAssertTrue(marks.unreadable.isEmpty)
    }

    // MARK: Fixtures

    private var sample: CollectionData {
        collection([watch("w1", "Alpha"), watch("w2", "Bravo"), watch("w3", "Charlie")],
                   wishlist: [item("i1", "One"), item("i2", "Two")])
    }

    private func watch(_ id: String, _ name: String, story: String = "", photos: [String] = []) -> Watch {
        Watch(id: id, name: name, story: story, purchasedText: "", price: 100, status: "owned", statusNote: "", photos: photos)
    }

    private func item(_ id: String, _ name: String, photos: [String] = []) -> WishlistItem {
        WishlistItem(id: id, name: name, brand: "Brand", priceNote: "", notes: "", status: "radar", added: "2026-11-01", photos: photos)
    }

    private func collection(_ watches: [Watch], wishlist: [WishlistItem]) -> CollectionData {
        CollectionData(
            settings: CollectionSettings(autoBackup: true, backupRemote: "gdrive:backups", autoImage: true,
                                         wrist: WristProfile(inches: 6.75, sweetSpotMin: 38, sweetSpotMax: 41, perfect: 39, lugMax: 48)),
            watches: watches, categories: ["Dive", "Dress"], wishlist: wishlist, brandWatchlist: [],
            dialColors: ["Black"], materials: ["Steel"]
        )
    }

    private func bytes(_ name: String) -> Data { Data("photo bytes of \(name)".utf8) }

    private func makeStore() -> FakeCloudStore {
        FakeCloudStore(folder: root.appendingPathComponent("cloud-\(UUID().uuidString)", isDirectory: true))
    }

    private func makeDevice(_ role: CloudRole, _ store: FakeCloudStore, _ data: CollectionData?,
                            budget: TimeInterval = 40) -> Device {
        let files = TempPhotoFiles(root: root.appendingPathComponent("\(role)-\(UUID().uuidString)", isDirectory: true))
        return Device(role: role, store: store, files: files, clock: clock, data: data, budget: budget)
    }

    /// The Mac makes the document from `macData`; a phone with no data joins it.
    private func joined(_ macData: CollectionData) async throws -> (store: FakeCloudStore, mac: Device, phone: Device) {
        let store = makeStore()
        let mac = makeDevice(.mac, store, macData)
        mac.hubSettledNow = true
        let created = await mac.pass()
        XCTAssertEqual(created.wroteCloud, true)
        let phone = makeDevice(.phone, store, nil)
        let joined = await phone.pass()
        XCTAssertNotNil(joined.installedData)
        XCTAssertTrue(phone.joinedBefore)
        return (store, mac, phone)
    }

    private func cloudData(_ store: FakeCloudStore) async throws -> CollectionData {
        let body = try await store.body()
        return try CloudLink.installable(try XCTUnwrap(body), local: nil)
    }

    private func totalCalls(_ store: FakeCloudStore) async -> Int {
        await store.calls.values.reduce(0, +)
    }

    private func story(_ data: CollectionData?, _ id: String) -> String? {
        data?.watches.first { $0.id == id }?.story
    }

    private func watchIDs(_ data: CollectionData?) -> Set<String> { Set(data?.watches.map(\.id) ?? []) }

    private func wishlistIDs(_ data: CollectionData?) -> Set<String> { Set(data?.wishlist.map(\.id) ?? []) }

    private func edited(_ value: JSONValue?, _ change: (inout [String: JSONValue]) -> Void) -> JSONValue {
        var fields = value?.objectValue ?? [:]
        change(&fields)
        return .object(fields)
    }

    private func editedEntry(_ list: JSONValue?, id: String, _ change: (inout [String: JSONValue]) -> Void) -> JSONValue {
        .array((list?.arrayValue ?? []).map { entry in
            guard entry.objectValue?["id"] == .string(id) else { return entry }
            return edited(entry, change)
        })
    }

    private func entry(_ list: JSONValue?, id: String) -> [String: JSONValue]? {
        list?.arrayValue?.first { $0.objectValue?["id"] == .string(id) }?.objectValue
    }

    private func assertUnknownKeysKept(_ store: FakeCloudStore, line: UInt = #line) async throws {
        let body = try await store.body()
        let top = try XCTUnwrap(body?.objectValue, line: line)
        XCTAssertEqual(top["lenses"], .object(["count": .number(3)]), line: line)
        XCTAssertEqual(top["settings"]?.objectValue?["theme"], .string("dark"), line: line)
        XCTAssertEqual(entry(top["watches"], id: "w1")?["strapLog"], .array([.string("nato")]), line: line)
        XCTAssertEqual(entry(top["wishlist"], id: "i1")?["alerts"], .bool(true), line: line)
        XCTAssertNil(top["settings"]?.objectValue?["autoBackup"], "device-only settings never go up", line: line)
    }

    private func XCTUnwrapAsync<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) async throws -> T {
        try XCTUnwrap(value, file: file, line: line)
    }
}

/// One device as P4's caller will drive it: it builds the input, installs data before the book, and keeps the
/// projection it settled at (`changedSinceLastPass`).
final class Device: @unchecked Sendable {
    let role: CloudRole
    let store: FakeCloudStore
    let files: TempPhotoFiles
    let clock: TestClock
    let budget: TimeInterval
    private(set) var link: CloudLink
    var data: CollectionData?
    var book = CloudBook()
    var hubBase: CollectionData?
    var joinedBefore = false
    var hubSettledNow = false
    var resolutions: [String: String] = [:]
    /// D5: the next pass merges with no base.
    var noBase = false
    /// The hub link's changes waiting here (C2 7).
    var hubConflicts = 0
    /// The saved `cloud-photos.json`.
    private(set) var savedMarks = CloudPhotoMarks()
    private var settled: String?

    init(role: CloudRole, store: FakeCloudStore, files: TempPhotoFiles, clock: TestClock, data: CollectionData?,
         budget: TimeInterval) {
        self.role = role
        self.store = store
        self.files = files
        self.clock = clock
        self.data = data
        self.budget = budget
        link = Self.makeLink(role: role, store: store, files: files, clock: clock, marks: CloudPhotoMarks(), budget: budget)
    }

    private static func makeLink(role: CloudRole, store: FakeCloudStore, files: TempPhotoFiles, clock: TestClock,
                                 marks: CloudPhotoMarks, budget: TimeInterval) -> CloudLink {
        CloudLink(store: store, files: files, marks: marks, role: role, device: "\(role)", now: { clock.now() },
                  build: "test", photoBudget: budget)
    }

    func edit(_ change: (inout CollectionData) -> Void) {
        guard var current = data else { return }
        change(&current)
        data = current
    }

    /// `savingBook: false` stops between saving the data and saving the book, as a crash would.
    @discardableResult
    func pass(savingBook: Bool = true) async -> CloudOutcome {
        let input = CloudInput(local: data, book: book, hubBase: hubBase, hubSettledNow: hubSettledNow,
                               joinedBefore: joinedBefore, resolutions: resolutions,
                               changedSinceLastPass: data.flatMap(CloudLink.projection) != settled,
                               noBase: noBase, hubConflicts: hubConflicts)
        let (outcome, next) = await link.pass(input)
        savedMarks = await link.marks
        switch outcome {
        case let .installed(installed, _):
            // Today's install steps: this device's own settings kept, boxes cleaned. The data first, then the book.
            var merged = BoxModel.installing(installed, hubSupportsBoxes: true, local: data)
            if let data {
                merged.settings.autoBackup = data.settings.autoBackup
                merged.settings.backupRemote = data.settings.backupRemote
                merged.settings.lastBackup = data.settings.lastBackup
            }
            data = merged
            settled = CloudLink.projection(merged)
            resolutions = [:]
            if role == .phone { joinedBefore = true }
            if savingBook { book = next }
        case .upToDate:
            settled = data.flatMap(CloudLink.projection)
            resolutions = [:]
            if savingBook { book = next }
        case .conflicts, .waiting:
            book = next
        }
        return outcome
    }

    /// The Mac's "Sync through iCloud again": keeps the returned book, returns why it did not start (nil: it did).
    func restartAfterErase() async -> CloudWait? {
        let (failure, next) = await link.restartAfterErase(book)
        book = next
        return failure
    }

    /// A new launch: a new link with the saved marks, nothing kept in memory.
    func relaunch() {
        link = Self.makeLink(role: role, store: store, files: files, clock: clock, marks: savedMarks, budget: budget)
        settled = nil
    }
}

extension CloudOutcome: @retroactive CustomStringConvertible {
    var wait: CloudWait? {
        if case let .waiting(wait) = self { return wait }
        return nil
    }

    var isUpToDate: Bool {
        if case .upToDate = self { return true }
        return false
    }

    var installedData: CollectionData? {
        if case let .installed(data, _) = self { return data }
        return nil
    }

    /// Whether an `.installed` pass wrote to iCloud; nil for any other outcome.
    var wroteCloud: Bool? {
        if case let .installed(_, wrote) = self { return wrote }
        return nil
    }

    var conflictList: [CollectionMerge.Conflict]? {
        if case let .conflicts(conflicts) = self { return conflicts }
        return nil
    }

    public var description: String {
        switch self {
        case .upToDate: return "upToDate"
        case let .installed(_, wrote): return "installed(wroteCloud: \(wrote))"
        case let .conflicts(conflicts): return "conflicts(\(conflicts.map(\.path)))"
        case let .waiting(wait): return "waiting(\(wait))"
        }
    }
}
