import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import Vision

// Watch cutouts for the box render.
//
// Platform neutral (iOS 17+ / macOS 14+): Vision, Core Image and Core Graphics only.
// One photo in, one square cutout out: the watch centred, 12 o'clock up, with the case
// radius in pixels so the box can draw it to scale from the watch's real diameter.
//
// Order of work:
//   1. Vision subject lift (VNGenerateForegroundInstanceMaskRequest), pick one instance.
//   2. If a person is in the photo (VNGeneratePersonSegmentationRequest) and the lift
//      carries skin that runs to the photo's edge, take the skin out (wrist, hand).
//   3. Case circle = the largest circle that fits inside what is left (distance transform),
//      checked against the picture: a real case has a circular edge there.
//   4. Strap axis from the pixels just outside the case; rotate so the strap is vertical.
//   5. Keep the case disc (with room for crown and pushers) and the strap band, drop the rest.
//   6. If any step cannot be trusted, fall back to a plain disc at the best circle found;
//      the box draws a strap under it in a sampled colour.

struct CutoutHint: Sendable {
    /// Case centre in the photo, 0...1 from the top left, and case radius as a fraction of the
    /// photo's shorter side. Set by the editor's ring; nil means find it.
    var centerX: Double?
    var centerY: Double?
    var radius: Double?
    /// Extra rotation in degrees on top of the detected strap axis (editor).
    var rotation: Double = 0
    /// Force the disc fallback (editor's "Case only").
    var discOnly = false
    /// Framing focus of the photo if the owner set one (weak prior for the instance pick).
    var focusX: Double = 0.5
    var focusY: Double = 0.5
}

enum CutoutMethod: String, Sendable {
    case lift            // Vision lift used as it came
    case liftCleaned     // lift with wrist or hand removed
    case disc            // fallback: case disc only, strap drawn by the box
    case failed
}

struct WatchCutout {
    var image: CGImage              // square, premultiplied alpha, watch centred, strap vertical
    var caseRadius: CGFloat         // case radius in `image` pixels
    var strapColor: (r: Double, g: Double, b: Double)   // 0...1, median of the strap pixels
    var strapAbove: Double          // 0...1 how much real strap survived above / below the case
    var strapBelow: Double
    var method: CutoutMethod
    var confidence: Double          // 0...1, below 0.5 the app shows "Check the cutout"
    var notes: [String]
    // Where the case was found in the source photo (for the editor's ring).
    var centerX: Double
    var centerY: Double
    var radius: Double
    var rotation: Double            // degrees the photo was turned
}

enum CutoutPipeline {
    static let version = 1                 // bump to invalidate every cached cutout
    static let workingSide = 1024          // long side the photo is analysed at
    static let outputSide = 560            // cutout side in pixels
    static let caseFraction: CGFloat = 0.21 // case radius as a fraction of the cutout side
    static let crownAllowance = 1.24       // disc kept = case radius x this (crown, pushers, lug tips)
    static let bandHalfWidth = 0.74        // strap band half width, in case radii
    static let bandReach = 2.3             // strap kept out to this many case radii from the centre
    static let mirrorFrom = 0.5            // a side with at least this much strap can lend it ...
    static let mirrorInto = 0.45           // ... to a side with less than this
    static let roundEnough = 0.62          // inscribed circle rim support below this is questioned
    static let innerCircleWins = 0.85      // ... and an inner circle with at least this support replaces it

    // MARK: Loading

    static func load(_ url: URL, maxSide: Int = workingSide) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxSide,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    // MARK: Entry point

