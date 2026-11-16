import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// The Atelier look: white space, big bold type, square photo tiles, pill buttons, hairlines,
/// and one green used sparingly. Colours are defined here for Light and Dark Mode; the tint is the
/// asset catalog's AccentColor, the same two greens. Switches use system green.
enum Platform {
    #if os(macOS)
    static let isMac = true
    static let deviceName = "Mac"
    /// The sync hub runs on this same Mac, so the desktop app talks to it directly.
    static let defaultSyncAddress = "http://127.0.0.1:8931"
    #else
    static let isMac = false
    static let deviceName = "iPhone"
    static let defaultSyncAddress = ""
    #endif
}

extension View {
    /// iOS sheets size themselves; a Mac sheet collapses to its content without a frame.
    @ViewBuilder
    func desktopSheet(width: CGFloat = 620, height: CGFloat = 720) -> some View {
        #if os(macOS)
        self.formStyle(.grouped).frame(minWidth: width, idealWidth: width, minHeight: height, idealHeight: height)
        #else
        self
        #endif
    }
}

extension View {
    /// The grouped page background behind a scrolling screen.
    @ViewBuilder
    func screenBackground() -> some View {
        #if os(macOS)
        self.background(WatchTheme.background)
        #else
        self.containerBackground(WatchTheme.background, for: .navigation)
        #endif
    }
}

extension View {
    /// The phone's photo-to-page zoom. The Mac has no such transition, so its page just appears.
    @ViewBuilder
    func zoomSource(id: String, in namespace: Namespace.ID) -> some View {
        #if os(iOS)
        self.matchedTransitionSource(id: id, in: namespace)
        #else
        self
        #endif
    }

    @ViewBuilder
    func zoomDestination(id: String, in namespace: Namespace.ID) -> some View {
        #if os(iOS)
        self.navigationTransition(.zoom(sourceID: id, in: namespace))
        #else
        self
        #endif
    }
}

extension View {
    /// List rows that are buttons read as rows on the Mac, not as a stack of bordered buttons.
    @ViewBuilder
    func desktopPlainRows() -> some View {
        #if os(macOS)
        self.buttonStyle(.plain)
        #else
        self
        #endif
    }
}

/// Fades a screen in when it appears, so moving between screens never just snaps.
private struct PageAppear: ViewModifier {
    @State private var shown = false

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .onAppear { withAnimation(.easeOut(duration: 0.2)) { shown = true } }
            .onDisappear { shown = false }
    }
}

extension EnvironmentValues {
    /// False for a Mac section that's kept alive behind the one on screen.
    @Entry var sectionIsActive = true
    /// Opens a page in the Mac's shared navigation stack.
    @Entry var openPage: (any Hashable) -> Void = { _ in }
}

/// A section's navigation. On the phone each tab has its own stack. On the Mac all sections share one,
/// owned by the window, because a split view's detail column can't hold several stacks at once.
struct SectionStack<Content: View>: View {
    private let path: Binding<NavigationPath>?
    private let content: Content

    init(path: Binding<NavigationPath>? = nil, @ViewBuilder content: () -> Content) {
        self.path = path
        self.content = content()
    }

    var body: some View {
        #if os(iOS)
        if let path {
            NavigationStack(path: path) { content }
        } else {
            NavigationStack { content }
        }
        #else
        content
        #endif
    }
}

#if os(macOS)
extension View {
    /// A section's title and controls, drawn by the app instead of the window toolbar. Rebuilding a
    /// different toolbar for each section was most of the delay when switching between them.
    /// The title sits in the title bar row, but the toolbar view there takes every click, so
    /// anything clickable has to go in the row beneath it.
    func desktopHeader<Leading: View, Trailing: View>(
        _ title: String,
        subtitle: String? = nil,
        @ViewBuilder leading: () -> Leading = { EmptyView() },
        @ViewBuilder trailing: () -> Trailing = { EmptyView() }
    ) -> some View {
        let leadingControls = leading()
        let trailingControls = trailing()
        return safeAreaInset(edge: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.title3.bold())
                        .lineLimit(1)
                    if let subtitle {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .frame(height: Self.desktopTitleBarHeight)
                HStack(spacing: 10) {
                    leadingControls
                    Spacer(minLength: 12)
                    trailingControls
                        .buttonStyle(.bordered)
                        .buttonBorderShape(.circle)
                }
                .frame(minHeight: 30)
                .padding(.bottom, 10)
            }
            .padding(.horizontal, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(WatchTheme.background)
            .padding(.top, -Self.desktopTitleBarHeight)
        }
    }

