import SwiftUI

// The "product shot": the closed box seen from the front and above, drawer and brass plate
// included. For sharing only; arranging happens in the top-down scene.
//
// Not a 3D engine. The box's faces are quads from one small perspective projection, and each
// compartment is drawn as an upright card (pillow plus watch) at its projected place. The real
// pillows lean toward the viewer, so an upright card is closer to the truth than a dial squashed
// flat onto the tray would be.

struct BoxProductView: View {
    var geometry: BoxGeometry
    var finish: BoxFinish
    var slots: [Int: BoxSlotContent]
    var emptyTile: CGImage? = nil

    var body: some View {
        Canvas(opaque: false, rendersAsynchronously: false) { context, size in
            BoxProductPainter(geometry: geometry, palette: .of(finish), slots: slots, size: size, emptyTile: emptyTile).draw(&context)
        }
        .aspectRatio(BoxProductPainter.aspect(geometry), contentMode: .fit)
        .shadow(color: .black.opacity(0.28), radius: 18, x: 0, y: 16)
    }
}

struct BoxProductPainter {
    var geometry: BoxGeometry
    var palette: BoxPalette
    var slots: [Int: BoxSlotContent]
    var size: CGSize
    var emptyTile: CGImage? = nil

    static let pitch = 40.0 * Double.pi / 180     // camera looks down by this much
    static let distance = 1500.0                  // millimetres from the camera to the front edge
    static let bandTop: CGFloat = 100             // height of the wood below the sloping pane
    static let backTier: CGFloat = 112            // pillow centre heights: the back row sits higher
    static let frontTier: CGFloat = 88
    static let cardSquash: CGFloat = 0.9

    /// Width over height: as wide as the box, and tall enough for its back rail, which rises with every row. Two rows
    /// keep the prototype's 345 by 262 frame; one row is shorter, three and four taller.
    static func aspect(_ g: BoxGeometry) -> CGFloat { g.outer.width / height(g) }

    /// The picture's height in the units of its width (the box's millimetres): the back rail's top as the camera sees
    /// it, and the room the two-row picture leaves above that.
    static func height(_ g: BoxGeometry) -> CGFloat { rise(depth: g.outer.height) * widthUsed + headroom }

    /// How far the top of the back rail stands above the front edge's foot in the picture, in millimetres at the
    /// front's scale, for a box `depth` deep.
    static func rise(depth: CGFloat) -> CGFloat {
        let c = CGFloat(cos(pitch)), s = CGFloat(sin(pitch)), h = BoxGeometry.height
        let up = depth * s + h * c, away = depth * c - h * s
        return up * CGFloat(distance) / (CGFloat(distance) + away)
    }

    /// The share of the width the box's front takes.
    private static let widthUsed: CGFloat = 0.985
    private static let headroom = 262 - rise(depth: BoxGeometry(columns: 6, rows: 2).outer.height) * widthUsed

    private var k: CGFloat { size.width * Self.widthUsed / geometry.outer.width }

    /// The highest point drawn (the top of the back rail), in the picture's points from its top.
    var top: CGFloat { P(0, geometry.outer.height, BoxGeometry.height).y }

    /// X across from the left, Y back from the front, Z up from the table. Returns the point and
    /// the scale there.
    private func project(_ x: CGFloat, _ y: CGFloat, _ z: CGFloat) -> (CGPoint, CGFloat) {
        let c = CGFloat(cos(Self.pitch)), s = CGFloat(sin(Self.pitch))
        let depth = y * c - z * s, up = y * s + z * c
        let scale = CGFloat(Self.distance) / (CGFloat(Self.distance) + depth)
        return (CGPoint(x: size.width / 2 + (x - geometry.outer.width / 2) * scale * k, y: size.height - 6 - up * scale * k), scale)
    }
    private func P(_ x: CGFloat, _ y: CGFloat, _ z: CGFloat) -> CGPoint { project(x, y, z).0 }
    private func poly(_ points: [CGPoint]) -> Path { Path { p in p.addLines(points); p.closeSubpath() } }

