import SwiftUI

/// "Edit" on the Boxes tab: the boxes in tab order, each opening its form; reorder, delete, and "Add a box".
struct BoxManageSheet: View {
    @ObservedObject var store: AppStore
    @Binding var selectedBoxID: String
    @Environment(\.dismiss) private var dismiss
    @State private var deleting: WatchBox?
    @State private var adding = false

    private var boxes: [WatchBox] { store.data?.boxes ?? [] }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(boxes) { box in
                        NavigationLink {
                            BoxEditForm(store: store, box: box)
                        } label: {
                            row(box)
                        }
                    }
                    .onMove { source, destination in
                        Task { await store.moveBox(from: source, to: destination) }
                    }
                    .onDelete { offsets in
                        if let index = offsets.first, boxes.indices.contains(index) { deleting = boxes[index] }
                    }
                } footer: {
                    if boxes.count > 1 {
                        Text("The order here is the order of the tabs.")
                    }
                }
                Section {
                    Button("Add a box") { adding = true }
                        .disabled(boxes.count >= BoxModel.boxLimit)
                } footer: {
                    if boxes.count >= BoxModel.boxLimit {
                        Text("Up to \(BoxModel.boxLimit) boxes.")
                    }
                }
            }
            .navigationTitle("Boxes")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(role: .close) { dismiss() }
                }
                #if os(iOS)
                ToolbarItem(placement: .primaryAction) { EditButton() }
                #endif
            }
            .navigationDestination(isPresented: $adding) {
                BoxEditForm(store: store, box: nil) { added in selectedBoxID = added }
            }
            .confirmationDialog(
                "Delete \(deleting?.name ?? "this box")?",
                isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                titleVisibility: .visible
            ) {
                Button("Delete Box", role: .destructive) {
                    if let box = deleting { Task { await store.deleteBox(id: box.id) } }
                    deleting = nil
                }
                Button("Cancel", role: .cancel) { deleting = nil }
            } message: {
                Text("Its watches go back to the tray.")
            }
            .storeErrorAlert(store)
        }
        .desktopSheet(width: 460, height: 520)
    }

    private func row(_ box: WatchBox) -> some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(LinearGradient(
                    colors: [box.resolvedFinish == "brown" ? WatchTheme.Box.brown.frameLight : WatchTheme.Box.black.frameLight,
                             box.resolvedFinish == "brown" ? WatchTheme.Box.brown.frameDark : WatchTheme.Box.black.frameDark],
                    startPoint: .topLeading, endPoint: .bottomTrailing))
                // A hairline edge so the black swatch still reads on a dark row.
                .overlay {
                    RoundedRectangle(cornerRadius: 3, style: .continuous).strokeBorder(WatchTheme.separator, lineWidth: 0.5)
                }
                .frame(width: 30, height: 20)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(box.name)
                    .foregroundStyle(WatchTheme.ink)
                Text("\(BoxFinish(name: box.finish).label), \(box.columns) by \(box.rows), \(box.slots.count) of \(box.capacity) spaces used")
                    .font(AtelierType.caption)
                    .foregroundStyle(WatchTheme.muted)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// One box's name, finish and size, or a new box.
struct BoxEditForm: View {
    @ObservedObject var store: AppStore
    let box: WatchBox?
    var added: (String) -> Void = { _ in }
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var finish: String
    @State private var size: String
    @State private var confirmDelete = false
    @State private var saving = false

    init(store: AppStore, box: WatchBox?, added: @escaping (String) -> Void = { _ in }) {
        self.store = store
        self.box = box
        self.added = added
        _name = State(initialValue: box?.name ?? "")
        _finish = State(initialValue: box?.resolvedFinish ?? "black")
        _size = State(initialValue: box.map { "\($0.columns)x\($0.rows)" } ?? "6x2")
    }

    private var sizes: [(columns: Int, rows: Int)] {
        var options = BoxModel.sizePresets
        if let box, !options.contains(where: { $0.columns == box.columns && $0.rows == box.rows }) {
            options.append((box.columns, box.rows))
        }
        return options
    }

    private var chosen: (columns: Int, rows: Int) {
        let parts = size.split(separator: "x").compactMap { Int($0) }
        return parts.count == 2 ? (parts[0], parts[1]) : (6, 2)
    }

    /// Watches that will go back to the tray with the size chosen.
    private var displaced: Int {
        guard let box, box.columns != chosen.columns || box.rows != chosen.rows else { return 0 }
        return box.slots.count - BoxModel.resize(box, columns: chosen.columns, rows: chosen.rows).slots.count
    }

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $name)
                Picker("Finish", selection: $finish) {
                    ForEach(BoxModel.finishes, id: \.self) { finish in
                        Text(BoxFinish(name: finish).label).tag(finish)
                    }
                }
                .pickerStyle(.segmented)
            }
            Section {
                Picker("Size", selection: $size) {
                    ForEach(sizes.indices, id: \.self) { index in
                        let option = sizes[index]
                        Text("\(option.columns) by \(option.rows), \(option.columns * option.rows) spaces")
                            .tag("\(option.columns)x\(option.rows)")
                    }
                }
            } footer: {
                if displaced > 0 {
                    Text(displaced == 1 ? "1 watch goes back to the tray." : "\(displaced) watches go back to the tray.")
                }
            }
            if let box {
                Section {
                    Button("Delete Box", role: .destructive) { confirmDelete = true }
                } footer: {
                    Text("Its watches go back to the tray.")
                }
                .confirmationDialog("Delete \(box.name)?", isPresented: $confirmDelete, titleVisibility: .visible) {
                    Button("Delete Box", role: .destructive) {
                        Task {
                            await store.deleteBox(id: box.id)
                            dismiss()
                        }
                    }
                    Button("Cancel", role: .cancel) {}
                }
            }
        }
        .navigationTitle(box == nil ? "New Box" : "Edit Box")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(role: .confirm) { save() }
                    .disabled(BoxModel.cleanName(name) == nil || saving)
            }
        }
    }

    private func save() {
        guard let clean = BoxModel.cleanName(name) else { return }
        saving = true
        Task {
            if var box {
                box.name = clean
                box.finish = finish
                box.columns = chosen.columns
                box.rows = chosen.rows
                await store.updateBox(box)
            } else if let id = await store.addBox(name: clean, finish: finish, columns: chosen.columns, rows: chosen.rows) {
                added(id)
            }
            saving = false
            dismiss()
        }
    }
}