    static func make(photo: CGImage, hint: CutoutHint = CutoutHint()) -> WatchCutout? {
        let w = photo.width, h = photo.height
        guard w > 32, h > 32, let rgba = Raster.rgba(photo) else { return nil }
        var notes: [String] = []
        let handler = VNImageRequestHandler(cgImage: photo)

        // 1. Subject lift.
        let lift = VNGenerateForegroundInstanceMaskRequest()
        let person = VNGeneratePersonSegmentationRequest()
        person.qualityLevel = .balanced
        person.outputPixelFormat = kCVPixelFormatType_OneComponent8
        let hands = VNDetectHumanHandPoseRequest()
        hands.maximumHandCount = 2
        try? handler.perform([lift, person, hands])
        let handHeld = !(hands.results ?? []).isEmpty

        var matte: [Float]? = nil
        if let observation = lift.results?.first, !hint.discOnly {
            var best: (score: Double, matte: [Float])? = nil
            for instance in observation.allInstances {
                guard let buffer = try? observation.generateScaledMaskForImage(forInstances: IndexSet(integer: instance), from: handler),
                      let m = Raster.floats(buffer, width: w, height: h) else { continue }
                let s = instanceScore(m, w: w, h: h, hint: hint)
                if s > (best?.score ?? 0) { best = (s, m) }
            }
            matte = best?.matte
            if observation.allInstances.count > 1 { notes.append("\(observation.allInstances.count) subjects, kept the central one") }
        }
        if matte == nil && !hint.discOnly { notes.append("no subject found") }

        // 2. Skin out, only when Vision sees a person.
        var method = CutoutMethod.lift
        let personMask = person.results?.first.flatMap { Raster.bytesScaled($0.pixelBuffer, width: w, height: h) }
        let personShare = personMask.map { m in Double(m.reduce(0) { $0 + ($1 > 127 ? 1 : 0) }) / Double(w * h) } ?? 0
        if var m = matte, personShare > 0.04 {
            let removed = removeBorderSkin(&m, rgba: rgba, w: w, h: h)
            if removed > 0.004 {
                method = .liftCleaned
                notes.append(String(format: "skin removed (%.0f%% of the photo)", removed * 100))
                matte = m
            }
        }
        if var m = matte {
            keepLargestComponent(&m, w: w, h: h)
            matte = m
        }

        // 3. Case circle.
        var center = CGPoint(x: Double(w) / 2, y: Double(h) / 2)
        var radius = Double(min(w, h)) * 0.2
        var confidence = 0.0
        let gray = Raster.gray(rgba, w: w, h: h)
        if let m = matte {
            let (c, r) = largestInscribedCircle(m, w: w, h: h)
            center = c; radius = r
            let support = circleSupport(gray: gray, matte: m, w: w, h: h, center: c, radius: r)
            confidence = support
            notes.append(String(format: "inscribed r=%.0f support=%.2f", r, support))
            if support < roundEnough {
                // The blob is more than the watch (it sits on a cushion, a sleeve came with it):
                // take the strongest circular edge inside it and keep the case disc only.
                if let found = strongestCircle(gray: gray, w: w, h: h, near: c, within: r * 0.5, radii: (r * 0.45)...(r * 0.92)),
                   found.support >= innerCircleWins {
                    notes.append(String(format: "blob is not the watch alone, used edge circle r=%.0f support=%.2f", found.radius, found.support))
                    center = found.center; radius = found.radius; confidence = found.support * 0.7
                    method = .disc
                } else if support < 0.42 {
                    method = .disc; confidence = min(confidence, 0.3)
                    notes.append("no clear case edge")
                }
            }
            let minSide = Double(min(w, h))
            if radius < minSide * 0.045 || radius > minSide * 0.5 { method = .disc; confidence = min(confidence, 0.2); notes.append("case size implausible") }
        } else {
            method = .disc
            let guess = CGPoint(x: hint.focusX * Double(w), y: hint.focusY * Double(h))
            if let found = strongestCircle(gray: gray, w: w, h: h, near: guess, within: Double(min(w, h)) * 0.3,
                                           radii: (Double(min(w, h)) * 0.08)...(Double(min(w, h)) * 0.42)) {
                center = found.center; radius = found.radius; confidence = found.support * 0.6
            }
        }
        if let x = hint.centerX, let y = hint.centerY, let r = hint.radius {
            center = CGPoint(x: x * Double(w), y: y * Double(h)); radius = r * Double(min(w, h)); confidence = 1
            notes.append("ring set by hand")
        }
        if hint.discOnly { method = .disc }

        // 4. Strap axis.
        var angle = 0.0   // radians, clockwise from straight up
        if method != .disc, let m = matte, let a = strapAxis(m, w: w, h: h, center: center, radius: radius) { angle = a }
        angle += hint.rotation * .pi / 180

        // 5 and 6. Cut.
        let side = outputSide
        let scale = (Double(side) * Double(caseFraction)) / radius
        guard let photoOut = Raster.resample(photo, side: side, center: center, sourceHeight: h, angle: angle, scale: scale, gray: false),
              var out = Raster.rgba(photoOut) else { return nil }
        var alpha = [Float](repeating: 1, count: side * side)
        if method != .disc, let m = matte, let matteImage = Raster.grayImage(m, w: w, h: h),
           let matteOut = Raster.resample(matteImage, side: side, center: center, sourceHeight: h, angle: angle, scale: scale, gray: true),
           let bytes = Raster.grayBytes(matteOut) {
            for i in 0..<(side * side) { alpha[i] = Float(bytes[i]) / 255 }
        }
        let r = Double(side) * Double(caseFraction)
        let mid = Double(side) / 2
        var strapSamples: [(UInt8, UInt8, UInt8)] = []
        var above = 0.0, below = 0.0, bandArea = 0.0
        for y in 0..<side {
            for x in 0..<side {
                let u = Double(x) + 0.5 - mid, v = Double(y) + 0.5 - mid
                let d = (u * u + v * v).squareRoot()
                var keep: Double
                if method == .disc {
                    keep = smooth(r * 1.0 + 1.5, r * 1.0 - 1.5, d)
                } else {
                    let disc = smooth(r * crownAllowance + 2, r * crownAllowance - 2, d)
                    let band = smooth(r * bandHalfWidth + 2, r * bandHalfWidth - 2, abs(u)) * smooth(r * bandReach + 2, r * bandReach - 2, abs(v))
                    keep = max(disc, band)
                }
                let i = y * side + x
                let a = Double(alpha[i]) * keep
                alpha[i] = Float(a)
                if method != .disc, abs(u) < r * 0.5, abs(v) > r * 1.3, abs(v) < r * 2.0 {
                    bandArea += 0.5
                    if a > 0.6 { if v < 0 { above += 1 } else { below += 1 } }
                }
                // Strap colour: from just past the lugs outward, where a short strap still shows.
                if method != .disc, a > 0.6, abs(u) < r * 0.4, abs(v) > r * 1.16, abs(v) < r * 2.0, (x + y) % 3 == 0 {
                    strapSamples.append((out[i * 4], out[i * 4 + 1], out[i * 4 + 2]))
                }
            }
        }
        if method != .disc {
            // Skin left inside the kept shape. Held in a hand: any skin outside the case circle is
            // fingers. On a wrist: only skin beside the strap band, so a tan strap survives.
            if personShare > 0.04 {
                var body = [Bool](repeating: false, count: side * side)
                var any = false
                for y in 0..<side {
                    for x in 0..<side {
                        let i = y * side + x
                        guard alpha[i] > 0.2 else { continue }
                        let u = Double(x) + 0.5 - mid, v = Double(y) + 0.5 - mid
                        guard (u * u + v * v).squareRoot() > r * (handHeld ? 0.82 : 1.0), handHeld || abs(u) > r * bandHalfWidth * 0.92 else { continue }
                        if isSkin(out[i * 4], out[i * 4 + 1], out[i * 4 + 2]) { body[i] = true; any = true }
                    }
                }
                if any {
                    // Only regions that reach the cutout's own edge: a rivet or a tan patch inside the
                    // strap is part of the watch.
                    body = Raster.majority(body, w: side, h: side, radius: 2)
                    body = Raster.keepRegions(body, w: side, h: side) { i in alpha[i] <= 0.2 }
                    body = Raster.dilate(body, w: side, h: side, radius: 3)
                    var cleared = 0
                    for y in 0..<side {
                        for x in 0..<side where body[y * side + x] {
                            let u = Double(x) + 0.5 - mid, v = Double(y) + 0.5 - mid
                            if (u * u + v * v).squareRoot() > r * (handHeld ? 0.82 : 0.985) { alpha[y * side + x] = 0; cleared += 1 }
                        }
                    }
                    if cleared > side * side / 400 {
                        notes.append(handHeld ? "fingers removed" : "wrist beside the case removed")
                        if method == .lift { method = .liftCleaned }
                    }
                }
            }
            keepLargestComponent(&alpha, w: side, h: side)
            // Recount the strap now that fingers are gone.
            above = 0; below = 0
            for y in 0..<side {
                for x in 0..<side {
                    let u = Double(x) + 0.5 - mid, v = Double(y) + 0.5 - mid
                    if abs(u) < r * 0.5, abs(v) > r * 1.3, abs(v) < r * 2.0, alpha[y * side + x] > 0.6 { if v < 0 { above += 1 } else { below += 1 } }
                }
            }
            // A wrist shot usually shows the strap on the near side only. Give the far side the
            // near side turned half a turn about the case centre, a little darker.
            let shareAbove = bandArea > 0 ? above / bandArea : 0, shareBelow = bandArea > 0 ? below / bandArea : 0
            if max(shareAbove, shareBelow) >= mirrorFrom, min(shareAbove, shareBelow) < mirrorInto {
                let fillTop = shareBelow > shareAbove
                let source = out, sourceAlpha = alpha
                for y in 0..<side {
                    for x in 0..<side {
                        let v = Double(y) + 0.5 - mid, u = Double(x) + 0.5 - mid
                        guard fillTop ? v < 0 : v > 0, (u * u + v * v).squareRoot() > r * 0.97 else { continue }
                        let i = y * side + x, j = (side - 1 - y) * side + (side - 1 - x)
                        guard sourceAlpha[j] > alpha[i] else { continue }
                        let t = sourceAlpha[j]
                        for c in 0..<3 { out[i * 4 + c] = UInt8(Float(source[j * 4 + c]) * 0.86 * t + Float(out[i * 4 + c]) * (1 - t)) }
                        alpha[i] = max(alpha[i], t)
                    }
                }
                notes.append(fillTop ? "far strap mirrored from the near side" : "near strap mirrored from the far side")
                if fillTop { above = below } else { below = above }
            }
        }
        for i in 0..<(side * side) {
            let a = alpha[i]
            out[i * 4] = UInt8(Float(out[i * 4]) * a)
            out[i * 4 + 1] = UInt8(Float(out[i * 4 + 1]) * a)
            out[i * 4 + 2] = UInt8(Float(out[i * 4 + 2]) * a)
            out[i * 4 + 3] = UInt8(255 * a)
        }
        guard let image = Raster.image(out, side: side) else { return nil }
        var strap = (r: 0.13, g: 0.13, b: 0.14)
        if strapSamples.count > 40 {
            let rs = strapSamples.map(\.0).sorted(), gs = strapSamples.map(\.1).sorted(), bs = strapSamples.map(\.2).sorted()
            strap = (Double(rs[rs.count / 2]) / 255, Double(gs[gs.count / 2]) / 255, Double(bs[bs.count / 2]) / 255)
        } else if method == .disc {
            strap = ringColor(rgba, w: w, h: h, center: center, radius: radius, angle: angle)
        }
        return WatchCutout(
            image: image, caseRadius: CGFloat(r), strapColor: strap,
            strapAbove: bandArea > 0 ? min(1, above / bandArea) : 0, strapBelow: bandArea > 0 ? min(1, below / bandArea) : 0,
            method: method, confidence: confidence, notes: notes,
            centerX: center.x / Double(w), centerY: center.y / Double(h), radius: radius / Double(min(w, h)), rotation: angle * 180 / .pi)
    }

