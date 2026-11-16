import Foundation

/// One watch box: a grid of compartments seen from the front, row 0 at the back and column 0 at the
/// left end, so a compartment's index is `row * columns + column`.
///
/// `slots` maps a compartment index, written as a decimal string, to an owned watch id. An empty
/// compartment has no key, never null. It is an object and not an array on purpose: sync merges
/// objects key by key, so the phone moving one watch and the Mac another merge cleanly.
struct WatchBox: Codable, Identifiable, Hashable, Sendable {
    let id: String
    var name: String
    var finish: String
    var columns: Int
    var rows: Int
    var slots: [String: String]

    var capacity: Int { max(0, columns) * max(0, rows) }
    /// "black" or "brown"; an unknown finish is drawn as black.
    var resolvedFinish: String { BoxModel.resolvedFinish(finish) }
    func watchID(at slot: Int) -> String? { slots[BoxModel.slotKey(slot)] }
}

/// How a watch's box cutout is made from one of its photos. Absent means fully automatic.
struct BoxCutout: Codable, Hashable, Sendable {
    /// Which of the item's photos the cutout is made from. If it is no longer in `photos`, the whole value is ignored.
    var photo: String
    /// The case ring set by hand: centre as a fraction of the photo's width and height from the top left,
    /// radius as a fraction of its shorter side. All three or none.
    var x: Double? = nil
    var y: Double? = nil
    var r: Double? = nil
    /// Degrees added to the detected strap direction, -180...180. Omitted when 0.
    var turn: Double? = nil
    /// Forces the case disc fallback. Omitted when false.
    var caseOnly: Bool? = nil
    /// Shows the cutout even when a rendered tile exists. Omitted when false.
    var useCutout: Bool? = nil

    static let ringRadius = 0.05...0.5

    /// The value as it is stored: a partial ring dropped and a full one kept in range, turn kept in
    /// -180...180 and omitted at 0, false flags omitted.
    var normalized: BoxCutout {
        var clean = self
        if let x, let y, let r, x.isFinite, y.isFinite, r.isFinite {
            clean.x = min(1, max(0, x))
            clean.y = min(1, max(0, y))
            clean.r = min(Self.ringRadius.upperBound, max(Self.ringRadius.lowerBound, r))
        } else {
            (clean.x, clean.y, clean.r) = (nil, nil, nil)
        }
        if let turn, turn.isFinite, turn != 0 { clean.turn = min(180, max(-180, turn)) } else { clean.turn = nil }
        if caseOnly != true { clean.caseOnly = nil }
        if useCutout != true { clean.useCutout = nil }
        return clean
    }
}

/// A compartment: which box, which space.
struct BoxSpace: Hashable, Sendable {
    var boxID: String
    var slot: Int
}

/// What fills a compartment, in the order of preference of brief section 5.3 step 5.
enum BoxSlotPicture: Hashable, Sendable {
    /// The watch's own rendered tile for this finish (a file in its photo folder).
    case tile(String)
    /// The finish's empty pillow tile (a file in photos/_box); the cutout is drawn on it.
    case emptyTile(String)
    /// The drawn pillow; the cutout is drawn on it.
    case pillow
}

/// The pure rules for boxes. `sanitized` has a Python twin, `sync.clean_boxes`: same rules, same
/// order, so the hub and every device settle on the same document.
enum BoxModel {
    static let finishes = ["black", "brown"]
    static let columnRange = 1...8
    static let rowRange = 1...4
    /// The document never holds more (sync.MAX_BOXES).
    static let maximumBoxes = 8
    /// How many boxes "Add a box" goes up to.
    static let boxLimit = 4
    /// Name length the hub accepts, counted in Unicode scalars as Python counts characters.
    static let nameLimit = 40
    static let sizePresets: [(columns: Int, rows: Int)] = [(6, 2), (5, 2), (4, 2), (3, 2)]

    static func resolvedFinish(_ finish: String) -> String {
        finishes.contains(finish) ? finish : "black"
    }

    static func slotKey(_ index: Int) -> String { String(index) }

    /// The compartment a slot key names, or nil unless the key is a decimal integer written the one
    /// canonical way ("5", never "05", "+5" or " 5"), as `sync.SLOT_KEY` reads it.
    static func slotIndex(_ key: String) -> Int? {
        let bytes = Array(key.utf8)
        guard let first = bytes.first, bytes.allSatisfy({ (48...57).contains($0) }),
              first != 48 || bytes.count == 1 else { return nil }
        return Int(key)
    }

    // MARK: Rules

