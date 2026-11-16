import Foundation

/// Wishlist watches being tried in a box, on this device only: box id to slot key to wishlist id.
///
/// Kept in UserDefaults under `boxTrialsV1`, never in the collection document and never sent. A
/// candidate is in at most one trial space. While a trial covers an occupied compartment the owned
/// watch stays where it is in the document; the screen draws the candidate there and lists the owned
/// watch as stepping out. Dropping an owned watch on a trial space ends that trial.
struct BoxTrial: Hashable, Sendable {
    static let defaultsKey = "boxTrialsV1"

    private(set) var boxes: [String: [String: String]] = [:]

    init() {}

    init(_ boxes: [String: [String: String]]) {
        self.boxes = boxes.filter { !$0.value.isEmpty }
    }

    var isEmpty: Bool { boxes.isEmpty }

    // MARK: Storage

    static func load(from defaults: UserDefaults = .standard) -> BoxTrial {
        guard let stored = defaults.dictionary(forKey: defaultsKey) else { return BoxTrial() }
        var boxes: [String: [String: String]] = [:]
        for (boxID, value) in stored {
            if let slots = value as? [String: String] { boxes[boxID] = slots }
        }
        return BoxTrial(boxes)
    }

    func save(to defaults: UserDefaults = .standard) {
        if boxes.isEmpty {
            defaults.removeObject(forKey: Self.defaultsKey)
        } else {
            defaults.set(boxes, forKey: Self.defaultsKey)
        }
    }

    // MARK: Reading

    /// The candidates on trial in a box, by compartment.
    func candidates(in boxID: String) -> [Int: String] {
        var result: [Int: String] = [:]
        for (key, wishlistID) in boxes[boxID] ?? [:] {
            if let slot = BoxModel.slotIndex(key) { result[slot] = wishlistID }
        }
        return result
    }

    func candidate(at space: BoxSpace) -> String? {
        boxes[space.boxID]?[BoxModel.slotKey(space.slot)]
    }

    func space(of wishlistID: String) -> BoxSpace? {
        for (boxID, slots) in boxes {
            if let key = slots.first(where: { $0.value == wishlistID })?.key, let slot = BoxModel.slotIndex(key) {
                return BoxSpace(boxID: boxID, slot: slot)
            }
        }
        return nil
    }

    /// Owned watches whose compartment a candidate covers in this box, in slot order.
    func steppingOut(of boxID: String, in data: CollectionData) -> [String] {
        guard let box = data.boxes?.first(where: { $0.id == boxID }) else { return [] }
        return candidates(in: boxID).keys.sorted().compactMap { box.watchID(at: $0) }
    }

    // MARK: Changing

    /// Puts a candidate on trial in a space, taking it from any other; a candidate already there leaves the trial.
    mutating func place(_ wishlistID: String, at space: BoxSpace) {
        end(wishlistID)
        boxes[space.boxID, default: [:]][BoxModel.slotKey(space.slot)] = wishlistID
    }

    mutating func end(_ wishlistID: String) {
        for boxID in Array(boxes.keys) {
            boxes[boxID] = boxes[boxID]?.filter { $0.value != wishlistID }
            if boxes[boxID]?.isEmpty == true { boxes[boxID] = nil }
        }
    }

    /// Ends whatever trial covers this space (an owned watch was dropped on it).
    mutating func end(at space: BoxSpace) {
        boxes[space.boxID]?[BoxModel.slotKey(space.slot)] = nil
        if boxes[space.boxID]?.isEmpty == true { boxes[space.boxID] = nil }
    }

    mutating func clear(boxID: String) {
        boxes[boxID] = nil
    }

    /// The trial after `box` takes a new size: each candidate keeps its row and column when they still
    /// exist, as the owned watches do (`BoxModel.resize`); one whose place is gone leaves the trial.
    func resized(_ box: WatchBox, columns: Int, rows: Int) -> BoxTrial {
        guard let slots = boxes[box.id] else { return self }
        var moved: [String: String] = [:]
        for (key, wishlistID) in slots {
            guard let index = BoxModel.slotIndex(key),
                  let target = BoxModel.resizedSlot(index, of: box, columns: columns, rows: rows) else { continue }
            moved[BoxModel.slotKey(target)] = wishlistID
        }
        var result = boxes
        result[box.id] = moved
        return BoxTrial(result)
    }

    /// Drops what no longer applies: boxes that are gone, spaces outside a box's size, candidates
    /// that were removed or bought, and every repeat of a candidate after its first space (box order,
    /// then slot order).
    func cleaned(for data: CollectionData) -> BoxTrial {
        let candidates = Set(data.wishlist.lazy.filter { $0.status != "bought" }.map(\.id))
        var seen: Set<String> = []
        var result: [String: [String: String]] = [:]
        for box in data.boxes ?? [] {
            guard let slots = boxes[box.id] else { continue }
            let ordered = slots.compactMap { key, wishlistID -> (slot: Int, key: String, wishlistID: String)? in
                guard let slot = BoxModel.slotIndex(key), slot < box.capacity, candidates.contains(wishlistID) else { return nil }
                return (slot, key, wishlistID)
            }.sorted { $0.slot < $1.slot }
            for entry in ordered where seen.insert(entry.wishlistID).inserted {
                result[box.id, default: [:]][entry.key] = entry.wishlistID
            }
        }
        return BoxTrial(result)
    }
}
