import SwiftUI

/// System colours, so the app follows Light and Dark Mode the way Apple's own apps do.
/// The tint is the asset catalog's AccentColor: system orange, like the icon's seconds hand.
enum WatchTheme {
    /// Named directly: Color.accentColor resolves to system blue with the iOS 27 SDK on iOS 26.
    static let accent = Color("AccentColor")
    static let background = Color(.systemGroupedBackground)
    static let card = Color(.secondarySystemGroupedBackground)
    static let raised = Color(.tertiarySystemGroupedBackground)
    static let fill = Color(.tertiarySystemFill)
    static let separator = Color(.separator)
    static let warning = Color.red
    /// Corner radius shared by cards and photos, close to iOS 26's grouped sections.
    static let corner: CGFloat = 24
}

extension Font {
    /// SF Pro Rounded for figures, as Health and Fitness show their numbers.
    static func figure(_ style: Font.TextStyle = .title, weight: Font.Weight = .bold) -> Font {
        .system(style, design: .rounded, weight: weight)
    }
}

extension View {
    /// A rounded card on the grouped background, like a Health summary tile.
    func groupedCard(padding: CGFloat = 16, cornerRadius: CGFloat = WatchTheme.corner) -> some View {
        self
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(WatchTheme.card, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

/// Small secondary label above a title or figure.
struct Eyebrow: View {
    let text: String
    var color: Color = .secondary

    init(_ text: String, color: Color = .secondary) {
        self.text = text
        self.color = color
    }

    var body: some View {
        Text(text)
            .font(.footnote.weight(.semibold))
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
