import SwiftUI

// The box, drawn. Top-down, light from the upper left, the way a flat-lay photo of the box would be lit.
// Everything is sized in millimetres through BoxGeometry, so a 34 mm watch is drawn smaller than a 49 mm one.
//
// BoxPainter is the one place the drawing numbers live. The app draws it in layers so watches can move
// (BoxStage: the base, one small canvas per watch, then the marks and the glass); a shared picture draws
// all of it in one canvas (BoxSceneView), in the same order, so the two look the same.

enum BoxFinish: String, CaseIterable, Sendable {
    case black   // matte black wood, black leather lining and pillows
    case brown   // walnut grain, brown leather lining, dark brown pillows

    /// The finish a box names; an unknown value is drawn as black.
    init(name: String) {
        self = BoxFinish(rawValue: BoxModel.resolvedFinish(name)) ?? .black
    }

    var label: String { self == .black ? "Black" : "Brown" }
}

struct BoxPalette {
    var frameLight: Color
    var frameDark: Color
    var wood: Bool
    var lining: Color
    var dividerTop: Color
    var dividerEdge: Color
    var cushionEdge: Color
    var cushionMid: Color
    var cushionSheen: Color
    var cushionShadow: Double
    var contactShadow: Double
    var wallShadow: Double
    var strapFalloff: Double
    var trial: Color
    var brassLight = WatchTheme.Box.brassLight
    var brassDark = WatchTheme.Box.brassDark

    static func of(_ finish: BoxFinish) -> BoxPalette {
        let tokens = finish == .black ? WatchTheme.Box.black : WatchTheme.Box.brown
        return BoxPalette(
            frameLight: tokens.frameLight, frameDark: tokens.frameDark, wood: finish == .brown,
            lining: tokens.lining, dividerTop: tokens.dividerTop, dividerEdge: tokens.dividerEdge,
            cushionEdge: tokens.cushionEdge, cushionMid: tokens.cushionMid, cushionSheen: tokens.cushionSheen,
            cushionShadow: tokens.cushionShadow, contactShadow: tokens.contactShadow, wallShadow: tokens.wallShadow,
            strapFalloff: tokens.strapFalloff, trial: WatchTheme.Box.trial
        )
    }
}

/// What sits in one compartment.
struct BoxSlotContent {
    var cutout: CGImage?
    var caseRadiusPx: CGFloat = 1          // case radius inside `cutout`
    var diameter: CGFloat = BoxGeometry.defaultDiameter   // millimetres, from the watch
    var strap: (r: Double, g: Double, b: Double) = (0.13, 0.13, 0.14)
    var strapAbove = 0.0                   // 0...1, how much real strap the cutout has on each side
    var strapBelow = 0.0
    var dial = Color(hex: 0x1C1C1E)        // used when there is no cutout at all
    var isTrial = false
    /// A rendered picture of this watch on its pillow (58 x 87 mm, dial upright). Replaces the drawn pillow and the cutout.
    var tile: CGImage?
    // Editor adjustments (boxCutout): millimetres, factor, degrees.
    var nudge = CGSize.zero
    var zoom: CGFloat = 1
    var turn: Double = 0

    /// What a compartment shows for a watch (brief 5.3 step 5): its own tile when the picture rule picked it and the
    /// image is loaded; otherwise the cutout (or the token while there is none), drawn on the finish's empty tile or
    /// on the drawn pillow, whichever the painter has.
    static func make(
        picture: BoxSlotPicture,
        tileImage: CGImage?,
        cutout: CutoutResult?,
        diameter: Double?,
        dialName: String?,
        isTrial: Bool = false
    ) -> BoxSlotContent {
        var content = BoxSlotContent()
        content.diameter = CGFloat(diameter.flatMap { $0 > 0 ? $0 : nil } ?? Double(BoxGeometry.defaultDiameter))
        content.dial = BoxPainter.tokenDial(dialName)
        content.isTrial = isTrial
        if case .tile = picture, let tileImage {
            content.tile = tileImage
        }
        if let cutout {
            content.cutout = cutout.image
            content.caseRadiusPx = cutout.caseRadius
            content.strap = (cutout.strap[0], cutout.strap[1], cutout.strap[2])
            content.strapAbove = cutout.strapAbove
            content.strapBelow = cutout.strapBelow
        }
        return content
    }
}

/// The whole box in one canvas: the shared picture and the editor's preview.
struct BoxSceneView: View {
    var geometry: BoxGeometry
    var finish: BoxFinish
    var lidClosed: Bool
    var slots: [Int: BoxSlotContent]
    var trialTag = "TRYING"
    var emptyTile: CGImage? = nil
    /// Dark pages: a hairline round the box so the black one does not melt into the page.
    var outlined = false

