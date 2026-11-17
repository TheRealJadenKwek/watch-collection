import CryptoKit
import Foundation

/// The Swift twin of the hub's `sync.py`: the same three-way merge, run on the device for the iCloud link.
/// Pure, no I/O. It works on raw `JSONValue` documents so a key this build does not know, present only in
/// the remote, survives into the output (`merge`'s output starts from the remote, as `sync.py:207` does).
///
/// Every rule follows `sync.py` line for line, edges included, and `CollectionMergeTests` replays the
/// vectors `tools/merge_vectors.py` writes from it. Where Python itself would raise (a list entry with no
/// id, settings that are not an object), this twin picks the quiet answer noted at that place instead.
///
/// Fingerprints and conflict ids are this implementation's own. They equal the hub's only for documents
/// holding no whole floats, which is a property, not a promise anything relies on.
enum CollectionMerge {
    struct Conflict: Equatable, Sendable {
        var id: String
        var path: [String]
        /// nil when that side deleted the value (`localDeleted`); `.null` when it holds a JSON null.
        var local: JSONValue?
        var remote: JSONValue?
        var localDeleted: Bool
        var remoteDeleted: Bool
    }

    /// sync.COLLECTIONS: lists whose entries are matched by this key and merged one by one.
    static let identities = ["watches": "id", "wishlist": "id", "brandWatchlist": "brand",
                             "wearSessions": "id", "serviceRecords": "id", "boxes": "id"]
    /// sync.SETTINGS: the settings that sync; the rest are this device's own.
    static let syncedSettings: Set<String> = ["autoImage", "suggestExclude", "wrist"]
    /// sync.TOP: the top-level keys the merge walks.
    static let topKeys: Set<String> = ["settings", "watches", "wishlist", "brandWatchlist", "categories",
                                       "dialColors", "materials", "boxes", "emptyBoxTiles"]
    /// sync.MAX_BOXES.
    static let maximumBoxes = 8
    /// sync.ORDERED: identity lists whose order means something (box tabs).
    static let ordered: Set<String> = ["boxes"]
    /// sync.RING_RADIUS: a hand-set cutout ring's radius, as a fraction of the photo's shorter side.
    static let ringRadius = (lower: 0.05, upper: 0.5)

    /// Item keys `normalize` drops when empty (sync.py:113).
    private static let emptyDropped: Set<String> = ["wearDates", "wearSessions", "serviceRecords"]

    // MARK: sync.normalize

    /// The synced projection: top-level keys in `topKeys` only, settings cut to `syncedSettings` (always
    /// present, `{}` when absent), and in every watch and wishlist item the keys holding null, or an empty
    /// (Python-falsy) `wearDates`, `wearSessions` or `serviceRecords`, dropped.
    /// A document or settings that are not objects count as empty (Python would raise).
    static func normalize(_ document: JSONValue) -> JSONValue {
        var result = (document.objectValue ?? [:]).filter { topKeys.contains($0.key) }
        result["settings"] = .object((result["settings"]?.objectValue ?? [:]).filter { syncedSettings.contains($0.key) })
        for kind in ["watches", "wishlist"] {
            guard case let .array(items)? = result[kind] else { continue }
            result[kind] = .array(items.map { item in
                guard case var .object(fields) = item else { return item }
                for (key, value) in fields where value == .null || (emptyDropped.contains(key) && value.pythonFalsy) {
                    fields[key] = nil
                }
                return .object(fields)
            })
        }
        return .object(result)
    }

    // MARK: sync.fingerprint

    /// SHA-256 of `canonicalData`, lower-case hex.
    static func fingerprint(_ value: JSONValue) -> String {
        let digits = Array("0123456789abcdef".utf8)
        var hex: [UInt8] = []
        hex.reserveCapacity(64)
        for byte in SHA256.hash(data: value.canonicalData) {
            hex.append(digits[Int(byte >> 4)])
            hex.append(digits[Int(byte & 0xF)])
        }
        return String(decoding: hex, as: UTF8.self)
    }

    // MARK: sync.merge