    private static var desktopTitleBarHeight: CGFloat { 52 }
}
#endif

extension View {
    /// For a main section. The Mac cross-fades its sections itself, so it needs nothing here.
    @ViewBuilder
    func pageAppear() -> some View {
        #if os(iOS)
        modifier(PageAppear())
        #else
        self
        #endif
    }

    /// For a pushed page: the phone already zooms or slides, the Mac needs the fade.
    @ViewBuilder
    func desktopPageAppear() -> some View {
        #if os(macOS)
        modifier(PageAppear())
        #else
        self
        #endif
    }
}

extension Color {
    /// A colour that follows Light and Dark Mode, from two sRGB hex values.
    init(light: UInt32, dark: UInt32, lightOpacity: Double = 1, darkOpacity: Double = 1) {
        #if os(iOS)
        let lightColor = UIColor(hex: light, alpha: lightOpacity)
        let darkColor = UIColor(hex: dark, alpha: darkOpacity)
        self.init(uiColor: UIColor { traits in traits.userInterfaceStyle == .dark ? darkColor : lightColor })
        #else
        let lightColor = NSColor(hex: light, alpha: lightOpacity)
        let darkColor = NSColor(hex: dark, alpha: darkOpacity)
        self.init(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? darkColor : lightColor
        })
        #endif
    }

    /// The same sRGB hex value in both modes.
    init(hex: UInt32, opacity: Double = 1) {
        self.init(light: hex, dark: hex, lightOpacity: opacity, darkOpacity: opacity)
    }
}

#if os(iOS)
private extension UIColor {
    convenience init(hex: UInt32, alpha: Double) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }
}
#else
private extension NSColor {
    convenience init(hex: UInt32, alpha: Double) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }
}
#endif

enum WatchTheme {
    /// Named directly: Color.accentColor resolves to system blue with the iOS 27 SDK on iOS 26.
    /// The asset holds the two greens: #127749 in Light Mode, #249A64 in Dark.
    static let accent = Color("AccentColor")
    /// Pressed green.
    static let accentDeep = Color(hex: 0x0B3E27)
    static let background = Color(light: 0xFFFFFF, dark: 0x0E0E0E)
    /// Panels: watch tiles, insight panels, feature blocks.
    static let card = Color(light: 0xF8F8F8, dark: 0x1A1A1A)
    /// Pressed states, inner wells, bar tracks.
    static let raised = Color(light: 0xECECEC, dark: 0x242424)
    /// Quiet pill buttons and chips.
    static let fill = Color(light: 0xD4D4D4, dark: 0x767676, lightOpacity: 0.3, darkOpacity: 0.3)
    /// Headings, figures and primary text.
    static let ink = Color(light: 0x212121, dark: 0xF4F4F4)
    /// Secondary text.
    static let muted = Color(light: 0x767676, dark: 0xA0A0A0)
    /// Hairlines.
    static let separator = Color(light: 0xD4D4D4, dark: 0x333333)
    /// Catalogue numbers only, plus the short rule under the hero figure on Insights.
    static let gold = Color(light: 0xA37E2C, dark: 0xDFAB3A)
    static let warning = Color.red

    /// Tiles, photos and panels are square.
    static let corner: CGFloat = 0
    /// The few places a card floats over a photo.
    static let cornerSoft: CGFloat = 10
    /// A hairline: half a point.
    static let hairline: CGFloat = 0.5

    /// The prominent pill: 45 degrees, deep green to bright green, in both modes.
    static let prominentGradient = LinearGradient(
        colors: [Color(hex: 0x10633D), Color(hex: 0x1A915A)],
        startPoint: .bottomLeading,
        endPoint: .topTrailing
    )

    /// Side margin of a page; narrower on small screens (see `pageMargin`).
    static let margin: CGFloat = 20
    static let narrowMargin: CGFloat = 16
    /// Gap between tiles in a grid and between panels that tile like one.
    static let gridGap: CGFloat = 6
    /// Gap between groups of sections.
    static let sectionGap: CGFloat = 44
    /// Inside a panel.
    static let panelPadding: CGFloat = 20