    var body: some View {
        let mm = geometry.canvas
        Canvas(opaque: false, rendersAsynchronously: false) { context, size in
            BoxPainter(geometry: geometry, palette: .of(finish), lidClosed: lidClosed,
                       slots: slots, trialTag: trialTag, k: size.width / mm.width, emptyTile: emptyTile).draw(&context, size: size)
        }
        .aspectRatio(mm.width / mm.height, contentMode: .fit)
        .overlay {
            if outlined {
                GeometryReader { proxy in
                    let k = proxy.size.width / mm.width
                    let outer = CGRect(origin: .zero, size: geometry.outer)
                    RoundedRectangle(cornerRadius: BoxGeometry.frameCorner * k, style: .continuous)
                        .stroke(WatchTheme.separator, lineWidth: WatchTheme.hairline)
                        .frame(width: outer.width * k, height: outer.height * k)
                        .offset(x: outer.minX * k, y: outer.minY * k)
                }
            }
        }
        .modifier(BoxSceneShadow())
        .accessibilityHidden(true)
    }
}

/// The two shadows the whole scene casts on the page (brief 5.3 step 10). Flattened first: the box on screen is a
/// stack of layers (base, one canvas per watch, marks, glass, guides), and unflattened each layer would cast its own
/// shadow across the compartments.
struct BoxSceneShadow: ViewModifier {
    func body(content: Content) -> some View {
        content
            .compositingGroup()
            .shadow(color: .black.opacity(0.30), radius: 16, x: 6, y: 14)
            .shadow(color: .black.opacity(0.18), radius: 3, x: 1, y: 2)
    }
}

struct BoxPainter {
    var geometry: BoxGeometry
    var palette: BoxPalette
    var lidClosed: Bool
    var slots: [Int: BoxSlotContent]
    var trialTag: String
    var k: CGFloat   // points per millimetre
    var emptyTile: CGImage? = nil

    /// Millimetres a tile covers. The compartment is the middle 50 of its 58.
    static let tileField = CGSize(width: 58, height: 87)

    /// Box space (millimetres) to drawing space (points).
    func R(_ rect: CGRect) -> CGRect {
        CGRect(x: rect.minX * k, y: rect.minY * k, width: rect.width * k, height: rect.height * k)
    }

    /// A compartment in drawing space (points).
    func slotRect(_ index: Int) -> CGRect { R(geometry.slot(index)) }

    /// The pillow in a compartment, in drawing space (points).
    func cushionRect(_ index: Int) -> CGRect {
        let slotBox = geometry.slot(index)
        return R(CGRect(x: slotBox.midX - BoxGeometry.cushion.width / 2, y: slotBox.midY - BoxGeometry.cushion.height / 2,
                        width: BoxGeometry.cushion.width, height: BoxGeometry.cushion.height))
    }

    /// The box itself, without the drawer plate in front of it.
    var outerRect: CGRect { R(CGRect(origin: .zero, size: geometry.outer)) }

    // MARK: Whole scene

    /// Everything in one canvas, in the layers' order: base, contents, marks, glass.
    func draw(_ ctx: inout GraphicsContext, size: CGSize) {
        drawBase(&ctx)
        for index in slots.keys.sorted() {
            if let content = slots[index] { drawContents(&ctx, slot: index, content: content) }
        }
        drawMarks(&ctx)
        if lidClosed { glass(&ctx) }
        _ = size
    }

    // MARK: Layers

