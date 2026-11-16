import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A watch cutout as the box draws it: from the cache, or fresh from `CutoutPipeline`.
struct CutoutResult: @unchecked Sendable {
    var image: CGImage
    /// Case radius in `image` pixels.
    var caseRadius: CGFloat
    /// Strap colour, red, green and blue in 0...1.
    var strap: [Double]
    var strapAbove: Double
    var strapBelow: Double
    var method: CutoutMethod
    var confidence: Double
    /// The photo it was made from.
    var photo: String
    /// Where the case was found in the photo: centre as fractions of width and height, radius as a fraction of the
    /// shorter side. The editor's ring starts here.
    var centerX: Double
    var centerY: Double
    var radius: Double
    /// Degrees the photo was turned to stand the strap upright (the detected direction plus any `turn`).
    var rotation: Double

    /// The disc fallback, a failed lift or a weak circle: the screen says "Check the cutout".
    var isDoubtful: Bool { method == .disc || method == .failed || confidence < 0.5 }
    /// A lift good enough to stop looking at other photos (brief 6.2).
    var isGoodLift: Bool { (method == .lift || method == .liftCleaned) && confidence >= 0.5 }
}

/// What a cutout is made from: one watch's or candidate's photos and its saved `boxCutout`.
struct CutoutSource: Hashable, Sendable {
    var itemID: String
    var wishlist: Bool
    var photos: [String]
    /// The saved settings, only when their photo is still among `photos`.
    var setting: BoxCutout?
    var focus: [String: PhotoFocus]

    /// The item's photo folder, which also names its cutouts in the cache.
    var directory: String { wishlist ? "wl-\(itemID)" : itemID }

    init(itemID: String, wishlist: Bool, photos: [String], setting: BoxCutout?, focus: [String: PhotoFocus]?) {
        self.itemID = itemID
        self.wishlist = wishlist
        self.photos = photos
        self.setting = BoxModel.effectiveCutout(setting, photos: photos)
        self.focus = focus ?? [:]
    }

    init(watch: Watch) {
        self.init(itemID: watch.id, wishlist: false, photos: watch.photos, setting: watch.boxCutout, focus: watch.photoFocus)
    }

    init(candidate: WishlistItem) {
        self.init(itemID: candidate.id, wishlist: true, photos: candidate.photos, setting: candidate.boxCutout, focus: candidate.photoFocus)
    }
}

/// What the cache keeps next to each cutout PNG: the fields of `prototype/renders/cutouts/*.json`.
struct CutoutSidecar: Codable {
    var version: Int
    var photo: String
    var caseRadius: Double
    var method: String
    var confidence: Double
    var strap: [Double]
    var strapAbove: Double
    var strapBelow: Double
    var x: Double
    var y: Double
    var r: Double
    var turn: Double
    var notes: [String]?
}