    // MARK: Steps

    private static func smooth(_ edge0: Double, _ edge1: Double, _ x: Double) -> Double {
        let t = max(0, min(1, (x - edge0) / (edge1 - edge0)))
        return t * t * (3 - 2 * t)
    }

    /// Bigger, more central, less cut by the photo's edge wins.
    private static func instanceScore(_ m: [Float], w: Int, h: Int, hint: CutoutHint) -> Double {
        var area = 0.0, sx = 0.0, sy = 0.0, border = 0.0
        for y in 0..<h {
            for x in 0..<w where m[y * w + x] > 0.5 {
                area += 1; sx += Double(x); sy += Double(y)
                if x == 0 || y == 0 || x == w - 1 || y == h - 1 { border += 1 }
            }
        }
        guard area > Double(w * h) * 0.004 else { return 0 }
        let cx = sx / area / Double(w), cy = sy / area / Double(h)
        let d2 = pow(cx - hint.focusX, 2) + pow(cy - hint.focusY, 2)
        let central = exp(-d2 / (2 * 0.3 * 0.3))
        let cut = 1 - min(0.8, border / Double(2 * (w + h)) * 4)
        return (area / Double(w * h)).squareRoot() * central * cut
    }

    static func isSkin(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> Bool {
        let R = Double(r), G = Double(g), B = Double(b)
        let y = 0.299 * R + 0.587 * G + 0.114 * B
        let cb = 128 - 0.168736 * R - 0.331264 * G + 0.5 * B
        let cr = 128 + 0.5 * R - 0.418688 * G - 0.081312 * B
        // Cream, ivory and steel under warm light fall in the same chroma box; real skin is more saturated.
        return y > 40 && cb > 80 && cb < 130 && cr > 134 && cr < 178 && R > G && G > B * 0.9 && (R - B) > R * 0.17
    }

    /// Clears skin-coloured regions of the lift that reach the photo's edge. Returns the share of
    /// the photo that was cleared. A salmon dial or a tan strap on a clean lift is left alone
    /// because it does not run to the edge.
    private static func removeBorderSkin(_ m: inout [Float], rgba: [UInt8], w: Int, h: Int) -> Double {
        var skin = [Bool](repeating: false, count: w * h)
        for i in 0..<(w * h) where m[i] > 0.35 { skin[i] = isSkin(rgba[i * 4], rgba[i * 4 + 1], rgba[i * 4 + 2]) }
        // Close pinholes (hair, specular dots) so the arm is one region.
        skin = Raster.majority(skin, w: w, h: h, radius: 2)
        var label = [Int32](repeating: 0, count: w * h)
        var next: Int32 = 0
        var remove = [Bool](repeating: false, count: w * h)
        var removed = 0
        var stack: [Int] = []
        for start in 0..<(w * h) where skin[start] && label[start] == 0 {
            next += 1
            var members: [Int] = []
            var touches = false
            stack.append(start); label[start] = next
            while let i = stack.popLast() {
                members.append(i)
                let x = i % w, y = i / w
                if x == 0 || y == 0 || x == w - 1 || y == h - 1 { touches = true }
                if x > 0, skin[i - 1], label[i - 1] == 0 { label[i - 1] = next; stack.append(i - 1) }
                if x < w - 1, skin[i + 1], label[i + 1] == 0 { label[i + 1] = next; stack.append(i + 1) }
                if y > 0, skin[i - w], label[i - w] == 0 { label[i - w] = next; stack.append(i - w) }
                if y < h - 1, skin[i + w], label[i + w] == 0 { label[i + w] = next; stack.append(i + w) }
            }
            if touches && members.count > w * h / 250 {
                for i in members { remove[i] = true }
                removed += members.count
            }
        }
        guard removed > 0 else { return 0 }
        remove = Raster.dilate(remove, w: w, h: h, radius: 3)
        for i in 0..<(w * h) where remove[i] { m[i] = 0 }
        return Double(removed) / Double(w * h)
    }

    private static func keepLargestComponent(_ m: inout [Float], w: Int, h: Int) {
        var label = [Int32](repeating: 0, count: w * h)
        var next: Int32 = 0
        var bestLabel: Int32 = 0, bestCount = 0
        var stack: [Int] = []
        for start in 0..<(w * h) where m[start] > 0.5 && label[start] == 0 {
            next += 1
            var count = 0
            stack.append(start); label[start] = next
            while let i = stack.popLast() {
                count += 1
                let x = i % w, y = i / w
                if x > 0, m[i - 1] > 0.5, label[i - 1] == 0 { label[i - 1] = next; stack.append(i - 1) }
                if x < w - 1, m[i + 1] > 0.5, label[i + 1] == 0 { label[i + 1] = next; stack.append(i + 1) }
                if y > 0, m[i - w] > 0.5, label[i - w] == 0 { label[i - w] = next; stack.append(i - w) }
                if y < h - 1, m[i + w] > 0.5, label[i + w] == 0 { label[i + w] = next; stack.append(i + w) }
            }
            if count > bestCount { bestCount = count; bestLabel = next }
        }
        guard next > 1 else { return }
        // Soft edge pixels (0...0.5) next to the kept blob survive; other blobs go.
        for i in 0..<(w * h) where label[i] != bestLabel && label[i] != 0 { m[i] = 0 }
    }

    /// Chamfer (3,4) distance transform; the photo's edge counts as outside.
    static func largestInscribedCircle(_ m: [Float], w: Int, h: Int) -> (CGPoint, Double) {
        var d = [Int32](repeating: 0, count: w * h)
        let big: Int32 = 1 << 28
        for i in 0..<(w * h) { d[i] = m[i] > 0.5 ? big : 0 }
        for y in 0..<h {
            for x in 0..<w where d[y * w + x] != 0 {
                var v = d[y * w + x]
                if x == 0 || y == 0 || x == w - 1 || y == h - 1 { v = 3 } else {
                    v = min(v, d[y * w + x - 1] + 3, d[(y - 1) * w + x] + 3, d[(y - 1) * w + x - 1] + 4, d[(y - 1) * w + x + 1] + 4)
                }
                d[y * w + x] = v
            }
        }
        var best: Int32 = 0, bestIndex = 0
        for y in stride(from: h - 1, through: 0, by: -1) {
            for x in stride(from: w - 1, through: 0, by: -1) where d[y * w + x] != 0 {
                var v = d[y * w + x]
                if x < w - 1 && y < h - 1 && x > 0 {
                    v = min(v, d[y * w + x + 1] + 3, d[(y + 1) * w + x] + 3, d[(y + 1) * w + x + 1] + 4, d[(y + 1) * w + x - 1] + 4)
                }
                d[y * w + x] = v
                if v > best { best = v; bestIndex = y * w + x }
            }
        }
        return (CGPoint(x: Double(bestIndex % w) + 0.5, y: Double(bestIndex / w) + 0.5), Double(best) / 3)
    }

    /// Share of the circle's rim that sits on a radial edge in the picture or on the lift's own
    /// outline, within 7 percent of the radius.
    static func circleSupport(gray: [Float], matte: [Float]?, w: Int, h: Int, center: CGPoint, radius: Double) -> Double {
        let steps = 120
        var hits = 0, valid = 0
        for s in 0..<steps {
            let t = Double(s) / Double(steps) * 2 * .pi
            let dx = cos(t), dy = sin(t)
            var strongest: Float = 0
            var inside = true
            var r = radius * 0.93
            while r <= radius * 1.07 {
                let x0 = Int(center.x + dx * (r - 2)), y0 = Int(center.y + dy * (r - 2))
                let x1 = Int(center.x + dx * (r + 2)), y1 = Int(center.y + dy * (r + 2))
                guard x0 >= 0, y0 >= 0, x0 < w, y0 < h, x1 >= 0, y1 >= 0, x1 < w, y1 < h else { inside = false; break }
                var e = abs(gray[y1 * w + x1] - gray[y0 * w + x0])
                if let matte { e = max(e, abs(matte[y1 * w + x1] - matte[y0 * w + x0]) * 0.6) }
                strongest = max(strongest, e)
                r += 1
            }
            guard inside else { continue }
            valid += 1
            if strongest > 0.11 { hits += 1 }
        }
        return valid > steps / 2 ? Double(hits) / Double(valid) : 0
    }

    /// Coarse search for the best supported circle. Prefers the largest radius within 8 percent
    /// of the best score, so the bezel's outer edge wins over the dial ring.
    static func strongestCircle(gray: [Float], w: Int, h: Int, near: CGPoint, within: Double, radii: ClosedRange<Double>)
        -> (center: CGPoint, radius: Double, support: Double)? {
        var results: [(CGPoint, Double, Double)] = []
        let stepC = max(3, within / 7), stepR = max(2, (radii.upperBound - radii.lowerBound) / 16)
        var cy = near.y - within
        while cy <= near.y + within {
            var cx = near.x - within
            while cx <= near.x + within {
                var r = radii.lowerBound
                while r <= radii.upperBound {
                    let s = circleSupport(gray: gray, matte: nil, w: w, h: h, center: CGPoint(x: cx, y: cy), radius: r)
                    if s > 0.3 { results.append((CGPoint(x: cx, y: cy), r, s)) }
                    r += stepR
                }
                cx += stepC
            }
            cy += stepC
        }
        guard let top = results.map(\.2).max() else { return nil }
        let good = results.filter { $0.2 >= top - 0.08 }
        guard let pick = good.max(by: { $0.1 < $1.1 }) else { return nil }
        return (pick.0, pick.1, pick.2)
    }

    /// Principal axis of the lift between 1.15 and 2.6 case radii from the centre, as an angle
    /// clockwise from straight up, folded into -90...90 degrees. Nil when there is no clear strap.
    static func strapAxis(_ m: [Float], w: Int, h: Int, center: CGPoint, radius: Double) -> Double? {
        var sxx = 0.0, syy = 0.0, sxy = 0.0, n = 0.0
        let reach = radius * 2.6
        let x0 = max(0, Int(center.x - reach)), x1 = min(w - 1, Int(center.x + reach))
        let y0 = max(0, Int(center.y - reach)), y1 = min(h - 1, Int(center.y + reach))
        guard x1 > x0, y1 > y0 else { return nil }
        for y in y0...y1 {
            for x in x0...x1 where m[y * w + x] > 0.5 {
                let dx = Double(x) - center.x, dy = Double(y) - center.y
                let d = (dx * dx + dy * dy).squareRoot()
                guard d > radius * 1.15, d < reach else { continue }
                sxx += dx * dx; syy += dy * dy; sxy += dx * dy; n += 1
            }
        }
        guard n > radius * radius * 0.25 else { return nil }
        let theta = 0.5 * atan2(2 * sxy, sxx - syy)          // major axis angle from +x, y down
        let common = ((sxx - syy) * (sxx - syy) / 4 + sxy * sxy).squareRoot()
        let l1 = (sxx + syy) / 2 + common, l2 = (sxx + syy) / 2 - common
        guard l1 > l2 * 2.2 else { return nil }
        var ax = cos(theta), ay = sin(theta)
        if ay > 0 { ax = -ax; ay = -ay }                     // point it up the photo
        let fromUp = atan2(ax, -ay)                          // clockwise from up
        // Little strap to go on: only trust a small turn.
        let limit = (n > radius * radius * 0.6 ? 60.0 : 25.0) * .pi / 180
        return abs(fromUp) > limit ? nil : fromUp
    }

    /// Strap colour guess for the disc fallback: median just outside the case at 12 and 6.
    private static func ringColor(_ rgba: [UInt8], w: Int, h: Int, center: CGPoint, radius: Double, angle: Double) -> (r: Double, g: Double, b: Double) {
        var rs: [UInt8] = [], gs: [UInt8] = [], bs: [UInt8] = []
        for sign in [-1.0, 1.0] {
            for k in stride(from: 1.2, through: 1.5, by: 0.05) {
                for off in stride(from: -0.3, through: 0.3, by: 0.1) {
                    let u = off * radius, v = sign * k * radius
                    let x = Int(center.x + u * cos(angle) - v * sin(angle)), y = Int(center.y + u * sin(angle) + v * cos(angle))
                    guard x >= 0, y >= 0, x < w, y < h else { continue }
                    let i = (y * w + x) * 4
                    if isSkin(rgba[i], rgba[i + 1], rgba[i + 2]) { continue }
                    rs.append(rgba[i]); gs.append(rgba[i + 1]); bs.append(rgba[i + 2])
                }
            }
        }
        guard rs.count > 8 else { return (0.13, 0.13, 0.14) }
        rs.sort(); gs.sort(); bs.sort()
        return (Double(rs[rs.count / 2]) / 255, Double(gs[gs.count / 2]) / 255, Double(bs[bs.count / 2]) / 255)
    }
}

// MARK: - Raster helpers

enum Raster {
    static let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