    /// The side margin for a screen this wide: 16 under 380 points, else 20.
    static func margin(forWidth width: CGFloat) -> CGFloat {
        width > 0 && width < 380 ? narrowMargin : margin
    }

    /// The watch boxes' own colours. The box is an object, so these do not change with Light and Dark Mode.
    /// The brown values were matched by eye to the maker's photos. BoxPalette reads them.
    enum Box {
        struct Finish {
            /// The frame's diagonal gradient, upper left to lower right.
            let frameLight: Color
            let frameDark: Color
            let lining: Color
            let dividerTop: Color
            let dividerEdge: Color
            let cushionEdge: Color
            let cushionMid: Color
            let cushionSheen: Color
            /// Black opacities.
            let cushionShadow: Double
            let contactShadow: Double
            let wallShadow: Double
            /// Black opacity at the pillow's end: the strap darkens as it curves away.
            let strapFalloff: Double
        }

        static let black = Finish(
            frameLight: Color(hex: 0x2E2E30), frameDark: Color(hex: 0x131314), lining: Color(hex: 0x060607),
            dividerTop: Color(hex: 0x1B1B1D), dividerEdge: Color(hex: 0x4A4A4E),
            cushionEdge: Color(hex: 0x0A0A0B), cushionMid: Color(hex: 0x232326), cushionSheen: Color(hex: 0x4A4A50),
            cushionShadow: 0.8, contactShadow: 0.6, wallShadow: 0.6, strapFalloff: 0.78
        )
        static let brown = Finish(
            frameLight: Color(hex: 0x7E4B2C), frameDark: Color(hex: 0x4A2816), lining: Color(hex: 0x21130D),
            dividerTop: Color(hex: 0x3A231A), dividerEdge: Color(hex: 0x6E4A3A),
            cushionEdge: Color(hex: 0x1E110C), cushionMid: Color(hex: 0x4A2D21), cushionSheen: Color(hex: 0x7A5140),
            cushionShadow: 0.75, contactShadow: 0.55, wallShadow: 0.55, strapFalloff: 0.74
        )
        /// The trial ring and its tag. Chosen for contrast on both linings; do not swap it for the accent.
        static let trial = Color(hex: 0x2FB877)
        static let brassLight = Color(red: 0.86, green: 0.74, blue: 0.47)
        static let brassDark = Color(red: 0.50, green: 0.38, blue: 0.17)
    }
}

extension EnvironmentValues {
    /// Side margin of the page, set once from the window width. The Mac keeps its 24 so content
    /// lines up with the title drawn by `desktopHeader`.
    @Entry var pageMargin: CGFloat = Platform.isMac ? 24 : WatchTheme.margin
}

/// The type scale, all built on text styles so Dynamic Type still works. SF Pro throughout.
enum AtelierType {
    /// Mastheads and the watch name on its page. Use with `.tracking(-0.6)`.
    static let display = Font.system(.largeTitle, weight: .bold).leading(.tight)
    /// The display size on large canvases (the Mac).
    static let displayLarge = Font.system(size: 44, weight: .bold).leading(.tight)
    /// Section titles on a watch page, statement text.
    static let heading = Font.system(.title, weight: .bold)
    /// Row titles in spec lists, panel titles.
    static let title = Font.system(.title2, weight: .bold)
    /// The watch name on a tile.
    static let cardTitle = Font.system(.headline, weight: .bold)
    /// Running text. Use with `.lineSpacing(5)`.
    static let body = Font.system(.body, weight: .light)
    /// Spec lines under a tile name, row values.
    static let detail = Font.system(.subheadline, weight: .light)
    /// Small print.
    static let caption = Font.system(.footnote, weight: .regular)
    /// The small wide capitals above a title. Always uppercased, tracking 1.4 (see `Eyebrow`).
    static let kicker = Font.system(.caption2, weight: .regular).width(.expanded)
    /// Label of a pill button.
    static let button = Font.system(.body, weight: .bold)
}

