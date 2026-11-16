import XCTest
@testable import WatchCollection

/// Small collections for the box tests, built in code.
enum BoxFixture {
    static func watch(_ id: String, status: String = "owned", purchased: String? = nil, photos: [String] = []) -> Watch {
        Watch(
            id: id, name: id.capitalized, story: "", purchased: purchased, purchasedText: "",
            diameter: 40, price: 100, original: true, status: status, statusNote: "", photos: photos,
            category: nil, dialColor: nil, lugToLug: nil, material: nil, brand: nil
        )
    }

    static func candidate(_ id: String, status: String = "considering", photos: [String] = []) -> WishlistItem {
        WishlistItem(
            id: id, name: id.capitalized, brand: "", priceNote: "", notes: "", status: status,
            added: "2026-11", photos: photos
        )
    }

    static func box(_ id: String, columns: Int = 6, rows: Int = 2, slots: [String: String] = [:]) -> WatchBox {
        WatchBox(id: id, name: id.capitalized + " Box", finish: id == "brown" ? "brown" : "black", columns: columns, rows: rows, slots: slots)
    }

    static func data(_ watches: [Watch], boxes: [WatchBox]?, wishlist: [WishlistItem] = []) -> CollectionData {
        CollectionData(
            settings: CollectionSettings(
                autoBackup: false, autoImage: false,
                wrist: WristProfile(inches: 6.5, sweetSpotMin: 36, sweetSpotMax: 41, perfect: 39, lugMax: 48)
            ),
            watches: watches, categories: [], wishlist: wishlist, brandWatchlist: [], dialColors: [], materials: [],
            boxes: boxes
        )
    }

    /// field, diver, dress owned; sold-one sold. Black holds field at 0.
    static var standard: CollectionData {
        data(
            [watch("field", purchased: "2024-05"), watch("diver", purchased: "2025-01"), watch("dress"),
             watch("sold-one", status: "sold", purchased: "2023-02")],
            boxes: [box("black", slots: ["0": "field"]), box("brown")]
        )
    }
}

private func slots(_ data: CollectionData, _ boxID: String) -> [String: String] {
    data.boxes?.first { $0.id == boxID }?.slots ?? [:]
}

final class BoxModelTests: XCTestCase {
    // MARK: sanitized

    func testSanitizedRule1DropsBadSlotKeys() {
        var data = BoxFixture.standard
        data.boxes?[0].slots = ["0": "field", "12": "diver", "-1": "dress", "05": "dress", "x": "dress", " 3": "dress", "+4": "dress"]
        data.boxes?[1] = BoxFixture.box("brown", columns: 4, slots: ["9": "dress"])
        let clean = BoxModel.sanitized(data)
        XCTAssertEqual(slots(clean, "black"), ["0": "field"])
        XCTAssertEqual(slots(clean, "brown"), [:])
    }

    func testSanitizedRule2KeepsOwnedWatchesOnly() {
        var data = BoxFixture.standard
        data.boxes?[0].slots.merge(["1": "sold-one", "2": "no-such-watch", "3": "diver"]) { $1 }
        XCTAssertEqual(slots(BoxModel.sanitized(data), "black"), ["0": "field", "3": "diver"])
    }

    func testSanitizedRule3FirstPlaceWins() {
        var data = BoxFixture.standard
        data.boxes?[0].slots.merge(["10": "diver", "2": "diver"]) { $1 }
        data.boxes?[1].slots = ["0": "field", "1": "dress"]
        let clean = BoxModel.sanitized(data)
        XCTAssertEqual(slots(clean, "black"), ["0": "field", "2": "diver"])
        XCTAssertEqual(slots(clean, "brown"), ["1": "dress"])
    }

    func testSanitizedRule4CapsAndDedupesBoxes() {
        var data = BoxFixture.standard
        let extra = (0..<8).map { BoxFixture.box(String(format: "box-%08x", $0), columns: 3) }
        var copy = BoxFixture.box("black")
        copy.name = "Copy"
        data.boxes? += [copy] + extra
        let clean = BoxModel.sanitized(data)
        XCTAssertEqual(clean.boxes?.count, 7)
        XCTAssertEqual(clean.boxes?.prefix(3).map(\.id), ["black", "brown", "box-00000000"])
        XCTAssertEqual(clean.boxes?.first?.name, "Black Box")
    }