    /// Returns a proposal and its conflicts; the caller commits only when there are none. `resolutions`
    /// maps a conflict id to "local" or "remote"; the id covers both values, so an answer cannot overwrite
    /// a newer edit. A missing base never implies a deletion.
    static func merge(base: JSONValue?, local: JSONValue, remote: JSONValue,
                      resolutions: [String: String]) -> (output: JSONValue, conflicts: [Conflict]) {
        var local = local
        // sync.py:140-145. No common past for the boxes: the remote's boxes, when it has some, win whole.
        if base == nil || base?.objectValue?["boxes"] == nil {
            if case let .array(boxes)? = remote.objectValue?["boxes"], !boxes.isEmpty,
               case var .object(fields) = local, fields["boxes"] != nil {
                fields["boxes"] = nil
                local = .object(fields)
            }
        }
        var walker = Walker(resolutions: resolutions)
        let result = walker.walk(base.map(normalize), normalize(local), normalize(remote), []) ?? .object([:])
        // sync.py:207-210. Device-only settings and unknown top-level keys stay the remote's.
        let merged = result.objectValue ?? [:]
        var output = remote.objectValue ?? [:]
        for (key, value) in merged where key != "settings" {
            output[key] = value
        }
        var settings = output["settings"]?.objectValue ?? [:]
        for (key, value) in merged["settings"]?.objectValue ?? [:] {
            settings[key] = value
        }
        output["settings"] = .object(settings)
        let cleaned = cleaning(output)
        return (.object(cleaned.output), cleanedRemotes(walker.conflicts, before: output, cleaned: cleaned))
    }

    /// The remote side of each conflict as `sync.py` reports it. Python's `conflict` returns the very object
    /// it records as "remote" (sync.py:156-157), that object lands in the output, and `clean_boxes(output)`
    /// (sync.py:210) then edits cutouts and box slots in place. So a remote value that is, or holds, a
    /// cutout or a box is reported cleaned, while its id was taken before the cleaning. A value strictly
    /// inside one of those edited objects (a cutout's `x`, a box's old `slots`) is a different object and
    /// stays as it was.
    private static func cleanedRemotes(_ conflicts: [Conflict], before: [String: JSONValue],
                                       cleaned: Cleaning) -> [Conflict] {
        guard !conflicts.isEmpty, !cleaned.edited.isEmpty else { return conflicts }
        let tree = JSONValue.object(before), aliased = JSONValue.object(cleaned.aliased)
        return conflicts.map { conflict in
            guard conflict.remote != nil, let steps = location(of: conflict.path, in: tree),
                  !cleaned.edited.contains(where: { $0.count < steps.count && steps.starts(with: $0) }),
                  let value = value(at: steps, in: aliased) else { return conflict }
            var conflict = conflict
            conflict.remote = value
            return conflict
        }
    }

    private enum Step: Equatable {
        case key(String), index(Int)
    }

    /// Where the value at a conflict's path sits in the merged document: object keys as they are, and in an
    /// identity list the index of the entry with that id.
    private static func location(of path: [String], in tree: JSONValue) -> [Step]? {
        var node = tree
        var steps: [Step] = []
        for (position, step) in path.enumerated() {
            switch node {
            case let .object(fields):
                guard let next = fields[step] else { return nil }
                steps.append(.key(step))
                node = next
            case let .array(items):
                guard position > 0, let identity = identities[path[position - 1]],
                      let index = items.firstIndex(where: { item in
                          guard case let .string(id)? = item.objectValue?[identity] else { return false }
                          return Exact(id) == Exact(step)
                      }) else { return nil }
                steps.append(.index(index))
                node = items[index]
            default:
                return nil
            }
        }
        return steps
    }

    private static func value(at steps: [Step], in tree: JSONValue) -> JSONValue? {
        var node = tree
        for step in steps {
            switch (step, node) {
            case let (.key(key), .object(fields)):
                guard let next = fields[key] else { return nil }
                node = next
            case let (.index(index), .array(items)):
                guard items.indices.contains(index) else { return nil }
                node = items[index]
            default:
                return nil
            }
        }
        return node
    }

    /// `walk` and `conflict` from `sync.merge`. A nil value is Python's MISSING.
    private struct Walker {
        let resolutions: [String: String]
        var conflicts: [Conflict] = []

        mutating func conflict(_ path: [String], _ left: JSONValue?, _ right: JSONValue?) -> JSONValue? {
            let values: [String: JSONValue] = [
                "path": .array(path.map(JSONValue.string)), "local": left ?? .null, "remote": right ?? .null,
                "localDeleted": .bool(left == nil), "remoteDeleted": .bool(right == nil),
            ]
            let key = CollectionMerge.fingerprint(.object(values))
            switch resolutions[key] {
            case "local": return left
            case "remote": return right
            default:
                conflicts.append(Conflict(id: key, path: path, local: left, remote: right,
                                          localDeleted: left == nil, remoteDeleted: right == nil))
                return right
            }
        }