extension Font {
    /// Bold figures in the default design with even-width digits, so numbers line up as they change.
    static func figure(_ style: Font.TextStyle = .title, weight: Font.Weight = .bold) -> Font {
        .system(style, design: .default, weight: weight).monospacedDigit()
    }
}

extension View {
    /// The prominent pill: green gradient, white bold label. One style for the phone and the Mac.
    func prominentButton() -> some View {
        buttonStyle(AtelierPillButtonStyle(kind: .prominent))
    }

    /// The quiet pill for secondary actions: a soft grey fill with an ink label, or over a photo,
    /// white at 30% with a white label.
    func quietButton(overPhoto: Bool = false) -> some View {
        buttonStyle(AtelierPillButtonStyle(kind: overPhoto ? .quietOverPhoto : .quiet))
    }
}

enum AtelierPillKind {
    case prominent, quiet, quietOverPhoto
}

/// The capsule every Atelier button uses. A small control size (as in a card's action row) keeps the
/// shape but tightens the padding so a row of pills fits.
struct AtelierPillButtonStyle: ButtonStyle {
    let kind: AtelierPillKind
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.controlSize) private var controlSize

    func makeBody(configuration: Configuration) -> some View {
        AtelierPill(kind: kind, pressed: configuration.isPressed, compact: controlSize == .small || controlSize == .mini) {
            configuration.label
        }
        .opacity(isEnabled ? 1 : 0.4)
    }
}

/// The pill itself, also drawn on its own where the whole surrounding block is the tap target
/// (the "View watch" pill on the Collection feature).
struct AtelierPill<Label: View>: View {
    let kind: AtelierPillKind
    var pressed = false
    var compact = false
    @ViewBuilder let label: Label

    private var minHeight: CGFloat {
        if compact { return Platform.isMac ? 30 : 34 }
        return Platform.isMac ? 40 : 44
    }

    var body: some View {
        label
            .font(AtelierType.button)
            .lineLimit(1)
            // A row of small pills (a wishlist card's) is short of room on a narrow phone: the label shrinks a little
            // before it is cut off. Where it fits it keeps its size.
            .minimumScaleFactor(compact ? 0.75 : 1)
            .foregroundStyle(kind == .quiet ? WatchTheme.ink : Color.white)
            .padding(.horizontal, compact ? 16 : 30)
            .frame(minHeight: minHeight)
            .background { background }
            .contentShape(Capsule())
    }

    @ViewBuilder
    private var background: some View {
        switch kind {
        case .prominent:
            if pressed {
                Capsule().fill(WatchTheme.accentDeep.opacity(0.9))
            } else {
                Capsule().fill(WatchTheme.prominentGradient)
            }
        case .quiet:
            Capsule().fill(pressed ? WatchTheme.raised : WatchTheme.fill)
        case .quietOverPhoto:
            Capsule().fill(Color.white.opacity(pressed ? 0.45 : 0.3))
        }
    }
}