    /// Runs after every load, every sync result and every mutation:
    /// 1. drop slot keys that are not a decimal integer in 0..<columns*rows;
    /// 2. drop slots whose watch id is not a watch with status owned;
    /// 3. a watch placed more than once keeps its first place (box order, then numeric slot order);
    /// 4. boxes beyond the eighth are dropped; duplicate box ids keep the first.
    static func sanitized(_ data: CollectionData) -> CollectionData {
        guard var boxes = data.boxes else { return data }
        let owned = Set(data.watches.lazy.filter { $0.status == "owned" }.map(\.id))
        var placed: Set<String> = []
        for index in boxes.indices {
            let box = boxes[index]
            let capacity = box.capacity
            let candidates = box.slots.compactMap { key, watchID -> (slot: Int, key: String, watchID: String)? in
                guard let slot = slotIndex(key), slot < capacity, owned.contains(watchID) else { return nil }
                return (slot, key, watchID)
            }.sorted { $0.slot < $1.slot }
            var kept: [String: String] = [:]
            for candidate in candidates where placed.insert(candidate.watchID).inserted {
                kept[candidate.key] = candidate.watchID
            }
            if kept != box.slots { boxes[index].slots = kept }
        }
        var seen: Set<String> = []
        boxes = boxes.prefix(maximumBoxes).filter { seen.insert($0.id).inserted }
        var result = data
        result.boxes = boxes
        return result
    }

