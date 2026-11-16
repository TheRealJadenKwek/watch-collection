import SwiftUI

// One layout engine for a folding iPhone. The window's size and the hinge decide the posture; the device's name
// never does. An ordinary iPhone is always `.phone` and lays out exactly as it did before this file existed.
// Ported from the Arsenal app, which shipped it; the names and the numbers are the same.
//
//   folded   the cover screen: short and wide, with the clock in a strip down the trailing side
//   open     the inner screen held flat: a two-page spread held like a book, or one wide page with the crease across
//   half     the inner screen with the hinge part open: nothing important sits on the crease

struct DuoLayout: Equatable {
    enum Posture: String, Equatable { case phone, folded, open, half }
    enum Hinge: String, Equatable { case unknown, closed, partiallyOpen, fullyOpen }
    /// Which way the crease runs through a half-open window: across it (table top) or down it (held like a book).
    enum Fold: Equatable { case across, down }

    var posture: Posture
    /// The whole window, safe areas included.
    var size: CGSize
    /// The window's safe area at rest: the keyboard is never counted.
    var insets: EdgeInsets

    static let phone = DuoLayout(posture: .phone, size: .zero, insets: EdgeInsets())

    init(posture: Posture, size: CGSize, insets: EdgeInsets) {
        self.posture = posture
        self.size = size
        self.insets = insets
    }

    init(size: CGSize, insets: EdgeInsets, hinge: Hinge) {
        self.init(posture: Self.posture(size: size, hinge: hinge), size: size, insets: insets)
    }

    /// The shortest side of the inner screen is 669 pt; no iPhone's cover or slab reaches 600.
    static let innerSide: CGFloat = 600
    /// An ordinary iPhone is at least 1.77 times as tall as it is wide. The cover screen is 1.45.
    static let squat: CGFloat = 1.62

    static func posture(size: CGSize, hinge: Hinge) -> Posture {
        guard size.width > 0, size.height > 0 else { return .phone }
        if min(size.width, size.height) >= innerSide { return hinge == .partiallyOpen ? .half : .open }
        // The hinge reads part open on the cover screen too, while the phone is being opened: it changes nothing there.
        // The cover is taller than it is wide; an ordinary iPhone's window turned sideways is not a cover.
        if size.width >= 420, size.height > size.width, size.height / size.width < squat { return .folded }
        return .phone
    }

    /// Open or half open: the layouts with columns.
    var isWide: Bool { posture == .open || posture == .half }

    var fold: Fold? {
        guard posture == .half else { return nil }
        return size.height >= size.width ? .across : .down
    }

    // MARK: The cover screen's status strip

    /// The strip down the trailing side of a cover screen where the clock and Wi-Fi sit. 0 when there is none.
    var statusStrip: CGFloat { posture == .folded && insets.trailing >= 40 ? insets.trailing : 0 }

    /// How far down that strip the status items reach. Measured on the cover screen: the last one ends at 147 pt.
    static let statusDepth: CGFloat = 162

    /// The one corner of a cover screen that stays clear. Everything else runs to the edges.
    var statusCorner: CGSize { statusStrip > 0 ? CGSize(width: statusStrip, height: Self.statusDepth) : .zero }

    // MARK: Pages

    /// The side margin of a page in this posture.
    var gutter: CGFloat { isWide ? 22 : 16 }

    /// Half the width of the band a half-open page keeps clear around its crease.
    static let creaseClearance: CGFloat = 14

    /// Cards lay out in two columns once there is room for two.
    var cardColumns: Int { isWide ? 2 : 1 }

    // MARK: The home indicator

    /// The tallest bottom inset taken as the home indicator. The home indicator is 34; a keyboard, and every step of
    /// one being dragged away, is taller, so anything over this keeps the inset last seen at rest.
    static let tallestHomeInset: CGFloat = 40

