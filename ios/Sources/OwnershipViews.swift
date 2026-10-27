import SwiftUI

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
                Group {
                    Section("New record") {
                        Picker("Type", selection: $kind) {
                            ForEach(kinds, id: \.self) { Text($0).tag($0) }
                        }
                        DatePicker("Completed", selection: $serviceDate, in: ...Date(), displayedComponents: .date)
                        NumberField("Cost (CAD)", value: $cost)
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
                .listRowBackground(WatchTheme.card)
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