    func testSanitizedIsIdempotentAndLeavesNoBoxesAlone() {
        var data = BoxFixture.standard
        data.boxes?[0].slots.merge(["1": "sold-one", "3": "diver", "40": "dress"]) { $1 }
        data.boxes?[1].slots = ["0": "diver", "5": "dress"]
        let once = BoxModel.sanitized(data)
        XCTAssertEqual(BoxModel.sanitized(once).boxes, once.boxes)
        XCTAssertEqual(slots(once, "black"), ["0": "field", "3": "diver"])
        XCTAssertEqual(slots(once, "brown"), ["5": "dress"])
        XCTAssertNil(BoxModel.sanitized(BoxFixture.data([BoxFixture.watch("field")], boxes: nil)).boxes)
        XCTAssertEqual(BoxModel.sanitized(BoxFixture.data([BoxFixture.watch("field")], boxes: [])).boxes, [])
    }

    func testSlotKeysAreCanonical() {
        XCTAssertEqual(BoxModel.slotIndex("0"), 0)
        XCTAssertEqual(BoxModel.slotIndex("11"), 11)
        for key in ["", "00", "05", "+5", "-1", " 5", "5 ", "x", "\u{0663}", "99999999999999999999999"] {
            XCTAssertNil(BoxModel.slotIndex(key), key)
        }
    }

    // MARK: tray, place, swap, takeOut, resize

    func testTrayIsOwnedWatchesInNoBoxNewestFirst() {
        var data = BoxFixture.standard
        data.watches.append(BoxFixture.watch("newest", purchased: "2026-03"))
        XCTAssertEqual(BoxModel.tray(data).map(\.id), ["newest", "diver", "dress"])
        data.boxes = nil
        XCTAssertEqual(BoxModel.tray(data).map(\.id), ["newest", "diver", "field", "dress"])
    }

    func testPlaceIntoAnEmptySpace() throws {
        var data = BoxFixture.standard
        try BoxModel.place(watchID: "diver", boxID: "brown", slot: 4, in: &data)
        XCTAssertEqual(slots(data, "brown"), ["4": "diver"])
        try BoxModel.place(watchID: "field", boxID: "black", slot: 7, in: &data)
        XCTAssertEqual(slots(data, "black"), ["7": "field"])
        XCTAssertEqual(BoxModel.location(of: "field", in: data), BoxSpace(boxID: "black", slot: 7))
    }

    func testPlaceFromACompartmentOntoAnOccupiedOneSwaps() throws {
        var data = BoxFixture.standard
        try BoxModel.place(watchID: "diver", boxID: "brown", slot: 2, in: &data)
        try BoxModel.place(watchID: "diver", boxID: "black", slot: 0, in: &data)
        XCTAssertEqual(slots(data, "black"), ["0": "diver"])
        XCTAssertEqual(slots(data, "brown"), ["2": "field"])
        // Within one box too.
        try BoxModel.place(watchID: "dress", boxID: "black", slot: 5, in: &data)
        try BoxModel.place(watchID: "dress", boxID: "black", slot: 0, in: &data)
        XCTAssertEqual(slots(data, "black"), ["0": "dress", "5": "diver"])
    }

    func testPlaceFromTheTrayOntoAnOccupiedSpaceSendsTheOccupantToTheTray() throws {
        var data = BoxFixture.standard
        try BoxModel.place(watchID: "diver", boxID: "black", slot: 0, in: &data)
        XCTAssertEqual(slots(data, "black"), ["0": "diver"])
        XCTAssertNil(BoxModel.location(of: "field", in: data))
        XCTAssertTrue(BoxModel.tray(data).map(\.id).contains("field"))
    }

