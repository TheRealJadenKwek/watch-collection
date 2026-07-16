import SwiftUI

enum WatchTheme {
    static let background = Color(red: 18 / 255, green: 16 / 255, blue: 13 / 255)
    static let card = Color(red: 26 / 255, green: 23 / 255, blue: 18 / 255)
    static let raised = Color(red: 35 / 255, green: 31 / 255, blue: 24 / 255)
    static let gold = Color(red: 201 / 255, green: 163 / 255, blue: 92 / 255)
    static let secondary = Color(red: 183 / 255, green: 176 / 255, blue: 163 / 255)
    static let green = Color(red: 91 / 255, green: 143 / 255, blue: 113 / 255)
    static let amber = Color(red: 198 / 255, green: 139 / 255, blue: 76 / 255)
    static let red = Color(red: 191 / 255, green: 93 / 255, blue: 88 / 255)
}

extension View {
    func watchCard() -> some View {
        self
            .background(WatchTheme.card)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Color.white.opacity(0.06), lineWidth: 1)
            }
    }

    func serifTitle() -> some View {
        fontDesign(.serif)
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

func cad(cents: Int) -> String {
    cad(Double(cents) / 100)
}

func compactNumber(_ value: Double) -> String {
    value.formatted(.number.precision(.fractionLength(value.rounded() == value ? 0 : 1)))
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