        mutating func walk(_ old: JSONValue?, _ left: JSONValue?, _ right: JSONValue?, _ path: [String]) -> JSONValue? {
            if pythonEqual(left, right) { return left }
            if let old {
                if pythonEqual(left, old) { return right }
                if pythonEqual(right, old) { return left }
                if left == nil || right == nil { return conflict(path, left, right) }
            } else {
                guard let left else { return right }
                guard right != nil else { return left }
            }
            guard let left, let right else { return conflict(path, left, right) }

            if case let .object(leftFields) = left, case let .object(rightFields) = right {
                let previous = old?.objectValue ?? [:]
                let keys = Set(previous.keys).union(leftFields.keys).union(rightFields.keys)
                    .sorted(by: JSONValue.codePointOrder)
                var result: [String: JSONValue] = [:]
                for key in keys {
                    if let value = walk(previous[key], leftFields[key], rightFields[key], path + [key]) {
                        result[key] = value
                    }
                }
                return .object(result)
            }
            if case let .array(leftItems) = left, case let .array(rightItems) = right {
                let previous = old?.arrayValue ?? []
                if let identity = CollectionMerge.identities[path.last ?? ""] {
                    return identityList(identity, previous, leftItems, rightItems, path)
                        ?? conflict(path, left, right)
                }
                if let previous = previous.stringValues, let leftStrings = leftItems.stringValues,
                   let rightStrings = rightItems.stringValues {
                    return .array(stringUnion(previous, leftStrings, rightStrings).map(JSONValue.string))
                }
            }
            return conflict(path, left, right)
        }

        /// sync.py:185-198, or nil when an entry is not an object with a string under `identity` (Python
        /// raises there, or puts a non-string in the path; this twin calls the whole list a conflict).
        private mutating func identityList(_ identity: String, _ previous: [JSONValue], _ left: [JSONValue],
                                           _ right: [JSONValue], _ path: [String]) -> JSONValue? {
            guard let oldIDs = Self.ids(previous, identity), let leftIDs = Self.ids(left, identity),
                  let rightIDs = Self.ids(right, identity) else { return nil }
            let indexes = [(previous, oldIDs), (left, leftIDs), (right, rightIDs)].map { items, ids in
                // Later entries win, as in a Python dict built from the list.
                Dictionary(zip(ids.map(Exact.init), items), uniquingKeysWith: { _, last in last })
            }
            var keys = Self.unique(rightIDs + leftIDs + oldIDs)
            if path.count == 1, CollectionMerge.ordered.contains(path[0]),
               CollectionMerge.reordered(oldIDs, leftIDs), !CollectionMerge.reordered(oldIDs, rightIDs) {
                // Only the client moved entries: its order stands, the hub's additions go after it.
                keys = Self.unique(leftIDs + rightIDs + oldIDs)
            }
            var result: [JSONValue] = []
            for key in keys {
                let exact = Exact(key)
                if let value = walk(indexes[0][exact], indexes[1][exact], indexes[2][exact], path + [key]) {
                    result.append(value)
                }
            }
            return .array(result)
        }

        private static func ids(_ items: [JSONValue], _ identity: String) -> [String]? {
            var ids: [String] = []
            for item in items {
                guard case let .string(id)? = item.objectValue?[identity] else { return nil }
                ids.append(id)
            }
            return ids
        }

        /// `list(dict.fromkeys(...))`: first occurrence kept, compared code point by code point.
        private static func unique(_ values: [String]) -> [String] {
            var seen: Set<Exact> = []
            return values.filter { seen.insert(Exact($0)).inserted }
        }

        /// sync.py:199-202. The order follows the local side whenever it differs from the base list.
        private func stringUnion(_ previous: [String], _ left: [String], _ right: [String]) -> [String] {
            let leftChanged = !left.elementsEqual(previous) { Exact($0) == Exact($1) }
            let order = leftChanged ? left + right : right + left
            let old = Set(previous.map(Exact.init))
            let leftSet = Set(left.map(Exact.init))
            let rightSet = Set(right.map(Exact.init))
            return Self.unique(order).filter { value in
                let exact = Exact(value)
                return !old.contains(exact) || (leftSet.contains(exact) && rightSet.contains(exact))
            }
        }
    }