    func testPlaceRefusesWhatCannotGoInABox() {
        var data = BoxFixture.standard
        XCTAssertThrowsError(try BoxModel.place(watchID: "sold-one", boxID: "black", slot: 1, in: &data))
        XCTAssertThrowsError(try BoxModel.place(watchID: "nobody", boxID: "black", slot: 1, in: &data))
        XCTAssertThrowsError(try BoxModel.place(watchID: "diver", boxID: "grey", slot: 1, in: &data))
        XCTAssertThrowsError(try BoxModel.place(watchID: "diver", boxID: "black", slot: 12, in: &data))
        XCTAssertThrowsError(try BoxModel.place(watchID: "diver", boxID: "black", slot: -1, in: &data))
        XCTAssertEqual(data.boxes, BoxFixture.standard.boxes)
    }

    func testSwapExchangesTwoSpaces() throws {
        var data = BoxFixture.standard
        data.boxes?[1].slots = ["3": "diver"]
        try BoxModel.swap(BoxSpace(boxID: "black", slot: 0), BoxSpace(boxID: "brown", slot: 3), in: &data)
        XCTAssertEqual(slots(data, "black"), ["0": "diver"])
        XCTAssertEqual(slots(data, "brown"), ["3": "field"])
        try BoxModel.swap(BoxSpace(boxID: "black", slot: 0), BoxSpace(boxID: "black", slot: 9), in: &data)
        XCTAssertEqual(slots(data, "black"), ["9": "diver"])
        XCTAssertThrowsError(try BoxModel.swap(BoxSpace(boxID: "black", slot: 0), BoxSpace(boxID: "black", slot: 12), in: &data))
    }

    func testTakeOut() {
        var data = BoxFixture.standard
        XCTAssertTrue(BoxModel.takeOut(watchID: "field", in: &data))
        XCTAssertEqual(slots(data, "black"), [:])
        XCTAssertFalse(BoxModel.takeOut(watchID: "field", in: &data))
        XCTAssertEqual(BoxModel.tray(data).map(\.id), ["diver", "field", "dress"])
    }

    func testResizeKeepsRowAndColumn() {
        // 6 by 2: slot 4 is (0, 4), slot 6 is (1, 0), slot 11 is (1, 5).
        let box = BoxFixture.box("black", slots: ["4": "a", "6": "b", "11": "c", "2": "d"])
        let smaller = BoxModel.resize(box, columns: 5, rows: 2)
        XCTAssertEqual(smaller.slots, ["4": "a", "5": "b", "2": "d"])
        let oneRow = BoxModel.resize(box, columns: 6, rows: 1)
        XCTAssertEqual(oneRow.slots, ["4": "a", "2": "d"])
        let wider = BoxModel.resize(box, columns: 8, rows: 3)
        XCTAssertEqual(wider.slots, ["4": "a", "8": "b", "13": "c", "2": "d"])
        XCTAssertEqual([wider.columns, wider.rows], [8, 3])
    }

    func testResizedSlotIsTheSameRowAndColumn() {
        let box = BoxFixture.box("black")  // 6 by 2
        XCTAssertEqual(BoxModel.resizedSlot(6, of: box, columns: 5, rows: 2), 5)
        XCTAssertEqual(BoxModel.resizedSlot(4, of: box, columns: 5, rows: 2), 4)
        XCTAssertEqual(BoxModel.resizedSlot(10, of: box, columns: 5, rows: 2), 9)
        XCTAssertNil(BoxModel.resizedSlot(5, of: box, columns: 5, rows: 2), "column 6 is gone")
        XCTAssertNil(BoxModel.resizedSlot(6, of: box, columns: 6, rows: 1), "the front row is gone")
        XCTAssertEqual(BoxModel.resizedSlot(7, of: box, columns: 8, rows: 3), 9)
        XCTAssertNil(BoxModel.resizedSlot(12, of: box, columns: 8, rows: 3), "not a compartment of the old size")
        XCTAssertNil(BoxModel.resizedSlot(-1, of: box, columns: 8, rows: 3))
    }

    // MARK: Seeding