    /// Drawer plate, frame, chamfer, lining, every compartment's bed (pillow or empty tile) with the shadows its
    /// walls throw, the dividers and the front wall. Under every watch.
    func drawBase(_ ctx: inout GraphicsContext) {
        let bounds = outerRect   // the box; the canvas also holds the drawer pull
        let outer = Path(roundedRect: bounds, cornerRadius: BoxGeometry.frameCorner * k, style: .continuous)
        let cavity = R(geometry.cavity)
        handle(&ctx)

        // Frame.
        ctx.drawLayer { f in
            f.clip(to: outer)
            f.fill(Path(bounds), with: .linearGradient(Gradient(colors: [palette.frameLight, palette.frameDark]),
                                                        startPoint: bounds.origin, endPoint: CGPoint(x: bounds.maxX, y: bounds.maxY)))
            if palette.wood { woodGrain(&f, in: bounds) }
            f.blendMode = .softLight
            f.opacity = palette.wood ? 0.22 : 0.3
            f.fill(Path(bounds), with: .tiledImage(Image(decorative: BoxGrain.tile, scale: 3)))
            f.blendMode = .normal
            f.opacity = 1
            // Satin sheen across the rim.
            f.fill(Path(bounds), with: .linearGradient(
                Gradient(stops: [.init(color: .white.opacity(0.10), location: 0), .init(color: .clear, location: 0.3),
                                 .init(color: .clear, location: 0.75), .init(color: .black.opacity(0.22), location: 1)]),
                startPoint: bounds.origin, endPoint: CGPoint(x: bounds.maxX, y: bounds.maxY)))
        }
        // Outer bevel: a lit top-left edge, a dark bottom-right edge.
        ctx.stroke(Path(roundedRect: bounds.insetBy(dx: 0.6, dy: 0.6), cornerRadius: BoxGeometry.frameCorner * k, style: .continuous),
                   with: .linearGradient(Gradient(stops: [.init(color: .white.opacity(0.32), location: 0), .init(color: .white.opacity(0.04), location: 0.45),
                                                          .init(color: .black.opacity(0.45), location: 1)]),
                                         startPoint: bounds.origin, endPoint: CGPoint(x: bounds.maxX, y: bounds.maxY)), lineWidth: 1.2)

        // Inner chamfer of the frame: the far sides face the light.
        let c = BoxGeometry.chamfer * k
        let lip = cavity.insetBy(dx: -c, dy: -c)
        func quad(_ a: CGPoint, _ b: CGPoint, _ d: CGPoint, _ e: CGPoint) -> Path { Path { p in p.move(to: a); p.addLine(to: b); p.addLine(to: d); p.addLine(to: e); p.closeSubpath() } }
        ctx.fill(quad(lip.origin, CGPoint(x: lip.maxX, y: lip.minY), CGPoint(x: cavity.maxX, y: cavity.minY), cavity.origin), with: .color(.black.opacity(0.62)))
        ctx.fill(quad(lip.origin, cavity.origin, CGPoint(x: cavity.minX, y: cavity.maxY), CGPoint(x: lip.minX, y: lip.maxY)), with: .color(.black.opacity(0.48)))
        ctx.fill(quad(CGPoint(x: lip.minX, y: lip.maxY), CGPoint(x: cavity.minX, y: cavity.maxY), CGPoint(x: cavity.maxX, y: cavity.maxY), CGPoint(x: lip.maxX, y: lip.maxY)),
                 with: .color(.white.opacity(palette.wood ? 0.20 : 0.13)))
        ctx.fill(quad(CGPoint(x: lip.maxX, y: lip.minY), CGPoint(x: lip.maxX, y: lip.maxY), CGPoint(x: cavity.maxX, y: cavity.maxY), CGPoint(x: cavity.maxX, y: cavity.minY)),
                 with: .color(.white.opacity(palette.wood ? 0.13 : 0.08)))

        // Lining.
        ctx.fill(Path(cavity), with: .color(palette.lining))
        ctx.drawLayer { l in
            l.clip(to: Path(cavity)); l.blendMode = .softLight; l.opacity = 0.35
            l.fill(Path(cavity), with: .tiledImage(Image(decorative: BoxGrain.tile, scale: 3)))
        }

        // Every compartment's bed: the watches go on top, in their own layer.
        for index in 0..<geometry.slotCount {
            let rect = slotRect(index)
            ctx.drawLayer { layer in
                layer.clip(to: Path(rect))
                bed(&layer, rect: rect, cushion: cushionRect(index), tile: emptyTile)
                wallShadows(&layer, rect: rect)
            }
        }

        // Dividers on top of the compartment shadows.
        dividers(&ctx)

        // Hardware.
        hardware(&ctx)
    }

    /// One compartment's watch: its tile with the wall shadows laid over it again (they seat it in the box), or the
    /// watch on the bed the base already drew. Clipped to the compartment. `lifted` draws a tile picked up out of the
    /// box (no walls round it); `lift` 0...1 loosens the watch's contact shadow as it rises.
    func drawContents(_ ctx: inout GraphicsContext, slot index: Int, content: BoxSlotContent, lift: CGFloat = 0, lifted: Bool = false) {
        let rect = slotRect(index), cushion = cushionRect(index)
        ctx.drawLayer { layer in
            layer.clip(to: Path(rect))
            if let tile = content.tile {
                drawTile(&layer, tile, rect: rect)
                if !lifted { wallShadows(&layer, rect: rect) }
            } else {
                watch(&layer, content, cushion: cushion, slot: rect, lift: lift)
            }
        }
    }

    /// Trial marks sit under the glass, like a tag laid in the compartment. Over the watches, so a tile cannot hide one.
    /// `ringWidth` is 2.5 with Increase Contrast.
    func drawMarks(_ ctx: inout GraphicsContext, ringWidth: CGFloat = Self.trialRingWidth) {
        for index in slots.keys.sorted() where slots[index]?.isTrial == true {
            trialMark(&ctx, rect: slotRect(index), lineWidth: ringWidth)
        }
    }

    // MARK: Compartment

    /// One compartment: pillow, the shadows the walls throw on it, and its watch. Used by the product view, which
    /// draws each compartment as an upright card.
    func cell(_ ctx: inout GraphicsContext, rect: CGRect, cushion: CGRect, content: BoxSlotContent?) {
        ctx.drawLayer { layer in
            layer.clip(to: Path(rect))
            bed(&layer, rect: rect, cushion: cushion, tile: content?.tile ?? emptyTile)
            wallShadows(&layer, rect: rect)
            if let content, content.tile == nil { watch(&layer, content, cushion: cushion, slot: rect) }
        }
    }

