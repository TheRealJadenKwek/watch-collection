import XCTest
@testable import WatchCollection

/// The document keys for boxes: old documents load and save exactly as before, new ones round trip,
/// and trials never reach the document.
final class BoxCodableTests: XCTestCase {
    /// A document from before boxes, holding only keys the app knows (so nothing is dropped on decode).
    private let oldDocument = """
    {"brandWatchlist":[{"added":"2026-01","brand":"Oris","notes":""}],"categories":["Field","Dive"],\
    "dialColors":["Black","Blue"],"materials":["Steel"],\
    "settings":{"autoBackup":true,"autoImage":true,"backupRemote":"local","suggestExclude":["Dive"],\
    "wrist":{"inches":6.5,"lugMax":48,"perfect":39,"sweetSpotMax":41,"sweetSpotMin":36}},\
    "watches":[{"brand":"Hamilton","category":"Field","diameter":38,"dialColor":"Black","id":"field",\
    "material":"Steel","name":"Field","original":true,"photoFocus":{"a1.jpg":{"x":0.4,"y":0.6,"zoom":1.5}},\
    "photos":["a1.jpg","a2.jpg"],"price":500,"purchased":"2024-05","purchasedText":"May 2024","status":"owned",\
    "statusNote":"","story":"First"},\
    {"id":"sold-one","name":"Sold","photos":[],"price":100,"purchasedText":"","status":"sold","statusNote":"",\
    "story":"","salePrice":80,"soldOn":"2025"}],\
    "wishlist":[{"added":"2026-11","brand":"Nomos","id":"nomos","name":"Nomos Club","notes":"","photos":["n1.jpg"],\
    "priceExpected":2000,"priceNote":"","status":"considering"}]}
    """

    private func sorted() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private func object(_ data: Data) throws -> NSDictionary {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? NSDictionary)
    }

    func testDocumentWithoutBoxesDecodesAndSavesAsBefore() throws {
        let source = Data(oldDocument.utf8)
        let decoded = try JSONDecoder().decode(CollectionData.self, from: source)
        XCTAssertNil(decoded.boxes)
        XCTAssertNil(decoded.emptyBoxTiles)
        XCTAssertNil(decoded.watches[0].boxCutout)
        XCTAssertNil(decoded.watches[0].boxTiles)
        XCTAssertNil(decoded.wishlist[0].boxTiles)
        // Same content as it came in: no new keys, nothing lost.
        let encoded = try sorted().encode(decoded)
        XCTAssertEqual(try object(encoded), try object(source))
        for key in ["boxes", "emptyBoxTiles", "boxCutout", "boxTiles"] {
            XCTAssertNil(String(decoding: encoded, as: UTF8.self).range(of: "\"\(key)\""), key)
        }
        // Byte-stable through decode and encode with the sorted encoder (backups). The plain encoder
        // (sync, cache) orders keys differently on every call, so there it is the content that holds.
        let again = try sorted().encode(JSONDecoder().decode(CollectionData.self, from: encoded))
        XCTAssertEqual(again, encoded)
        let plain = try JSONEncoder().encode(decoded)
        XCTAssertEqual(try object(plain), try object(source))
        XCTAssertEqual(try object(JSONEncoder().encode(JSONDecoder().decode(CollectionData.self, from: plain))), try object(source))
        // The rules leave a document without boxes alone.
        XCTAssertEqual(try sorted().encode(BoxModel.sanitized(decoded)), encoded)
    }

    func testDocumentWithBoxesCutoutsAndTilesRoundTrips() throws {
        var data = try JSONDecoder().decode(CollectionData.self, from: Data(oldDocument.utf8))
        data.boxes = [
            WatchBox(id: "black", name: "Black Box", finish: "black", columns: 6, rows: 2, slots: ["1": "field"]),
            WatchBox(id: "box-0a1b2c3d", name: "Travel", finish: "brown", columns: 3, rows: 2, slots: [:]),
        ]
        data.watches[0].boxCutout = BoxCutout(photo: "a2.jpg", x: 0.52, y: 0.47, r: 0.21, turn: -4)
        data.watches[0].boxTiles = ["black": "box-black-0123abcd.jpg", "brown": "box-brown-89abcdef.jpg"]
        data.wishlist[0].boxCutout = BoxCutout(photo: "n1.jpg", caseOnly: true, useCutout: true)
        data.wishlist[0].boxTiles = ["black": "box-black-11112222.jpg"]
        data.emptyBoxTiles = ["black": "empty-black-33334444.jpg"]

        let first = try sorted().encode(data)
        let decoded = try JSONDecoder().decode(CollectionData.self, from: first)
        let second = try sorted().encode(decoded)
        XCTAssertEqual(first, second)
        XCTAssertEqual(decoded.boxes, data.boxes)
        XCTAssertEqual(decoded.watches[0].boxCutout, data.watches[0].boxCutout)
        XCTAssertEqual(decoded.watches[0].boxTiles, data.watches[0].boxTiles)
        XCTAssertEqual(decoded.wishlist[0].boxCutout, data.wishlist[0].boxCutout)
        XCTAssertEqual(decoded.emptyBoxTiles, data.emptyBoxTiles)
        XCTAssertEqual(decoded.watches[0].photos, ["a1.jpg", "a2.jpg"], "tile names never go in photos")

        let json = try object(first)
        let boxes = try XCTUnwrap(json["boxes"] as? [NSDictionary])
        XCTAssertEqual(boxes[0]["slots"] as? [String: String], ["1": "field"], "slots is an object keyed by slot")
        XCTAssertEqual(boxes[1]["slots"] as? [String: String], [:])
        let cutout = try XCTUnwrap((json["watches"] as? [NSDictionary])?.first?["boxCutout"] as? NSDictionary)
        XCTAssertEqual(Set(cutout.allKeys as? [String] ?? []), ["photo", "x", "y", "r", "turn"], "unset values are left out")
        XCTAssertFalse(String(decoding: first, as: UTF8.self).contains("null"))
    }

    func testDocumentFromTheHubDecodes() throws {
        let hub = """
        {"settings":{"autoBackup":true,"autoImage":true,"ownerName":"x","wrist":{"inches":6,"sweetSpotMin":35,"sweetSpotMax":40,"perfect":38,"lugMax":47}},
         "watches":[],"categories":[],"wishlist":[],"brandWatchlist":[],"dialColors":[],"materials":[],
         "boxes":[{"id":"black","name":"Black Box","finish":"walnut","columns":6,"rows":2,"slots":{"0":"x"},"lid":"open"}],
         "emptyBoxTiles":{"brown":"empty-brown-00000000.jpg"},"somethingNew":1}
        """
        let decoded = try JSONDecoder().decode(CollectionData.self, from: Data(hub.utf8))
        XCTAssertEqual(decoded.boxes?.first?.resolvedFinish, "black")
        XCTAssertEqual(decoded.emptyBoxTiles, ["brown": "empty-brown-00000000.jpg"])
        XCTAssertEqual(BoxModel.sanitized(decoded).boxes?.first?.slots, [:])
    }
}

