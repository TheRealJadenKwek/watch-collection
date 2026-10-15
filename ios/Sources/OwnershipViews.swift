import SwiftUI

struct WearTodaySheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: AppStore
    @State private var selectedDate = Date()
    @State private var selectedWatch: WearDaySelection?

    private var selectedDay: String { calendarDayKey(selectedDate) }
    private var owned: [Watch] {
        (store.data?.watches ?? [])
            .filter { $0.status == "owned" }
            .sorted {
                let order = $0.name.localizedCaseInsensitiveCompare($1.name)
                return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
            }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    DatePicker("Date", selection: $selectedDate, in: ...Date(), displayedComponents: .date)
                } footer: {
                    Text("Tap a watch to set its hours. You can update your total throughout the day.")
                        .font(.subheadline)
                        .foregroundStyle(WatchTheme.secondary)
                }

                Section(calendarDayLabel(selectedDay)) {
                    ForEach(owned) { watch in
                        let existingMinutes = wearMinutes(for: watch, on: selectedDay)
                        Button {
                            selectedWatch = WearDaySelection(watch: watch, date: selectedDate)
                        } label: {
                            HStack(spacing: 12) {
                                RemoteWatchImage(
                                    asset: watch.photos.first.flatMap {
                                        store.photoAsset(itemID: watch.id, filename: $0, wishlist: false)
                                    },
                                    allowsRemoteFetch: false,
                                    focus: watch.focus(for: watch.photos.first)
                                )
                                .frame(width: 64, height: 64)
                                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                .allowsHitTesting(false)

                                VStack(alignment: .leading, spacing: 4) {
                                    Text(watch.name)
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(.primary)
                                    Text(existingMinutes > 0
                                         ? "\(wearDurationLabel(existingMinutes)) worn · tap to adjust"
                                         : "Tap to set hours")
                                    .font(.caption)
                                    .foregroundStyle(existingMinutes > 0 ? WatchTheme.green : WatchTheme.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(WatchTheme.gold)
                            }
                            .padding(.vertical, 4)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(watch.name)
                        .accessibilityValue("\(wearDurationLabel(existingMinutes)) worn on \(calendarDayLabel(selectedDay))")
                        .accessibilityHint("Opens the hours slider for this watch")
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(WatchTheme.background)
            .navigationTitle("Log Wear")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
            }
            .sheet(item: $selectedWatch) { selection in
                WearDayEditorSheet(store: store, selection: selection)
            }
        }
        .preferredColorScheme(.dark)
        .presentationDetents([.large])
    }
}

private struct WearDaySelection: Identifiable {
    let id = UUID()
    let watch: Watch
    let date: Date
}

private struct WearDayEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: AppStore
    let selection: WearDaySelection
    @State private var hours: Double
    @State private var isSaving = false
    @State private var saveError: String?

    init(store: AppStore, selection: WearDaySelection) {
        self.store = store
        self.selection = selection
        let minutes = wearMinutes(for: selection.watch, on: calendarDayKey(selection.date))
        _hours = State(initialValue: min(Double(minutes) / 60, 24))
    }

    private var minutes: Int { Int((hours * 60).rounded()) }
    private var isToday: Bool { Calendar.current.isDateInToday(selection.date) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    VStack(spacing: 16) {
                        RemoteWatchImage(
                            asset: selection.watch.photos.first.flatMap {
                                store.photoAsset(itemID: selection.watch.id, filename: $0, wishlist: false)
                            },
                            allowsRemoteFetch: false,
                            focus: selection.watch.focus(for: selection.watch.photos.first)
                        )
                        .frame(width: 210, height: 210)
                        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                        .allowsHitTesting(false)
                        .shadow(color: .black.opacity(0.25), radius: 20, y: 10)

                        Text(selection.watch.name)
                            .font(.title2.weight(.semibold))
                            .multilineTextAlignment(.center)
                    }

                    VStack(spacing: 16) {
                        Text(isToday ? "Hours worn so far today" : "Hours worn on \(calendarDayLabel(calendarDayKey(selection.date)))")
                            .font(.subheadline)
                            .foregroundStyle(WatchTheme.secondary)
                            .multilineTextAlignment(.center)

                        HStack(spacing: 20) {
                            adjustmentButton("minus", label: "15 minutes less", enabled: minutes > 0) {
                                hours = max(0, Double(minutes - 15) / 60)
                            }
                            Text(hours.formatted(.number.precision(.fractionLength(0...2))))
                                .font(.system(size: 48, weight: .semibold, design: .rounded).monospacedDigit())
                                .foregroundStyle(WatchTheme.gold)
                                .frame(maxWidth: .infinity)
                                .minimumScaleFactor(0.6)
                                .lineLimit(1)
                                .accessibilityLabel("\(wearDurationLabel(minutes)) worn")
                            adjustmentButton("plus", label: "15 minutes more", enabled: minutes < 24 * 60) {
                                hours = min(24, Double(minutes + 15) / 60)
                            }
                        }

                        Slider(value: $hours, in: 0...24, step: 0.25)
                            .tint(WatchTheme.gold)
                            .accessibilityLabel("Hours worn")
                            .accessibilityValue(wearDurationLabel(minutes))
                            .accessibilityIdentifier("wear.total.slider")
                        HStack {
                            Text("0 hours")
                            Spacer()
                            Text("24 hours")
                        }
                        .font(.caption)
                        .foregroundStyle(WatchTheme.secondary)

                        Text("This is your total for the day, not extra time. Update it whenever you switch watches.")
                            .font(.footnote)
                            .foregroundStyle(WatchTheme.secondary)
                            .multilineTextAlignment(.center)
                        if wearMinutes(for: selection.watch, on: calendarDayKey(selection.date)) > 24 * 60 {
                            Text("Previous entries total more than 24 hours. Save a corrected daily total below.")
                                .font(.footnote)
                                .foregroundStyle(WatchTheme.gold)
                        }
                        if let saveError {
                            Text(saveError).font(.footnote).foregroundStyle(.red)
                        }
                    }
                    .padding(20)
                    .background(WatchTheme.card, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                }
                .padding(24)
            }
            .background(WatchTheme.background)
            .safeAreaInset(edge: .bottom) {
                Button {
                    isSaving = true
                    saveError = nil
                    Task {
                        let saved = await store.setWearTotal(
                            watchID: selection.watch.id,
                            on: selection.date,
                            totalMinutes: minutes
                        )
                        isSaving = false
                        if saved { dismiss() }
                        else { saveError = store.errorMessage ?? "Couldn't save your hours. Please try again." }
                    }
                } label: {
                    Text(isSaving ? "Saving…" : "Save total · \(wearDurationLabel(minutes))")
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 36)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderedProminent)
                .tint(WatchTheme.gold)
                .controlSize(.large)
                .accessibilityIdentifier("wear.total.save")
                .disabled(isSaving)
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
                .background(WatchTheme.background)
            }
            .navigationTitle(isToday ? "Today's Wear" : "Daily Wear")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.disabled(isSaving)
                }
            }
            .disabled(isSaving)
        }
        .preferredColorScheme(.dark)
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled(isSaving)
    }

    private func adjustmentButton(_ symbol: String, label: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.title3.weight(.semibold))
                .frame(width: 48, height: 48)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(WatchTheme.gold)
        .background(WatchTheme.gold.opacity(0.1), in: Circle())
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
        .accessibilityLabel(label)
    }
}