    /// The compartment's floor: a rendered tile (the empty pillow, or a watch's own) or the drawn pillow.
    private func bed(_ layer: inout GraphicsContext, rect: CGRect, cushion: CGRect, tile: CGImage?) {
        if let tile {
            drawTile(&layer, tile, rect: rect)
            return
        }
        // Cushion: a roll lying across the compartment, the strap goes over it.
        let path = Path(roundedRect: cushion, cornerRadius: BoxGeometry.cushionCorner * k, style: .continuous)
        layer.drawLayer { s in
            s.addFilter(.shadow(color: .black.opacity(palette.cushionShadow), radius: 2.6 * k, x: 1.2 * k, y: 1.9 * k))
            s.fill(path, with: .color(palette.cushionEdge))
        }
        // The strap runs up and down over the roll.
        let a = CGPoint(x: cushion.midX, y: cushion.minY), b = CGPoint(x: cushion.midX, y: cushion.maxY)
        layer.fill(path, with: .linearGradient(Gradient(stops: [
            .init(color: palette.cushionEdge, location: 0), .init(color: palette.cushionMid, location: 0.2),
            .init(color: palette.cushionSheen, location: 0.43), .init(color: palette.cushionMid, location: 0.62),
            .init(color: palette.cushionMid.opacity(0.92), location: 0.82), .init(color: palette.cushionEdge, location: 1)]), startPoint: a, endPoint: b))
        let a2 = CGPoint(x: cushion.minX, y: cushion.midY), b2 = CGPoint(x: cushion.maxX, y: cushion.midY)
        layer.fill(path, with: .linearGradient(Gradient(stops: [
            .init(color: .black.opacity(0.30), location: 0), .init(color: .clear, location: 0.16),
            .init(color: .clear, location: 0.84), .init(color: .black.opacity(0.34), location: 1)]), startPoint: a2, endPoint: b2))
        layer.drawLayer { g in
            g.clip(to: path); g.blendMode = .softLight; g.opacity = 0.4
            g.fill(Path(cushion), with: .tiledImage(Image(decorative: BoxGrain.tile, scale: 3)))
        }
        layer.stroke(path, with: .linearGradient(Gradient(colors: [.white.opacity(0.16), .clear, .black.opacity(0.3)]),
                                                 startPoint: cushion.origin, endPoint: CGPoint(x: cushion.maxX, y: cushion.maxY)), lineWidth: 0.8)
    }

    /// A tile covers the compartment's depth and is clipped to its width.
    private func drawTile(_ layer: inout GraphicsContext, _ tile: CGImage, rect: CGRect) {
        let h = rect.height, w = h * Self.tileField.width / Self.tileField.height
        layer.draw(Image(decorative: tile, scale: 1), in: CGRect(x: rect.midX - w / 2, y: rect.midY - h / 2, width: w, height: h))
    }

