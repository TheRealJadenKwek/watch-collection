import AppKit
import SwiftUI

/// Decides what this launch is before SwiftUI starts: the DEBUG CloudKit check, one headless bridge tick for the
/// LaunchAgent (`-WCBridge 1`), or the app. The app first takes the sync lock and holds it for life, so a bridge tick
/// never writes the library while the app is open (docs/icloud-plan.md section 11 P5).
@main
enum Entry {
    static func main() {
        #if DEBUG
        if let folder = CloudKitCheck.folder { CloudKitCheck.runAndExit(folder) }
        #endif
        if Bridge.requested { Bridge.runAndExit() }
        // Before anything reads `sync.json`. It waits briefly for a running tick to step aside, and never stops the
        // app: past its patience, or with no lock file, the app carries on (and says so in the log).
        let lock = SyncLock(url: SyncLock.appURL)
        lock.holdForApp()
        withExtendedLifetime(lock) { WatchCollectionMacApp.main() }
    }
}

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
    @State private var mounted: Set<String> = []
    /// Pages open in each section, so going back to a section returns to where you were in it.
    @State private var paths: [String: NavigationPath] = [:]

    var body: some View {
        Group {
            if store.data != nil {
                sections
            } else if store.isRefreshing || store.waitsForICloud {
                VStack(spacing: 14) {
                    ProgressView()
                    Text(store.isRefreshing ? "Opening the collection…" : "Waiting for your collection from iCloud…")
                        .foregroundStyle(.secondary)
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
        #if DEBUG
        .task {
            // `-atelierProbe settings` opens Settings, for screenshots.
            guard AtelierProbe.opensSettings else { return }
            try? await Task.sleep(for: .seconds(3))
            openSettings()
        }
        #endif
    }

    // Every section stays alive behind the current one, so switching only cross-fades what's
    // already drawn. Building one on demand froze the window for up to a quarter of a second.
    private var sections: some View {
        NavigationSplitView {
            MacSidebar(selection: $selectedTab) { paths[selectedTab] = NavigationPath() }
                .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 260)
                .safeAreaInset(edge: .bottom) {
                    SyncStatusBar(status: store.status) {
                        Task { await store.refresh() }
                    } restartCloud: {
                        Task { await store.restartCloudAfterErase() }
                    }
                }
        } detail: {
            NavigationStack(path: currentPath) {
                ZStack {
                    ForEach(AppTab.allCases, id: \.rawValue) { tab in
                        if mounted.contains(tab.rawValue) || tab.rawValue == selectedTab {
                            KeptSection(tab: tab, store: store, isActive: tab.rawValue == selectedTab)
                                .zIndex(tab.rawValue == selectedTab ? 1 : 0)
                        }
                    }
                }
                .navigationDestination(for: WatchRoute.self) { route in
                    WatchDossierView(store: store, watchID: route.id)
                        .desktopPageAppear()
                }
                .navigationDestination(for: YearRoute.self) { route in
                    YearPurchasesScreen(store: store, year: route.year, ownedOnly: route.ownedOnly)
                        .desktopPageAppear()
                }
                .navigationDestination(for: TimelineRoute.self) { route in
                    TimelinePresentationScreen(store: store, ownedOnly: route.ownedOnly)
                        .desktopPageAppear()
                }
            }
            .environment(\.openPage) { page in
                var path = paths[selectedTab] ?? NavigationPath()
                path.append(page)
                paths[selectedTab] = path
            }
        }
        .toolbar(removing: .title)
        .task {
            // One at a time, so launch never stalls for all of them at once.
            for tab in AppTab.allCases where !mounted.contains(tab.rawValue) {
                try? await Task.sleep(for: .milliseconds(200))
                mounted.insert(tab.rawValue)
            }
        }
    }

    private var currentPath: Binding<NavigationPath> {
        Binding(
            get: { paths[selectedTab] ?? NavigationPath() },
            set: { paths[selectedTab] = $0 }
        )
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { store.errorMessage != nil && store.data != nil },
            set: { if !$0 { store.errorMessage = nil } }
        )
    }
}

/// One section of the app. `showSettings` is unused on the Mac, and a closure that captures nothing
/// compares as unchanged, so switching sections doesn't rebuild the screens themselves.
private struct KeptSection: View {
    let tab: AppTab
    let store: AppStore
    let isActive: Bool