    /// The window's insets with the keyboard left out. `resting` is the home indicator's inset last seen, and is
    /// updated here whenever the bottom inset is one.
    static func restingInsets(_ insets: EdgeInsets, resting: inout CGFloat) -> EdgeInsets {
        var result = insets
        if insets.bottom > tallestHomeInset { result.bottom = resting } else { resting = insets.bottom }
        return result
    }
}

// MARK: Two pages and the crease (this app's additions)

extension DuoLayout {
    /// The inner screen held like a book, open or half open: wider than tall, the crease running down the middle.
    /// A page lays out as two pages, the left one ending `creaseClearance` before the crease, the right one starting
    /// as far after it.
    var isBook: Bool { isWide && size.width > size.height }

    /// The inner screen with the crease running across it, open or half open: one wide page, as on a phone.
    var isAcross: Bool { isWide && size.height >= size.width }

    /// Half open on a table, the crease across: the pane above the crease stays put, the one below it scrolls.
    var isTableTop: Bool { posture == .half && fold == .across }

    /// Where the crease runs, in window points: an x for a book, a y with the crease across. nil off the inner screen.
    var crease: CGFloat? {
        if isBook { return size.width / 2 }
        if isAcross { return size.height / 2 }
        return nil
    }

    /// Between two columns that stand either side of a book's crease, each keeping `inset` from its page's edge.
    static func creaseGap(inset: CGFloat) -> CGFloat { 2 * (creaseClearance + inset) }

    /// The side margin of a page: the phone's own margin on a phone, the gutter everywhere else.
    func pageMargin(phone: CGFloat) -> CGFloat { posture == .phone ? phone : gutter }

    /// Columns of a grid of tiles (Collection's Cards). On a book they fill one page.
    var tileColumns: Int {
        switch posture {
        case .phone, .folded: 2
        case .open, .half: isBook ? 2 : 3
        }
    }

    /// Columns of a grid of photos (Collection's Photos). On a book they fill one page.
    var photoColumns: Int {
        switch posture {
        case .phone: 3
        case .folded: 4
        case .open, .half: isBook ? 3 : 5
        }
    }

    /// The column each card goes in so the columns end as level as they can: each card in turn joins the shortest.
    /// `weights` are the cards' heights, or any measure in proportion to them.
    static func balance(_ weights: [CGFloat], columns: Int) -> [Int] {
        let count = max(1, columns)
        var heights = [CGFloat](repeating: 0, count: count)
        return weights.map { weight in
            let shortest = heights.indices.min { heights[$0] < heights[$1] } ?? 0
            heights[shortest] += weight
            return shortest
        }
    }
}

// MARK: The hinge

/// The hinge passes through "part open" every time the phone is opened or shut. The half-open layout waits until the
/// hinge has stayed there, so opening the phone never flashes through it; leaving it is immediate. Plain state in,
/// action out, so the rules can be tested without a clock.
struct HingeGate: Equatable {
    /// What the layout shows.
    private(set) var shown: DuoLayout.Hinge
    /// What a running wait will show when it ends. nil when nothing is waiting.
    private(set) var waiting: DuoLayout.Hinge?

    /// How long the hinge has to stay part open before the half-open layout comes.
    static let wait: Duration = .milliseconds(450)

    enum Action: Equatable {
        /// Nothing changes; a running wait keeps running.
        case none
        /// Stop any running wait and start a new one.
        case startWait
        /// Stop the running wait.
        case cancelWait
        /// Stop any running wait and lay out for `shown` now.
        case show
    }

    init(shown: DuoLayout.Hinge = .unknown) { self.shown = shown }

    /// The hinge reported `next`.
    mutating func update(_ next: DuoLayout.Hinge) -> Action {
        // The hinge reports again as its angle changes: the wait already running for this state carries on.
        if next == waiting { return .none }
        if next == shown {
            guard waiting != nil else { return .none }
            waiting = nil
            return .cancelWait
        }
        if next == .partiallyOpen {
            waiting = next
            return .startWait
        }
        waiting = nil
        shown = next
        return .show
    }

    /// The wait ran its full time.
    mutating func waitEnded() -> Action {
        guard let waiting else { return .none }
        shown = waiting
        self.waiting = nil
        return .show
    }
}