/// Watch cutouts, made on this device from the item's photos and kept in Caches (the system may purge them, backups
/// skip them, and they are never synced: the phone and the Mac each make their own from the same photo and the same
/// `boxCutout`, so they match). One Vision job at a time, at utility priority.
actor CutoutStore {
    static let shared = CutoutStore()
    static let memoryLimit = 40

    private let memory: NSCache<NSString, CutoutBox> = {
        let cache = NSCache<NSString, CutoutBox>()
        cache.countLimit = CutoutStore.memoryLimit
        return cache
    }()
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    /// Bumped by `cancelPending`: a job queued before it gives up instead of starting Vision.
    private var generation = 0
    private var seeded = false

    // MARK: Keys

    nonisolated static var root: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WatchCollection", isDirectory: true)
            .appendingPathComponent("cutouts", isDirectory: true)
    }

    /// The pipeline hint a saved setting asks for. The photo's framing focus is only a weak prior for which subject
    /// to keep, so it is not part of the cache key.
    nonisolated static func hint(for setting: BoxCutout?, focus: PhotoFocus?) -> CutoutHint {
        var hint = CutoutHint()
        if let setting {
            if let x = setting.x, let y = setting.y, let r = setting.r {
                hint.centerX = x
                hint.centerY = y
                hint.radius = r
            }
            hint.rotation = setting.turn ?? 0
            hint.discOnly = setting.caseOnly == true
        }
        if let focus {
            hint.focusX = focus.x
            hint.focusY = focus.y
        }
        return hint
    }

    /// A short, stable hash of the hint fields that change the cutout: the ring (x, y, r), turn and case only.
    nonisolated static func hintHash(_ hint: CutoutHint) -> String {
        func value(_ number: Double?) -> String { number.map { String(format: "%.5f", $0) } ?? "-" }
        let text = [value(hint.centerX), value(hint.centerY), value(hint.radius), value(hint.rotation), hint.discOnly ? "1" : "0"]
            .joined(separator: ";")
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return String(format: "%016llx", hash)
    }

    /// `v<version>/<photo directory>/<photo stem>-<hint hash>`, without an extension.
    nonisolated static func cacheKey(directory: String, photo: String, hint: CutoutHint, version: Int = CutoutPipeline.version) -> String {
        let stem = (photo as NSString).deletingPathExtension
        return "v\(version)/\(directory)/\(stem)-\(hintHash(hint))"
    }

    nonisolated static func fileURL(_ key: String, _ ext: String) -> URL {
        root.appendingPathComponent(key + "." + ext, isDirectory: false)
    }

    // MARK: Reading

    /// The cutout this item gets, from memory or disk only (never Vision): the saved photo, else the cover, else the
    /// first other photo with a good lift. A first answer for drawing at once; `cutout(_:)` settles it.
    func cached(_ source: CutoutSource) -> CutoutResult? {
        if let setting = source.setting {
            return load(Self.cacheKey(directory: source.directory, photo: setting.photo, hint: hint(source, setting.photo)))
        }
        var first: CutoutResult?
        for photo in source.photos {
            guard let hit = load(Self.cacheKey(directory: source.directory, photo: photo, hint: hint(source, photo))) else { continue }
            if hit.isGoodLift { return hit }
            if first == nil { first = hit }
        }
        return first
    }

    /// The cutout this item gets (brief 6.2): the saved photo when there is one; otherwise the cover, and when that
    /// gives the disc or a weak circle, the first other photo that gives a good lift, else the cover's result.
    /// A photo not on this device yet is skipped; nil means draw the token and ask again after the next sync.
    func cutout(_ source: CutoutSource) async -> CutoutResult? {
        if let setting = source.setting {
            return await cutout(directory: source.directory, photo: setting.photo, hint: hint(source, setting.photo), wishlist: source.wishlist, itemID: source.itemID)
        }
        var first: CutoutResult?
        for photo in source.photos {
            if Task.isCancelled { return first }
            guard let result = await cutout(directory: source.directory, photo: photo, hint: hint(source, photo), wishlist: source.wishlist, itemID: source.itemID) else { continue }
            if result.isGoodLift { return result }
            if first == nil { first = result }
        }
        return first
    }

    /// One photo's cutout with this hint: memory, then disk, then Vision (one job at a time).
    func cutout(directory: String, photo: String, hint: CutoutHint, wishlist: Bool, itemID: String) async -> CutoutResult? {
        let key = Self.cacheKey(directory: directory, photo: photo, hint: hint)
        if let hit = load(key) { return hit }
        guard let asset = PhotoStore.asset(itemID: itemID, filename: photo, wishlist: wishlist, baseURL: nil),
              let url = PhotoStore.existingLocalURL(for: asset) else { return nil }
        let ticket = generation
        await acquire()
        defer { release() }
        // Someone else may have made it while this waited; a job from before a cancel stops here.
        if let hit = load(key) { return hit }
        guard !Task.isCancelled, ticket == generation else { return nil }
        let made = await Task.detached(priority: .utility) { () -> WatchCutout? in
            guard let image = CutoutPipeline.load(url) else { return nil }
            return CutoutPipeline.make(photo: image, hint: hint)
        }.value
        guard let made else { return nil }
        let result = CutoutResult(
            image: made.image, caseRadius: made.caseRadius, strap: [made.strapColor.r, made.strapColor.g, made.strapColor.b],
            strapAbove: made.strapAbove, strapBelow: made.strapBelow, method: made.method, confidence: made.confidence,
            photo: photo, centerX: made.centerX, centerY: made.centerY, radius: made.radius, rotation: made.rotation
        )
        save(result, key: key, notes: made.notes)
        return result
    }

    /// Jobs waiting for Vision give up (the Boxes tab went away). A job already running finishes and is cached.
    func cancelPending() {
        generation += 1
    }

    private func hint(_ source: CutoutSource, _ photo: String) -> CutoutHint {
        Self.hint(for: source.setting?.photo == photo ? source.setting : nil, focus: source.focus[photo])
    }

    // MARK: One job at a time

    private func acquire() async {
        guard busy else {
            busy = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func release() {
        if waiters.isEmpty {
            busy = false
        } else {
            waiters.removeFirst().resume()
        }
    }

    // MARK: Disk and memory

    private func load(_ key: String) -> CutoutResult? {
        if let hit = memory.object(forKey: key as NSString) { return hit.result }
        let png = Self.fileURL(key, "png"), json = Self.fileURL(key, "json")
        guard let data = try? Data(contentsOf: json),
              let sidecar = try? JSONDecoder().decode(CutoutSidecar.self, from: data),
              let source = CGImageSourceCreateWithURL(png as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }
        let result = CutoutResult(
            image: image, caseRadius: CGFloat(sidecar.caseRadius),
            strap: sidecar.strap.count == 3 ? sidecar.strap : [0.13, 0.13, 0.14],
            strapAbove: sidecar.strapAbove, strapBelow: sidecar.strapBelow,
            method: CutoutMethod(rawValue: sidecar.method) ?? .failed, confidence: sidecar.confidence,
            photo: sidecar.photo, centerX: sidecar.x, centerY: sidecar.y, radius: sidecar.r, rotation: sidecar.turn
        )
        memory.setObject(CutoutBox(result), forKey: key as NSString)
        return result
    }

    private func save(_ result: CutoutResult, key: String, notes: [String]) {
        memory.setObject(CutoutBox(result), forKey: key as NSString)
        let png = Self.fileURL(key, "png"), json = Self.fileURL(key, "json")
        let sidecar = CutoutSidecar(
            version: CutoutPipeline.version, photo: result.photo, caseRadius: Double(result.caseRadius), method: result.method.rawValue,
            confidence: result.confidence, strap: result.strap, strapAbove: result.strapAbove, strapBelow: result.strapBelow,
            x: result.centerX, y: result.centerY, r: result.radius, turn: result.rotation, notes: notes
        )
        do {
            try FileManager.default.createDirectory(at: png.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard let destination = CGImageDestinationCreateWithURL(png as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
            CGImageDestinationAddImage(destination, result.image, nil)
            guard CGImageDestinationFinalize(destination) else { return }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(sidecar).write(to: json, options: .atomic)
        } catch {
            // A cache that cannot be written only means the cutout is made again next time.
        }
    }

    // MARK: Simulator seed

    /// Debug builds only. The iOS Simulator cannot run the subject lift (it lands on the disc), so for pictures a
    /// launch argument `-WatchCutoutSeed <dir>` copies ready-made cutouts into the cache before the first draw:
    /// `<photo directory>.png` with its `.json` sidecar, which names the photo. They are filed as that photo's
    /// automatic cutout.
    func seedIfAsked() {
        #if DEBUG
        guard !seeded else { return }
        seeded = true
        guard let path = UserDefaults.standard.string(forKey: "WatchCutoutSeed") else { return }
        let folder = URL(fileURLWithPath: path, isDirectory: true)
        guard let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { return }
        for json in files where json.pathExtension == "json" {
            let directory = json.deletingPathExtension().lastPathComponent
            let png = folder.appendingPathComponent(directory + ".png")
            guard let data = try? Data(contentsOf: json),
                  let sidecar = try? JSONDecoder().decode(CutoutSidecar.self, from: data),
                  sidecar.version == CutoutPipeline.version,
                  FileManager.default.fileExists(atPath: png.path) else { continue }
            let key = Self.cacheKey(directory: directory, photo: sidecar.photo, hint: CutoutHint())
            let targetPNG = Self.fileURL(key, "png"), targetJSON = Self.fileURL(key, "json")
            guard !FileManager.default.fileExists(atPath: targetJSON.path) else { continue }
            try? FileManager.default.createDirectory(at: targetPNG.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: targetPNG)
            try? FileManager.default.copyItem(at: png, to: targetPNG)
            try? FileManager.default.copyItem(at: json, to: targetJSON)
        }
        #endif
    }
}

/// NSCache holds classes.
private final class CutoutBox {
    let result: CutoutResult
    init(_ result: CutoutResult) { self.result = result }
}
