import CoreGraphics
import Foundation

// The box in millimetres. Pure maths, no drawing: the render, the drop targets and the tests
// all read the same numbers.
//
// Box space is the box seen from the front, lid hinge at the top, clasp at the bottom:
// x runs left to right, y from the back wall to the front wall. Slot 0 is back left, slots run
// along the back row first, then the front row.

enum BoxOrientation: String, Sendable {
    /// Clasp toward the viewer, dials upright. Wide: 6 across by 2 deep for a 12 watch box.
    case front
    /// The box turned a quarter clockwise, the way it is held lengthwise: the left end is at the
    /// top, the clasp on the left, 12 o'clock points right. Tall: fits a phone.
    case endOn
}

struct BoxGeometry: Equatable, Sendable {
    var columns: Int
    var rows: Int

    // Millimetres, from the maker's dimension sheet: 345 x 210 x 148 outside, pillows 50 x 72 x 35,
    // "dials up to 50 mm". The lid is a wooden U (two side rails and a back rail) around a clear
    // pane that folds down over the front, so there is no wooden rail along the front.
    static let compartment = CGSize(width: 50, height: 87)
    static let divider: CGFloat = 3
    static let sideRail: CGFloat = 15
    static let backRail: CGFloat = 24
    static let frontRail: CGFloat = 9       // the low front wall of the tray, under the pane
    static let frameCorner: CGFloat = 2.5
    static let chamfer: CGFloat = 2         // inner edge of the frame
    static let cushion = CGSize(width: 48.6, height: 72)
    static let cushionCorner: CGFloat = 10
    static let lidFold: CGFloat = 60        // the pane starts sloping down this far from the front
    static let handle = CGSize(width: 62, height: 8)   // brass drawer pull, sticks out past the front
    static let height: CGFloat = 148        // whole box; the drawer is the lower 60
    static let drawerHeight: CGFloat = 60
    static let defaultDiameter: CGFloat = 40

    var inner: CGSize {
        CGSize(width: CGFloat(columns) * Self.compartment.width + CGFloat(columns - 1) * Self.divider,
               height: CGFloat(rows) * Self.compartment.height + CGFloat(rows - 1) * Self.divider)
    }
    var outer: CGSize { CGSize(width: inner.width + 2 * Self.sideRail, height: inner.height + Self.backRail + Self.frontRail) }
    /// The drawing in box space: the box plus the drawer pull in front of it.
    var canvas: CGSize { CGSize(width: outer.width, height: outer.height + Self.handle.height) }
    var slotCount: Int { columns * rows }

    /// Size of the drawing in millimetres for an orientation.
    func size(_ orientation: BoxOrientation) -> CGSize {
        orientation == .front ? canvas : CGSize(width: canvas.height, height: canvas.width)
    }

    /// Compartment rectangle in box space.
    func slot(_ index: Int) -> CGRect {
        let column = index % columns, row = index / columns
        return CGRect(x: Self.sideRail + CGFloat(column) * (Self.compartment.width + Self.divider),
                      y: Self.backRail + CGFloat(row) * (Self.compartment.height + Self.divider),
                      width: Self.compartment.width, height: Self.compartment.height)
    }

    var cavity: CGRect { CGRect(x: Self.sideRail, y: Self.backRail, width: inner.width, height: inner.height) }

    /// Box space to drawing space (still millimetres).
    func place(_ rect: CGRect, _ orientation: BoxOrientation) -> CGRect {
        switch orientation {
        case .front: rect
        case .endOn: CGRect(x: canvas.height - rect.maxY, y: rect.minX, width: rect.height, height: rect.width)
        }
    }

    func place(_ point: CGPoint, _ orientation: BoxOrientation) -> CGPoint {
        switch orientation {
        case .front: point
        case .endOn: CGPoint(x: canvas.height - point.y, y: point.x)
        }
    }

    /// Drawing space (millimetres) back to a slot, or nil outside every compartment.
    /// `slack` widens each compartment so a drop on a divider still lands.
    func slotIndex(at point: CGPoint, _ orientation: BoxOrientation, slack: CGFloat = Self.divider / 2) -> Int? {
        let p = orientation == .front ? point : CGPoint(x: point.y, y: canvas.height - point.x)
        for index in 0..<slotCount where slot(index).insetBy(dx: -slack, dy: -slack).contains(p) { return index }
        return nil
    }

    /// Points per millimetre that fits the drawing in `available`.
    func scale(fitting available: CGSize, _ orientation: BoxOrientation) -> CGFloat {
        let s = size(orientation)
        return min(available.width / s.width, available.height / s.height)
    }

    /// Which way to show the box in a space: front when it gives the bigger watches.
    static func orientation(for available: CGSize, columns: Int, rows: Int) -> BoxOrientation {
        let g = BoxGeometry(columns: columns, rows: rows)
        return g.scale(fitting: available, .front) >= g.scale(fitting: available, .endOn) ? .front : .endOn
    }
}
