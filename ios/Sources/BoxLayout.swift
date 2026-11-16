import SwiftUI

// How the Boxes tab stands in each posture (brief section 9). One view tree: the screen always hands `BoxPanes` the
// same two panes, a fixed one and a scrolling one, and only where they go changes. The selection, the lid and the
// trial carry over when the phone is opened or shut; the scroll view keeps its place in the tree, and `FoldScroll`
// brings the reader back to the same lines.

/// Where the box and the rest of the screen go.
enum BoxArrangement: Equatable {
    /// An ordinary iPhone and the cover screen: one scrolling column, the box end on (Turn may override), the tray
    /// docked at the bottom.
    case phone
    /// The inner screen with the crease across, and a Mac window too narrow for the side column: one scrolling
    /// column, the box front on across the page, chip grids in place of the tray.
    case column
    /// The inner screen held like a book: the box alone on the left page, everything else scrolling on the right.
    case book
    /// Half open on a table, the crease across: a compact header and the box above the crease, the rest scrolling
    /// below it.
    case table
    /// A Mac window with room for it: the box and its panel on the left, the chips in a column on the right.
    case desk

    /// Under this much detail width the Mac's side column moves below the box.
    static let deskWidth: CGFloat = 860
    /// The Mac's side column.
    static let sideColumn: CGFloat = 300
    /// The widest the box is drawn on a Mac.
    static let widestBox: CGFloat = 900
    /// Around the box where it stands in a fixed pane.
    static let wellPadding: CGFloat = 12

    static func of(_ duo: DuoLayout, mac: Bool, width: CGFloat) -> BoxArrangement {
        if mac { return width >= deskWidth ? .desk : .column }
        if duo.isTableTop { return .table }
        if duo.isBook { return .book }
        if duo.isAcross { return .column }
        return .phone
    }

    /// The box is in the scrolling pane, so a drag near its edges scrolls it.
    var stageScrolls: Bool { self == .phone || self == .column }
    /// The tray is docked under the page; elsewhere the chips stand in grids.
    var docksTray: Bool { self == .phone }
    /// Turn is offered only where the box is end on in a column a phone wide.
    var canTurn: Bool { self == .phone }

    /// Chips across in a grid.
    var chipColumns: Int {
        switch self {
        case .phone: 1
        case .column, .table: 6
        case .book: 4
        case .desk: 2
        }
    }

    /// The box's view and scale (points per millimetre) for the space it is given. In a column the box is as wide as
    /// `space.width` (the phone end on unless turned, elsewhere front on, at most `widestBox` on a Mac); in a fixed
    /// pane it takes the view that gives the bigger watches in `space` and fits inside it.
    static func stage(_ geometry: BoxGeometry, _ arrangement: BoxArrangement, space: CGSize, turned: Bool,
                      mac: Bool) -> (orientation: BoxOrientation, k: CGFloat) {
        switch arrangement {
        case .phone:
            let orientation: BoxOrientation = turned ? .front : .endOn
            return (orientation, max(0, space.width) / geometry.size(orientation).width)
        case .column:
            let width = mac ? min(space.width, widestBox) : space.width
            return (.front, max(0, width) / geometry.size(.front).width)
        case .book, .table, .desk:
            guard space.width > 0, space.height > 0 else { return (.front, 0) }
            let orientation = BoxGeometry.orientation(for: space, columns: geometry.columns, rows: geometry.rows)
            var k = geometry.scale(fitting: space, orientation)
            if mac { k = min(k, widestBox / geometry.size(orientation).width) }
            return (orientation, k)
        }
    }
}

/// The two panes of the Boxes tab, always in the same order: the fixed pane, then the scrolling one. A column gives
/// the scrolling pane everything and the fixed one nothing; a book puts them either side of the crease, a table one
/// above the other; the Mac's side column is the scrolling pane at the right. `crease` is in the layout's own
/// coordinates (an x for a book, a y for a table); nil puts it in the middle.
struct BoxPanes: Layout {
    var arrangement: BoxArrangement
    var crease: CGFloat?

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let frames = Self.panes(in: bounds, arrangement, crease: crease)
        for (subview, frame) in zip(subviews, [frames.fixed, frames.scrolling]) {
            subview.place(at: frame.origin, proposal: ProposedViewSize(frame.size))
        }
    }

    static func panes(in bounds: CGRect, _ arrangement: BoxArrangement, crease: CGFloat?) -> (fixed: CGRect, scrolling: CGRect) {
        switch arrangement {
        case .phone, .column:
            return (CGRect(origin: bounds.origin, size: .zero), bounds)
        case .book:
            let panes = CreaseSplit.panes(in: bounds, axis: .horizontal, crease: crease)
            return (panes.first, panes.second)
        case .table:
            let panes = CreaseSplit.panes(in: bounds, axis: .vertical, crease: crease)
            return (panes.first, panes.second)
        case .desk:
            let side = min(BoxArrangement.sideColumn, bounds.width)
            return (CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width - side, height: bounds.height),
                    CGRect(x: bounds.maxX - side, y: bounds.minY, width: side, height: bounds.height))
        }
    }
}