    /// Shadow the walls throw into the compartment (light from the upper left), then a thin dark line where every
    /// wall meets the floor.
    private func wallShadows(_ layer: inout GraphicsContext, rect: CGRect) {
        let top = 11 * k, left = 9 * k, thin = 3 * k
        layer.fill(Path(CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: top)),
                   with: .linearGradient(Gradient(colors: [.black.opacity(palette.wallShadow), .clear]),
                                         startPoint: rect.origin, endPoint: CGPoint(x: rect.minX, y: rect.minY + top)))
        layer.fill(Path(CGRect(x: rect.minX, y: rect.minY, width: left, height: rect.height)),
                   with: .linearGradient(Gradient(colors: [.black.opacity(palette.wallShadow * 0.8), .clear]),
                                         startPoint: rect.origin, endPoint: CGPoint(x: rect.minX + left, y: rect.minY)))
        layer.fill(Path(CGRect(x: rect.minX, y: rect.maxY - thin, width: rect.width, height: thin)),
                   with: .linearGradient(Gradient(colors: [.clear, .black.opacity(palette.wallShadow * 0.5)]),
                                         startPoint: CGPoint(x: rect.minX, y: rect.maxY - thin), endPoint: CGPoint(x: rect.minX, y: rect.maxY)))
        layer.fill(Path(CGRect(x: rect.maxX - thin, y: rect.minY, width: thin, height: rect.height)),
                   with: .linearGradient(Gradient(colors: [.clear, .black.opacity(palette.wallShadow * 0.5)]),
                                         startPoint: CGPoint(x: rect.maxX - thin, y: rect.minY), endPoint: CGPoint(x: rect.maxX, y: rect.minY)))
    }

    // MARK: Watch

    private func watch(_ ctx: inout GraphicsContext, _ content: BoxSlotContent, cushion: CGRect, slot: CGRect, lift: CGFloat = 0) {
        // The nudge is in the watch's own space: x across, y along the strap.
        let center = CGPoint(x: cushion.midX + content.nudge.width * k, y: cushion.midY + content.nudge.height * k)
        let caseR = content.diameter / 2 * k * content.zoom
        let half = (BoxGeometry.cushion.height / 2 + 1.5) * k          // strap visible to the cushion's end
        let across = (BoxGeometry.compartment.width / 2 - 0.4) * k     // the case may overhang the cushion, not the walls

        // Contact shadow under the case; it spreads and pales as the watch is lifted.
        let rise = max(0, min(1, lift))
        ctx.drawLayer { s in
            s.addFilter(.blur(radius: 2.4 * k * (1 + 1.5 * rise)))
            s.fill(Path(ellipseIn: CGRect(x: center.x - caseR * 1.02 + 1.3 * k * (1 + 2 * rise), y: center.y - caseR * 1.02 + 2.2 * k * (1 + 2 * rise),
                                          width: caseR * 2.04, height: caseR * 2.04)),
                   with: .color(.black.opacity(palette.contactShadow * (1 - 0.35 * rise))))
        }

        ctx.drawLayer { w in
            w.translateBy(x: cushion.midX, y: cushion.midY)
            // Local space from here: strap runs up and down, 12 o'clock is up.
            w.clip(to: Path(roundedRect: CGRect(x: -across, y: -half, width: across * 2, height: half * 2), cornerRadius: 3 * k))
            w.translateBy(x: (content.nudge.width) * k, y: (content.nudge.height) * k)
            w.rotate(by: .degrees(content.turn))
            let strapWidth = min(24, max(16, content.diameter * 0.5)) * k * content.zoom
            if content.strapAbove < 0.3 { strap(&w, content, CGRect(x: -strapWidth / 2, y: -half * 1.2, width: strapWidth, height: half * 1.2)) }
            if content.strapBelow < 0.3 { strap(&w, content, CGRect(x: -strapWidth / 2, y: 0, width: strapWidth, height: half * 1.2)) }
            if let cutout = content.cutout {
                let side = CGFloat(cutout.width) * caseR / content.caseRadiusPx
                w.draw(Image(decorative: cutout, scale: 1), in: CGRect(x: -side / 2, y: -side / 2, width: side, height: side))
            } else {
                token(&w, dial: content.dial, radius: caseR)
            }
            // The strap darkens as it curves away over the roll; the case stays as shot.
            let clear = min(0.82, max(0.5, caseR * 1.06 / half))
            w.blendMode = .sourceAtop
            let f = palette.strapFalloff
            w.fill(Path(CGRect(x: -across * 2, y: -half * 1.3, width: across * 4, height: half * 2.6)), with: .linearGradient(Gradient(stops: [
                .init(color: .black.opacity(f), location: 0), .init(color: .black.opacity(f * 0.42), location: 0.5 - (clear + 1) / 4),
                .init(color: .clear, location: 0.5 - clear / 2), .init(color: .clear, location: 0.5 + clear / 2),
                .init(color: .black.opacity(f * 0.42), location: 0.5 + (clear + 1) / 4), .init(color: .black.opacity(f), location: 1)]),
                startPoint: CGPoint(x: 0, y: -half), endPoint: CGPoint(x: 0, y: half)))
        }
        _ = slot
    }

    /// A drawn strap for the side the photo did not show: links for steel, a plain band otherwise.
    /// Rounded across like a real strap, a touch narrower toward the end.
    private func strap(_ ctx: inout GraphicsContext, _ content: BoxSlotContent, _ rect: CGRect) {
        let (r, g, b) = content.strap
        let base = Color(red: r, green: g, blue: b)
        let hi = max(r, g, b), lo = min(r, g, b)
        let metal = hi > 0.34 && (hi - lo) < 0.16
        let outward = rect.minY < -1            // this piece runs up from the case
        let taper = rect.width * 0.06
        let path = Path { p in
            let nearY = outward ? rect.maxY : rect.minY, farY = outward ? rect.minY : rect.maxY
            p.move(to: CGPoint(x: rect.minX, y: nearY)); p.addLine(to: CGPoint(x: rect.maxX, y: nearY))
            p.addLine(to: CGPoint(x: rect.maxX - taper, y: farY)); p.addLine(to: CGPoint(x: rect.minX + taper, y: farY)); p.closeSubpath()
        }
        ctx.drawLayer { s in
            s.clip(to: path)
            s.fill(Path(rect), with: .color(base))
            s.fill(Path(rect), with: .linearGradient(Gradient(stops: [
                .init(color: .black.opacity(0.5), location: 0), .init(color: .white.opacity(metal ? 0.22 : 0.10), location: 0.28),
                .init(color: .clear, location: 0.55), .init(color: .black.opacity(0.5), location: 1)]),
                startPoint: CGPoint(x: rect.minX, y: 0), endPoint: CGPoint(x: rect.maxX, y: 0)))
            if metal {
                var y = rect.minY
                while y < rect.maxY {
                    s.fill(Path(CGRect(x: rect.minX, y: y, width: rect.width, height: 0.5 * k)), with: .color(.black.opacity(0.42)))
                    s.fill(Path(CGRect(x: rect.minX + rect.width * 0.3, y: y + 0.5 * k, width: rect.width * 0.4, height: 0.4 * k)), with: .color(.white.opacity(0.22)))
                    y += 4.2 * k
                }
                s.fill(Path(CGRect(x: rect.minX + rect.width * 0.28, y: rect.minY, width: 0.35 * k, height: rect.height)), with: .color(.black.opacity(0.3)))
                s.fill(Path(CGRect(x: rect.maxX - rect.width * 0.28, y: rect.minY, width: 0.35 * k, height: rect.height)), with: .color(.black.opacity(0.3)))
            }
        }
    }

    /// Stand-in when a watch has no usable photo, and while its cutout is being made: a plain dial in its dial colour.
    static func token(_ ctx: inout GraphicsContext, dial: Color, radius: CGFloat) {
        let rim = CGRect(x: -radius, y: -radius, width: radius * 2, height: radius * 2)
        ctx.fill(Path(ellipseIn: rim), with: .linearGradient(Gradient(colors: [Color(hex: 0xE9E9EA), Color(hex: 0x7E7E82)]),
                                                              startPoint: rim.origin, endPoint: CGPoint(x: rim.maxX, y: rim.maxY)))
        let face = rim.insetBy(dx: radius * 0.12, dy: radius * 0.12)
        ctx.fill(Path(ellipseIn: face), with: .color(dial))
        ctx.fill(Path(ellipseIn: face), with: .linearGradient(Gradient(colors: [.white.opacity(0.18), .clear, .black.opacity(0.2)]),
                                                               startPoint: face.origin, endPoint: CGPoint(x: face.maxX, y: face.maxY)))
        let hand = Color.white.opacity(0.85)
        ctx.stroke(Path { p in p.move(to: .zero); p.addLine(to: CGPoint(x: radius * 0.34, y: -radius * 0.3)) }, with: .color(hand), style: StrokeStyle(lineWidth: max(1, radius * 0.07), lineCap: .round))
        ctx.stroke(Path { p in p.move(to: .zero); p.addLine(to: CGPoint(x: -radius * 0.2, y: -radius * 0.62)) }, with: .color(hand), style: StrokeStyle(lineWidth: max(0.8, radius * 0.05), lineCap: .round))
    }

    private func token(_ ctx: inout GraphicsContext, dial: Color, radius: CGFloat) {
        Self.token(&ctx, dial: dial, radius: radius)
    }

    /// The token's dial colour for a dial name, matched to the photos rather than to the app's chart colours.
    static func tokenDial(_ name: String?) -> Color {
        let colors: [String: UInt32] = [
            "Black": 0x161618, "Blue": 0x1F3F8A, "White": 0xF2F1EC, "Silver": 0xC9CACC, "Grey": 0x6E7074, "Cream": 0xE9DFC8,
            "Green": 0x1F5A3A, "Gold/Champagne": 0xC9A865, "Salmon": 0xE2A68E, "Brown": 0x5A3B22, "Screen": 0x0A0A0C,
        ]
        return Color(hex: colors[name ?? ""] ?? 0x1C1C1E)
    }

    // MARK: Dividers, hardware, glass, marks

    private func dividers(_ ctx: inout GraphicsContext) {
        let d = BoxGeometry.divider, cav = geometry.cavity
        var bars: [CGRect] = []
        for column in 1..<max(1, geometry.columns) {
            bars.append(CGRect(x: cav.minX + CGFloat(column) * (BoxGeometry.compartment.width + d) - d, y: cav.minY, width: d, height: cav.height))
        }
        for row in 1..<max(1, geometry.rows) {
            bars.append(CGRect(x: cav.minX, y: cav.minY + CGFloat(row) * (BoxGeometry.compartment.height + d) - d, width: cav.width, height: d))
        }
        for bar in bars {
            let r = R(bar)
            ctx.fill(Path(r), with: .color(palette.dividerTop))
            let vertical = r.height > r.width
            // Lit edge toward the light.
            ctx.fill(Path(vertical ? CGRect(x: r.minX, y: r.minY, width: 0.7, height: r.height) : CGRect(x: r.minX, y: r.minY, width: r.width, height: 0.7)),
                     with: .color(palette.dividerEdge.opacity(0.75)))
            ctx.fill(Path(vertical ? CGRect(x: r.maxX - 0.7, y: r.minY, width: 0.7, height: r.height) : CGRect(x: r.minX, y: r.maxY - 0.7, width: r.width, height: 0.7)),
                     with: .color(.black.opacity(0.45)))
        }
    }

    /// The low front wall of the tray. With the lid down it is seen through the pane.
    private func hardware(_ ctx: inout GraphicsContext) {
        let o = geometry.outer
        let wall = R(CGRect(x: BoxGeometry.sideRail, y: o.height - BoxGeometry.frontRail, width: geometry.inner.width, height: BoxGeometry.frontRail))
        ctx.fill(Path(wall), with: .color(palette.dividerTop))
        ctx.fill(Path(wall), with: .linearGradient(Gradient(colors: [.white.opacity(0.10), .clear, .black.opacity(0.35)]),
                                                    startPoint: wall.origin, endPoint: CGPoint(x: wall.minX, y: wall.maxY)))
    }

    /// Brass drawer pull, blank plate, sticking out under the front edge.
    private func handle(_ ctx: inout GraphicsContext) {
        let o = geometry.outer, h = BoxGeometry.handle
        let bar = R(CGRect(x: o.width / 2 - h.width / 2, y: o.height + h.height - 3.2, width: h.width, height: 3.2))
        for dx in [-h.width / 2 + 9, h.width / 2 - 12] {
            let post = R(CGRect(x: o.width / 2 + dx, y: o.height - 1, width: 3, height: h.height - 2))
            ctx.fill(Path(post), with: .color(palette.brassDark))
        }
        brass(&ctx, Path(roundedRect: bar, cornerRadius: 0.6 * k), in: bar)
    }

    func brass(_ ctx: inout GraphicsContext, _ path: Path, in rect: CGRect) {
        ctx.drawLayer { b in
            b.addFilter(.shadow(color: .black.opacity(0.5), radius: 0.8 * k, x: 0.4 * k, y: 0.6 * k))
            b.fill(path, with: .linearGradient(Gradient(colors: [palette.brassLight, palette.brassDark]), startPoint: rect.origin, endPoint: CGPoint(x: rect.maxX, y: rect.maxY)))
        }
        ctx.stroke(path, with: .color(.white.opacity(0.25)), lineWidth: 0.5)
    }

    /// The clear lid: a flat pane between the rails that folds down over the front. `lampShift` slides the ceiling
    /// light's reflection (points), for the lid's own motion.
    func glass(_ ctx: inout GraphicsContext, lampShift: CGFloat = 0) {
        let o = geometry.outer
        let pane = R(CGRect(x: BoxGeometry.sideRail, y: BoxGeometry.backRail, width: geometry.inner.width, height: o.height - BoxGeometry.backRail))
        let slope = R(CGRect(x: BoxGeometry.sideRail, y: o.height - BoxGeometry.lidFold, width: geometry.inner.width, height: BoxGeometry.lidFold))
        let fold = R(CGRect(x: BoxGeometry.sideRail, y: o.height - BoxGeometry.lidFold - 0.25, width: geometry.inner.width, height: 0.5))
        ctx.drawLayer { g in
            g.clip(to: Path(pane))
            g.fill(Path(pane), with: .color(.black.opacity(0.10)))
            // A ceiling light, soft, upper left: the one thing every photo of a clear lid has.
            let side = min(pane.width, pane.height)
            let lamp = CGPoint(x: pane.minX + pane.width * 0.26 + lampShift, y: pane.minY + pane.height * 0.2 + lampShift * 0.5)
            g.fill(Path(pane), with: .radialGradient(Gradient(stops: [.init(color: .white.opacity(0.30), location: 0), .init(color: .white.opacity(0.11), location: 0.45), .init(color: .clear, location: 1)]),
                                                      center: lamp, startRadius: 0, endRadius: side * 0.55))
            // Two window streaks across the pane.
            g.fill(Path(pane), with: .linearGradient(Gradient(stops: [
                .init(color: .clear, location: 0.36), .init(color: .white.opacity(0.15), location: 0.44), .init(color: .white.opacity(0.05), location: 0.5), .init(color: .clear, location: 0.53),
                .init(color: .clear, location: 0.62), .init(color: .white.opacity(0.10), location: 0.66), .init(color: .clear, location: 0.71),
                .init(color: .clear, location: 0.88), .init(color: .white.opacity(0.05), location: 1)]),
                startPoint: CGPoint(x: pane.minX, y: pane.minY), endPoint: CGPoint(x: pane.maxX, y: pane.minY + pane.width * 0.9)))
            // The sloping front faces the room, so it carries a little more veil; the fold is a faint line.
            g.fill(Path(slope), with: .color(.white.opacity(0.05)))
            g.drawLayer { f in
                f.addFilter(.blur(radius: 0.7 * k))
                f.fill(Path(fold.insetBy(dx: 0, dy: -0.6 * k)), with: .color(.white.opacity(0.04)))
            }
            g.fill(Path(fold), with: .color(.white.opacity(0.13)))
        }
        // Pane edge: catches light on the far sides.
        ctx.stroke(Path(pane.insetBy(dx: 0.5, dy: 0.5)), with: .linearGradient(Gradient(colors: [.black.opacity(0.5), .white.opacity(0.10), .white.opacity(0.42)]),
                                                                               startPoint: pane.origin, endPoint: CGPoint(x: pane.maxX, y: pane.maxY)), lineWidth: 1)
    }

    // MARK: Trial mark

    static let trialWord = "TRYING"
    /// The tag's word where even the narrow setting of the full one does not fit.
    static let trialWordShort = "TRY"
    /// The trial ring's centre line, inside the compartment, and its width (2.5 with Increase Contrast).
    static let trialRingInset: CGFloat = 1.4
    static let trialRingWidth: CGFloat = 1.6
    /// From the compartment's walls to the tag.
    static let tagMargin: CGFloat = 5
    /// Between the selection ring and the trial ring when one compartment has both.
    static let selectionGap: CGFloat = 1

    /// One way of setting the tag.
    struct TrialTagStyle: Equatable {
        var word: String
        var expanded: Bool
        var tracking: CGFloat
        /// Across the capsule, both ends together.
        var padding: CGFloat
    }

    /// The tag's settings, widest first: the word in expanded type, then in normal width with less padding, then the
    /// short word. The first that fits between the walls is drawn.
    static func trialTagStyles(_ word: String) -> [TrialTagStyle] {
        let short = word == trialWord ? trialWordShort : String(word.prefix(3))
        return [TrialTagStyle(word: word, expanded: true, tracking: 1.1, padding: 12),
                TrialTagStyle(word: word, expanded: false, tracking: 0.6, padding: 8),
                TrialTagStyle(word: short, expanded: true, tracking: 1.1, padding: 8)]
    }

    /// The tag for a compartment `rect`, given the text's size in each style: the first style whose capsule fits
    /// between the walls with `tagMargin` to spare, else the last one. Its frame, at the compartment's upper left.
    static func trialTag(in rect: CGRect, styles: [TrialTagStyle], measure: (TrialTagStyle) -> CGSize) -> (style: TrialTagStyle, frame: CGRect) {
        let room = CGSize(width: rect.width - 2 * tagMargin, height: rect.height - 2 * tagMargin)
        var chosen: (TrialTagStyle, CGRect)?
        for style in styles {
            let text = measure(style)
            let frame = CGRect(x: rect.minX + tagMargin, y: rect.minY + tagMargin, width: text.width + style.padding, height: text.height + 5)
            chosen = (style, frame)
            if frame.width <= room.width, frame.height <= room.height { break }
        }
        return chosen ?? (TrialTagStyle(word: "", expanded: false, tracking: 0, padding: 0), .zero)
    }

    /// The selection ring's centre line, inset from a compartment's edge, for a ring `lineWidth` wide: just inside
    /// the walls; on a candidate on trial, just outside them on the dividers, with `selectionGap` to the trial ring,
    /// so neither hides the other.
    static func selectionInset(lineWidth: CGFloat, overTrial: Bool, trialWidth: CGFloat = trialRingWidth) -> CGFloat {
        guard overTrial else { return lineWidth / 2 + 0.5 }
        return trialRingInset - trialWidth / 2 - selectionGap - lineWidth / 2
    }

    /// A ring inside the compartment and a "TRYING" tag at its upper left: a trial never passes for an owned watch.
    /// The tag takes a narrower setting where the compartment is narrow, and never runs over a divider.
    func trialMark(_ ctx: inout GraphicsContext, rect: CGRect, lineWidth: CGFloat = Self.trialRingWidth) {
        let ring = Path(roundedRect: rect.insetBy(dx: Self.trialRingInset, dy: Self.trialRingInset), cornerRadius: 2)
        ctx.stroke(ring, with: .color(palette.trial), lineWidth: lineWidth)
        let size = max(7, 4.6 * k)
        func text(_ style: TrialTagStyle, _ ctx: GraphicsContext) -> GraphicsContext.ResolvedText {
            ctx.resolve(Text(style.word).font(.system(size: size, weight: .bold).width(style.expanded ? .expanded : .standard))
                .tracking(style.tracking).foregroundColor(.white))
        }
        let measuring = ctx
        let tag = Self.trialTag(in: rect, styles: Self.trialTagStyles(trialTag)) {
            text($0, measuring).measure(in: CGSize(width: 400, height: 100))
        }
        ctx.drawLayer { layer in
            layer.clip(to: Path(rect))
            layer.fill(Path(roundedRect: tag.frame, cornerRadius: tag.frame.height / 2), with: .color(palette.trial))
            layer.draw(text(tag.style, layer), at: CGPoint(x: tag.frame.midX, y: tag.frame.midY), anchor: .center)
        }
    }

    /// Long, slightly wandering grain lines along the box's long side.
    func woodGrain(_ ctx: inout GraphicsContext, in bounds: CGRect) {
        var rng = SplitMix(seed: 0x5EED_B0C5)
        let alongX = bounds.width >= bounds.height
        let span = alongX ? bounds.height : bounds.width, length = alongX ? bounds.width : bounds.height
        var offset: CGFloat = 0
        while offset < span {
            let dark = rng.unit() < 0.62
            let width = CGFloat(0.25 + rng.unit() * 1.1) * k
            let wobble = CGFloat(rng.unit() - 0.5) * 2.4 * k
            let path = Path { p in
                func point(_ t: CGFloat, _ o: CGFloat) -> CGPoint { alongX ? CGPoint(x: t, y: o) : CGPoint(x: o, y: t) }
                p.move(to: point(0, offset))
                p.addCurve(to: point(length, offset + wobble * 0.3), control1: point(length * 0.33, offset + wobble), control2: point(length * 0.66, offset - wobble))
            }
            ctx.stroke(path, with: .color((dark ? Color(hex: 0x2B170B) : Color(hex: 0xB07E52)).opacity(0.10 + rng.unit() * (dark ? 0.26 : 0.16))), lineWidth: width)
            offset += CGFloat(0.5 + rng.unit() * 1.9) * k
        }
    }
}

/// Fine leather / lacquer grain: one 128 px tile of soft noise, made once.
enum BoxGrain {
    static let tile: CGImage = {
        let side = 128
        var rng = SplitMix(seed: 0xC0FFEE)
        var px = [UInt8](repeating: 0, count: side * side * 4)
        var field = [Double](repeating: 0, count: side * side)
        for i in 0..<(side * side) { field[i] = rng.unit() }
        for y in 0..<side {
            for x in 0..<side {
                // A little blur so the grain reads as pores, not static.
                var sum = 0.0
                for (dx, dy, wgt) in [(0, 0, 4.0), (1, 0, 1.5), (-1, 0, 1.5), (0, 1, 1.5), (0, -1, 1.5)] {
                    sum += field[((y + dy + side) % side) * side + (x + dx + side) % side] * wgt
                }
                let v = UInt8(max(0, min(255, (sum / 10 - 0.5) * 0.9 * 255 + 127.5)))
                let i = (y * side + x) * 4
                px[i] = v; px[i + 1] = v; px[i + 2] = v; px[i + 3] = 255
            }
        }
        let provider = CGDataProvider(data: Data(px) as CFData)!
        return CGImage(width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: side * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)!
    }()
}

struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
}
