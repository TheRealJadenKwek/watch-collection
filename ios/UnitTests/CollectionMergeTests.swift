import XCTest
@testable import WatchCollection

/// `CollectionMerge` against the hub's `sync.py`. The vectors in Fixtures/merge-vectors.json are written by
/// `python3 tools/merge_vectors.py` (from the repo root) straight from `sync.merge`: hand-written cases, each
/// named, 300 seeded random ones, and 200 seeded random ones built from look-alike Unicode and number pools.
/// The named tests below replay a hand-written case, check it against Python, then state what it proves; the
/// inputs live in the script, under the same name.
///
/// The check is strict: the output and each conflict's sides are compared as bytes against the script's
/// canonical spelling (sync.fingerprint's, with a whole float written as an integer, the one agreed
/// difference), and conflict paths and answers are matched code point by code point. Swift's own `==` on
/// `String` and `JSONValue` treats canonically equivalent strings as one, so it is never the judge here.
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
            let localDeleted: Bool
            let remoteDeleted: Bool
            /// The sides in the script's canonical spelling ("null" for a deleted side).
            let localCanonical: String
            let remoteCanonical: String
        }

        let name: String
        let base: JSONValue?
        let local: JSONValue
        let remote: JSONValue
        let resolveByPath: [Choice]
        /// sync.py's output in the script's canonical spelling; nil when sync.py raised.
        let outputCanonical: String?
        let conflicts: [PythonConflict]
        /// Every number in the inputs is spelled by Swift as Python spells it (no whole float, no integer a
        /// Double cannot hold), so Python's conflict ids are hashed from the same bytes as ours.
        let idsComparable: Bool
        /// The exception sync.py raised on this input (it writes nothing then); nil when it merged.
        let raises: String?
    }

    private struct Fixture: Decodable {
        let seed: Int
        let random: Int
        let twinSeed: Int
        let twins: Int
        let vectors: [Vector]
    }

    /// Vectors where this twin parts from sync.py on purpose, each on input no app writes: base and local
    /// are encoded from `CollectionData`, and the iCloud body is only ever written by `canonicalData`.
    /// `testEveryVectorMatchesPython` requires each of these to still differ, so the list cannot go stale.
    private static let knownDifferences: [String: String] = [
        "look-alike object keys from the two sides":
            "dictionary keys are Swift Strings, which merge canonical twins; app keys are ASCII or UUID photo names",
        "look-alike object keys in one object":
            "the decoder's [String: JSONValue] keeps one of two canonically equal keys; no app writes such keys",
        "integers past 2^53 that a Double cannot hold":
            "JSONValue keeps every number as a Double, so they are rounded; the apps hold numbers as Doubles too",
        "integers at or past 2^63":
            "a Double at or past 2^63 is written in exponent form; the apps hold numbers as Doubles too",
        "integers that differ only past a Double's precision":
            "both read as one Double, so the conflict is missed; the apps hold numbers as Doubles too",
        "a box size written as a whole float":
            "a Double cannot tell 6.0 from 6, so the slots are kept where sync.py drops them; the apps write 6",
    ]

    private static func bytes(_ text: String) -> Data { Data(text.utf8) }

    /// Two paths that are the same code point by code point (Swift's `==` would also match a canonical twin).
    private static func samePath(_ a: [String], _ b: [String]) -> Bool {
        a.count == b.count && zip(a, b).allSatisfy { $0.utf8.elementsEqual($1.utf8) }
    }

    /// A path with every non-ASCII code point escaped, so twins read differently in a failure message.
    private static func spelled(_ path: [String]) -> String {
        JSONValue.array(path.map(JSONValue.string)).text
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
    /// A path matches only when it is spelled with the same code points, as the script's `json.dumps` keys do.
    private static func replay(_ vector: Vector) -> Result {
        let first = CollectionMerge.merge(base: vector.base, local: vector.local, remote: vector.remote, resolutions: [:])
        var resolutions: [String: String] = [:]
        for conflict in first.conflicts {
            if let choice = vector.resolveByPath.first(where: { samePath($0.path, conflict.path) }) {
                resolutions[conflict.id] = choice.choice
            }
        }
        return CollectionMerge.merge(base: vector.base, local: vector.local, remote: vector.remote, resolutions: resolutions)
    }

    /// What differs from Python, or nil: the output's bytes, then each conflict's path (code point by code
    /// point), sides (as bytes) and deleted flags, in order.
    private static func difference(_ vector: Vector, _ result: Result) -> String? {
        guard let output = vector.outputCanonical else {
            return "\(vector.name): sync.py raised \(vector.raises ?? "?"), so there is nothing to compare"
        }
        if result.output.canonicalData != bytes(output) {
            return "\(vector.name): output\n swift  \(result.output.text)\n python \(output)"
        }
        guard result.conflicts.count == vector.conflicts.count else {
            return "\(vector.name): \(result.conflicts.count) conflicts, Python \(vector.conflicts.count)\n"
                + " swift  \(result.conflicts.map { spelled($0.path) })\n python \(vector.conflicts.map { spelled($0.path) })"
        }
        for (index, (swift, python)) in zip(result.conflicts, vector.conflicts).enumerated() {
            let local = (swift.local ?? .null).canonicalData, remote = (swift.remote ?? .null).canonicalData
            let same = samePath(swift.path, python.path)
                && local == bytes(python.localCanonical) && remote == bytes(python.remoteCanonical)
                && swift.localDeleted == python.localDeleted && swift.remoteDeleted == python.remoteDeleted
            if !same {
                return "\(vector.name): conflict \(index)\n swift  \(spelled(swift.path)) \((swift.local ?? .null).text) | "
                    + "\((swift.remote ?? .null).text) \(swift.localDeleted) \(swift.remoteDeleted)\n python \(spelled(python.path)) "
                    + "\(python.localCanonical) | \(python.remoteCanonical) \(python.localDeleted) \(python.remoteDeleted)"
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
        let twinCount = fixture.vectors.filter { $0.name.hasPrefix("twins ") }.count
        XCTAssertEqual(randomCount, 300)
        XCTAssertEqual(fixture.random, 300)
        XCTAssertEqual(twinCount, 200)
        XCTAssertEqual(fixture.twins, 200)
        let names = Set(fixture.vectors.map(\.name))
        XCTAssertEqual(Set(Self.knownDifferences.keys).subtracting(names), [], "a known difference names no vector")
        var failures: [String] = []
        var matched = 0, known = 0, raised = 0
        for vector in fixture.vectors {
            if vector.raises != nil {
                raised += 1  // testWhereSyncPyRaisesTheTwinAnswersQuietly
                continue
            }
            let difference = Self.difference(vector, Self.replay(vector))
            if let reason = Self.knownDifferences[vector.name] {
                known += 1
                if difference == nil { failures.append("\(vector.name): matches sync.py now, so drop it from knownDifferences (\(reason))") }
            } else if let difference {
                failures.append(difference)
            } else {
                matched += 1
            }
        }
        print("CollectionMerge: \(matched) of \(fixture.vectors.count - known - raised) vectors match sync.py byte for byte "
              + "(\(fixture.vectors.count - randomCount - twinCount) hand-written, \(randomCount) random, seed \(fixture.seed), "
              + "\(twinCount) look-alike, seed \(fixture.twinSeed)); \(known) known differences, \(raised) that sync.py refuses")
        XCTAssertEqual(failures, [], failures.prefix(5).joined(separator: "\n\n"))
    }

    /// Not required (ids are each side's own), but the canonical spelling is Python's, so they agree.
    func testConflictIDsMatchPythonWhereComparable() throws {
        var compared = 0
        for vector in try Self.fixture.get().vectors
        where vector.idsComparable && vector.raises == nil && Self.knownDifferences[vector.name] == nil {
            let result = Self.replay(vector)
            guard result.conflicts.count == vector.conflicts.count else { continue }  // testEveryVectorMatchesPython says why
            for (swift, python) in zip(result.conflicts, vector.conflicts) {
                XCTAssertEqual(swift.id, python.id, "\(vector.name) \(Self.spelled(swift.path))")
                compared += 1
            }
        }
        XCTAssertGreaterThan(compared, 140)
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

    // MARK: Look-alike Unicode and numbers (review A6 to A8)

    /// Canonically equivalent spellings are different strings to Python (and to `Exact`), so none of them
    /// may be merged into its twin: ids, list strings, owned ids, box ids and plain values. Compared by
    /// `text`, which escapes every non-ASCII code point, because `JSONValue ==` would call the twins equal.
    func testLookAlikeUnicodeStaysApart() throws {
        let answered = try merged("Unicode: look-alike watch ids are two watches, each answered by its own path")
        XCTAssertEqual(answered.output["watches"]?.ids.map { JSONValue.string($0).text }, [#""\u212a""#])
        XCTAssertEqual(answered.conflicts.map { Self.spelled($0.path) }, [#"["watches","\u212a"]"#])
        XCTAssertEqual(try merged("Unicode: a look-alike category added on the local side is kept").output["categories"]?.text,
                       #"["Caf\u00e9","Cafe\u0301","GMT"]"#)
        XCTAssertEqual(try merged("Unicode: every kind of canonical look-alike in a string list").output["categories"]?.text,
                       #"["\u212a","\u1112\u1161\u11ab","\u212b","\u037e","Cafe\u0301"]"#)
        XCTAssertEqual(try merged("Unicode: a look-alike photo added as the cover while the other side removes its twin")
            .output["watches"]?.arrayValue?.first?["photos"]?.text, #"["cafe\u0301.jpg","a.jpg"]"#)
        let boxes = try merged("Unicode: look-alike box ids, slot watch ids and owned ids stay apart").output["boxes"]?.arrayValue
        XCTAssertEqual(boxes?.map { $0["id"]?.text }, [#""\u00e9""#, #""e\u0301""#])
        XCTAssertEqual(boxes?.map { $0["slots"]?.text }, [#"{"1":"\u00e91"}"#, "{}"])
        XCTAssertEqual(try merged("Unicode: look-alike box ids moved on the local side keep the local order")
            .output["boxes"]?.arrayValue?.map { $0["id"]?.text }, [#""e\u0301""#, #""\u00e9""#, #""travel""#])
        _ = try merged("Unicode: look-alike wear session ids and brands merge one by one")
        let respelled = try merged("Unicode: a value respelled with look-alike code points is an edit")
        XCTAssertEqual(respelled.output["watches"]?.arrayValue?.first?["name"]?.text, #""Cafe\u0301""#)
        XCTAssertEqual(respelled.output["watches"]?.arrayValue?.first?["brand"]?.text, #""\u212a""#)
        XCTAssertEqual(try merged("Unicode: look-alike edits on both sides are a conflict").conflicts.count, 1)
        XCTAssertEqual(try merged("Unicode: compatibility look-alikes are different strings").output["boxes"]?
            .arrayValue?.first?["slots"]?.text, #"{"5":"fi"}"#)
    }

    func testNumbersAreSpelledAsPythonSpellsThem() throws {
        // Whole floats come back as integers (the agreed difference); the rest as Python's repr.
        let floats = try merged("numbers: floats with a whole value and floats without")
            .output["watches"]?.arrayValue?.first?["floats"]
        XCTAssertEqual(floats?.text, #"{"fractional":[0.1,2.5,6.75,-3.75,1e-07,2.5e-05,5e-324,123456789012.5],"#
            + #""whole":[6,42,0,1,10000000000000000,9223372036854774784,9.223372036854776e+18,1.8446744073709552e+19,1e+21,1e+300]}"#)
        _ = try merged("numbers: a conflict between a whole float and a fraction")
        XCTAssertEqual(try merged("numbers: integers past 2^53 that a Double holds").output["watches"]?.arrayValue?.first?["serials"]?.text,
                       "[9007199254740992,9007199254740994,-9007199254740994,1152921504606846976,-4611686018427387904,"
                       + "9223372036854774784,9007199254740991]")
        _ = try merged("boxes: a size with a fraction holds nothing")
    }

    /// The known differences, and which way each goes. None is reachable from what the apps write.
    func testKnownDifferencesGoTheDocumentedWay() throws {
        func swift(_ name: String) throws -> Result { Self.replay(try vector(name)) }
        // Two canonically equal keys become one: Swift keeps one spelling and reports a conflict on it.
        let keys = try swift("look-alike object keys from the two sides")
        XCTAssertEqual(keys.output["watches"]?.arrayValue?.first?["photoFocus"]?.objectValue?.count, 1)
        XCTAssertEqual(try swift("look-alike object keys in one object").output["watches"]?.arrayValue?.first?["futureField"]?
            .objectValue?.count, 2)
        // Integers a Double cannot hold come back rounded, and one past 2^63 in exponent form.
        XCTAssertEqual(try swift("integers past 2^53 that a Double cannot hold").output["futureTop"]?.text,
                       #"{"barcode":9007199254740992,"debt":-9007199254740992}"#)
        XCTAssertEqual(try swift("integers at or past 2^63").output["watches"]?.arrayValue?.first?["serials"]?.text,
                       "[9.223372036854776e+18,-9.223372036854776e+18,1.8446744073709552e+19,1e+20]")
        XCTAssertEqual(try swift("integers that differ only past a Double's precision").conflicts, [])
        // A whole-float box size counts as a size, so the slots stay where sync.py would empty them.
        XCTAssertEqual(try swift("a box size written as a whole float").output["boxes"]?.arrayValue?.map { $0["slots"]?.text },
                       [#"{"0":"w1"}"#, #"{"0":"w2"}"#])
    }

    /// Where sync.py raises (and so the hub writes nothing), the twin answers quietly, as CollectionMerge
    /// says at each place. None of these reaches it through CloudSync: local is encoded from
    /// `CollectionData`, and a remote must decode as one to be installed, so every id is a string and
    /// settings are an object. (Review A5: answering the whole-list conflict "local" keeps the local list
    /// whole and drops the remote's edits; unreachable for the same reason.)
    func testWhereSyncPyRaisesTheTwinAnswersQuietly() throws {
        let raising = try Self.fixture.get().vectors.filter { $0.raises != nil }
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: raising.map { ($0.name, $0.raises ?? "") }), [
            "sync.py raises: a watch with no id": "KeyError",
            "sync.py raises: a wishlist entry that is not an object": "TypeError",
            "sync.py raises: settings that are not an object": "AttributeError",
        ])
        // An identity list with an entry that has no string id is one conflict on the whole list, and the
        // remote's list stands until it is answered.
        for (name, list) in [("sync.py raises: a watch with no id", "watches"),
                             ("sync.py raises: a wishlist entry that is not an object", "wishlist")] {
            let vector = try vector(name)
            let result = Self.replay(vector)
            XCTAssertEqual(result.conflicts.map(\.path), [[list]], name)
            XCTAssertEqual(result.conflicts.first?.local?.text, vector.local[list]?.text, name)
            XCTAssertEqual(result.output[list]?.text, vector.remote[list]?.text, name)
        }
        // Settings that are not an object count as empty.
        let settings = Self.replay(try vector("sync.py raises: settings that are not an object"))
        XCTAssertEqual(settings.conflicts, [])
        XCTAssertEqual(settings.output["settings"], json("{}"))
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
