import SwiftUI

@main
struct WatchCollectionApp: App {
    /// Lets only a folding iPhone's inner screen turn; everything else stays upright.
    @UIApplicationDelegateAdaptor(WatchAppDelegate.self) private var appDelegate
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
            // Every view below reads how a folding iPhone is held from `@Environment(\.duo)`.
            DuoRoot { RootView(store: store) }
                .tint(WatchTheme.accent)
                .task { await store.start() }
                .onChange(of: scenePhase, initial: true) { _, phase in store.sceneChanged(phase) }
                #if DEBUG
                .task { await DuoSnapshot.runIfAsked(store: store) }
                #endif
        }
        .backgroundTask(.appRefresh(AppStore.backgroundSyncID)) {
            // One tick, the document only: missing photos are fetched when the app is next open.
            await store.backgroundRefresh()
        }
    }
}

struct RootView: View {
    @ObservedObject var store: AppStore
    @AppStorage("selectedTabV4") private var selectedTab = AppTab.collection.rawValue
    @State private var showSettings = false
    @State private var windowWidth: CGFloat = 0
    @Environment(\.duo) private var duo

    var body: some View {
        ZStack {
            WatchTheme.background.ignoresSafeArea()
            Group {
                if store.data != nil {
                    tabs
                } else if store.isRefreshing || store.waitsForICloud {
                    // With no collection and no address, it waits for iCloud rather than asking for an address.
                    VStack(spacing: 14) {
                        ProgressView()
                        Text(store.isRefreshing ? "Opening the collection…" : "Waiting for your collection from iCloud…")
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
        // Every screen takes its side margin from the window width: narrower on small phones. A folding
        // iPhone's cover and inner screen take the Duo gutter instead.
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { windowWidth = $0 }
        .environment(\.pageMargin, duo.pageMargin(phone: WatchTheme.margin(forWidth: windowWidth)))
        #if DEBUG
        .task {
            guard AtelierProbe.opensSettings else { return }
            try? await Task.sleep(for: .seconds(4))
            showSettings = true
        }
        #endif
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
            Tab("Boxes", systemImage: "square.grid.3x2", value: AppTab.boxes.rawValue) {
                BoxesScreen(store: store, showSettings: { showSettings = true })
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