struct WearHistorySheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: AppStore
    let watchID: String
    @State private var selectedDate = Date()
    @State private var isSaving = false
    @AppStorage("wearLog.lastDurationMinutes") private var durationMinutes = 4 * 60

    private var watch: Watch? { store.data?.watches.first { $0.id == watchID } }
    private var sessions: [WearSession] {
        guard let watch else { return [] }
        return Array(wearSessions(for: watch).reversed())
    }
    private var totalMinutes: Int { sessions.reduce(0) { $0 + $1.durationMinutes } }

    var body: some View {
        NavigationStack {
            Form {
                Section("Add a wear") {
                    DatePicker("Date", selection: $selectedDate, in: ...Date(), displayedComponents: .date)
                    WearDurationPicker(minutes: $durationMinutes)
                    Button {
                        isSaving = true
                        Task {
                            await store.logWear(
                                watchID: watchID,
                                on: selectedDate,
                                durationMinutes: durationMinutes
                            )
                            isSaving = false
                        }
                    } label: {
                        Label(isSaving ? "Saving…" : "Add wear", systemImage: "calendar.badge.plus")
                    }
                    .disabled(isSaving)
                }

                Section("History · \(sessions.count) sessions · \(wearDurationLabel(totalMinutes))") {
                    if sessions.isEmpty {
                        Text("No wears logged yet.")
                            .foregroundStyle(WatchTheme.secondary)
                    } else {
                        ForEach(sessions) { session in
                            HStack {
                                Label(calendarDayLabel(session.date), systemImage: "watch.analog")
                                Spacer()
                                Text(wearDurationLabel(session.durationMinutes))
                                    .font(.caption.weight(.semibold).monospacedDigit())
                                    .foregroundStyle(WatchTheme.gold)
                            }
                                .swipeActions {
                                    Button("Delete", role: .destructive) {
                                        Task { await store.removeWear(watchID: watchID, sessionID: session.id) }
                                    }
                                }
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(WatchTheme.background)
            .navigationTitle(watch?.name ?? "Wear History")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
            }
        }
        .preferredColorScheme(.dark)
        .presentationDetents([.medium, .large])
    }
}

private struct WearDurationPicker: View {
    @Binding var minutes: Int

    private let presets = [60, 3 * 60, 6 * 60, 12 * 60]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Stepper(value: $minutes, in: 30...(24 * 60), step: 30) {
                LabeledContent("Duration", value: wearDurationLabel(minutes))
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(presets, id: \.self) { value in
                        Button(wearDurationLabel(value)) { minutes = value }
                            .buttonStyle(.bordered)
                            .tint(minutes == value ? WatchTheme.gold : WatchTheme.secondary)
                    }
                    Button("All day") { minutes = 16 * 60 }
                        .buttonStyle(.bordered)
                        .tint(minutes == 16 * 60 ? WatchTheme.gold : WatchTheme.secondary)
                }
            }
            .buttonStyle(.borderless)
        }
    }
}

