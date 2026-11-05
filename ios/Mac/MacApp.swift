import SwiftUI

@main
struct WatchCollectionMacApp: App {
    @StateObject private var store = AppStore()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // Graphite as this app's system accent, so controls stay monochrome with contrast the system
        // has tuned. The white Dark Mode accent made selected sidebar rows white on white.
        UserDefaults.standard.register(defaults: ["AppleAccentColor": -1])
    }

    var body: some Scene {
        Window("Watch Collection", id: "main") {
            MacRootView(store: store)
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
        Group {
            if store.data != nil {
                sections
            } else if store.isRefreshing {
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

    // Native tabs keep every section alive, so going back to one is instant and keeps its place.
    private var sections: some View {
        TabView(selection: $selectedTab) {
            Tab("Collection", systemImage: "watch.analog", value: AppTab.collection.rawValue) {
                CollectionScreen(store: store, showSettings: { openSettings() })
            }
            Tab("Insights", systemImage: "chart.bar.xaxis", value: AppTab.stats.rawValue) {
                StatsScreen(store: store, showSettings: { openSettings() })
            }
            Tab("Wishlist", systemImage: "star", value: AppTab.wishlist.rawValue) {
                WishlistScreen(store: store, showSettings: { openSettings() })
            }
            Tab("Search", systemImage: "magnifyingglass", value: AppTab.search.rawValue) {
                SearchScreen(store: store)
            }
        }
        .tabViewStyle(.sidebarAdaptable)
        .tabViewSidebarBottomBar {
            SyncStatusBar(status: store.status) {
                Task { await store.refresh() }
            }
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { store.errorMessage != nil && store.data != nil },
            set: { if !$0 { store.errorMessage = nil } }
        )
    }
}

/// Watches only the sync status, so a sync tick redraws this line and nothing else.
private struct SyncStatusBar: View {
    @ObservedObject var status: SyncStatus
    let syncNow: () -> Void

    var body: some View {
        Button(action: syncNow) {
            HStack(spacing: 8) {
                Circle()
                    .fill(status.message == "Up to date" ? Color.green : Color.yellow)
                    .frame(width: 7, height: 7)
                VStack(alignment: .leading, spacing: 1) {
                    Text(status.conflicts.isEmpty ? status.message : "\(status.conflicts.count) changes need a choice")
                        .lineLimit(2)
                    if let lastSync = status.lastSync {
                        Text("Synced \(lastSync.formatted(.relative(presentation: .named)))")
                            .foregroundStyle(.secondary)
                    }
                    if let phone = status.lastPhoneSync {
                        Text("iPhone \(phone.formatted(.relative(presentation: .named)))")
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.caption)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
        .help("Sync with the iPhone now")
    }
}