    /// sync.reordered: true when the ids both lists hold are in a different order in `new` than in `old`.
    /// Adding or removing an entry is not a reorder; only moving one past another is.
    static func reordered(_ old: [String], _ new: [String]) -> Bool {
        let shared = Set(old.map(Exact.init)).intersection(new.map(Exact.init))
        return !old.filter { shared.contains(Exact($0)) }
            .elementsEqual(new.filter { shared.contains(Exact($0)) }) { Exact($0) == Exact($1) }
    }

    // MARK: sync.clean_boxes and sync.clean_cutout

    /// The twin of `sync.clean_boxes` (and so of `BoxModel.sanitized`), in the same order:
    /// 1. drop slot keys that are not a decimal integer in 0..<columns*rows;
    /// 2. drop slots whose watch id is not a watch with status owned;
    /// 3. a watch placed more than once keeps its first place (box order, then numeric slot order);
    /// 4. boxes beyond the eighth are dropped; duplicate box ids keep the first;
    /// 5. every watch's and candidate's box cutout is kept in range, with or without boxes.
    /// Placements in a box that rule 4 then drops still count for rule 3, as in Python.
    static func cleanBoxes(_ document: JSONValue) -> JSONValue {
        guard case let .object(data) = document else { return document }
        return .object(cleaning(data).output)
    }

    /// `clean_boxes` and what its in-place edits leave behind in Python, for `cleanedRemotes`.
    private struct Cleaning {
        /// The cleaned document.
        var output: [String: JSONValue]
        /// The document with cutouts and slots cleaned but no box dropped yet: what every object the
        /// edits touched looks like afterwards.
        var aliased: [String: JSONValue]
        /// Where those objects are: each cleaned cutout, and each box whose slots were rewritten.
        var edited: [[Step]]
    }

    private static func cleaning(_ document: [String: JSONValue]) -> Cleaning {
        var data = document
        var edited: [[Step]] = []
        for kind in ["watches", "wishlist"] {
            guard case var .array(items)? = data[kind] else { continue }
            for index in items.indices {
                guard case var .object(item) = items[index], case let .object(cutout)? = item["boxCutout"] else { continue }
                item["boxCutout"] = .object(cleanCutout(cutout))
                items[index] = .object(item)
                edited.append([.key(kind), .index(index), .key("boxCutout")])
            }
            data[kind] = .array(items)
        }
        guard case var .array(boxes)? = data["boxes"] else { return Cleaning(output: data, aliased: data, edited: edited) }
        var owned: Set<Exact> = []
        for watch in data["watches"]?.arrayValue ?? [] {
            guard let fields = watch.objectValue, fields["status"] == .string("owned"),
                  case let .string(id)? = fields["id"] else { continue }
            owned.insert(Exact(id))
        }
        var placed: Set<Exact> = []
        for index in boxes.indices {
            guard case var .object(box) = boxes[index], case let .object(slots)? = box["slots"] else { continue }
            var capacity = 0.0
            if let columns = box["columns"]?.wholeNumber, let rows = box["rows"]?.wholeNumber {
                capacity = max(0, columns) * max(0, rows)
            }
            // Canonical slot keys have no leading zeros, so ordering by length and then by digits is
            // numeric order, exactly, whatever the size.
            let candidates = slots.compactMap { key, value -> (key: String, watch: Exact)? in
                guard let slot = slotNumber(key), slot < capacity, case let .string(id) = value,
                      owned.contains(Exact(id)) else { return nil }
                return (key, Exact(id))
            }.sorted { ($0.key.utf8.count, $0.key) < ($1.key.utf8.count, $1.key) }
            var kept: Set<String> = []
            for candidate in candidates where placed.insert(candidate.watch).inserted {
                kept.insert(candidate.key)
            }
            box["slots"] = .object(slots.filter { kept.contains($0.key) })
            boxes[index] = .object(box)
            edited.append([.key("boxes"), .index(index)])
        }
        var aliased = data
        aliased["boxes"] = .array(boxes)
        var seen: Set<Exact> = []
        var survivors: [JSONValue] = []
        for box in boxes.prefix(maximumBoxes) {
            if case let .string(id)? = box.objectValue?["id"], !seen.insert(Exact(id)).inserted { continue }
            survivors.append(box)
        }
        data["boxes"] = .array(survivors)
        return Cleaning(output: data, aliased: aliased, edited: edited)
    }

    /// sync.SLOT_KEY (`0|[1-9][0-9]*`, ASCII digits only) and `int(key)`. Exact below 2^53, which any box
    /// whose capacity could reach it would need.
    private static func slotNumber(_ key: String) -> Double? {
        let bytes = Array(key.utf8)
        guard let first = bytes.first, bytes.allSatisfy({ (48...57).contains($0) }),
              first != 48 || bytes.count == 1 else { return nil }
        return Double(key)
    }