    var body: some View {
        Group {
            switch tab {
            case .collection: CollectionScreen(store: store, showSettings: {})
            case .boxes: BoxesScreen(store: store, showSettings: {})
            case .stats: StatsScreen(store: store, showSettings: {})
            case .wishlist: WishlistScreen(store: store, showSettings: {})
            case .search: SearchScreen(store: store)
            }
        }
        .environment(\.sectionIsActive, isActive)
        .opacity(isActive ? 1 : 0)
        .allowsHitTesting(isActive)
        .accessibilityHidden(!isActive)
        .animation(.easeOut(duration: 0.2), value: isActive)
    }
}

/// The sidebar, drawn by the app because the system's has no hover state: the row under the mouse
/// lights up, and the selection slides to the row you pick.
private struct MacSidebar: View {
    @Binding var selection: String
    /// Clicking the section you're already in goes back to its main screen.
    let reselect: () -> Void
    @State private var hovered: String?
    @Namespace private var highlight

    private let items: [(tab: AppTab, title: String, symbol: String)] = [
        (.collection, "Collection", "watch.analog"),
        (.boxes, "Boxes", "square.grid.3x2"),
        (.stats, "Insights", "chart.bar.xaxis"),
        (.wishlist, "Wishlist", "star"),
        (.search, "Search", "magnifyingglass"),
    ]

    var body: some View {
        VStack(spacing: 2) {
            ForEach(Array(items.enumerated()), id: \.element.title) { index, item in
                row(item.title, symbol: item.symbol, value: item.tab.rawValue, shortcut: index + 1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.top, 4)
        .animation(.easeOut(duration: 0.1), value: hovered)
        .animation(.easeInOut(duration: 0.22), value: selection)
    }

    private func row(_ title: String, symbol: String, value: String, shortcut: Int) -> some View {
        let isSelected = selection == value
        return Button {
            if isSelected { reselect() } else { selection = value }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .frame(width: 20)
                    .foregroundStyle(isSelected ? .primary : .secondary)
                Text(title)
                    .fontWeight(isSelected ? .semibold : .regular)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Color.primary.opacity(0.16))
                        .matchedGeometryEffect(id: "selection", in: highlight)
                } else if hovered == value {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Color.primary.opacity(0.08))
                }
            }
        }
        .buttonStyle(.plain)
        .onHover { inside in
            if inside { hovered = value } else if hovered == value { hovered = nil }
        }
        .keyboardShortcut(KeyEquivalent(Character("\(shortcut)")), modifiers: .command)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// Watches only the sync status, so a sync tick redraws this line and nothing else.
private struct SyncStatusBar: View {
    @ObservedObject var status: SyncStatus
    let syncNow: () -> Void
    /// "Sync through iCloud again", shown only after he erased the app's iCloud data.
    let restartCloud: () -> Void

    var body: some View {
        let cloudLine = status.cloud.flatMap { CloudSyncCopy.sentence($0, device: Platform.deviceName) }
        VStack(alignment: .leading, spacing: 6) {
            Button(action: syncNow) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(status.message == "Up to date" && !cloudNeedsAttention ? Color.green : Color.yellow)
                        .frame(width: 7, height: 7)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(status.conflicts.isEmpty ? status.message : "\(status.conflicts.count) changes need a choice")
                            .lineLimit(2)
                        if let lastSync = status.lastSync {
                            Text("Synced \(lastSync.formatted(.relative(presentation: .named)))")
                                .foregroundStyle(.secondary)
                        }
                        if let phone = status.lastPhoneSync {
                            // With iCloud on, the iPhone's own Status record says when it last synced.
                            Text(status.cloud == nil
                                 ? "iPhone \(phone.formatted(.relative(presentation: .named)))"
                                 : CloudSyncCopy.phoneSeen(phone, now: Date()))
                                .foregroundStyle(.secondary)
                        }
                        if let cloudLine {
                            Text(cloudLine)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .font(.caption)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Sync with the iPhone now")
            if status.cloud?.wait == .erased {
                Button(CloudSyncCopy.restartButton, action: restartCloud)
                    .controlSize(.small)
                    .disabled(status.isSyncing)
                    .padding(.leading, 15)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    /// An iCloud state that needs him (the photo upload and the wait for the library are only progress).
    private var cloudNeedsAttention: Bool {
        guard let cloud = status.cloud else { return false }
        switch cloud.wait {
        case .noAccount?, .full?, .newerFormat?, .erased?: return true
        default: return cloud.otherConflicts > 0
        }
    }
}