    static func rgba(_ image: CGImage) -> [UInt8]? {
        let w = image.width, h = image.height
        var px = [UInt8](repeating: 0, count: w * h * 4)
        let ok = px.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: srgb, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        return ok ? px : nil
    }

    static func grayBytes(_ image: CGImage) -> [UInt8]? {
        let w = image.width, h = image.height
        var px = [UInt8](repeating: 0, count: w * h)
        let ok = px.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        return ok ? px : nil
    }

    static func gray(_ rgba: [UInt8], w: Int, h: Int) -> [Float] {
        var g = [Float](repeating: 0, count: w * h)
        for i in 0..<(w * h) {
            g[i] = (0.299 * Float(rgba[i * 4]) + 0.587 * Float(rgba[i * 4 + 1]) + 0.114 * Float(rgba[i * 4 + 2])) / 255
        }
        return g
    }

    static func floats(_ buffer: CVPixelBuffer, width: Int, height: Int) -> [Float]? {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let bw = CVPixelBufferGetWidth(buffer), bh = CVPixelBufferGetHeight(buffer)
        guard bw == width, bh == height, let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        var out = [Float](repeating: 0, count: width * height)
        for y in 0..<height {
            let row = base.advanced(by: y * rowBytes).assumingMemoryBound(to: Float32.self)
            for x in 0..<width { out[y * width + x] = row[x] }
        }
        return out
    }