    func testSeedingOnlyWhenBoxesAreNil() throws {
        let ids = BoxModel.startingLayout.flatMap { $0.slots.values } + ["apple-watch-series-10"]
        var watches = ids.map { BoxFixture.watch($0) }
        watches.append(BoxFixture.watch("oris-aquis-date-sold", status: "sold"))
        let fresh = BoxFixture.data(watches, boxes: nil)
        let seeded = try XCTUnwrap(BoxModel.seeding(fresh))
        XCTAssertEqual(seeded.boxes, BoxModel.startingLayout)
        XCTAssertEqual(slots(seeded, "black").count, 11)
        XCTAssertNil(slots(seeded, "black")["0"])
        XCTAssertEqual(slots(seeded, "brown"), ["6": "zenith-220s", "7": "pierre-paulin-jumping-hour", "8": "casio-mq24-7b"])
        XCTAssertEqual(BoxModel.tray(seeded).map(\.id), ["apple-watch-series-10"])
        XCTAssertNil(BoxModel.seeding(BoxFixture.data(watches, boxes: [])))
        XCTAssertNil(BoxModel.seeding(seeded))
        // Ids that are not owned watches here are left out.
        let other = try XCTUnwrap(BoxModel.seeding(BoxFixture.data([BoxFixture.watch("timex-marlin")], boxes: nil)))
        XCTAssertEqual(slots(other, "black"), ["8": "timex-marlin"])
        XCTAssertEqual(slots(other, "brown"), [:])
        XCTAssertEqual(other.boxes?.map(\.id), ["black", "brown"])
    }