    func draw(_ ctx: inout GraphicsContext) {
        let W = geometry.outer.width, D = geometry.outer.height, H = BoxGeometry.height
        let rail = BoxGeometry.sideRail, back = BoxGeometry.backRail, fold = BoxGeometry.lidFold, band = Self.bandTop
        let drawer = BoxGeometry.drawerHeight

        // Front: the drawer, the seam above it, the band of the tray.
        let front = poly([P(0, 0, 0), P(W, 0, 0), P(W, 0, band), P(0, 0, band)])
        wood(&ctx, front, light: 0.0, shade: 0.30)
        ctx.fill(poly([P(0, 0, drawer), P(W, 0, drawer), P(W, 0, drawer + 2.2), P(0, 0, drawer + 2.2)]), with: .color(.black.opacity(0.75)))
        ctx.fill(poly([P(0, 0, drawer - 1), P(W, 0, drawer - 1), P(W, 0, drawer), P(0, 0, drawer)]), with: .color(.white.opacity(0.10)))
        // Brass plate, blank.
        let plate = CGRect(origin: P(W / 2 - 31, 0, 39), size: .zero).union(CGRect(origin: P(W / 2 + 31, 0, 21), size: .zero))
        let plateShape = Path(roundedRect: plate, cornerRadius: 1.2 * k)
        ctx.drawLayer { b in
            b.addFilter(.shadow(color: .black.opacity(0.55), radius: 1.5 * k, x: 0, y: 1.6 * k))
            b.fill(plateShape, with: .linearGradient(Gradient(colors: [palette.brassLight, palette.brassDark]), startPoint: plate.origin, endPoint: CGPoint(x: plate.maxX, y: plate.maxY)))
        }
        ctx.stroke(Path(roundedRect: plate.insetBy(dx: 2.2 * k, dy: 2.2 * k), cornerRadius: 0.6 * k), with: .color(.black.opacity(0.35)), lineWidth: 0.8)
        ctx.stroke(plateShape, with: .color(.white.opacity(0.3)), lineWidth: 0.6)

        // The tray seen through the pane.
        let tray = poly([P(rail, 0, band), P(W - rail, 0, band), P(W - rail, fold, H), P(W - rail, D - back, H), P(rail, D - back, H), P(rail, fold, H)])
        ctx.fill(tray, with: .color(palette.lining))
        ctx.drawLayer { t in
            t.clip(to: tray)
            // Back row first, then the front row over its feet.
            for row in 0..<geometry.rows {
                let tier = row == 0 ? Self.backTier : Self.frontTier
                for column in 0..<geometry.columns {
                    let index = row * geometry.columns + column
                    let box = geometry.slot(index)
                    let (centre, scale) = project(box.midX, D - box.midY, tier)
                    let unit = k * scale
                    let rect = CGRect(x: -box.width / 2 * unit, y: -box.height / 2 * unit, width: box.width * unit, height: box.height * unit)
                    let painter = BoxPainter(geometry: geometry, palette: palette, orientation: .front, lidClosed: true, slots: [:],
                                             trialTag: BoxPainter.trialWord, k: unit, emptyTile: emptyTile)
                    t.drawLayer { card in
                        card.translateBy(x: centre.x, y: centre.y)
                        card.scaleBy(x: 1, y: Self.cardSquash)
                        let cushion = CGRect(x: -BoxGeometry.cushion.width / 2 * unit, y: -BoxGeometry.cushion.height / 2 * unit,
                                             width: BoxGeometry.cushion.width * unit, height: BoxGeometry.cushion.height * unit)
                        painter.cell(&card, rect: rect, cushion: cushion, content: slots[index])
                    }
                    if slots[index]?.isTrial == true {
                        // The box's own mark (ring and TRYING tag) over the card, the type not squashed with it.
                        t.drawLayer { mark in
                            mark.translateBy(x: centre.x, y: centre.y)
                            let card = CGRect(x: rect.minX, y: rect.minY * Self.cardSquash, width: rect.width, height: rect.height * Self.cardSquash)
                            painter.trialMark(&mark, rect: card)
                        }
                    }
                }
            }
            // Depth: the far end of the tray is in the lid's shade.
            let (farPoint, _) = project(W / 2, D - back, H)
            let (nearPoint, _) = project(W / 2, fold, H)
            t.fill(tray, with: .linearGradient(Gradient(colors: [.black.opacity(0.45), .clear]), startPoint: farPoint, endPoint: CGPoint(x: farPoint.x, y: farPoint.y + (nearPoint.y - farPoint.y) * 0.45)))
        }

        // The pane: flat top, then the fold, then the slope down to the band.
        let top = poly([P(rail, fold, H), P(W - rail, fold, H), P(W - rail, D - back, H), P(rail, D - back, H)])
        let slope = poly([P(rail, 0, band), P(W - rail, 0, band), P(W - rail, fold, H), P(rail, fold, H)])
        let a = P(rail, D - back, H), b = P(W - rail, fold, H)
        ctx.fill(top, with: .color(.black.opacity(0.08)))
        ctx.fill(top, with: .linearGradient(Gradient(stops: [
            .init(color: .white.opacity(0.16), location: 0), .init(color: .white.opacity(0.03), location: 0.22), .init(color: .clear, location: 0.36),
            .init(color: .white.opacity(0.13), location: 0.47), .init(color: .clear, location: 0.56),
            .init(color: .clear, location: 0.7), .init(color: .white.opacity(0.07), location: 0.76), .init(color: .clear, location: 0.82)]),
            startPoint: a, endPoint: CGPoint(x: b.x, y: b.y + (b.x - a.x) * 0.25)))
        ctx.fill(slope, with: .linearGradient(Gradient(colors: [.white.opacity(0.10), .white.opacity(0.02)]), startPoint: P(W / 2, fold, H), endPoint: P(W / 2, 0, band)))
        ctx.stroke(Path { p in p.move(to: P(rail, fold, H)); p.addLine(to: P(W - rail, fold, H)) }, with: .color(.white.opacity(0.20)), lineWidth: 0.8)
        ctx.stroke(Path { p in p.move(to: P(rail, 0, band)); p.addLine(to: P(W - rail, 0, band)) }, with: .color(.white.opacity(0.28)), lineWidth: 0.8)

        // The lid's wooden U: two side rails that follow the slope, and the back rail.
        for x in [CGFloat(0), W - rail] {
            wood(&ctx, poly([P(x, 0, band), P(x + rail, 0, band), P(x + rail, fold, H), P(x, fold, H)]), light: 0.10, shade: 0.05)
            wood(&ctx, poly([P(x, fold, H), P(x + rail, fold, H), P(x + rail, D, H), P(x, D, H)]), light: 0.16, shade: 0.0)
        }
        wood(&ctx, poly([P(rail, D - back, H), P(W - rail, D - back, H), P(W - rail, D, H), P(rail, D, H)]), light: 0.16, shade: 0.0)
        // Inner edges of the rails, in shade.
        ctx.stroke(Path { p in
            p.move(to: P(rail, 0, band)); p.addLine(to: P(rail, fold, H)); p.addLine(to: P(rail, D - back, H))
            p.addLine(to: P(W - rail, D - back, H)); p.addLine(to: P(W - rail, fold, H)); p.addLine(to: P(W - rail, 0, band))
        }, with: .color(.black.opacity(0.55)), lineWidth: 1.2)
        // Lit top edge of the front.
        ctx.stroke(Path { p in p.move(to: P(0, 0, band)); p.addLine(to: P(W, 0, band)) }, with: .color(.white.opacity(0.16)), lineWidth: 0.8)
    }

    private func wood(_ ctx: inout GraphicsContext, _ shape: Path, light: Double, shade: Double) {
        let box = shape.boundingRect
        ctx.drawLayer { f in
            f.clip(to: shape)
            f.fill(Path(box), with: .linearGradient(Gradient(colors: [palette.frameLight, palette.frameDark]), startPoint: box.origin, endPoint: CGPoint(x: box.maxX, y: box.maxY)))
            if palette.wood {
                BoxPainter(geometry: geometry, palette: palette, orientation: .front, lidClosed: true, slots: [:], trialTag: "", k: k).woodGrain(&f, in: box)
            }
            f.blendMode = .softLight; f.opacity = 0.3
            f.fill(Path(box), with: .tiledImage(Image(decorative: BoxGrain.tile, scale: 3)))
            f.blendMode = .normal; f.opacity = 1
            if light > 0 { f.fill(Path(box), with: .color(.white.opacity(light))) }
            if shade > 0 { f.fill(Path(box), with: .linearGradient(Gradient(colors: [.clear, .black.opacity(shade)]), startPoint: box.origin, endPoint: CGPoint(x: box.minX, y: box.maxY))) }
        }
    }
}