    /// 8-bit one-component buffer, nearest-neighbour scaled to the photo's size.
    static func bytesScaled(_ buffer: CVPixelBuffer, width: Int, height: Int) -> [UInt8]? {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let bw = CVPixelBufferGetWidth(buffer), bh = CVPixelBufferGetHeight(buffer)
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        var out = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height {
            let row = base.advanced(by: (y * bh / height) * rowBytes).assumingMemoryBound(to: UInt8.self)
            for x in 0..<width { out[y * width + x] = row[x * bw / width] }
        }
        return out
    }

    static func grayImage(_ m: [Float], w: Int, h: Int) -> CGImage? {
        let bytes = m.map { UInt8(max(0, min(1, $0)) * 255) }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue), provider: provider, decode: nil,
                       shouldInterpolate: true, intent: .defaultIntent)
    }

    static func image(_ rgba: [UInt8], side: Int) -> CGImage? {
        guard let provider = CGDataProvider(data: Data(rgba) as CFData) else { return nil }
        return CGImage(width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: side * 4, space: srgb,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: provider, decode: nil,
                       shouldInterpolate: true, intent: .defaultIntent)
    }

    /// Draws `image` into a square so that `center` (top-left pixel coordinates) lands in the
    /// middle, turned so a direction `angle` clockwise from up points straight up, scaled by `scale`.
    static func resample(_ image: CGImage, side: Int, center: CGPoint, sourceHeight: Int, angle: Double, scale: Double, gray: Bool) -> CGImage? {
        let space = gray ? CGColorSpaceCreateDeviceGray() : srgb
        let info = gray ? CGImageAlphaInfo.none.rawValue : CGImageAlphaInfo.premultipliedLast.rawValue
        guard let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: info) else { return nil }
        ctx.interpolationQuality = .high
        if gray { ctx.setFillColor(gray: 0, alpha: 1) } else { ctx.setFillColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1) }
        ctx.fill(CGRect(x: 0, y: 0, width: side, height: side))
        ctx.translateBy(x: CGFloat(side) / 2, y: CGFloat(side) / 2)
        ctx.rotate(by: CGFloat(angle))
        ctx.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
        ctx.translateBy(x: -center.x, y: -(CGFloat(sourceHeight) - center.y))
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return ctx.makeImage()
    }

    /// Keeps the 4-connected regions of `m` that have at least one neighbour passing `touches`.
    static func keepRegions(_ m: [Bool], w: Int, h: Int, touching touches: (Int) -> Bool) -> [Bool] {
        var out = [Bool](repeating: false, count: w * h)
        var seen = [Bool](repeating: false, count: w * h)
        var stack: [Int] = []
        for start in 0..<(w * h) where m[start] && !seen[start] {
            var members: [Int] = []
            var hit = false
            stack.append(start); seen[start] = true
            while let i = stack.popLast() {
                members.append(i)
                let x = i % w, y = i / w
                for (dx, dy) in [(-1, 0), (1, 0), (0, -1), (0, 1)] {
                    let nx = x + dx, ny = y + dy
                    guard nx >= 0, ny >= 0, nx < w, ny < h else { hit = true; continue }
                    let j = ny * w + nx
                    if m[j] { if !seen[j] { seen[j] = true; stack.append(j) } } else if touches(j) { hit = true }
                }
            }
            if hit { for i in members { out[i] = true } }
        }
        return out
    }

    static func dilate(_ m: [Bool], w: Int, h: Int, radius: Int) -> [Bool] {
        var cur = m
        for _ in 0..<radius {
            var next = cur
            for y in 0..<h {
                for x in 0..<w where !cur[y * w + x] {
                    if (x > 0 && cur[y * w + x - 1]) || (x < w - 1 && cur[y * w + x + 1]) || (y > 0 && cur[(y - 1) * w + x]) || (y < h - 1 && cur[(y + 1) * w + x]) {
                        next[y * w + x] = true
                    }
                }
            }
            cur = next
        }
        return cur
    }

    /// Box majority filter: a pixel is set when more than half of its (2r+1) square is set.
    static func majority(_ m: [Bool], w: Int, h: Int, radius: Int) -> [Bool] {
        var integral = [Int32](repeating: 0, count: (w + 1) * (h + 1))
        for y in 0..<h {
            var row: Int32 = 0
            for x in 0..<w {
                row += m[y * w + x] ? 1 : 0
                integral[(y + 1) * (w + 1) + x + 1] = integral[y * (w + 1) + x + 1] + row
            }
        }
        var out = m
        for y in 0..<h {
            for x in 0..<w {
                let x0 = max(0, x - radius), x1 = min(w, x + radius + 1), y0 = max(0, y - radius), y1 = min(h, y + radius + 1)
                let sum = integral[y1 * (w + 1) + x1] - integral[y0 * (w + 1) + x1] - integral[y1 * (w + 1) + x0] + integral[y0 * (w + 1) + x0]
                out[y * w + x] = sum * 2 > Int32((x1 - x0) * (y1 - y0))
            }
        }
        return out
    }
}