struct MaintenanceSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: AppStore
    let watchID: String

    @State private var serviceDate = Date()
    @State private var kind = "Full service"
    @State private var notes = ""
    @State private var cost: Double?
    @State private var hasReminder = true
    @State private var nextDue = Calendar.current.date(byAdding: .year, value: 5, to: Date()) ?? Date()
    @State private var isSaving = false

    private let kinds = [
        "Full service", "Battery", "Pressure test", "Repair", "Regulation", "Bracelet/strap", "Other",
    ]

    private var watch: Watch? { store.data?.watches.first { $0.id == watchID } }
    private var records: [ServiceRecord] {
        guard let watch else { return [] }
        return Array(serviceRecords(for: watch).reversed())
    }
    private var validationIssue: String? {
        if let cost, cost < 0 { return "Cost cannot be negative." }
        if hasReminder,
           Calendar.current.startOfDay(for: nextDue) < Calendar.current.startOfDay(for: serviceDate) {
            return "The reminder must be after the service date."
        }
        return nil
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("New record") {
                    Picker("Type", selection: $kind) {
                        ForEach(kinds, id: \.self) { Text($0).tag($0) }
                    }
                    DatePicker("Completed", selection: $serviceDate, in: ...Date(), displayedComponents: .date)
                    TextField("Cost (CAD)", text: optionalNumberBinding($cost))
                        .keyboardType(.decimalPad)
                    TextField("Notes", text: $notes, axis: .vertical)
                        .lineLimit(2...5)
                    Toggle("Remind me when next due", isOn: $hasReminder)
                    if hasReminder {
                        DatePicker("Next due", selection: $nextDue, displayedComponents: .date)
                    }
                    if let validationIssue {
                        Label(validationIssue, systemImage: "exclamationmark.circle")
                            .font(.caption)
                            .foregroundStyle(WatchTheme.amber)
                    }
                    Button {
                        addRecord()
                    } label: {
                        Label(isSaving ? "Saving…" : "Add service record", systemImage: "wrench.and.screwdriver")
                    }
                    .disabled(isSaving || validationIssue != nil)
                }

                Section("History · \(records.count)") {
                    if records.isEmpty {
                        Text("No service records yet.")
                            .foregroundStyle(WatchTheme.secondary)
                    } else {
                        ForEach(records) { record in
                            VStack(alignment: .leading, spacing: 5) {
                                HStack {
                                    Text(record.kind).font(.subheadline.weight(.semibold))
                                    Spacer()
                                    Text(calendarDayLabel(record.date))
                                        .font(.caption)
                                        .foregroundStyle(WatchTheme.secondary)
                                }
                                if !record.notes.isEmpty {
                                    Text(record.notes)
                                        .font(.caption)
                                        .foregroundStyle(WatchTheme.secondary)
                                }
                                HStack(spacing: 10) {
                                    if let cost = record.cost {
                                        Text(cad(cost)).foregroundStyle(WatchTheme.gold)
                                    }
                                    if let due = record.nextDue {
                                        Label("Due \(calendarDayLabel(due))", systemImage: "bell")
                                    }
                                }
                                .font(.caption)
                            }
                            .swipeActions {
                                Button("Delete", role: .destructive) {
                                    Task { await store.deleteServiceRecord(watchID: watchID, recordID: record.id) }
                                }
                            }
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(WatchTheme.background)
            .navigationTitle(watch?.name ?? "Service History")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
            }
            .onChange(of: kind) { _, _ in
                if hasReminder { nextDue = suggestedDueDate() }
            }
            .onChange(of: serviceDate) { _, _ in
                if hasReminder { nextDue = suggestedDueDate() }
            }
            .onChange(of: hasReminder) { _, enabled in
                if enabled { nextDue = suggestedDueDate() }
            }
        }
        .preferredColorScheme(.dark)
        .presentationDetents([.large])
    }

    private func addRecord() {
        guard validationIssue == nil else { return }
        isSaving = true
        let record = ServiceRecord(
            id: UUID().uuidString.lowercased(),
            date: calendarDayKey(serviceDate),
            kind: kind,
            notes: notes.trimmingCharacters(in: .whitespacesAndNewlines),
            cost: cost,
            nextDue: hasReminder ? calendarDayKey(nextDue) : nil
        )
        Task {
            await store.addServiceRecord(watchID: watchID, record: record)
            notes = ""
            cost = nil
            isSaving = false
        }
    }

    private func suggestedDueDate() -> Date {
        let years: Int
        switch kind {
        case "Battery": years = 2
        case "Pressure test": years = 1
        case "Bracelet/strap": years = 2
        default: years = 5
        }
        return Calendar.current.date(byAdding: .year, value: years, to: serviceDate) ?? serviceDate
    }
}
