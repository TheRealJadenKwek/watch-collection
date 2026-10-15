import SwiftUI

enum WatchTheme {
    // Near-black with a warm undertone, champagne gold used sparingly, ivory type.
    static let background = Color(red: 8 / 255, green: 7 / 255, blue: 6 / 255)
    static let card = Color(red: 19 / 255, green: 17 / 255, blue: 14 / 255)
    static let raised = Color(red: 29 / 255, green: 26 / 255, blue: 21 / 255)
    static let gold = Color(red: 212 / 255, green: 180 / 255, blue: 120 / 255)
    static let goldDeep = Color(red: 166 / 255, green: 134 / 255, blue: 78 / 255)
    static let ivory = Color(red: 240 / 255, green: 234 / 255, blue: 220 / 255)
    static let secondary = Color(red: 158 / 255, green: 150 / 255, blue: 136 / 255)
    static let hairline = Color.white.opacity(0.08)
    static let green = Color(red: 110 / 255, green: 160 / 255, blue: 126 / 255)
    static let amber = Color(red: 214 / 255, green: 150 / 255, blue: 84 / 255)
    static let red = Color(red: 200 / 255, green: 102 / 255, blue: 96 / 255)
}

extension Font {
    /// Didot (bundled with iOS) for display type: titles, watch names and big numerals.
    static func display(_ size: CGFloat, relativeTo style: Font.TextStyle = .title) -> Font {
        .custom("Didot", size: size, relativeTo: style)
    }

    static func displayItalic(_ size: CGFloat, relativeTo style: Font.TextStyle = .body) -> Font {
        .custom("Didot-Italic", size: size, relativeTo: style)
    }
}

/// Thin full-width rule used to open editorial sections.
struct GoldRule: View {
    var opacity: Double = 0.35

    var body: some View {
        Rectangle().fill(WatchTheme.gold.opacity(opacity)).frame(height: 0.75)
    }
}

extension View {
    func watchCard(cornerRadius: CGFloat = 20) -> some View {
        self
            .background {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(WatchTheme.card)
                    .overlay {
                        // Faint top light so cards read as raised objects, not flat boxes.
                        LinearGradient(colors: [Color.white.opacity(0.035), .clear], startPoint: .top, endPoint: .center)
                            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                    }
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(WatchTheme.hairline, lineWidth: 1)
            }
    }

    func serifTitle() -> some View {
        fontDesign(.serif)
    }
}

/// Small tracked uppercase label used above titles and figures.
struct Eyebrow: View {
    let text: String
    var color: Color = WatchTheme.gold

    init(_ text: String, color: Color = WatchTheme.gold) {
        self.text = text
        self.color = color
    }

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 10.5, weight: .semibold))
            .tracking(1.8)
            .foregroundStyle(color)
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
    guard let value else { return "—" }
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

func lastWearDate(for watch: Watch) -> String? {
    wearSessions(for: watch).last?.date
}

func wearMinutes(for watch: Watch, on day: String? = nil) -> Int {
    wearSessions(for: watch)
        .filter { day == nil || $0.date == day }
        .reduce(0) { $0 + $1.durationMinutes }
}

func wearDurationLabel(_ minutes: Int) -> String {
    if minutes < 60 { return "\(minutes)m" }
    if minutes % 60 == 0 { return "\(minutes / 60)h" }
    return "\(minutes / 60)h \(minutes % 60)m"
}

func optionalNumberBinding(_ value: Binding<Double?>) -> Binding<String> {
    Binding(
        get: { value.wrappedValue.map(compactNumber) ?? "" },
        set: { value.wrappedValue = Double($0.replacingOccurrences(of: ",", with: ".")) }
    )
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
    if wrist.sweetSpotMin...wrist.sweetSpotMax ~= diameter {
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
    case "Gold/Champagne": WatchTheme.gold
    case "Cream": Color(red: 0.88, green: 0.83, blue: 0.68)
    case "Orange": .orange
    case "Red": .red
    case "Brown": .brown
    case "Screen": Color(red: 0.35, green: 0.45, blue: 0.55)
    default: Color.purple.opacity(0.8)
    }
}
