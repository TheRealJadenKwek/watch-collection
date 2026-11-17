import XCTest
@testable import WatchCollection

/// `CollectionMerge` against the hub's `sync.py`. The vectors in Fixtures/merge-vectors.json are written by
/// `python3 tools/merge_vectors.py` (from the repo root) straight from `sync.merge`: hand-written cases, each
/// named, and 300 seeded random ones. The named tests below replay a hand-written case, check it against
/// Python, then state what it proves; the inputs live in the script, under the same name.
final class CollectionMergeTests: XCTestCase {
    typealias Result = (output: JSONValue, conflicts: [CollectionMerge.Conflict])

    // MARK: Vectors

    private struct Vector: Decodable {
        struct Choice: Decodable {
            let path: [String]
            let choice: String
        }

        struct PythonConflict: Decodable {
            let id: String
            let path: [String]
            let local: JSONValue?
            let remote: JSONValue?
            let localDeleted: Bool
            let remoteDeleted: Bool
        }

        let name: String
        let base: JSONValue?
        let local: JSONValue
        let remote: JSONValue
        let resolveByPath: [Choice]
        let output: JSONValue
        let conflicts: [PythonConflict]
        /// No input holds a whole float, so Python's conflict ids are spelled from the same bytes as ours.
        let idsComparable: Bool
    }

    private struct Fixture: Decodable {
        let seed: Int
        let random: Int
        let vectors: [Vector]
    }

