import SwiftUI

@main
struct WatchCollectionApp: App {
    @StateObject private var store = AppStore()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        URLCache.shared = URLCache(
            memoryCapacity: 50 * 1024 * 1024,
            diskCapacity: 200 * 1024 * 1024,
            diskPath: "watch-images"
        )
    }

    var body: some Scene {
        WindowGroup {
            RootView(store: store)
                .tint(WatchTheme.accent)
                .task { await store.start() }
                .onChange(of: scenePhase, initial: true) { _, phase in store.sceneChanged(phase) }
        }
        .backgroundTask(.appRefresh(AppStore.backgroundSyncID)) {
            await store.start()
            await store.syncNow()
            await store.scheduleBackgroundSync()
        }
    }
}

struct RootView: View {
    @ObservedObject var store: AppStore
    @AppStorage("selectedTabV4") private var selectedTab = AppTab.collection.rawValue
    @State private var showSettings = false

    var body: some View {
        ZStack {
            WatchTheme.background.ignoresSafeArea()
            Group {
                if store.data != nil {
                    tabs
                } else if store.isRefreshing {
                    VStack(spacing: 14) {
                        ProgressView()
                        Text("Opening the collection…")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    VStack {
                        EmptyCollectionView(
                            title: "Collection unavailable",
                            detail: store.errorMessage ?? "No collection is stored on this iPhone yet."
                        )
                        Button("Open Settings") { showSettings = true }
                            .prominentButton()
                    }
                }
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(store: store)
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
                    .padding(.bottom, 84)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .task(id: notice) {
                        try? await Task.sleep(for: .seconds(2.5))
                        if store.notice == notice { store.notice = nil }
                    }
            }
        }
        .animation(.easeInOut, value: store.notice)
    }

    private var tabs: some View {
        TabView(selection: $selectedTab) {
            Tab("Collection", systemImage: "watch.analog", value: AppTab.collection.rawValue) {
                CollectionScreen(store: store, showSettings: { showSettings = true })
            }
            Tab("Insights", systemImage: "chart.bar.xaxis", value: AppTab.stats.rawValue) {
                StatsScreen(store: store, showSettings: { showSettings = true })
            }
            Tab("Wishlist", systemImage: "star", value: AppTab.wishlist.rawValue) {
                WishlistScreen(store: store, showSettings: { showSettings = true })
            }
            Tab(value: AppTab.search.rawValue, role: .search) {
                SearchScreen(store: store)
            }
        }
        .tabBarMinimizeBehavior(.onScrollDown)
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { store.errorMessage != nil && store.data != nil },
            set: { if !$0 { store.errorMessage = nil } }
        )
    }
}
