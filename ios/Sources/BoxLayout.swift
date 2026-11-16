import SwiftUI

// How the Boxes tab stands in each posture (brief section 9). One view tree: the screen always hands `BoxPanes` the
// same two panes, a fixed one and a scrolling one, and only where they go changes. The selection, the lid and the
// trial carry over when the phone is opened or shut; the scroll view keeps its place in the tree, and `FoldScroll`
// brings the reader back to the same lines.

/// Where the box and the rest of the screen go.
enum BoxArrangement: Equatable {
    /// An ordinary iPhone and the cover screen: one scrolling column, the box front on across the column, the tray
    /// docked at the bottom.
    case phone
    /// The inner screen with the crease across, and a Mac window too narrow for the side column: one scrolling
    /// column, the box front on across the page, chip grids in place of the tray.
    case column
    /// The inner screen held like a book: the box alone on the left page, front on and fitted to it, everything else
    /// scrolling on the right.
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

    /// Chips across in a grid.
    var chipColumns: Int {
        switch self {
        case .phone: 1
        case .column, .table: 6
        case .book: 4
        case .desk: 2
        }
    }

    /// The box's scale (points per millimetre) for the space it is given. The box is always front on, dials upright.
    /// In a column it is as wide as `space.width` (at most `widestBox` on a Mac); in a fixed pane it fits inside
    /// `space`.
    static func stage(_ geometry: BoxGeometry, _ arrangement: BoxArrangement, space: CGSize, mac: Bool) -> CGFloat {
        switch arrangement {
        case .phone:
            return max(0, space.width) / geometry.canvas.width
        case .column:
            let width = mac ? min(space.width, widestBox) : space.width
            return max(0, width) / geometry.canvas.width
        case .book, .table, .desk:
            guard space.width > 0, space.height > 0 else { return 0 }
            var k = geometry.scale(fitting: space)
            if mac { k = min(k, widestBox / geometry.canvas.width) }
            return k
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

/// Every box at once, one under the other in box order (the Both view): each box under a label line, at one scale
/// for the whole stack so two boxes the same size draw the same size and a smaller one draws truly smaller.
enum BoxStack {
    /// The name line (14) and the 8 pt under it.
    static let label: CGFloat = 22
    /// From one box to the next box's label.
    static let gap: CGFloat = 16
    /// Never shrink a column's boxes below this to fit them: the stack scrolls instead.
    static let minimumFitWidth: CGFloat = 300

    /// The labels and gaps of `count` boxes.
    static func chrome(_ count: Int) -> CGFloat {
        guard count > 0 else { return 0 }
        return CGFloat(count) * label + CGFloat(count - 1) * gap
    }

    /// The whole stack's height at scale `k`: every label, every gap and every box.
    static func height(_ geometries: [BoxGeometry], k: CGFloat) -> CGFloat {
        chrome(geometries.count) + geometries.reduce(0) { $0 + $1.canvas.height } * k
    }

    /// One scale (points per millimetre) for the whole stack. A column keeps the boxes as wide as it is unless they
    /// all fit under each other with a box at least `minimumFitWidth` wide; a book's page and the Mac's desk fit the
    /// whole stack; a table fits the box above the crease (with its label) and the rest scroll below at that scale.
    static func scale(_ geometries: [BoxGeometry], _ arrangement: BoxArrangement, space: CGSize, mac: Bool) -> CGFloat {
        guard let widest = geometries.map(\.canvas.width).max(), widest > 0 else { return 0 }
        let tall = geometries.reduce(0) { $0 + $1.canvas.height }
        let chrome = chrome(geometries.count)
        switch arrangement {
        case .phone, .column:
            let full = max(0, mac ? min(space.width, BoxArrangement.widestBox) : space.width) / widest
            guard space.height > 0 else { return full }
            let fit = (space.height - chrome) / tall
            if fit >= full { return full }
            if fit * widest >= minimumFitWidth { return fit }
            return full
        case .book, .desk:
            guard space.width > 0, space.height > 0 else { return 0 }
            var k = min(space.width / widest, (space.height - chrome) / tall)
            if mac { k = min(k, BoxArrangement.widestBox / widest) }
            return max(0, k)
        case .table:
            guard space.width > 0, space.height > 0 else { return 0 }
            let k = geometries.map { min(space.width / $0.canvas.width, (space.height - label) / $0.canvas.height) }.min() ?? 0
            return max(0, k)
        }
    }

    /// How many boxes of the stack stand in the fixed pane: all of them on a book's page and the Mac's desk, the
    /// first above a table's crease, none in a column.
    static func fixedCount(_ arrangement: BoxArrangement, count: Int) -> Int {
        switch arrangement {
        case .book, .desk: max(0, count)
        case .table: min(1, max(0, count))
        case .phone, .column: 0
        }
    }
}

/// Frames a drag needs, kept out of view state so scrolling does not redraw the screen. Every rect is in the screen's
/// named space.
final class BoxFrames {
    struct Stage: Equatable {
        /// The box's drawing.
        var rect: CGRect
        /// It is in the scroll view, so the bar and the tray can cover part of it.
        var scrolls: Bool
    }

    /// The boxes on screen, by box id.
    var stages: [String: Stage] = [:]
    /// The boxes on screen, top first.
    var order: [String] = []
    /// The scroll view's own frame. It already starts below the bar and ends above the tray (or the tab bar where
    /// there is no tray): its content insets for those bars are not added again.
    var scroll: CGRect = .zero
    var tray: CGRect = .zero
    /// The scroll view's offset from its top, and how far it can go.
    var offset: CGFloat = 0
    var maxOffset: CGFloat = 0

    /// The top of what the scroll view shows of its content.
    var visibleTop: CGFloat { scroll.minY }
    /// The bottom of what the scroll view shows: the docked tray, or the end of its frame.
    var visibleBottom: CGFloat {
        let end = scroll.height > 0 ? scroll.maxY : .infinity
        return tray.height > 0 ? min(tray.minY, end) : end
    }

    /// The shown stages, top first.
    private var shown: [Stage] { order.compactMap { stages[$0] } }

    /// True where a box is on screen: inside its frame and, when it scrolls, below the bar and above the tray.
    func shows(_ boxID: String, at point: CGPoint) -> Bool {
        guard order.contains(boxID), let stage = stages[boxID], stage.rect.contains(point) else { return false }
        guard stage.scrolls else { return true }
        if point.y >= visibleBottom { return false }
        if scroll.height > 0, point.y < visibleTop { return false }
        return true
    }

    /// True on the stack of boxes as it shows: a box, a label above one, the gap between two, the band over a table's
    /// crease. Not on the tray, nor where the bar covers a part of it that scrolls. A drop here puts the watch back.
    func showsStack(at point: CGPoint) -> Bool {
        let shown = shown
        guard !shown.isEmpty else { return false }
        // With more than one box, each has its name above it.
        let label = shown.count > 1 ? BoxStack.label : 0
        // What the scroll view shows: from its top (when it has one) down to the tray or its end.
        let stripTop = scroll.height > 0 ? visibleTop : -.infinity
        var union: CGRect?
        for stage in shown {
            var rect = CGRect(x: stage.rect.minX, y: stage.rect.minY - label, width: stage.rect.width,
                              height: stage.rect.height + label)
            if stage.scrolls {
                // Only the part on screen: a box scrolled up under the bar or the crease, or down under the tray,
                // does not reach out over the tabs or the tray.
                let top = max(rect.minY, stripTop), bottom = min(rect.maxY, visibleBottom)
                guard bottom > top else { continue }
                rect = CGRect(x: rect.minX, y: top, width: rect.width, height: bottom - top)
            }
            union = union.map { $0.union(rect) } ?? rect
        }
        // A fixed box above the scroll view (a table's top pane): the band over the crease down to the scroll view's
        // top belongs to the stack however far the rest has scrolled.
        let fixed = shown.filter { !$0.scrolls }
        if scroll.height > 0, fixed.count < shown.count, let low = fixed.map(\.rect.maxY).max(), low < visibleTop {
            let left = fixed.map(\.rect.minX).min() ?? 0, right = fixed.map(\.rect.maxX).max() ?? 0
            let band = CGRect(x: left, y: low, width: right - left, height: visibleTop - low)
            union = union.map { $0.union(band) } ?? band
        }
        guard let union, union.contains(point) else { return false }
        // The tray, and the end of the scroll view, take a watch out.
        if shown.contains(where: \.scrolls), point.y >= visibleBottom { return false }
        return true
    }

    /// The compartment at a point: the first box (top first) that shows the point, mapped with that box's own
    /// geometry, a divider landing by the half-divider slack. nil off every compartment.
    func space(at point: CGPoint, boxes: [(id: String, geometry: BoxGeometry)], k: CGFloat) -> BoxSpace? {
        guard k > 0 else { return nil }
        for id in order where shows(id, at: point) {
            guard let stage = stages[id], let geometry = boxes.first(where: { $0.id == id })?.geometry else { continue }
            let local = CGPoint(x: (point.x - stage.rect.minX) / k, y: (point.y - stage.rect.minY) / k)
            return geometry.slotIndex(at: local).map { BoxSpace(boxID: id, slot: $0) }
        }
        return nil
    }

    /// While a watch is dragged: -8 (up) in the top 60 pt of what the scroll view shows or up to 40 pt above it, 8
    /// (down) in the bottom 60 pt above the tray or the tab bar, otherwise 0. With every box shown (`both`), only
    /// while the stack runs on past that edge: on a phone the lower box ends just above the tray, and a watch held
    /// over its front row must not scroll the page away from under it.
    func autoScrollStep(at y: CGFloat, both: Bool = false) -> CGFloat {
        let top = visibleTop, bottom = visibleBottom
        let scrolling = shown.filter(\.scrolls)
        if y < top + 60, y > top - 40 {
            guard both else { return -8 }
            if let first = scrolling.first, first.rect.minY < top + 6 { return -8 }
            return 0
        }
        if y > bottom - 60, y < bottom {
            guard both else { return 8 }
            if let last = scrolling.last, last.rect.maxY > bottom - 6 { return 8 }
            return 0
        }
        return 0
    }

    /// How far to scroll so `rect` (in the screen's space) shows with 12 pt to spare below the bar and above the tray;
    /// 0 when it already does.
    func revealDelta(for rect: CGRect) -> CGFloat {
        let top = visibleTop + 12, bottom = visibleBottom - 12
        if rect.maxY > bottom { return rect.maxY - bottom }
        if rect.minY < top { return rect.minY - top }
        return 0
    }
}