    /// The twin of `sync.clean_cutout` (and of `BoxCutout.normalized`): a ring kept only whole (x, y and r
    /// all finite numbers) and in range; turn in -180...180 and left out at 0; caseOnly and useCutout left
    /// out unless true. Python's `min` and `max` keep their first argument on a tie, and so do these.
    static func cleanCutout(_ cutout: [String: JSONValue]) -> [String: JSONValue] {
        var cutout = cutout
        func clamp(_ value: Double, _ lower: Double, _ upper: Double) -> Double {
            let raised = value > lower ? value : lower   // max(lower, value)
            return raised < upper ? raised : upper       // min(upper, raised)
        }
        if let x = cutout["x"]?.finiteNumber, let y = cutout["y"]?.finiteNumber, let r = cutout["r"]?.finiteNumber {
            cutout["x"] = .number(clamp(x, 0, 1))
            cutout["y"] = .number(clamp(y, 0, 1))
            cutout["r"] = .number(clamp(r, ringRadius.lower, ringRadius.upper))
        } else {
            for key in ["x", "y", "r"] { cutout[key] = nil }
        }
        if let turn = cutout["turn"]?.finiteNumber, turn != 0 {
            cutout["turn"] = .number(clamp(turn, -180, 180))
        } else {
            cutout["turn"] = nil
        }
        for flag in ["caseOnly", "useCutout"] where cutout[flag] != .bool(true) {
            cutout[flag] = nil
        }
        return cutout
    }
}

// MARK: Python's view of a value

/// A string compared code point by code point, as Python compares it (Swift's `==` treats a composed "é"
/// and "e" + combining accent as one string; Python does not).
private struct Exact: Hashable {
    let bytes: [UInt8]
    init(_ string: String) { bytes = Array(string.utf8) }
}

/// Python's `==` between two values (nil is MISSING, equal only to itself): numbers by value with
/// `True == 1` and `False == 0`, strings by code point, lists in order, dicts by key.
private func pythonEqual(_ a: JSONValue?, _ b: JSONValue?) -> Bool {
    switch (a, b) {
    case (nil, nil): return true
    case let (a?, b?): return pythonEqual(a, b)
    default: return false
    }
}

private func pythonEqual(_ a: JSONValue, _ b: JSONValue) -> Bool {
    switch (a, b) {
    case (.null, .null):
        return true
    case let (.string(x), .string(y)):
        return x.utf8.elementsEqual(y.utf8)
    case let (.array(x), .array(y)):
        return x.count == y.count && zip(x, y).allSatisfy { pythonEqual($0, $1) }
    case let (.object(x), .object(y)):
        return x.count == y.count && x.allSatisfy { key, value in y[key].map { pythonEqual(value, $0) } ?? false }
    default:
        guard let x = a.pythonNumber, let y = b.pythonNumber else { return false }
        return x == y
    }
}

private extension JSONValue {
    /// A bool as Python's int (bool is a subclass of int there).
    var pythonNumber: Double? {
        switch self {
        case let .number(value): return value
        case let .bool(value): return value ? 1 : 0
        default: return nil
        }
    }

    /// `_finite_number`: a number that is finite; a bool is not one.
    var finiteNumber: Double? {
        if case let .number(value) = self, value.isFinite { return value }
        return nil
    }

    /// `isinstance(v, int) and not isinstance(v, bool)`. A Double cannot tell 6 from 6.0, so a whole
    /// number counts, where Python would refuse a float 6.0. Every writer of these documents writes 6.
    var wholeNumber: Double? {
        if case let .number(value) = self, value.isFinite, value.rounded(.towardZero) == value { return value }
        return nil
    }

    /// Python's `not value`.
    var pythonFalsy: Bool {
        switch self {
        case .null: return true
        case let .bool(value): return !value
        case let .number(value): return value == 0
        case let .string(value): return value.isEmpty
        case let .array(value): return value.isEmpty
        case let .object(value): return value.isEmpty
        }
    }
}

private extension Array where Element == JSONValue {
    /// The strings, or nil unless every entry is one (`all(isinstance(v, str) ...)`; true when empty).
    var stringValues: [String]? {
        var strings: [String] = []
        for item in self {
            guard case let .string(value) = item else { return nil }
            strings.append(value)
        }
        return strings
    }
}
