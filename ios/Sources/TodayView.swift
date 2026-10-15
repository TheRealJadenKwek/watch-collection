import SwiftUI

/// Home tab: what's on the wrist today, the watch box to log from, and rotation health.
struct TodayScreen: View {
    @ObservedObject var store: AppStore
    let showSettings: () -> Void
    @State private var wearSelection: WearDaySelection?
    @Namespace private var zoom

    private var owned: [Watch] {
        (store.data?.watches ?? []).filter { $0.status == "owned" }
    }
    private var todayKey: String { calendarDayKey() }
    private var wornToday: [Watch] {
        owned
            .filter { wearMinutes(for: $0, on: todayKey) > 0 }
            .sorted { wearMinutes(for: $0, on: todayKey) > wearMinutes(for: $1, on: todayKey) }
    }
    private var numbers: [String: Int] { catalogueNumbers(store.data?.watches ?? []) }

    var body: some View {
        NavigationStack {
            RefreshableScreen(store: store) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 34) {
                        ScreenHeader(
                            eyebrow: Date().formatted(.dateTime.weekday(.wide).day().month(.wide)),
                            title: wornToday.isEmpty ? "Today" : "On the wrist"
                        )
                        hero
                        watchBox
                        rotation
                        resting
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 6)
                    .padding(.bottom, 40)
                }
                .background(WatchTheme.background)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { GearToolbarButton(action: showSettings) }
            }
            .navigationDestination(for: WatchRoute.self) { route in
                WatchDossierView(store: store, watchID: route.id)
                    .navigationTransition(.zoom(sourceID: route.id, in: zoom))
            }
            .sheet(item: $wearSelection) { selection in
                WearDayEditorSheet(store: store, selection: selection)
            }
        }
    }

    // MARK: Hero

    @ViewBuilder
    private var hero: some View {
        if let watch = wornToday.first ?? restingOrder(owned).first {
            let isWorn = wearMinutes(for: watch, on: todayKey) > 0
            VStack(alignment: .leading, spacing: 16) {
                NavigationLink(value: WatchRoute(id: watch.id)) {
                    FramedPhoto(
                        store: store,
                        itemID: watch.id,
                        filename: watch.photos.first,
                        focus: watch.focus(for: watch.photos.first)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                    .overlay(alignment: .topLeading) {
                        PhotoTag(text: isWorn ? "Wearing now" : "Suggested for today", color: WatchTheme.gold)
                            .padding(14)
                    }
                    .matchedTransitionSource(id: watch.id, in: zoom)
                }
                .buttonStyle(.plain)

                VStack(alignment: .leading, spacing: 6) {
                    Text(catalogueLabel(numbers[watch.id]))
                        .font(.system(size: 11, weight: .semibold).monospacedDigit())
                        .tracking(1.4)
                        .foregroundStyle(WatchTheme.gold)
                    Text(watch.name)
                        .font(.display(32))
                        .foregroundStyle(WatchTheme.ivory)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(alignment: .center, spacing: 12) {
                    Text(isWorn
                         ? "\(wearDurationLabel(wearMinutes(for: watch, on: todayKey))) logged today"
                         : lastWornLabel(watch))
                        .font(.subheadline)
                        .foregroundStyle(WatchTheme.secondary)
                    Spacer(minLength: 8)
                    Button {
                        wearSelection = WearDaySelection(watch: watch, date: Date())
                    } label: {
                        Text(isWorn ? "Edit hours" : "Wear it")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(WatchTheme.background)
                            .padding(.horizontal, 18)
                            .padding(.vertical, 11)
                            .background(WatchTheme.gold, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(store.isOffline)
                }
                if wornToday.count > 1 {
                    Text("Also today: " + wornToday.dropFirst().map(\.name).joined(separator: ", "))
                        .font(.footnote)
                        .foregroundStyle(WatchTheme.secondary)
                }
            }
        } else {
            EmptyCollectionView(title: "No watches yet", detail: "Add a watch from the Collection tab.")
                .frame(minHeight: 280)
        }
    }

    // MARK: Watch box

    private var watchBox: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Eyebrow("The watch box")
                Spacer()
                Text("Tap to log today")
                    .font(.caption)
                    .foregroundStyle(WatchTheme.secondary)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 16) {
                    ForEach(owned.sorted { $0.price > $1.price }) { watch in
                        let worn = wearMinutes(for: watch, on: todayKey) > 0
                        Button {
                            wearSelection = WearDaySelection(watch: watch, date: Date())
                        } label: {
                            VStack(spacing: 8) {
                                WatchPortrait(store: store, watch: watch, size: 66, highlighted: worn)
                                    .frame(width: 74, height: 74)
                                Text(watch.name)
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(worn ? WatchTheme.gold : WatchTheme.ivory.opacity(0.85))
                                    .multilineTextAlignment(.center)
                                    .lineLimit(2, reservesSpace: true)
                                    .frame(width: 78)
                            }
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            NavigationLink(value: WatchRoute(id: watch.id)) {
                                Label("Open", systemImage: "arrow.up.right")
                            }
                        }
                    }
                }
                .padding(.horizontal, 20)
            }
            .padding(.horizontal, -20)
            .disabled(store.isOffline)
        }
    }

    // MARK: Rotation

    private var rotation: some View {
        let month = dailyMinutes(owned, days: 30)
        let since = Calendar.current.date(byAdding: .day, value: -29, to: Calendar.current.startOfDay(for: Date()))
        let wornIDs = Set(owned.filter { watch in
            wearSessions(for: watch).contains { calendarDayDate($0.date).map { $0 >= (since ?? .distantPast) } ?? false }
        }.map(\.id))
        let totalMinutes = month.reduce(0) { $0 + $1.minutes }
        return VStack(alignment: .leading, spacing: 18) {
            GoldRule()
            Eyebrow("Rotation · last 30 days")
            HStack(alignment: .top, spacing: 0) {
                Figure(value: "\(wornIDs.count)/\(owned.count)", label: "Watches worn")
                    .frame(maxWidth: .infinity, alignment: .leading)
                Figure(value: wearDurationLabel(totalMinutes), label: "On the wrist")
                    .frame(maxWidth: .infinity, alignment: .leading)
                Figure(value: "\(month.filter { $0.minutes > 0 }.count)", label: "Days logged")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            WearStrip(days: month)
        }
    }

    // MARK: Resting

    @ViewBuilder
    private var resting: some View {
        let waiting = Array(restingOrder(owned).prefix(4))
        if !waiting.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                GoldRule()
                Eyebrow("Resting longest")
                ForEach(waiting) { watch in
                    NavigationLink(value: WatchRoute(id: watch.id)) {
                        HStack(spacing: 14) {
                            WatchPortrait(store: store, watch: watch, size: 48)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(watch.name)
                                    .font(.display(19))
                                    .foregroundStyle(WatchTheme.ivory)
                                    .lineLimit(1)
                                Text(lastWornLabel(watch))
                                    .font(.caption)
                                    .foregroundStyle(WatchTheme.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(WatchTheme.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}