    func testNewBoxIDAndNames() {
        let id = BoxModel.newBoxID(existing: ["black", "brown"])
        XCTAssertNotNil(id.range(of: #"^box-[0-9a-f]{8}$"#, options: .regularExpression))
        XCTAssertEqual(BoxModel.cleanName("  Travel Roll  "), "Travel Roll")
        XCTAssertNil(BoxModel.cleanName("   "))
        XCTAssertNotNil(BoxModel.cleanName(String(repeating: "n", count: 40)))
        XCTAssertNil(BoxModel.cleanName(String(repeating: "n", count: 41)))
        XCTAssertNil(BoxModel.cleanName(String(repeating: "e\u{301}", count: 21)), "counted as the hub counts: Unicode scalars")
        XCTAssertEqual(BoxFixture.box("x").resolvedFinish, "black")
        XCTAssertEqual(WatchBox(id: "w", name: "W", finish: "white", columns: 6, rows: 2, slots: [:]).resolvedFinish, "black")
    }

    // MARK: Cutout settings and pictures

    func testCutoutNormalized() {
        let partial = BoxCutout(photo: "a.jpg", x: 0.5, y: 0.5, turn: 0, caseOnly: false, useCutout: false).normalized
        XCTAssertEqual(partial, BoxCutout(photo: "a.jpg"))
        let wild = BoxCutout(photo: "a.jpg", x: 1.4, y: -0.2, r: 0.9, turn: 400, caseOnly: true, useCutout: true).normalized
        XCTAssertEqual(wild, BoxCutout(photo: "a.jpg", x: 1, y: 0, r: 0.5, turn: 180, caseOnly: true, useCutout: true))
        XCTAssertEqual(BoxCutout(photo: "a.jpg", x: 0.5, y: 0.5, r: 0.01, turn: -4).normalized.r, 0.05)
        XCTAssertNil(BoxCutout(photo: "a.jpg", x: .nan, y: 0.5, r: 0.2).normalized.x)
    }

    func testSlotPicturePrefersTileThenEmptyTileThenPillow() {
        let tiles = ["black": "box-black-11111111.jpg", "brown": "box-brown-22222222.jpg"]
        let empties = ["black": "empty-black-33333333.jpg"]
        func picture(finish: String = "black", cutout: BoxCutout? = nil, onDevice: Set<String>) -> BoxSlotPicture {
            BoxModel.picture(finish: finish, boxTiles: tiles, cutout: cutout, emptyBoxTiles: empties,
                             hasTile: onDevice.contains, hasEmptyTile: onDevice.contains)
        }
        let everything: Set<String> = Set(tiles.values).union(empties.values)
        XCTAssertEqual(picture(onDevice: everything), .tile("box-black-11111111.jpg"))
        XCTAssertEqual(picture(finish: "brown", onDevice: everything), .tile("box-brown-22222222.jpg"))
        XCTAssertEqual(picture(finish: "walnut", onDevice: everything), .tile("box-black-11111111.jpg"))
        XCTAssertEqual(picture(onDevice: ["empty-black-33333333.jpg"]), .emptyTile("empty-black-33333333.jpg"))
        XCTAssertEqual(picture(onDevice: []), .pillow)
        XCTAssertEqual(picture(finish: "brown", onDevice: ["empty-black-33333333.jpg"]), .pillow)
        let refused = BoxCutout(photo: "a.jpg", useCutout: true)
        XCTAssertEqual(picture(cutout: refused, onDevice: everything), .emptyTile("empty-black-33333333.jpg"))
        XCTAssertEqual(picture(cutout: BoxCutout(photo: "a.jpg", useCutout: false), onDevice: everything), .tile("box-black-11111111.jpg"))
        XCTAssertEqual(BoxModel.picture(finish: "black", boxTiles: nil, cutout: nil, emptyBoxTiles: nil,
                                        hasTile: { _ in true }, hasEmptyTile: { _ in true }), .pillow)
    }

    func testCutoutWhosePhotoIsGoneIsIgnored() {
        let cutout = BoxCutout(photo: "gone.jpg", useCutout: true)
        XCTAssertNil(BoxModel.effectiveCutout(cutout, photos: ["kept.jpg"]))
        XCTAssertEqual(BoxModel.effectiveCutout(cutout, photos: ["kept.jpg", "gone.jpg"]), cutout)
        // A device without any of the files falls back to the drawn pillow.
        XCTAssertEqual(BoxModel.picture(itemID: "no-such-watch-\(UUID().uuidString.lowercased())", wishlist: false,
                                        photos: [], boxTiles: ["black": "box-black-11111111.jpg"], cutout: nil,
                                        finish: "black", emptyBoxTiles: ["black": "empty-black-00000000.jpg"]), .pillow)
    }

    // MARK: Referenced files

    func testReferencedFilesIncludeTilesButPhotosDoNot() {
        var data = BoxFixture.standard
        data.watches[0].photos = ["cover.jpg"]
        data.watches[0].boxTiles = ["brown": "box-brown-22222222.jpg", "black": "box-black-11111111.jpg"]
        data.wishlist = [BoxFixture.candidate("nomos", photos: ["n.jpg"])]
        data.wishlist[0].boxTiles = ["black": "box-black-44444444.jpg"]
        data.emptyBoxTiles = ["black": "empty-black-33333333.jpg", "brown": "empty-brown-55555555.jpg"]
        let files = PhotoStore.assets(in: data, baseURL: "http://127.0.0.1:1").map { "\($0.directory)/\($0.filename)" }
        XCTAssertEqual(files, [
            "field/cover.jpg", "field/box-black-11111111.jpg", "field/box-brown-22222222.jpg",
            "wl-nomos/n.jpg", "wl-nomos/box-black-44444444.jpg",
            "_box/empty-black-33333333.jpg", "_box/empty-brown-55555555.jpg",
        ])
        XCTAssertEqual(data.watches[0].photos, ["cover.jpg"])
        let empty = PhotoStore.assets(in: data, baseURL: "http://127.0.0.1:1").last
        XCTAssertEqual(empty?.remoteURL?.absoluteString, "http://127.0.0.1:1/photos/_box/empty-brown-55555555.jpg")
    }

    func testLostFilesDropTheirTilesAndCutout() {
        var data = BoxFixture.standard
        data.watches[0].photos = ["cover.jpg", "wrist.jpg"]
        data.watches[0].boxCutout = BoxCutout(photo: "wrist.jpg", turn: 5)
        data.watches[0].boxTiles = ["black": "box-black-11111111.jpg", "brown": "box-brown-22222222.jpg"]
        data.watches[1].photos = ["d.jpg"]
        data.watches[1].boxCutout = BoxCutout(photo: "d.jpg")
        data.emptyBoxTiles = ["black": "empty-black-33333333.jpg"]
        let lost: Set<String> = ["field/wrist.jpg", "field/box-black-11111111.jpg", "_box/empty-black-33333333.jpg"]
        let result = CollectionSyncClient.removingPhotos(lost, from: data)
        XCTAssertEqual(result.watches[0].photos, ["cover.jpg"])
        XCTAssertNil(result.watches[0].boxCutout)
        XCTAssertEqual(result.watches[0].boxTiles, ["brown": "box-brown-22222222.jpg"])
        XCTAssertEqual(result.watches[1].boxCutout, BoxCutout(photo: "d.jpg"))
        XCTAssertNil(result.emptyBoxTiles)
    }

    func testUploadsSendTilesOnlyForItemsTheHubLacks() {
        var hub = BoxFixture.standard
        hub.wishlist = [BoxFixture.candidate("nomos")]
        var local = hub
        // field: a new photo, and a tile the hub has since replaced (it lists only its current one).
        local.watches[0].photos = ["new.jpg"]
        local.watches[0].boxTiles = ["black": "box-black-11111111.jpg", "brown": "box-brown-22222222.jpg"]
        // A candidate the hub has, holding a tile the hub removed.
        local.wishlist[0].boxTiles = ["black": "box-black-44444444.jpg"]
        // A candidate bought here: a watch the hub has never seen, its tiles copied into its own folder.
        var bought = BoxFixture.watch("nomos-watch", photos: ["n.jpg"])
        bought.boxTiles = ["black": "box-black-44444444.jpg"]
        local.watches.append(bought)
        local.emptyBoxTiles = ["black": "empty-black-33333333.jpg"]
        let hubFiles = ["field/box-brown-22222222.jpg"]
        let sent = CollectionSyncClient.uploads(from: local, hub: hub, hubFiles: hubFiles).map { "\($0.directory)/\($0.filename)" }
        XCTAssertEqual(sent, ["field/new.jpg", "nomos-watch/n.jpg", "nomos-watch/box-black-44444444.jpg"])
        // Files the hub lists are never sent again, tiles of an item it lacks included.
        let again = CollectionSyncClient.uploads(from: local, hub: hub, hubFiles: hubFiles + sent)
        XCTAssertEqual(again, [])
    }

    // MARK: Conflict wording

    func testBoxSlotConflictReadsAsBoxAndSpace() throws {
        func conflict(_ json: String) throws -> SyncConflict {
            try JSONDecoder().decode(SyncConflict.self, from: Data(json.utf8))
        }
        let data = BoxFixture.standard
        let slot = try conflict(#"{"id":"a","path":["boxes","black","slots","5"],"local":"diver","remote":"dress","localDeleted":false,"remoteDeleted":false}"#)
        XCTAssertEqual(slot.title, "boxes / black / slots / 5")
        let named = slot.labelled(using: [nil, data])
        XCTAssertEqual(named.title, "Black Box, space 6")
        XCTAssertEqual(named.localText, "Diver")
        XCTAssertEqual(named.remoteText, "Dress")
        XCTAssertEqual(named.id, "a")
        let gone = try conflict(#"{"id":"b","path":["boxes","grey","slots","0"],"local":"someone","remote":null,"localDeleted":false,"remoteDeleted":true}"#)
            .labelled(using: [data])
        XCTAssertEqual(gone.title, "grey, space 1")
        XCTAssertEqual(gone.localText, "someone")
        XCTAssertEqual(gone.remoteText, "Deleted")
        let other = try conflict(#"{"id":"c","path":["watches","field","story"],"local":"A","remote":"B","localDeleted":false,"remoteDeleted":false}"#)
        XCTAssertEqual(other.labelled(using: [data]).title, "watches / field / story")
    }
}
