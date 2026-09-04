import SwiftUI

@main
struct WatchCollectionApp: App {
    @StateObject private var store = AppStore()

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
                .preferredColorScheme(.dark)
                .tint(WatchTheme.gold)
                .task { await store.start() }
        }
    }
}

struct RootView: View {
    @ObservedObject var store: AppStore
    @AppStorage("selectedTab") private var selectedTab = AppTab.collection.rawValue
    @State private var showSettings = false

    var body: some View {
        ZStack {
            WatchTheme.background.ignoresSafeArea()
            Group {
                if store.data != nil {
                    tabs
                } else if store.isRefreshing {
                    VStack(spacing: 14) {
                        ProgressView().tint(WatchTheme.gold)
                        Text("Opening the collection…")
                            .foregroundStyle(WatchTheme.secondary)
                    }
                } else {
                    EmptyCollectionView(
                        title: "Collection unavailable",
                        detail: store.errorMessage ?? "No collection is stored on this iPhone yet."
                    )
                }
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(store: store)
                .preferredColorScheme(.dark)
        }
        .alert("Watch Collection", isPresented: errorBinding) {
            Button("OK", role: .cancel) { store.errorMessage = nil }
        } message: {
            Text(store.errorMessage ?? "Unknown error")
        }
        .overlay(alignment: .bottom) {
            if let notice = store.notice {
                Text(notice)
                    .font(.footnote.weight(.semibold))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(WatchTheme.raised)
                    .clipShape(Capsule())
                    .overlay { Capsule().stroke(WatchTheme.gold.opacity(0.35)) }
                    .padding(.bottom, 72)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .task {
                        try? await Task.sleep(for: .seconds(2.5))
                        if store.notice == notice { store.notice = nil }
                    }
            }
        }
        .animation(.easeInOut, value: store.notice)
    }

    private var tabs: some View {
        TabView(selection: $selectedTab) {
            CollectionScreen(store: store, showSettings: { showSettings = true })
                .tag(AppTab.collection.rawValue)
                .tabItem { Label("Collection", systemImage: "square.grid.2x2") }
            PastScreen(store: store, showSettings: { showSettings = true })
                .tag(AppTab.past.rawValue)
                .tabItem { Label("Past", systemImage: "clock.arrow.circlepath") }
            StatsScreen(store: store, showSettings: { showSettings = true })
                .tag(AppTab.stats.rawValue)
                .tabItem { Label("Stats", systemImage: "chart.bar.xaxis") }
            WishlistScreen(store: store, showSettings: { showSettings = true })
                .tag(AppTab.wishlist.rawValue)
                .tabItem { Label("Wishlist", systemImage: "sparkles") }
        }
        .toolbarBackground(WatchTheme.card, for: .tabBar)
        .toolbarBackground(.visible, for: .tabBar)
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { store.errorMessage != nil && store.data != nil },
            set: { if !$0 { store.errorMessage = nil } }
        )
    }
}