private struct DuoLayoutKey: EnvironmentKey {
    static let defaultValue = DuoLayout.phone
}

extension EnvironmentValues {
    /// How the window is held. `.phone` everywhere but on a folding iPhone, and always on the Mac.
    var duo: DuoLayout {
        get { self[DuoLayoutKey.self] }
        set { self[DuoLayoutKey.self] = newValue }
    }
}

// MARK: Cards in columns

/// Which column of a `CardColumns` a card stands in. Ignored where there is one column.
struct CardColumn: LayoutValueKey {
    static let defaultValue = 0
}

/// Cards in columns, each down the column it names, in the order they are given. Two columns on the inner screen,
/// where an ordinary iPhone and the cover screen stack the same cards in one. Because the cards are the same views in
/// either case, opening or shutting the phone moves them without making them new: what is typed in one, its scroll
/// and the sheet it has open all carry over.
struct CardColumns: SwiftUI.Layout {
    var columns: Int
    /// Between two cards in a column.
    var spacing: CGFloat
    /// Between two columns.
    var gap: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? idealWidth(subviews)
        return CGSize(width: width, height: frames(width: width, subviews: subviews).height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let placed = frames(width: bounds.width, subviews: subviews)
        // Each card is offered its column's width, as it was when it was measured.
        let proposal = ProposedViewSize(width: columnWidth(bounds.width), height: nil)
        for (subview, frame) in zip(subviews, placed.frames) {
            subview.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                          proposal: ProposedViewSize(width: proposal.width, height: frame.height))
        }
    }

    private var count: Int { max(1, columns) }

    private func columnWidth(_ width: CGFloat) -> CGFloat { max(0, (width - gap * CGFloat(count - 1)) / CGFloat(count)) }

    private func idealWidth(_ subviews: Subviews) -> CGFloat {
        let widest = subviews.map { $0.sizeThatFits(.unspecified).width }.max() ?? 0
        return widest * CGFloat(count) + gap * CGFloat(count - 1)
    }

    /// Each card's frame, and the height of the tallest column.
    func frames(width: CGFloat, subviews: Subviews) -> (frames: [CGRect], height: CGFloat) {
        let column = columnWidth(width)
        var heights = [CGFloat](repeating: 0, count: count), filled = [Bool](repeating: false, count: count)
        var frames: [CGRect] = []
        for subview in subviews {
            let index = count == 1 ? 0 : min(count - 1, max(0, subview[CardColumn.self]))
            let size = subview.sizeThatFits(ProposedViewSize(width: column, height: nil))
            if filled[index], size.height > 0 { heights[index] += spacing }
            // Centred in its column, as a stack centres it.
            frames.append(CGRect(x: CGFloat(index) * (column + gap) + (column - size.width) / 2, y: heights[index], width: size.width, height: size.height))
            heights[index] += size.height
            if size.height > 0 { filled[index] = true }
        }
        return (frames, heights.max() ?? 0)
    }
}

// MARK: Panes either side of the crease (this app's addition)

