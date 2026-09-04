import SwiftUI

struct WearTodaySheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: AppStore
    @State private var savingID: String?
    @State private var selectedDate = Date()
    @AppStorage("wearLog.lastDurationMinutes") private var durationMinutes = 4 * 60

    private var selectedDay: String { calendarDayKey(selectedDate) }
    private var owned: [Watch] {
        (store.data?.watches ?? [])
            .filter { $0.status == "owned" }
            .sorted {
                let left = lastWearDate(for: $0) ?? ""
                let right = lastWearDate(for: $1) ?? ""
                if left == right {
                    return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                }
                return left < right
            }
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Wear session") {
                    DatePicker("Date", selection: $selectedDate, in: ...Date(), displayedComponents: .date)
                    WearDurationPicker(minutes: $durationMinutes)
                    Text("Tap every watch you wore. You can add multiple sessions for the same watch and day.")
                        .font(.subheadline)
                        .foregroundStyle(WatchTheme.secondary)
                }

                Section(calendarDayLabel(selectedDay)) {
                    ForEach(owned) { watch in
                        let existingMinutes = wearMinutes(for: watch, on: selectedDay)
                        Button {
                            savingID = watch.id
                            Task {
                                await store.logWear(
                                    watchID: watch.id,
                                    on: selectedDate,
                                    durationMinutes: durationMinutes
                                )
                                savingID = nil
                            }
                        } label: {
                            HStack(spacing: 12) {
                                RemoteWatchImage(
                                    asset: watch.photos.first.flatMap {
                                        store.photoAsset(itemID: watch.id, filename: $0, wishlist: false)
                                    },
                                    allowsRemoteFetch: false
                                )
                                .frame(width: 58, height: 58)
                                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                                VStack(alignment: .leading, spacing: 4) {
                                    Text(watch.name)
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(.primary)
                                    Text(lastWearDate(for: watch).map {
                                        "Last worn \(calendarDayLabel($0).lowercased())"
                                    } ?? "No wears logged yet")
                                    .font(.caption)
                                    .foregroundStyle(WatchTheme.secondary)
                                }
                                Spacer()
                                if savingID == watch.id {
                                    ProgressView().tint(WatchTheme.gold)
                                } else {
                                    VStack(alignment: .trailing, spacing: 3) {
                                        if existingMinutes > 0 {
                                            Text(wearDurationLabel(existingMinutes))
                                                .font(.caption.weight(.semibold))
                                                .foregroundStyle(WatchTheme.green)
                                        }
                                        Image(systemName: "plus.circle")
                                            .foregroundStyle(WatchTheme.gold)
                                    }
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(savingID != nil)
                        .accessibilityLabel("Log \(wearDurationLabel(durationMinutes)) with \(watch.name) on \(calendarDayLabel(selectedDay))")
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
        }
        .preferredColorScheme(.dark)
        .presentationDetents([.medium, .large])
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