extension View {
    /// A square panel on the card colour.
    func groupedCard(padding: CGFloat = WatchTheme.panelPadding, cornerRadius: CGFloat = WatchTheme.corner) -> some View {
        self
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(WatchTheme.card, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

/// The kicker: the small wide capitals above a title or figure.
struct Eyebrow: View {
    let text: String
    var color: Color = WatchTheme.muted

    init(_ text: String, color: Color = WatchTheme.muted) {
        self.text = text
        self.color = color
    }

    var body: some View {
        Text(text.uppercased())
            .font(AtelierType.kicker)
            .tracking(1.4)
            .foregroundStyle(color)
    }
}

/// A full-width hairline.
struct Hairline: View {
    var body: some View {
        Rectangle()
            .fill(WatchTheme.separator)
            .frame(height: WatchTheme.hairline)
            .accessibilityHidden(true)
    }
}

let cadFormatter: NumberFormatter = {
    let formatter = NumberFormatter()
    formatter.numberStyle = .currency
    formatter.currencyCode = "CAD"
    formatter.locale = Locale(identifier: "en_CA")
    formatter.maximumFractionDigits = 2
    return formatter
}()

func cad(_ value: Double?) -> String {
    guard let value else { return "Price TBD" }
    return cadFormatter.string(from: NSNumber(value: value)) ?? "$\(value)"
}

private let cadWholeFormatter: NumberFormatter = {
    let formatter = NumberFormatter()
    formatter.numberStyle = .currency
    formatter.currencyCode = "CAD"
    formatter.locale = Locale(identifier: "en_CA")
    formatter.maximumFractionDigits = 0
    return formatter
}()

/// Whole-dollar CAD for headline figures where cents are noise.
func cadWhole(_ value: Double?) -> String {
    guard let value else { return "–" }
    return cadWholeFormatter.string(from: NSNumber(value: value.rounded())) ?? "$\(Int(value.rounded()))"
}

func cad(cents: Int) -> String {
    cad(Double(cents) / 100)
}

func compactNumber(_ value: Double) -> String {
    value.formatted(.number.precision(.fractionLength(value.rounded() == value ? 0 : 1)))
}

func purchaseMonthParts(_ value: String?) -> (year: Int, month: Int)? {
    guard let value else { return nil }
    let parts = value.split(separator: "-")
    guard parts.count == 2,
          let year = Int(parts[0]),
          let month = Int(parts[1]),
          (1...12).contains(month)
    else { return nil }
    return (year, month)
}

func purchaseMonthKey(year: Int, month: Int) -> String {
    String(format: "%04d-%02d", year, month)
}

func currentPurchaseMonth() -> String {
    let components = Calendar.current.dateComponents([.year, .month], from: Date())
    return purchaseMonthKey(year: components.year ?? 2000, month: components.month ?? 1)
}

/// "2019-12" reads "December 2019"; a year on its own ("2019") reads "2019".
func soldMonthLabel(_ value: String?) -> String {
    if let value, value.count == 4, Int(value) != nil { return value }
    return purchaseMonthLabel(value)
}

func purchaseMonthLabel(_ value: String?) -> String {
    guard let parts = purchaseMonthParts(value),
          let date = Calendar.current.date(from: DateComponents(year: parts.year, month: parts.month))
    else { return "" }
    return date.formatted(.dateTime.month(.wide).year())
}

func calendarDayKey(_ date: Date = Date()) -> String {
    let components = Calendar.current.dateComponents([.year, .month, .day], from: date)
    return String(
        format: "%04d-%02d-%02d",
        components.year ?? 2000,
        components.month ?? 1,
        components.day ?? 1
    )
}

func calendarDayDate(_ value: String?) -> Date? {
    guard let value else { return nil }
    let parts = value.split(separator: "-")
    guard parts.count == 3,
          let year = Int(parts[0]),
          let month = Int(parts[1]),
          let day = Int(parts[2]),
          let date = Calendar.current.date(from: DateComponents(year: year, month: month, day: day)),
          calendarDayKey(date) == value
    else { return nil }
    return date
}

func calendarDayLabel(_ value: String?) -> String {
    guard let date = calendarDayDate(value) else { return "Unknown date" }
    if Calendar.current.isDateInToday(date) { return "Today" }
    if Calendar.current.isDateInYesterday(date) { return "Yesterday" }
    return date.formatted(.dateTime.month(.abbreviated).day().year())
}

func wearSessions(for watch: Watch) -> [WearSession] {
    var sessions = watch.wearSessions ?? []
    if sessions.isEmpty {
        sessions = Array(Set(watch.wearDates ?? [])).compactMap { day in
            guard calendarDayDate(day) != nil else { return nil }
            return WearSession(id: "legacy-\(day)", date: day, durationMinutes: 8 * 60)
        }
    }
    var seen = Set<String>()
    return sessions.filter { session in
        calendarDayDate(session.date) != nil &&
            (15...(24 * 60)).contains(session.durationMinutes) &&
            seen.insert(session.id).inserted
    }.sorted {
        if $0.date == $1.date { return $0.id < $1.id }
        return $0.date < $1.date
    }
}

func serviceRecords(for watch: Watch) -> [ServiceRecord] {
    (watch.serviceRecords ?? []).sorted {
        if $0.date == $1.date { return $0.id < $1.id }
        return $0.date < $1.date
    }
}

/// Parses what someone typed as a number: ignores grouping commas and spaces,
/// accepts a comma decimal ("38,5"). Empty or unparseable gives nil.
func parseTypedNumber(_ text: String) -> Double? {
    var cleaned = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: " ", with: "")
    if cleaned.contains(".") || cleaned.filter({ $0 == "," }).count > 1 || cleaned.range(of: #",\d{3}$"#, options: .regularExpression) != nil {
        cleaned = cleaned.replacingOccurrences(of: ",", with: "")
    } else {
        cleaned = cleaned.replacingOccurrences(of: ",", with: ".")
    }
    return Double(cleaned)
}

/// Text field for a number that keeps the typed text while editing (no reformatting
/// mid-keystroke) and writes the parsed value on every change, so Save never sees a stale value.
struct NumberField: View {
    let title: String
    @Binding var value: Double?
    @State private var text: String

    init(_ title: String, value: Binding<Double?>) {
        self.title = title
        _value = value
        _text = State(initialValue: value.wrappedValue.map(plainNumber) ?? "")
    }

    init(_ title: String, value: Binding<Double>) {
        self.init(title, value: Binding<Double?>(
            get: { value.wrappedValue },
            set: { value.wrappedValue = $0 ?? 0 }
        ))
    }

    var body: some View {
        // Label on the left, value on the right, as in Apple's own forms.
        LabeledContent(title) {
            TextField(title, text: $text, prompt: Text("None"))
                .multilineTextAlignment(.trailing)
                .labelsHidden()
        }
        .keyboardType(.decimalPad)
        .onChange(of: text) { _, new in value = parseTypedNumber(new) }
        .onChange(of: value) { _, new in
            // Treat empty and 0 alike so clearing a required price doesn't snap back to "0".
            if (parseTypedNumber(text) ?? 0) != (new ?? 0) { text = new.map(plainNumber) ?? "" }
        }
    }
}

private func plainNumber(_ value: Double) -> String {
    value.formatted(.number.grouping(.never).precision(.fractionLength(0...2)))
}

func optionalSelectionBinding(_ value: Binding<String?>) -> Binding<String> {
    Binding(
        get: { value.wrappedValue ?? "" },
        set: { value.wrappedValue = $0.isEmpty ? nil : $0 }
    )
}

func fitInfo(for diameter: Double?, lugToLug: Double?, wrist: WristProfile) -> FitInfo? {
    if let lugToLug {
        if lugToLug <= wrist.lugMax - 1 {
            return FitInfo(key: "great", label: "great fit · \(compactNumber(lugToLug)) L2L", basis: "L2L")
        }
        if lugToLug <= wrist.lugMax {
            return FitInfo(key: "limit", label: "at the limit · \(compactNumber(lugToLug)) L2L", basis: "L2L")
        }
        return FitInfo(key: "over", label: "+\(compactNumber(lugToLug - wrist.lugMax))mm L2L over", basis: "L2L")
    }
    guard let diameter else { return nil }
    if abs(diameter - wrist.perfect) <= 1 {
        return FitInfo(key: "perfect", label: "perfect · \(compactNumber(diameter))mm", basis: "diameter")
    }
    if diameter >= wrist.sweetSpotMin && diameter <= wrist.sweetSpotMax {
        return FitInfo(key: "sweet", label: "sweet spot · \(compactNumber(diameter))mm", basis: "diameter")
    }
    if diameter < wrist.sweetSpotMin {
        return FitInfo(key: "under", label: "−\(compactNumber(wrist.sweetSpotMin - diameter))mm under", basis: "diameter")
    }
    return FitInfo(key: "over", label: "+\(compactNumber(diameter - wrist.sweetSpotMax))mm over", basis: "diameter")
}

func statusLabel(_ raw: String) -> String {
    WatchStatus(rawValue: raw)?.label ?? raw.replacingOccurrences(of: "_", with: " ").capitalized
}

func dialColor(_ name: String?) -> Color {
    switch name {
    case "Black": .black
    case "White": .white
    case "Silver": .gray
    case "Blue": .blue
    case "Green": .green
    case "Grey": .gray
    case "Gold/Champagne": Color(red: 0.83, green: 0.71, blue: 0.47)
    case "Cream": Color(red: 0.88, green: 0.83, blue: 0.68)
    case "Orange": .orange
    case "Red": .red
    case "Brown": .brown
    case "Screen": Color(red: 0.35, green: 0.45, blue: 0.55)
    default: Color.purple.opacity(0.8)
    }
}