    /// Owned watches that are in no compartment, newest first (the Collection's Newest order).
    static func tray(_ data: CollectionData) -> [Watch] {
        let placed = Set(data.boxes?.flatMap { $0.slots.values } ?? [])
        let all = data.watches
        let loose = all.filter { $0.status == "owned" && !placed.contains($0.id) }
        let byID = Dictionary(loose.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let stand = loose.map { watch -> Watch in
            var copy = watch
            let source = datedSource(watch, in: all)
            copy.purchased = source.purchased
            copy.purchasedText = source.purchasedText
            return copy
        }
        let ordered = acquisitionOrder(stand).compactMap { byID[$0.id] }
        let dated = ordered.filter { datedSource($0, in: all).purchased != nil }
        return Array(dated.reversed()) + ordered.filter { datedSource($0, in: all).purchased == nil }
    }

    /// Where a watch sits: the first place in box order, then numeric slot order.
    static func location(of watchID: String, in data: CollectionData) -> BoxSpace? {
        for box in data.boxes ?? [] {
            if let slot = box.slots.compactMap({ $0.value == watchID ? slotIndex($0.key) : nil }).min() {
                return BoxSpace(boxID: box.id, slot: slot)
            }
        }
        return nil
    }

    /// Takes the watch from wherever it is, then: an empty target takes it; an occupied target swaps
    /// with it when it came from a compartment; when it came from the tray the occupant goes to the tray.
    static func place(watchID: String, boxID: String, slot: Int, in data: inout CollectionData) throws {
        guard data.watches.contains(where: { $0.id == watchID && $0.status == "owned" }),
              var boxes = data.boxes,
              let target = boxes.firstIndex(where: { $0.id == boxID })
        else { throw LocalStoreError.itemNotFound }
        guard (0..<boxes[target].capacity).contains(slot) else { throw LocalStoreError.invalidOperation }
        let origin = location(of: watchID, in: data)
        if origin == BoxSpace(boxID: boxID, slot: slot) { return }
        let key = slotKey(slot)
        let occupant = boxes[target].slots[key]
        for index in boxes.indices where boxes[index].slots.values.contains(watchID) {
            boxes[index].slots = boxes[index].slots.filter { $0.value != watchID }
        }
        if let occupant, let origin, let from = boxes.firstIndex(where: { $0.id == origin.boxID }) {
            boxes[from].slots[slotKey(origin.slot)] = occupant
        }
        boxes[target].slots[key] = watchID
        data.boxes = boxes
    }

    /// Exchanges what two compartments hold; either may be empty.
    static func swap(_ first: BoxSpace, _ second: BoxSpace, in data: inout CollectionData) throws {
        guard var boxes = data.boxes,
              let a = boxes.firstIndex(where: { $0.id == first.boxID }),
              let b = boxes.firstIndex(where: { $0.id == second.boxID })
        else { throw LocalStoreError.itemNotFound }
        guard (0..<boxes[a].capacity).contains(first.slot), (0..<boxes[b].capacity).contains(second.slot) else {
            throw LocalStoreError.invalidOperation
        }
        guard first != second else { return }
        let (keyA, keyB) = (slotKey(first.slot), slotKey(second.slot))
        let (watchA, watchB) = (boxes[a].slots[keyA], boxes[b].slots[keyB])
        boxes[a].slots[keyA] = watchB
        boxes[b].slots[keyB] = watchA
        data.boxes = boxes
    }

    /// Puts the watch back in the tray. Returns false when it was in no compartment.
    @discardableResult
    static func takeOut(watchID: String, in data: inout CollectionData) -> Bool {
        guard var boxes = data.boxes, boxes.contains(where: { $0.slots.values.contains(watchID) }) else { return false }
        for index in boxes.indices where boxes[index].slots.values.contains(watchID) {
            boxes[index].slots = boxes[index].slots.filter { $0.value != watchID }
        }
        data.boxes = boxes
        return true
    }

    /// A new size: every watch keeps its (row, column) when that still exists, otherwise it goes to the tray.
    static func resize(_ box: WatchBox, columns: Int, rows: Int) -> WatchBox {
        var resized = box
        resized.columns = columns
        resized.rows = rows
        resized.slots = [:]
        guard box.columns > 0 else { return resized }
        for (key, watchID) in box.slots {
            guard let index = slotIndex(key), index < box.capacity else { continue }
            let (row, column) = (index / box.columns, index % box.columns)
            guard row < rows, column < columns else { continue }
            resized.slots[slotKey(row * columns + column)] = watchID
        }
        return resized
    }

    /// A trimmed name the hub accepts, or nil.
    static func cleanName(_ name: String) -> String? {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean.unicodeScalars.count <= nameLimit else { return nil }
        return clean
    }

    static func newBoxID(existing: [String]) -> String {
        var id: String
        repeat {
            id = "box-" + String(format: "%08x", UInt32.random(in: .min ... .max))
        } while existing.contains(id)
        return id
    }

    // MARK: Starting layout

    /// Where things start (brief section 12), read off his photo. No watch has a home box: he moves
    /// the fourteen non-smart watches between the two freely; both Apple Watches start in the tray.
    static let startingLayout: [WatchBox] = [
        WatchBox(id: "black", name: "Black Box", finish: "black", columns: 6, rows: 2, slots: [
            "1": "moonswatch-jupiter",
            "2": "stuhrling-regatta-elite-326b",
            "3": "invicta-pro-diver-22068",
            "4": "hamilton-khaki-field-auto-38mm",
            "5": "seiko-5-srpd51",
            "6": "casio-g-steel-gsts300g",
            "7": "casio-mtpvd01d",
            "8": "timex-marlin",
            "9": "oris-aquis-date",
            "10": "patek-philippe-aquanaut-5167a-rep",
            "11": "rolex-submariner-126610ln-rep",
        ]),
        WatchBox(id: "brown", name: "Brown Box", finish: "brown", columns: 6, rows: 2, slots: [
            "6": "zenith-220s",
            "7": "pierre-paulin-jumping-hour",
            "8": "casio-mq24-7b",
        ]),
    ]

    /// The collection with the starting layout, or nil when boxes were already set up: only a
    /// collection that has never had boxes (nil, not an empty list) is seeded. Ids that are not
    /// owned watches in this collection are left out by `sanitized`.
    static func seeding(_ data: CollectionData) -> CollectionData? {
        guard data.boxes == nil else { return nil }
        var seeded = data
        seeded.boxes = startingLayout
        return sanitized(seeded)
    }

    // MARK: Pictures

    /// The cutout settings that apply: nil when there are none or their photo is gone.
    static func effectiveCutout(_ cutout: BoxCutout?, photos: [String]) -> BoxCutout? {
        guard let cutout, photos.contains(cutout.photo) else { return nil }
        return cutout
    }

    /// What a compartment of this finish shows for a watch: its tile when the file is on the device
    /// and `useCutout` is not set; else the finish's empty tile under the cutout; else the drawn
    /// pillow under the cutout.
    static func picture(
        finish: String,
        boxTiles: [String: String]?,
        cutout: BoxCutout?,
        emptyBoxTiles: [String: String]?,
        hasTile: (String) -> Bool,
        hasEmptyTile: (String) -> Bool
    ) -> BoxSlotPicture {
        let finish = resolvedFinish(finish)
        if cutout?.useCutout != true, let file = boxTiles?[finish], hasTile(file) { return .tile(file) }
        if let file = emptyBoxTiles?[finish], hasEmptyTile(file) { return .emptyTile(file) }
        return .pillow
    }

    /// The same, for an owned watch or a wishlist candidate, checking the files in `PhotoStore`.
    static func picture(
        itemID: String,
        wishlist: Bool,
        photos: [String],
        boxTiles: [String: String]?,
        cutout: BoxCutout?,
        finish: String,
        emptyBoxTiles: [String: String]?
    ) -> BoxSlotPicture {
        picture(
            finish: finish,
            boxTiles: boxTiles,
            cutout: effectiveCutout(cutout, photos: photos),
            emptyBoxTiles: emptyBoxTiles,
            hasTile: { file in
                PhotoStore.asset(itemID: itemID, filename: file, wishlist: wishlist, baseURL: nil)
                    .flatMap(PhotoStore.existingLocalURL) != nil
            },
            hasEmptyTile: { file in
                PhotoStore.emptyTileAsset(filename: file, baseURL: nil).flatMap(PhotoStore.existingLocalURL) != nil
            }
        )
    }
}