/// Two panes either side of the inner screen's crease: side by side on a book, one above the other with the crease
/// across. Each pane ends `creaseClearance` from the crease and is offered its whole height (or width).
/// `crease` is in the layout's own coordinates; nil puts it in the middle. `CreasePanes` works it out from the window.
struct CreaseSplit: SwiftUI.Layout {
    var axis: Axis
    var crease: CGFloat?

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let panes = Self.panes(in: bounds, axis: axis, crease: crease)
        for (subview, frame) in zip(subviews, [panes.first, panes.second]) {
            subview.place(at: frame.origin, proposal: ProposedViewSize(frame.size))
        }
    }

    /// The two panes' frames in `bounds`. A crease outside the bounds leaves the pane on that side empty.
    static func panes(in bounds: CGRect, axis: Axis, crease: CGFloat?) -> (first: CGRect, second: CGRect) {
        let clear = DuoLayout.creaseClearance
        switch axis {
        case .horizontal:
            let middle = bounds.minX + (crease ?? bounds.width / 2)
            let firstEnd = min(bounds.maxX, max(bounds.minX, middle - clear))
            let secondStart = min(bounds.maxX, max(bounds.minX, middle + clear))
            return (CGRect(x: bounds.minX, y: bounds.minY, width: firstEnd - bounds.minX, height: bounds.height),
                    CGRect(x: secondStart, y: bounds.minY, width: bounds.maxX - secondStart, height: bounds.height))
        case .vertical:
            let middle = bounds.minY + (crease ?? bounds.height / 2)
            let firstEnd = min(bounds.maxY, max(bounds.minY, middle - clear))
            let secondStart = min(bounds.maxY, max(bounds.minY, middle + clear))
            return (CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: firstEnd - bounds.minY),
                    CGRect(x: bounds.minX, y: secondStart, width: bounds.width, height: bounds.maxY - secondStart))
        }
    }
}

/// `CreaseSplit` placed on the window's real crease: side by side on a book, one above the other with the crease
/// across. Anywhere else (a phone, the cover) it splits down its own middle, so use it only on the inner screen.
/// With `firstRunsToTop` the panes reach up to the top of the window, under the bars: the first pane (a photo) fills
/// that space, and a second pane beside it keeps its content below the bars as a scroll view does.
struct CreasePanes<First: View, Second: View>: View {
    @Environment(\.duo) private var duo
    /// Where the panes' top left corner is in the window.
    @State private var origin: CGPoint = .zero
    /// Where the safe area's top left corner is in the window: below the bars.
    @State private var safeOrigin: CGPoint = .zero
    private let firstRunsToTop: Bool
    private let first: First
    private let second: Second

    init(firstRunsToTop: Bool = false, @ViewBuilder first: () -> First, @ViewBuilder second: () -> Second) {
        self.firstRunsToTop = firstRunsToTop
        self.first = first()
        self.second = second()
    }

    var body: some View {
        let axis: Axis = duo.isAcross ? .vertical : .horizontal
        let crease = duo.crease.map { axis == .horizontal ? $0 - origin.x : $0 - origin.y }
        let underBars = max(0, safeOrigin.y - origin.y)
        ZStack {
            Color.clear
                .onGeometryChange(for: CGPoint.self) { $0.frame(in: .global).origin } action: { safeOrigin = $0 }
            CreaseSplit(axis: axis, crease: crease) {
                // The pane's content fills it to the top. A page-style TabView inside still keeps its pages below
                // the bars: give it `PhotoPager(pagesIgnoreSafeArea: .top)`.
                first.ignoresSafeArea(.container, edges: firstRunsToTop ? .top : [])
                second
                    // Beside the photo the second pane also starts at the top: its content still starts below the bars.
                    .safeAreaPadding(.top, axis == .horizontal ? underBars : 0)
            }
            .onGeometryChange(for: CGPoint.self) { $0.frame(in: .global).origin } action: { origin = $0 }
            .ignoresSafeArea(.container, edges: firstRunsToTop ? .top : [])
        }
    }
}

// MARK: Shared pieces

extension View {
    /// Puts a card in a column of `CardColumns`. Each column draws over the one before it, as stacks side by side
    /// do, so a card's shadow falls the same way it did. In one column the cards keep the order they are given.
    func cardColumn(_ column: Int, of columns: Int) -> some View {
        layoutValue(key: CardColumn.self, value: column).zIndex(columns > 1 ? Double(column) : 0)
    }

    /// Lets a page, or a photo on it, run under a cover screen's status strip. Does nothing where there is no strip.
    /// One modifier whatever the posture, so the page keeps its identity (its scroll, its fields, its sheets) when the
    /// phone is opened or shut.
    func runsUnderStatusStrip(_ duo: DuoLayout) -> some View {
        #if os(iOS)
        self.ignoresSafeArea(.container, edges: duo.statusStrip > 0 ? .trailing : [])
        #else
        self
        #endif
    }
}