final class BoxTrialTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suite = "com.jadenkwek.watchcollection.tests.boxtrial"

    override func setUp() {
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
    }

    private var data: CollectionData {
        var data = BoxFixture.standard
        data.wishlist = [BoxFixture.candidate("nomos"), BoxFixture.candidate("tudor"), BoxFixture.candidate("bought-one", status: "bought")]
        return data
    }

    func testOneSpacePerCandidate() {
        var trial = BoxTrial()
        trial.place("nomos", at: BoxSpace(boxID: "black", slot: 3))
        trial.place("nomos", at: BoxSpace(boxID: "brown", slot: 1))
        XCTAssertEqual(trial.candidates(in: "black"), [:])
        XCTAssertEqual(trial.candidates(in: "brown"), [1: "nomos"])
        XCTAssertEqual(trial.space(of: "nomos"), BoxSpace(boxID: "brown", slot: 1))
        // A candidate dropped on a space another is trying takes it over.
        trial.place("tudor", at: BoxSpace(boxID: "brown", slot: 1))
        XCTAssertNil(trial.space(of: "nomos"))
        XCTAssertEqual(trial.candidate(at: BoxSpace(boxID: "brown", slot: 1)), "tudor")
        trial.end(at: BoxSpace(boxID: "brown", slot: 1))
        XCTAssertTrue(trial.isEmpty)
    }

    func testSteppingOutListsTheOwnedWatchUnderACandidate() {
        var trial = BoxTrial()
        trial.place("nomos", at: BoxSpace(boxID: "black", slot: 0))
        trial.place("tudor", at: BoxSpace(boxID: "black", slot: 4))
        XCTAssertEqual(trial.steppingOut(of: "black", in: data), ["field"])
        XCTAssertEqual(trial.steppingOut(of: "brown", in: data), [])
    }

    func testDroppedWhenTheCandidateOrBoxIsGone() {
        let stored = BoxTrial([
            "black": ["0": "nomos", "3": "bought-one", "40": "tudor", "x": "tudor"],
            "brown": ["2": "nomos", "5": "deleted-candidate"],
            "grey": ["1": "tudor"],
        ])
        let cleaned = stored.cleaned(for: data)
        XCTAssertEqual(cleaned, BoxTrial(["black": ["0": "nomos"]]))
        // With the black box gone, nomos's space in the brown box is its first and is kept.
        var gone = data
        gone.boxes?.removeAll { $0.id == "black" }
        XCTAssertEqual(stored.cleaned(for: gone), BoxTrial(["brown": ["2": "nomos"]]))
        gone.wishlist.removeAll { $0.id == "nomos" }
        XCTAssertTrue(stored.cleaned(for: gone).isEmpty)
    }

    func testSavedOnThisDeviceAndNeverInTheDocument() throws {
        var trial = BoxTrial()
        trial.place("nomos", at: BoxSpace(boxID: "black", slot: 0))
        trial.save(to: defaults)
        XCTAssertEqual(BoxTrial.load(from: defaults), trial)
        XCTAssertEqual(defaults.dictionary(forKey: BoxTrial.defaultsKey) as? [String: [String: String]], ["black": ["0": "nomos"]])

        let encoded = String(decoding: try JSONEncoder().encode(data), as: UTF8.self)
        XCTAssertFalse(encoded.contains(BoxTrial.defaultsKey))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(encoded.utf8)) as? [String: Any])
        let boxes = try XCTUnwrap(json["boxes"] as? [[String: Any]])
        let placed = boxes.flatMap { ($0["slots"] as? [String: String] ?? [:]).values }
        XCTAssertFalse(placed.contains("nomos"))
        XCTAssertEqual(Set(json.keys), ["settings", "watches", "categories", "wishlist", "brandWatchlist", "dialColors", "materials", "boxes"])

        BoxTrial().save(to: defaults)
        XCTAssertNil(defaults.object(forKey: BoxTrial.defaultsKey))
        defaults.set(["black": 3], forKey: BoxTrial.defaultsKey)
        XCTAssertTrue(BoxTrial.load(from: defaults).isEmpty)
    }
}
