import SwiftUI

/// Navigation value for opening a watch's dossier.
struct WatchRoute: Hashable {
    let id: String
}

/// Photo shapes shared by the views and the framing editor so a framed cover
/// looks the same everywhere it appears.
enum PhotoShape {
    static let plate: CGFloat = 0.8
    static let dossier: CGFloat = 0.78
    static let square: CGFloat = 1
}

// MARK: - Collection helpers

/// Catalogue number for every watch ever acquired, oldest first ("Nº 07").
func catalogueNumbers(_ watches: [Watch]) -> [String: Int] {
    let ordered = watches.enumerated().sorted { left, right in
        let l = left.element.purchased ?? "9999-99"
        let r = right.element.purchased ?? "9999-99"
        return l == r ? left.offset < right.offset : l < r
    }
    return Dictionary(uniqueKeysWithValues: ordered.enumerated().map { ($0.element.element.id, $0.offset + 1) })
}

func catalogueLabel(_ number: Int?) -> String {
    guard let number else { return "Nº —" }
    return String(format: "Nº %02d", number)
}

func daysSince(_ day: String?) -> Int? {
    guard let date = calendarDayDate(day) else { return nil }
    return Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: date), to: Calendar.current.startOfDay(for: Date())).day
}

func lastWornLabel(_ watch: Watch) -> String {
    guard let days = daysSince(lastWearDate(for: watch)) else { return "Never logged" }
    switch days {
    case 0: return "Worn today"
    case 1: return "Worn yesterday"
    default: return "Last worn \(days) days ago"
    }
}

/// Owned watches not worn today, longest-resting first (never-worn first of all).
func restingOrder(_ watches: [Watch]) -> [Watch] {
    let today = calendarDayKey()
    return watches
        .filter { wearMinutes(for: $0, on: today) == 0 }
        .sorted {
            let left = lastWearDate(for: $0) ?? ""
            let right = lastWearDate(for: $1) ?? ""
            if left == right { return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            return left < right
        }
}

/// Minutes worn per day for the last `days` days, oldest first.
func dailyMinutes(_ watches: [Watch], days: Int) -> [(date: Date, minutes: Int)] {
    let calendar = Calendar.current
    let today = calendar.startOfDay(for: Date())
    return (0..<max(1, days)).reversed().compactMap { offset in
        guard let date = calendar.date(byAdding: .day, value: -offset, to: today) else { return nil }
        let key = calendarDayKey(date)
        return (date, watches.reduce(0) { $0 + wearMinutes(for: $1, on: key) })
    }
}

func wearDayCount(_ watch: Watch) -> Int {
    Set(wearSessions(for: watch).map(\.date)).count
}

// MARK: - Views

/// Full-bleed framed photo at a fixed aspect ratio.
struct FramedPhoto: View {
    @ObservedObject var store: AppStore
    let itemID: String
    let filename: String?
    let focus: PhotoFocus?
    var wishlist = false
    var aspect: CGFloat = PhotoShape.plate

    var body: some View {
        Color.clear
            .aspectRatio(aspect, contentMode: .fit)
            .overlay {
                RemoteWatchImage(
                    asset: filename.flatMap { store.photoAsset(itemID: itemID, filename: $0, wishlist: wishlist) },
                    allowsRemoteFetch: !store.isOffline,
                    focus: focus
                )
            }
            .clipped()
    }
}

/// Circular watch portrait used in the watch box strip and lists.
struct WatchPortrait: View {
    @ObservedObject var store: AppStore
    let watch: Watch
    var size: CGFloat = 64
    var highlighted = false

    var body: some View {
        RemoteWatchImage(
            asset: watch.photos.first.flatMap { store.photoAsset(itemID: watch.id, filename: $0, wishlist: false) },
            allowsRemoteFetch: !store.isOffline,
            focus: watch.focus(for: watch.photos.first)
        )
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay {
            Circle().stroke(highlighted ? WatchTheme.gold : WatchTheme.hairline, lineWidth: highlighted ? 2 : 1)
        }
        .padding(highlighted ? 3 : 0)
        .overlay {
            if highlighted { Circle().stroke(WatchTheme.gold.opacity(0.35), lineWidth: 1) }
        }
    }
}

/// One slim bar per day; gold where wear was logged.
struct WearStrip: View {
    let days: [(date: Date, minutes: Int)]
    var height: CGFloat = 44

    var body: some View {
        VStack(spacing: 6) {
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(Array(days.enumerated()), id: \.offset) { _, day in
                    let fraction = min(Double(day.minutes) / (14 * 60), 1)
                    Capsule()
                        .fill(day.minutes > 0 ? WatchTheme.gold : Color.white.opacity(0.08))
                        .frame(height: day.minutes > 0 ? max(6, height * fraction) : 4)
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(height: height, alignment: .bottom)
            if let first = days.first?.date, let last = days.last?.date {
                HStack {
                    Text(first.formatted(.dateTime.month(.abbreviated).day()))
                    Spacer()
                    Text(Calendar.current.isDateInToday(last) ? "Today" : last.formatted(.dateTime.month(.abbreviated).day()))
                }
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(WatchTheme.secondary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(days.filter { $0.minutes > 0 }.count) of \(days.count) days with wear logged")
    }
}

/// Big Didot figure with a small label underneath.
struct Figure: View {
    let value: String
    let label: String
    var size: CGFloat = 34
    var color: Color = WatchTheme.ivory

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value)
                .font(.display(size))
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Eyebrow(label, color: WatchTheme.secondary)
        }
    }
}

/// Small dark-glass label laid over photos.
struct PhotoTag: View {
    let text: String
    var color: Color = WatchTheme.ivory

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .tracking(1.4)
            .foregroundStyle(color)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(Color.black.opacity(0.42), in: Capsule())
            .background(.ultraThinMaterial, in: Capsule())
            .environment(\.colorScheme, .dark)
    }
}

/// Screen header: small label above a large Didot title.
struct ScreenHeader: View {
    let eyebrow: String
    let title: String
    var subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Eyebrow(eyebrow)
            Text(title)
                .font(.display(42, relativeTo: .largeTitle))
                .foregroundStyle(WatchTheme.ivory)
                .lineLimit(2)
                .minimumScaleFactor(0.7)
            if let subtitle {
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(WatchTheme.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Capsule segmented control in the editorial style.
struct PillPicker: View {
    let options: [(value: String, label: String)]
    @Binding var selection: String

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.value) { option in
                let selected = selection == option.value
                Button {
                    withAnimation(.snappy) { selection = option.value }
                } label: {
                    Text(option.label)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(selected ? WatchTheme.background : WatchTheme.secondary)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(selected ? WatchTheme.ivory : .clear, in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(3)
        .background(WatchTheme.card, in: Capsule())
        .overlay { Capsule().stroke(WatchTheme.hairline) }
    }
}