    private static let fixture = Swift.Result<Fixture, Error> {
        guard let url = Bundle(for: CollectionMergeTests.self).url(forResource: "merge-vectors", withExtension: "json") else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSLocalizedDescriptionKey: "merge-vectors.json is not in the test bundle"])
        }
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    }

    private func vector(_ name: String) throws -> Vector {
        guard let vector = try Self.fixture.get().vectors.first(where: { $0.name == name }) else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSLocalizedDescriptionKey: "no vector named \(name)"])
        }
        return vector
    }

    /// Merge with no answers, answer by path with our own conflict ids, merge again: how the script made it.
    private static func replay(_ vector: Vector) -> Result {
        let first = CollectionMerge.merge(base: vector.base, local: vector.local, remote: vector.remote, resolutions: [:])
        var resolutions: [String: String] = [:]
        for conflict in first.conflicts {
            if let choice = vector.resolveByPath.first(where: { $0.path == conflict.path }) {
                resolutions[conflict.id] = choice.choice
            }
        }
        return CollectionMerge.merge(base: vector.base, local: vector.local, remote: vector.remote, resolutions: resolutions)
    }

    /// What differs from Python, or nil: the output, then each conflict's path, sides and deleted flags, in order.
    private static func difference(_ vector: Vector, _ result: Result) -> String? {
        if result.output != vector.output {
            return "\(vector.name): output\n swift  \(result.output.text)\n python \(vector.output.text)"
        }
        guard result.conflicts.count == vector.conflicts.count else {
            return "\(vector.name): \(result.conflicts.count) conflicts, Python \(vector.conflicts.count)\n"
                + " swift  \(result.conflicts.map(\.path))\n python \(vector.conflicts.map(\.path))"
        }
        for (index, (swift, python)) in zip(result.conflicts, vector.conflicts).enumerated() {
            let same = swift.path == python.path
                && (swift.local ?? .null) == (python.local ?? .null) && (swift.remote ?? .null) == (python.remote ?? .null)
                && swift.localDeleted == python.localDeleted && swift.remoteDeleted == python.remoteDeleted
            if !same {
                return "\(vector.name): conflict \(index)\n swift  \(swift.path) \((swift.local ?? .null).text) | "
                    + "\((swift.remote ?? .null).text) \(swift.localDeleted) \(swift.remoteDeleted)\n python \(python.path) "
                    + "\((python.local ?? .null).text) | \((python.remote ?? .null).text) \(python.localDeleted) \(python.remoteDeleted)"
            }
        }
        return nil
    }

    /// The named vector, replayed and checked against Python.
    private func merged(_ name: String, file: StaticString = #filePath, line: UInt = #line) throws -> Result {
        let vector = try vector(name)
        let result = Self.replay(vector)
        if let difference = Self.difference(vector, result) {
            XCTFail(difference, file: file, line: line)
        }
        return result
    }

    private func json(_ text: String) -> JSONValue {
        try! JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    }

    // MARK: Every vector

    func testEveryVectorMatchesPython() throws {
        let fixture = try Self.fixture.get()
        let randomCount = fixture.vectors.filter { $0.name.hasPrefix("random ") }.count
        XCTAssertEqual(randomCount, 300)
        XCTAssertEqual(fixture.random, 300)
        var failures: [String] = []
        for vector in fixture.vectors {
            if let difference = Self.difference(vector, Self.replay(vector)) { failures.append(difference) }
        }
        print("CollectionMerge: \(fixture.vectors.count - failures.count) of \(fixture.vectors.count) vectors match sync.py "
              + "(\(fixture.vectors.count - randomCount) hand-written, \(randomCount) random, seed \(fixture.seed))")
        XCTAssertEqual(failures, [], failures.prefix(5).joined(separator: "\n\n"))
    }

    /// Not required (ids are each side's own), but the canonical spelling is Python's, so they agree.
    func testConflictIDsMatchPythonWhereComparable() throws {
        var compared = 0
        for vector in try Self.fixture.get().vectors where vector.idsComparable {
            let result = Self.replay(vector)
            guard result.conflicts.count == vector.conflicts.count else { continue }  // testEveryVectorMatchesPython says why
            for (swift, python) in zip(result.conflicts, vector.conflicts) {
                XCTAssertEqual(swift.id, python.id, "\(vector.name) \(swift.path)")
                compared += 1
            }
        }
        XCTAssertGreaterThan(compared, 100)
    }

    // MARK: The named cases

    func testEditsOnEachSideOfDifferentFieldsBothLand() throws {
        let result = try merged("edit different fields")
        XCTAssertEqual(result.conflicts, [])
        let watch = result.output["watches"]?.entry("w1")
        XCTAssertEqual(watch?["name"], .string("Moonwatch"))
        XCTAssertEqual(watch?["price"], .number(200))
    }

    func testSameFieldOnBothSidesIsOneConflict() throws {
        let result = try merged("same field both sides")
        XCTAssertEqual(result.conflicts.map(\.path), [["watches", "w1", "name"]])
        let conflict = try XCTUnwrap(result.conflicts.first)
        XCTAssertEqual(conflict.local, .string("Moonwatch"))
        XCTAssertEqual(conflict.remote, .string("Speedy"))
        XCTAssertFalse(conflict.localDeleted)
        XCTAssertFalse(conflict.remoteDeleted)
        XCTAssertEqual(result.output["watches"]?.entry("w1")?["name"], .string("Speedy"))

        // Answered by its id; an answer to some other conflict changes nothing.
        let vector = try vector("same field both sides")
        func answered(_ resolutions: [String: String]) -> Result {
            CollectionMerge.merge(base: vector.base, local: vector.local, remote: vector.remote, resolutions: resolutions)
        }
        XCTAssertEqual(answered([conflict.id: "local"]).output["watches"]?.entry("w1")?["name"], .string("Moonwatch"))
        XCTAssertEqual(answered([conflict.id: "local"]).conflicts, [])
        XCTAssertEqual(answered([conflict.id: "remote"]).output["watches"]?.entry("w1")?["name"], .string("Speedy"))
        XCTAssertEqual(answered([conflict.id: "remote"]).conflicts, [])
        XCTAssertEqual(answered(["another": "local"]).conflicts, result.conflicts)
        XCTAssertEqual(try merged("same field both sides, local chosen").conflicts, [])
        XCTAssertEqual(try merged("same field both sides, unknown choice").conflicts.count, 1)
        XCTAssertEqual(try merged("same change both sides").conflicts, [])
    }

    func testDeleteAgainstEditIsAConflictBothWays() throws {
        let deletedHere = try merged("local deletes, remote edits")
        XCTAssertEqual(deletedHere.conflicts.map(\.path), [["watches", "w2"]])
        let here = try XCTUnwrap(deletedHere.conflicts.first)
        XCTAssertTrue(here.localDeleted)
        XCTAssertNil(here.local)
        XCTAssertFalse(here.remoteDeleted)
        XCTAssertEqual(here.remote?["name"], .string("Black Bay 58"))
        XCTAssertEqual(deletedHere.output["watches"]?.ids, ["w1", "w2"])

        let deletedThere = try merged("remote deletes, local edits")
        XCTAssertEqual(deletedThere.conflicts.map(\.path), [["watches", "w2"]])
        let there = try XCTUnwrap(deletedThere.conflicts.first)
        XCTAssertTrue(there.remoteDeleted)
        XCTAssertNil(there.remote)
        XCTAssertFalse(there.localDeleted)
        XCTAssertEqual(there.local?["name"], .string("Black Bay 58"))
        XCTAssertEqual(deletedThere.output["watches"]?.ids, ["w1"])

        let keptEdit = try merged("remote deletes, local edits, local chosen")
        XCTAssertEqual(keptEdit.conflicts, [])
        XCTAssertEqual(keptEdit.output["watches"]?.entry("w2")?["name"], .string("Black Bay 58"))
        XCTAssertEqual(try merged("local deletes, remote edits, local chosen").output["watches"]?.ids, ["w1"])
        XCTAssertEqual(try merged("delete on one side only").output["watches"]?.ids, ["w1"])
    }

    func testNoBaseNeverDeletes() throws {
        let result = try merged("no base never deletes")
        XCTAssertEqual(result.conflicts, [])
        XCTAssertEqual(result.output["watches"]?.ids, ["w1", "w3", "w2"])
        XCTAssertEqual(result.output["wishlist"]?.ids, ["c2", "c1"])
    }

    func testBoxesWithNoBaseTakeTheRemoteWhole() throws {
        for name in ["boxes with no base", "boxes with a base that has none"] {
            let vector = try vector(name)
            let result = try merged(name)
            XCTAssertEqual(result.conflicts, [], name)
            XCTAssertEqual(result.output["boxes"], vector.remote["boxes"], name)
            XCTAssertNotEqual(vector.local["boxes"], vector.remote["boxes"], name)
        }
        // With no boxes on the remote side the device's own stand.
        for name in ["boxes with no base, remote has none", "boxes with no base, remote lacks the key"] {
            let vector = try vector(name)
            XCTAssertEqual(try merged(name).output["boxes"], vector.local["boxes"], name)
        }
    }

    func testBoxReorderOnOneSideKeepsThatOrder() throws {
        XCTAssertEqual(try merged("box reorder on the local side").output["boxes"]?.ids, ["brown", "black", "travel"])
        XCTAssertEqual(try merged("box reorder on the remote side").output["boxes"]?.ids, ["brown", "black", "travel"])
        XCTAssertEqual(try merged("box reorder on both sides").output["boxes"]?.ids, ["brown", "black", "travel"])
        XCTAssertFalse(CollectionMerge.reordered(["a", "b"], ["a", "b", "c"]))
        XCTAssertFalse(CollectionMerge.reordered(["a", "b", "c"], ["a", "c"]))
        XCTAssertTrue(CollectionMerge.reordered(["a", "b"], ["b", "a", "c"]))
    }

    func testPhotoListsUnionAndKeepTheCoverOrder() throws {
        let union = try merged("photo union and cover order")
        XCTAssertEqual(union.conflicts, [])
        // The phone's new cover (c) leads, the hub's removal (b) and both additions (d, e) all land.
        XCTAssertEqual(union.output["watches"]?.entry("w1")?["photos"], json(#"["c.jpg","a.jpg","d.jpg","e.jpg"]"#))
        // sync.py:201: any local change to the list puts the local order first, so the hub's new cover is lost.
        XCTAssertEqual(try merged("photo order follows local whenever local changed the list")
            .output["watches"]?.entry("w1")?["photos"], json(#"["a.jpg","b.jpg","d.jpg"]"#))
        XCTAssertEqual(try merged("photo order from the remote when local is empty and there is no base")
            .output["watches"]?.entry("w1")?["photos"], json(#"["b.jpg","a.jpg"]"#))
    }

    func testUnknownKeysSurviveWhenBaseAndLocalLackThem() throws {
        let vector = try vector("unknown keys survive")
        XCTAssertNil(vector.base?["futureTop"])
        XCTAssertNil(vector.local["futureTop"])
        XCTAssertNil(vector.local["watches"]?.entry("w1")?["futureField"])
        XCTAssertNil(vector.local["wishlist"]?.entry("c1")?["futureField"])
        let result = try merged("unknown keys survive")
        XCTAssertEqual(result.conflicts, [])
        XCTAssertEqual(result.output["futureTop"], json(#"{"version":2}"#))
        XCTAssertEqual(result.output["watches"]?.entry("w1")?["futureField"], json(#"{"strap":"NATO"}"#))
        XCTAssertEqual(result.output["wishlist"]?.entry("c1")?["futureField"], json("[1,2]"))
        XCTAssertEqual(result.output["watches"]?.entry("w1")?["name"], .string("Edited on the hub"))
        // A top-level key only this device has is not synced (sync.TOP).
        XCTAssertNil(try merged("unknown top-level key from local is dropped").output["localOnlyTop"])
    }

    func testFortyTwoEqualsFortyTwoPointZero() throws {
        XCTAssertEqual(json("42.0"), .number(42))
        XCTAssertEqual(json("42.0").canonicalData, Data("42".utf8))
        let result = try merged("42 equals 42.0")
        XCTAssertEqual(result.conflicts, [])
        XCTAssertEqual(result.output["watches"]?.entry("w1")?["name"], .string("B"))
        XCTAssertEqual(result.output["watches"]?.entry("w1")?["story"], .string("Remote story"))
        let repriced = try merged("42.0 on one side, a new price on the other")
        XCTAssertEqual(repriced.conflicts, [])
        XCTAssertEqual(repriced.output["watches"]?.entry("w1")?["price"], .number(43))
    }

    func testWatchInTwoBoxesAfterAMergeIsCleaned() throws {
        let result = try merged("watch in two boxes after a merge is cleaned")
        XCTAssertEqual(result.conflicts, [])
        XCTAssertEqual(result.output["boxes"]?.entry("black")?["slots"], json(#"{"0":"w1","1":"w2"}"#))
        XCTAssertEqual(result.output["boxes"]?.entry("brown")?["slots"], json("{}"))
    }

    func testNormalizeDropsNullsAndEmptyWearSessions() throws {
        let document = json(#"""
        {"settings":{"autoImage":true,"autoBackup":false,"lastBackup":null,"wrist":{"inches":6.75}},
         "watches":[{"id":"w1","purchased":null,"wearSessions":[],"wearDates":[],"serviceRecords":[],"brand":"Omega",
                     "story":"","photos":[],"futureList":[]}],
         "wishlist":[{"id":"c1","category":null,"wearSessions":[{"id":"s1"}]}],
         "categories":[],"headlineStats":{"owned":{"count":3}},"futureTop":1}
        """#)
        XCTAssertEqual(CollectionMerge.normalize(document), json(#"""
        {"settings":{"autoImage":true,"wrist":{"inches":6.75}},
         "watches":[{"id":"w1","brand":"Omega","story":"","photos":[],"futureList":[]}],
         "wishlist":[{"id":"c1","wearSessions":[{"id":"s1"}]}],
         "categories":[]}
        """#))
        XCTAssertEqual(CollectionMerge.normalize(json(#"{"watches":[]}"#)), json(#"{"settings":{},"watches":[]}"#))
        let result = try merged("normalize drops nulls and empty wear lists")
        XCTAssertEqual(result.conflicts, [])
        XCTAssertNil(result.output["watches"]?.entry("w1")?["purchased"])
        XCTAssertNil(result.output["watches"]?.entry("w1")?["wearSessions"])
    }

    // MARK: More of sync.py's edges

    func testAnEmptyListTakesTheStringListBranch() throws {
        XCTAssertEqual(try merged("empty list takes the string-list branch").output["categories"], json(#"["Pilot"]"#))
        XCTAssertEqual(try merged("empty against a list of objects inside a watch").conflicts.map(\.path),
                       [["watches", "w1", "straps"]])
        XCTAssertEqual(try merged("numbers in the base list block the string union").conflicts.count, 1)
    }

    func testTrueEqualsOneAsInPython() throws {
        XCTAssertEqual(try merged("True equals 1, as Python compares").output["watches"]?.entry("w1")?["original"], .bool(true))
        XCTAssertEqual(try merged("True and 1 added on both sides with no base").conflicts, [])
    }

    func testConflictsComeOutInPythonOrder() throws {
        let result = try merged("conflicts come out in Python's order")
        XCTAssertEqual(result.conflicts.map(\.path), [
            ["boxes", "black", "slots", "0"], ["categories"], ["settings", "wrist", "inches"],
            ["watches", "w1", "price"], ["watches", "w2", "name"], ["wishlist", "c1", "notes"],
        ])
        _ = try merged("conflicts in Python's order, some resolved")
        XCTAssertEqual(try merged("Unicode: escapes, key order and composed against decomposed").conflicts.map { $0.path.last },
                       ["name", "story", "zeta", "Ünknown", "日付"])
    }

    /// sync.py reports a conflict's remote cutout or box as `clean_boxes` left it (it edits the reported
    /// object in place), and a value inside one as it was sent.
    func testTheRemoteSideOfAConflictIsReportedAsTheHubReportsIt() throws {
        let cleanCut = json(#"{"photo":"a.jpg","x":1,"y":0.5,"r":0.5}"#)
        XCTAssertEqual(try merged("conflict on a cutout reports the remote cleaned").conflicts.first?.remote, cleanCut)
        XCTAssertEqual(try merged("conflict inside a cutout reports the remote as sent").conflicts.first?.remote, .number(1.5))
        XCTAssertEqual(try merged("delete against edit reports the remote watch cleaned").conflicts.first?.remote?["boxCutout"], cleanCut)
        XCTAssertEqual(try merged("delete against edit reports the remote box cleaned").conflicts.first?.remote?["slots"], json("{}"))
        XCTAssertEqual(try merged("conflict on a box's slots reports them as sent").conflicts.first?.remote,
                       json(#"{"0":"w1","1":"ghost"}"#))
        XCTAssertEqual(try merged("conflict on the whole box list reports every box with its slots cleaned")
            .conflicts.first?.remote?.arrayValue?.count, 9)
        _ = try merged("delete against edit reports the remote candidate cleaned")
        _ = try merged("conflict on the whole watch list reports the cutouts cleaned")
    }

    func testBoxRulesAndCutoutRanges() throws {
        let boxes = try merged("box rules: capacity, owned, invalid keys, more than eight, duplicate ids").output["boxes"]
        XCTAssertEqual(boxes?.arrayValue?.count, 7)
        XCTAssertEqual(boxes?.entry("b1")?["slots"], json(#"{"11":"w1"}"#))
        let cutout = try merged("cutouts kept in range").output["watches"]?.entry("w1")?["boxCutout"]
        XCTAssertEqual(cutout, json(#"{"photo":"a.jpg","x":0,"y":1,"r":0.05,"turn":180,"useCutout":true}"#))
    }

    // MARK: JSONValue

    func testDecodingKeepsBoolsAndNumbersApart() {
        XCTAssertEqual(json("[1,true,0,false,null,\"1\"]"),
                       .array([.number(1), .bool(true), .number(0), .bool(false), .null, .string("1")]))
    }

    func testCanonicalDataIsSortedCompactAndSpelledAsPythonSpellsIt() {
        let value = json(#"{"b":1,"a":[1.5,true,null,"\u00e9\n\"\\ \ud83d\ude00 \u007f"],"Z":{},"\u00e9":0.1,"big":1e20,"tiny":1e-7,"\u65e5":[]}"#)
        // json.dumps(value, sort_keys=True, separators=(",", ":")) for the same value.
        let python = #"{"Z":{},"a":[1.5,true,null,"\u00e9\n\"\\ \ud83d\ude00 \u007f"],"b":1,"big":1e+20,"tiny":1e-07,"\u00e9":0.1,"\u65e5":[]}"#
        XCTAssertEqual(value.text, python)
        XCTAssertEqual(CollectionMerge.fingerprint(value), "0cdc83d5619f9e80347ba4cc3e98e066b08d8de862bc2b7a7bc7742d43ccada2")
        XCTAssertEqual(JSONValue.number(-0.0).text, "0")
        XCTAssertEqual(JSONValue.number(9_007_199_254_740_994).text, "9007199254740994")
        XCTAssertEqual(JSONValue.number(1e20).text, "1e+20")
        XCTAssertEqual(json(python), value)
    }

    func testEncodingAndDecodingAModelRoundTrips() throws {
        let collection = try JSONDecoder().decode(CollectionData.self, from: Data(#"""
        {"settings":{"autoBackup":false,"autoImage":true,"wrist":{"inches":6.75,"sweetSpotMin":36,"sweetSpotMax":41,"perfect":39,"lugMax":49}},
         "watches":[{"id":"w1","name":"SKX007","story":"","purchasedText":"","price":280,"status":"owned","statusNote":"","photos":["a.jpg"],
                     "boxCutout":{"photo":"a.jpg","x":0.5,"y":0.5,"r":0.25}}],
         "categories":["Dive"],"wishlist":[],"brandWatchlist":[],"dialColors":[],"materials":[],
         "boxes":[{"id":"black","name":"Black Box","finish":"black","columns":6,"rows":2,"slots":{"0":"w1"}}]}
        """#.utf8))
        let value = try JSONValue(encoding: collection)
        XCTAssertNil(value["settings"]?["backupRemote"], "a nil optional is absent, not null")
        XCTAssertEqual(value["boxes"]?.entry("black")?["columns"], .number(6))
        let decoded = try value.decoded(CollectionData.self)
        XCTAssertEqual(try JSONValue(encoding: decoded), value)
        XCTAssertEqual(decoded.boxes?.first?.columns, 6)
        XCTAssertEqual(decoded.watches.first?.boxCutout?.r, 0.25)
    }
}

private extension JSONValue {
    subscript(key: String) -> JSONValue? { objectValue?[key] }

    /// The entry of an identity list with this id (boxes, watches and candidates are keyed by "id").
    func entry(_ id: String) -> JSONValue? {
        arrayValue?.first { $0["id"] == .string(id) }
    }

    var ids: [String] {
        (arrayValue ?? []).compactMap { entry in
            guard case let .string(id)? = entry["id"] else { return nil }
            return id
        }
    }

    var text: String { String(decoding: canonicalData, as: UTF8.self) }
}
