import SwiftUI

@main
struct WatchCollectionMacApp: App {
    @StateObject private var store = AppStore()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        Window("Watch Collection", id: "main") {
            MacRootView(store: store)
                .tint(WatchTheme.accent)
                .frame(minWidth: 980, minHeight: 640)
                .task { await store.start() }
                .onChange(of: scenePhase, initial: true) { _, phase in store.sceneChanged(phase) }
        }
        .defaultSize(width: 1360, height: 880)
        .commands {
            CommandGroup(after: .toolbar) {
                Button("Sync Now") { Task { await store.refresh() } }
                    .keyboardShortcut("r")
            }
        }

        Settings {
            SettingsView(store: store)
                .tint(WatchTheme.accent)
                .frame(width: 560, height: 680)
        }
    }
}

/// Desktop shell: a sidebar in place of the phone's tab bar, sync state always in view.
struct MacRootView: View {
    @ObservedObject var store: AppStore
    @AppStorage("selectedTabV4") private var selectedTab = AppTab.collection.rawValue
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        NavigationSplitView {
            List(selection: selection) {
                Label("Collection", systemImage: "watch.analog").tag(AppTab.collection.rawValue)
                Label("Insights", systemImage: "chart.bar.xaxis").tag(AppTab.stats.rawValue)
                Label("Wishlist", systemImage: "star").tag(AppTab.wishlist.rawValue)
                Label("Search", systemImage: "magnifyingglass").tag(AppTab.search.rawValue)
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 260)
            .safeAreaInset(edge: .bottom) { syncStatus }
        } detail: {
            detail
        }
        .alert("Watch Collection", isPresented: errorBinding) {
            Button("OK", role: .cancel) { store.errorMessage = nil }
        } message: {
            Text(store.errorMessage ?? "Unknown error")
        }
        .overlay(alignment: .bottom) {
            if let notice = store.notice {
                Text(notice)
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
                    .glassEffect(.regular, in: .capsule)
                    .padding(.bottom, 24)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .task(id: notice) {
                        try? await Task.sleep(for: .seconds(2.5))
                        if store.notice == notice { store.notice = nil }
                    }
            }
        }
        .animation(.easeInOut, value: store.notice)
    }

    private var selection: Binding<String?> {
        Binding(get: { selectedTab }, set: { if let value = $0 { selectedTab = value } })
    }

    @ViewBuilder
    private var detail: some View {
        if store.data == nil {
            if store.isRefreshing || store.isSyncing {
                VStack(spacing: 14) {
                    ProgressView()
                    Text("Opening the collection…").foregroundStyle(.secondary)
                }
            } else {
                VStack {
                    EmptyCollectionView(title: "Collection unavailable", detail: store.syncMessage)
                    Button("Open Settings") { openSettings() }.prominentButton()
                }
            }
        } else {
            // Each screen owns its navigation stack, so switching sections keeps its place.
            switch AppTab(rawValue: selectedTab) ?? .collection {
            case .collection: CollectionScreen(store: store, showSettings: { openSettings() })
            case .stats: StatsScreen(store: store, showSettings: { openSettings() })
            case .wishlist: WishlistScreen(store: store, showSettings: { openSettings() })
            case .search: SearchScreen(store: store)
            }
        }
    }

    private var syncStatus: some View {
        Button {
            Task { await store.refresh() }
        } label: {
            HStack(spacing: 8) {
                if store.isSyncing {
                    ProgressView().controlSize(.small)
                } else {
                    Circle()
                        .fill(store.syncMessage == "Up to date" ? Color.green : Color.yellow)
                        .frame(width: 7, height: 7)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(store.syncConflicts.isEmpty ? store.syncMessage : "\(store.syncConflicts.count) changes need a choice")
                        .lineLimit(2)
                    if let lastSync = store.lastSync {
                        Text("Synced \(lastSync.formatted(.relative(presentation: .named)))")
                            .foregroundStyle(.secondary)
                    }
                    if let phone = store.lastPhoneSync {
                        Text("iPhone \(phone.formatted(.relative(presentation: .named)))")
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.caption)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
            .padding(12)
        }
        .buttonStyle(.plain)
        .help("Sync with the iPhone now")
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { store.errorMessage != nil && store.data != nil },
            set: { if !$0 { store.errorMessage = nil } }
        )
    }
}
