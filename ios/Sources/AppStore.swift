import Foundation
import SwiftUI
import Network
#if canImport(BackgroundTasks) && os(iOS)
import BackgroundTasks
#endif

enum LocalStoreError: LocalizedError {
    case missingData
    case itemNotFound
    case duplicateValue
    case valueInUse(Int)
    case invalidOperation
    case saveFailed

    var errorDescription: String? {
        switch self {
        case .missingData: "No collection data is stored on this \(Platform.deviceName) yet."
        case .itemNotFound: "That item is no longer in the collection."
        case .duplicateValue: "That name already exists."
        case let .valueInUse(count): "Cannot delete this value because it is used by \(count) item(s). Reassign them first."
        case .invalidOperation: "That change could not be applied."
        case .saveFailed: "The collection could not be saved. Check the \(Platform.deviceName)'s available storage and try again."
        }
    }
}

/// Sync progress, kept apart from the collection so a sync tick only redraws what shows its status,
/// not every screen and photo in the app.
@MainActor
final class SyncStatus: ObservableObject {
    @Published var isSyncing = false
    @Published var message = "Waiting to sync"
    @Published var conflicts: [SyncConflict] = []
    /// The choices made so far for `conflicts`, by conflict id. A conflict with a choice no longer holds sync up.
    @Published var resolutions: [String: String] = [:]
    /// The last settled pass of either link.
    @Published var lastSync: Date?
    /// The Mac: when the iPhone last finished a sync, through the hub or through iCloud (`status-iphone.at`).
    @Published var lastPhoneSync: Date?
    /// Why an attempt of this session did not finish; nil once one reaches the Mac. The store's `SyncFailureLog`
    /// sets it, and `SyncHealth` reads it.
    @Published var failure: SyncFailure?
    /// The iCloud link, for the screens; nil on a device with no iCloud link.
    @Published var cloud: CloudDisplay?
}

@MainActor
final class AppStore: ObservableObject {
    @Published private(set) var data: CollectionData?
    /// Bumped each time the phone's fill has brought pictures from iCloud, so the boxes draw tiles that were missing.
    @Published private(set) var picturesLanded = 0
    @Published private(set) var scores: [String: WishlistScore] = [:]
    @Published private(set) var suggestions: SuggestionsResponse?
    @Published private(set) var isOffline = false
    @Published private(set) var isRefreshing = false
    @Published var errorMessage: String?
    @Published var notice: String?
    let status = SyncStatus()
    private(set) var syncMessage: String {
        get { status.message }
        set { if status.message != newValue { status.message = newValue } }
    }
    private(set) var isSyncing: Bool {
        get { status.isSyncing }
        set { if status.isSyncing != newValue { status.isSyncing = newValue } }
    }
    /// Every change waiting for a choice, from either link.
    var syncConflicts: [SyncConflict] { status.conflicts }
    /// The last settled pass of either link.
    var lastSync: Date? { status.lastSync }
    /// The changes each link is waiting on, and the choices made for them. `status` shows them together.
    private var conflictSet = SyncConflictSet() {
        didSet {
            let all = conflictSet.all
            if !(status.conflicts.isEmpty && all.isEmpty) { status.conflicts = all }
            let resolutions = conflictSet.resolutions
            if status.resolutions != resolutions { status.resolutions = resolutions }
        }
    }
    /// The hub link's last success, kept in `sync.json`.
    private var hubLastSuccess: Date? {
        didSet { showLastSync() }
    }
    /// When the hub last heard from a device other than this Mac (its `lastRemoteSync`).
    private var hubPhoneSync: Date? {
        didSet { showPhoneSync() }
    }
    /// The Mac: `status-iphone.at` as the last cloud pass read it.
    private var phoneStatusAt: Date?
    /// When the failure the sync notice reads is set and cleared; `status.failure` follows it.
    private var syncFailures = SyncFailureLog() {
        didSet { if status.failure != syncFailures.failure { status.failure = syncFailures.failure } }
    }
    @Published private(set) var syncEnabled = AppStore.initialSyncEnabled
    /// Wishlist watches being tried in a box, on this device only (never in the document).
    @Published private(set) var boxTrial = BoxTrial.load()
    /// What the Boxes tab should show when it next appears (set by the watch page and the wishlist).
    @Published var boxIntent: BoxIntent?
    @Published private(set) var syncAddress = AppStore.initialSyncAddress

    static let backgroundSyncID = "com.jadenkwek.watchcollection.refresh"
    private var syncBase: CollectionData?
    private var editGeneration = 0
    private var connectionMonitor: NWPathMonitor?
    private var syncTimer: Task<Void, Never>?
    /// The app has been in the background since the last visit began (true at launch, so the first visit starts one).
    private var returningFromBackground = true
    // What the last full sync settled on. If neither side has moved since, there is nothing to do.
    private var syncedRevision: String?
    private var syncedGeneration = -1
    private var lastSyncAttempt = Date.distantPast
    /// The iPhone seeds the starting boxes after its first sync of a launch that finds none.
    private var seedAfterSync = false
    /// The hub of this launch's last completed sync keeps boxes (its snapshot lists "boxes" in its features).
    @Published private(set) var hubSupportsBoxes = false

    // The iCloud link (docs/icloud-plan.md). Its state for the screens is `status.cloud`, never published here.
    /// Which side of the iCloud link this device plays.
    private let cloudRole: CloudRole = AppStore.initialRole
    /// nil wherever `CloudKitStore.live()` is: the app then syncs with the hub exactly as before.
    private var cloud: CloudSyncSession?
    /// The phone has installed from iCloud: iCloud is its link from then on (section 6).
    private var cloudJoinedOnce = UserDefaults.standard.bool(forKey: AppPaths.defaultsKey("cloudJoinedOnce"))
    /// The phone's "Sync directly with the Mac instead".
    private var preferHub = UserDefaults.standard.bool(forKey: AppPaths.defaultsKey("cloudPreferHub"))
    /// `contentVersion` and where each link last settled (section 4).
    private var versions = SyncVersions()
    /// The edit generation at which this tick's hub pass finished clean; nil when it did not (`hubSettledNow`).
    private var hubSettledAt: Int?
    /// Why the last cloud pass stopped short.
    private var cloudWait: CloudWait?
    /// A cloud pass of this launch settled (the starting layout may be offered on its word, as on a box hub's).
    private var cloudSettledThisLaunch = false
    /// The network is neither expensive nor constrained: the phone may fetch missing photos in bulk. False until the
    /// path monitor first says so.
    private var pathAllowsBulk = false
    private var fillTask: Task<Void, Never>?
    /// Moves when a fill is cancelled, so a cancelled fill finishing late never clears a newer one's slot.
    private var fillGeneration = 0
    /// D5: the link whose next pass merges with no base, after the phone's switch flipped which link is active.
    private var baselessNext = SyncLinkKind(
        rawValue: UserDefaults.standard.string(forKey: AppPaths.defaultsKey("cloudSwitchBaseless")) ?? "")
    /// A background refresh: the cloud pass fetches no photos afterwards.
    private var documentOnly = false
    #if DEBUG
    /// `-WCCloudStatus`: the screens show a made-up iCloud state and nothing syncs.
    private var forcedCloud = false
    #endif

    /// What this tick runs (section 1): the Mac both links, the phone exactly one.
    private var route: SyncRoute {
        SyncRoute.plan(role: cloudRole, cloudLink: cloud != nil, joined: cloudJoinedOnce, preferHub: preferHub)
    }

    /// The phone has no collection and nothing to ask for one but iCloud: the empty state waits for it instead of
    /// asking for an address.
    var waitsForICloud: Bool {
        data == nil && syncEnabled && syncAddress.isEmpty && status.cloud != nil
    }

    /// The starting layout (the iPhone's seed and "Use the starting layout") waits for a completed sync
    /// with a hub that keeps boxes, or a settled pass with iCloud (whose merge keeps boxes), so it never lands on
    /// top of boxes set up elsewhere nor goes to a hub that would drop it. With sync off it is there at once.
    var canOfferStartingLayout: Bool {
        Self.startingLayoutAllowed(syncOn: syncEnabled && (!syncAddress.isEmpty || route.active == .cloud),
                                   hubSupportsBoxes: hubSupportsBoxes || cloudSettledThisLaunch)
    }

    nonisolated static func startingLayoutAllowed(syncOn: Bool, hubSupportsBoxes: Bool) -> Bool {
        !syncOn || hubSupportsBoxes
    }

    private var started = false

    /// The hub address: in DEBUG `-WCHub` stands in for the saved one for this run (only with `-WCDataRoot`).
    static var initialSyncAddress: String {
        #if DEBUG
        if let hub = AppPaths.hub { return hub }
        #endif
        return UserDefaults.standard.string(forKey: AppPaths.defaultsKey("syncAddress"))
            ?? LegacyServerConfiguration.migrationURL ?? Platform.defaultSyncAddress
    }

    /// Automatic sync, on unless he turned it off.
    static var initialSyncEnabled: Bool {
        UserDefaults.standard.object(forKey: AppPaths.defaultsKey("syncEnabled")) as? Bool ?? true
    }

    /// Polish 3: the launch's JSON mirror. A bridge tick is a fresh launch every minute; it mirrors only after a
    /// tick that installed something (the installs do that themselves).
    nonisolated static func mirrorsAtLaunch(autoBackup: Bool, bridge: Bool) -> Bool {
        autoBackup && !bridge
    }

    /// Polish 6: the hub revision a bridge run starts its fast path from, when `sync.json` was last written by a
    /// settled hub pass with this address and nothing has written it since; else nil (a full exchange, as today).
    nonisolated static func hubRevisionAtLaunch(_ checkpoint: SyncCheckpoint?, address: String,
                                                bridge: Bool) -> String? {
        guard bridge, let checkpoint, checkpoint.server == address else { return nil }
        return checkpoint.revision
    }

    private static var initialRole: CloudRole {
        #if DEBUG
        if let role = AppPaths.role { return role }
        #endif
        return Platform.isMac ? .mac : .phone
    }

    func start() async {
        guard !started else { return }
        started = true
        isRefreshing = true
        defer { isRefreshing = false }

        let checkpoint = SyncDisk.load()
        if let checkpoint {
            syncBase = checkpoint.server == syncAddress ? checkpoint.base : nil
            hubLastSuccess = checkpoint.lastSuccess
            publish(checkpoint.data, persist: false)
        } else if let cached = CacheStore.loadData() {
            publish(cached, persist: true)
        }
        setUpCloud()
        if let revision = Self.hubRevisionAtLaunch(checkpoint, address: syncAddress, bridge: AppPaths.bridgeRun) {
            // Nothing has moved here since that hub pass: unless the hub has, this tick needs no exchange.
            syncedRevision = revision
            syncedGeneration = editGeneration
            versions.settle(.hub)
        }

        // Never replace a populated standalone phone with the old migration snapshot.
        startConnectionMonitor()
        await syncNow()
        if !Platform.isMac {
            // Only after the hub has had its say: a phone that has not completed a sync with a hub that
            // keeps boxes waits for one, so the seed never lands on top of boxes set up elsewhere.
            if canOfferStartingLayout {
                await seedBoxesIfNeeded()
            } else {
                seedAfterSync = true
            }
        }

        if let data, Self.mirrorsAtLaunch(autoBackup: data.settings.autoBackup, bridge: AppPaths.bridgeRun) {
            _ = try? AppPaths.mirrorJSON(from: data)
        }

        if data == nil, !waitsForICloud {
            errorMessage = "Set the Mac's sync address in Settings, or restore a collection backup."
        }
    }

    /// The background refresh: one tick that fetches no photos afterwards.
    func backgroundRefresh() async {
        documentOnly = true
        defer { documentOnly = false }
        await start()
        await syncNow()
        scheduleBackgroundSync()
    }

    func refresh() async {
        isRefreshing = true
        await syncNow()
        isRefreshing = false
    }

    func configureSync(enabled: Bool, address: String) async {
        let clean = address.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if clean != syncAddress {
            syncBase = nil
            syncedRevision = nil
            hubLastSuccess = nil
            hubSupportsBoxes = false
            conflictSet.clear(.hub)
        }
        syncAddress = clean
        syncEnabled = enabled
        // The next attempt speaks for the new settings, and one still running for the old ones cannot fail over it.
        syncFailures.startSession()
        editGeneration += 1
        UserDefaults.standard.set(clean, forKey: AppPaths.defaultsKey("syncAddress"))
        UserDefaults.standard.set(enabled, forKey: AppPaths.defaultsKey("syncEnabled"))
        if let data { publish(data, persist: true) }
        await syncNow()
        scheduleBackgroundSync()
    }

    /// The choice goes to the link that asked. Once every one of that link's changes has a choice, a tick sends them.
    func resolveSyncConflict(_ id: String, choice: String) async {
        guard conflictSet.resolve(id, choice: choice) != nil else { return }
        while isSyncing { try? await Task.sleep(for: .milliseconds(200)) }
        await syncNow()
    }

    /// The phone's "Sync directly with the Mac instead": flips which link runs. The first pass of the link that
    /// becomes active merges with no base (D5): union, nothing deleted, differing fields ask. Its base may be far
    /// behind or ahead of the other link's, and a three-way merge would read the gap as deletes and reverts.
    func setPreferHub(_ on: Bool) async {
        guard cloudRole == .phone, preferHub != on else { return }
        let before = route
        preferHub = on
        UserDefaults.standard.set(on, forKey: AppPaths.defaultsKey("cloudPreferHub"))
        if let link = SyncRoute.baselessAfterFlip(from: before, to: route) { setBaselessNext(link) }
        // What failed on the other link says nothing about this one.
        syncFailures.startSession()
        configurePhotoSource()
        showCloud()
        while isSyncing { try? await Task.sleep(for: .milliseconds(200)) }
        await syncNow()
        scheduleBackgroundSync()
    }

    /// The Mac's "Sync through iCloud again", after he erased the app's iCloud data (section 8).
    func restartCloudAfterErase() async {
        guard let cloud, cloudRole == .mac else { return }
        while isSyncing { try? await Task.sleep(for: .milliseconds(200)) }
        isSyncing = true
        let failure = await cloud.restartAfterErase()
        isSyncing = false
        cloudWait = failure
        showCloud()
        if failure == nil { await syncNow() }
    }

    func sceneChanged(_ phase: ScenePhase) {
        #if os(macOS)
        // A desktop window stays on screen unfocused, so keep it current the whole time it's open.
        guard syncTimer == nil else {
            if phase == .active { Task { await syncNow() } }
            return
        }
        syncTimer = Task { [weak self] in
            while !Task.isCancelled {
                await self?.syncNow()
                do { try await Task.sleep(for: .seconds(15)) } catch { break }
            }
        }
        #else
        syncTimer?.cancel()
        if phase == .active {
            // A new visit. What failed before (an earlier visit, the overnight refresh) says nothing about now: the
            // notice waits for an attempt of this visit to fail. An attempt still running from before, which turns
            // away the timer's first one, cannot bring the old failure back. Only after the background: a glance at
            // Control Center or a system alert is the same visit, and a notice already up stays up.
            if returningFromBackground {
                syncFailures.startSession()
                returningFromBackground = false
            }
            syncTimer = Task { [weak self] in
                while !Task.isCancelled {
                    await self?.syncNow()
                    // Every 20 s once iCloud carries the phone; the hub's 60 s otherwise.
                    let seconds = self?.route.active == .cloud ? 20 : 60
                    do { try await Task.sleep(for: .seconds(seconds)) } catch { break }
                }
            }
        } else if phase == .background {
            returningFromBackground = true
            // The fill fetches only while the app is on screen (C1 4); the next settled pass starts it again.
            cancelFill()
            scheduleBackgroundSync()
        }
        #endif
    }

    func scheduleBackgroundSync() {
        #if os(iOS)
        guard syncEnabled, !syncAddress.isEmpty || route.active == .cloud else { return }
        let request = BGAppRefreshTaskRequest(identifier: Self.backgroundSyncID)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        // The system determines the actual launch time; foreground sync is the fallback.
        try? BGTaskScheduler.shared.submit(request)
        #endif
    }

    private func startConnectionMonitor() {
        guard connectionMonitor == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let bulk = !path.isExpensive && !path.isConstrained
            Task { @MainActor [weak self] in self?.pathAllowsBulk = bulk }
            guard path.status == .satisfied else { return }
            Task { @MainActor [weak self] in
                // VPNs and Tailscale report path changes constantly; only a real gap is worth a sync.
                guard let self, Date().timeIntervalSince(self.lastSyncAttempt) > 10 else { return }
                await self.syncNow()
            }
        }
        monitor.start(queue: DispatchQueue(label: "watch-collection.connection"))
        connectionMonitor = monitor
    }

    /// One sync tick, over the links `route` names: the hub alone (no iCloud link, or the phone's switch), iCloud
    /// alone (a phone that has joined), iCloud then the hub only if iCloud did nothing (a phone not joined yet), or
    /// on the Mac the hub, iCloud, and the hub again when iCloud brought something in. True when the link the
    /// screens speak for settled.
    @discardableResult
    func syncNow() async -> Bool {
        guard started, !isSyncing else { return false }
        #if DEBUG
        if forcedCloud { return false }
        #endif
        guard syncEnabled else { syncMessage = "Automatic sync is off"; return false }
        lastSyncAttempt = Date()
        isSyncing = true
        defer { isSyncing = false }
        // The route as the tick began: a phone that joins iCloud in this tick's cloud pass does not then run the hub.
        let route = self.route
        var ran: [SyncLinkKind] = []
        var tick: CloudTick?
        var settled = false
        while let link = route.next(after: ran, cloud: tick) {
            switch link {
            case .hub:
                settled = await hubPass()
            case .cloud:
                tick = await cloudPass()
                if route.active == .cloud || route == .cloudElseHub { settled = Self.settles(tick?.outcome) }
            }
            ran.append(link)
        }
        return settled
    }

    private static func settles(_ outcome: CloudOutcome?) -> Bool {
        switch outcome {
        case .installed?, .upToDate?: return true
        default: return false
        }
    }

    /// The hub link, as it always was. Sets `hubSettledAt` when it finishes clean.
    private func hubPass() async -> Bool {
        hubSettledAt = nil
        guard !syncAddress.isEmpty else { syncMessage = "Add the Mac's address in Settings"; return false }
        let address = syncAddress
        let session = syncFailures.session
        do {
            let client = try CollectionSyncClient(address: address)
            for _ in 0..<3 {
                let generation = editGeneration
                let local = data
                let remote = try await client.snapshot()
                // The Mac answered: an earlier failure does not hold, even if every round below is overtaken by
                // edits and the attempt runs out without finishing.
                syncFailures.reachedMac()
                if let stamp = remote.lastRemoteSync { hubPhoneSync = ISO8601DateFormatter().date(from: stamp) }
                // Neither side changed: skip the upload, the disk writes and the redraw. "This side" includes what
                // the iCloud link brought in since the hub link last settled (`versions`).
                if generation == syncedGeneration, remote.revision == syncedRevision, versions.isCurrent(.hub),
                   conflictSet.resolutions(for: .hub).isEmpty, conflictSet.conflicts(for: .hub).isEmpty, let local,
                   PhotoStore.missingLocalCount(PhotoStore.assets(in: local, baseURL: nil)) == 0 {
                    hubLastSuccess = Date()
                    hubSettledAt = generation
                    syncMessage = "Up to date"
                    if isOffline { isOffline = false }
                    noteHub(remote)
                    clearBaseless(.hub)
                    seedIfWaiting()
                    return true
                }
                syncMessage = "Syncing collection and photos..."
                let result: SyncSnapshot
                if let local {
                    // With iCloud on, a file neither here nor on the hub may still come from iCloud: its reference is
                    // dropped only once iCloud has said it does not have it (section 5), and only while iCloud can
                    // answer (D4); otherwise as before iCloud. The phone, which holds photos lazily, asks for them
                    // first (C1 10).
                    var dropping: Set<String>?
                    if let cloud {
                        if cloudRole == .phone, cloudJoinedOnce {
                            await cloud.fetch(CollectionSyncClient.goneFiles(local: local, remote: remote))
                        }
                        dropping = await cloud.namesNotInCloud()
                    }
                    // D5: the first hub pass after the phone's switch made the hub its link again has no base.
                    let base = baselessNext == .hub ? nil : syncBase
                    guard let exchanged = try await client.exchange(base: base, local: local,
                                                                    resolutions: conflictSet.resolutions(for: .hub),
                                                                    remote: remote, dropping: dropping) else {
                        syncMessage = "Waiting for photos from iCloud"
                        return false
                    }
                    result = exchanged
                } else { result = remote }
                guard syncAddress == address, syncEnabled else { return false }
                // Do not install a response over edits made while a request was in flight.
                guard generation == editGeneration else { continue }
                if !result.conflicts.isEmpty {
                    conflictSet.set(result.conflicts.map { $0.labelled(using: [local, result.data]) }, for: .hub)
                    syncMessage = "\(result.conflicts.count) changes need your choice in Settings"
                    return false
                }
                try await client.downloadPhotos(result.data)
                try Task.checkCancellation()
                guard generation == editGeneration, syncAddress == address, syncEnabled else { continue }
                var merged = BoxModel.installing(result.data, hubSupportsBoxes: result.supportsBoxes, local: local)
                if let local {
                    merged.settings.autoBackup = local.settings.autoBackup
                    merged.settings.backupRemote = local.settings.backupRemote
                    merged.settings.lastBackup = local.settings.lastBackup
                }
                let now = Date()
                try SyncDisk.save(SyncCheckpoint(data: merged, base: result.data, server: address, lastSuccess: now,
                                                 revision: AppPaths.bridgeRun ? result.revision : nil))
                syncBase = result.data
                syncedRevision = result.revision
                syncedGeneration = generation
                hubLastSuccess = now
                publish(merged, persist: false)
                versions.settle(.hub)
                hubSettledAt = generation
                CacheStore.save(merged)
                if merged.settings.autoBackup { _ = try? AppPaths.mirrorJSON(from: merged) }
                conflictSet.clear(.hub)
                syncMessage = "Up to date"
                if isOffline { isOffline = false }
                noteHub(result)
                clearBaseless(.hub)
                seedIfWaiting()
                return true
            }
            syncMessage = "New edits are saved locally; sync will retry"
        } catch is CancellationError {
            syncMessage = "Saved on this \(Platform.deviceName); sync will resume"
        } catch {
            syncMessage = "Saved on this \(Platform.deviceName). \(error.localizedDescription)"
            syncFailures.failed(error, in: session)
            // Keep local editing enabled when the sync server is unreachable.
        }
        return false
    }

    // MARK: The iCloud link (docs/icloud-plan.md sections 4 to 8)

    /// Makes this launch's iCloud session, or none: wherever `CloudKitStore.live()` is nil, nothing below runs.
    private func setUpCloud() {
        #if DEBUG
        if let forced = AppPaths.forcedCloudStatus {
            forceCloudStatus(forced)
            return
        }
        #endif
        guard let session = CloudSyncSession.live(role: cloudRole) else { return }
        cloud = session
        // A launch that finds the data as the book left it starts on the fast path (a head fetch, no download).
        if let data {
            versions.note(CloudLink.projection(data))
            if let base = session.book.base, CloudLink.projection(base) == versions.projection { versions.settle(.cloud) }
        }
        configurePhotoSource()
        showLastSync()
        showCloud()
    }

    /// One cloud pass with the caller's steps (`CloudSyncSession`), then what it means for the screens.
    @discardableResult
    private func cloudPass() async -> CloudTick? {
        guard let cloud else { return nil }
        let role = cloudRole
        let session = syncFailures.session
        let joinedBefore = cloudJoinedOnce
        let host = CloudSyncSession.Host(
            local: { [weak self] in self?.data },
            generation: { [weak self] in self?.editGeneration ?? -1 },
            changed: { [weak self] in !(self?.versions.isCurrent(.cloud) ?? false) },
            hubSettledAt: role == .mac ? hubSettledAt : nil,
            hubBase: role == .phone ? syncBase : nil,
            joinedBefore: joinedBefore,
            resolutions: conflictSet.resolutions(for: .cloud),
            hubAt: role == .mac ? hubLastSuccess : nil,
            hubRevision: role == .mac ? syncedRevision : nil,
            noBase: role == .phone && baselessNext == .cloud,
            hubConflicts: role == .mac ? unansweredHubConflicts : 0,
            activeLink: route.active,
            install: { [weak self] installed, local in self?.installFromCloud(installed, local: local) ?? false },
            mirror: { _ = try? AppPaths.mirrorJSON(from: $0) }
        )
        let outcome = await cloud.pass(host)
        // R2 across passes: once a round confirmed a write, the book holds a base and D5's merge with no base is
        // spent, even if this pass then asked or waited.
        if cloud.lastPassConfirmedWrite { clearBaseless(.cloud) }
        let tick = CloudTick(outcome, installed: cloud.lastPassInstalled, wrote: cloud.lastPassWrote)
        let join = CloudPassEffects.of(outcome, role: role, joinedBefore: joinedBefore, speaksForCloud: false)
        switch outcome {
        case .installed, .upToDate:
            versions.settle(.cloud)
            conflictSet.clear(.cloud)
            cloudWait = nil
            cloudSettledThisLaunch = true
            clearBaseless(.cloud)
            if join.joins {
                // Section 6: the phone's link is iCloud from now on. The hub address stays stored. The hub's
                // waiting changes go: the join's merge has asked again about anything still real (C1 5).
                cloudJoinedOnce = true
                UserDefaults.standard.set(true, forKey: AppPaths.defaultsKey("cloudJoinedOnce"))
                if join.clearsHubConflicts { conflictSet.clear(.hub) }
                configurePhotoSource()
            }
            if isOffline { isOffline = false }
            seedIfWaiting()
            fillPhotosIfNeeded()
        case let .conflicts(list):
            conflictSet.set(list.map { SyncConflict($0).labelled(using: [data]) }, for: .cloud)
            cloudWait = nil
            syncMessage = "\(list.count) changes need your choice in Settings"
        case let .waiting(wait):
            cloudWait = wait
        }
        if route.active == .cloud {
            // The phone's screens speak for iCloud: its words, and its failures for the notice.
            switch outcome {
            case .installed, .upToDate: syncMessage = "Up to date"
            case .conflicts: break
            case let .waiting(wait):
                syncMessage = CloudSyncCopy.sentence(CloudDisplay(role: role, active: .cloud, joined: true,
                                                                  preferHub: false, wait: wait), device: Platform.deviceName)
                    ?? Self.quietMessage(wait)
            }
        }
        // The route as it is now: a phone that joined in this pass speaks for iCloud from here on.
        let effects = CloudPassEffects.of(outcome, role: role, joinedBefore: joinedBefore,
                                          speaksForCloud: route.active == .cloud)
        switch effects.notice {
        case .keep: break
        case .clear: syncFailures.reachedMac()
        case let .record(failure): syncFailures.failed(failure, in: session)
        }
        showLastSync()
        await showCloud(statuses: cloud.statuses())
        return tick
    }

    /// The hub link's changes still waiting for a choice here, for `status-mac.conflicts` (C2 7).
    private var unansweredHubConflicts: Int {
        let answered = conflictSet.resolutions(for: .hub)
        return conflictSet.conflicts(for: .hub).filter { answered[$0.id] == nil }.count
    }

    /// D5: the next pass of `link` merges with no base. Kept on disk, so a relaunch before that pass still does.
    private func setBaselessNext(_ link: SyncLinkKind?) {
        baselessNext = link
        if let link {
            UserDefaults.standard.set(link.rawValue, forKey: AppPaths.defaultsKey("cloudSwitchBaseless"))
        } else {
            UserDefaults.standard.removeObject(forKey: AppPaths.defaultsKey("cloudSwitchBaseless"))
        }
    }

    /// `link` settled: its baseless pass (if it owed one) is done.
    private func clearBaseless(_ link: SyncLinkKind) {
        if baselessNext == link { setBaselessNext(nil) }
    }

    private static func quietMessage(_ wait: CloudWait) -> String {
        switch wait {
        case .offline: return "Saved on this \(Platform.deviceName); sync will resume"
        case let .failed(reason): return "Saved on this \(Platform.deviceName). \(reason)"
        default: return "New edits are saved locally; sync will retry"
        }
    }

    /// Section 4 step 9, the data side: today's install steps, `sync.json` before the session saves the book. The
    /// hub base in `sync.json` is left as it is: it still belongs to the hub link.
    private func installFromCloud(_ installed: CollectionData, local: CollectionData?) -> Bool {
        var merged = BoxModel.installing(installed, hubSupportsBoxes: true, local: local)
        if let local {
            merged.settings.autoBackup = local.settings.autoBackup
            merged.settings.backupRemote = local.settings.backupRemote
            merged.settings.lastBackup = local.settings.lastBackup
        }
        do {
            try SyncDisk.save(SyncCheckpoint(data: merged, base: syncBase, server: syncAddress, lastSuccess: hubLastSuccess))
        } catch {
            return false
        }
        publish(merged, persist: false)
        versions.settle(.cloud)
        CacheStore.save(merged)
        if merged.settings.autoBackup { _ = try? AppPaths.mirrorJSON(from: merged) }
        return true
    }

    /// Phone, after a settled pass: the photos still missing come down in the background, 3 at a time, and only
    /// in bulk on a network that is neither expensive nor constrained, asked again before each fetch; never over
    /// cellular, and never once the app has left the screen (C1 4). Screens fetch what they show either way.
    private func fillPhotosIfNeeded() {
        guard cloudRole == .phone, !documentOnly, fillTask == nil, pathAllowsBulk, let cloud, let data,
              PhotoStore.missingLocalCount(PhotoStore.assets(in: data, baseURL: nil)) > 0 else { return }
        let generation = fillGeneration
        fillTask = Task { [weak self] in
            // The pictures the screens show first (covers, then the boxes' tiles), then the rest of the photos, the
            // second pass only when the first ran out of work. A cover fetches its own render on any network; the
            // boxes and their chips draw only tiles on this device, so they are told when some land.
            let pictures = await cloud.fill(data, picturesOnly: true, while: { [weak self] in await self?.fillMayGoOn(generation) ?? false })
            self?.noteLanded(pictures, generation: generation)
            if !pictures.stopped, !Task.isCancelled, self?.fillGeneration == generation {
                let rest = await cloud.fill(data, while: { [weak self] in await self?.fillMayGoOn(generation) ?? false })
                self?.noteLanded(rest, generation: generation)
            }
            if self?.fillGeneration == generation { self?.fillTask = nil }
        }
    }

    private func noteLanded(_ result: CloudLink.FillResult, generation: Int) {
        if result.fetched > 0, fillGeneration == generation { picturesLanded += 1 }
    }

    private func fillMayGoOn(_ generation: Int) -> Bool {
        pathAllowsBulk && fillGeneration == generation
    }

    private func cancelFill() {
        fillGeneration += 1
        fillTask?.cancel()
        fillTask = nil
    }

    /// Where `PhotoStore.load` fetches a file this device lacks: iCloud when there is a link, the hub only while the
    /// hub link is active.
    private func configurePhotoSource() {
        let store = cloud?.store
        let hubActive = route.active == .hub || cloudRole == .mac
        Task { await PhotoStore.shared.configure(cloud: store, hubActive: hubActive) }
    }

    /// `status.lastSync`: the later of the two links' last successes.
    private func showLastSync() {
        let latest = [hubLastSuccess, cloud?.book.lastSuccess].compactMap { $0 }.max()
        if status.lastSync != latest { status.lastSync = latest }
    }

    /// `status.lastPhoneSync` on the Mac: the later of the hub's word and the phone's own `Status` record.
    private func showPhoneSync() {
        let latest = [hubPhoneSync, phoneStatusAt].compactMap { $0 }.max()
        if status.lastPhoneSync != latest { status.lastPhoneSync = latest }
    }

    /// `status.cloud` from the session's book and the `Status` records.
    private func showCloud(statuses: [String: CloudStatus]? = nil) {
        guard let cloud else { return }
        let other = cloudRole == .mac ? "status-iphone" : "status-mac"
        var display = status.cloud ?? CloudDisplay(role: cloudRole, active: route.active, joined: cloudJoinedOnce,
                                                   preferHub: preferHub)
        display.active = route.active
        display.joined = cloudJoinedOnce
        display.preferHub = preferHub
        display.wait = cloudWait
        display.lastSync = cloud.book.lastSuccess
        if let statuses {
            display.macHubAt = statuses["status-mac"]?.hubAt
            display.otherConflicts = statuses[other]?.conflicts ?? 0
            if cloudRole == .mac {
                phoneStatusAt = statuses["status-iphone"]?.at
                showPhoneSync()
            }
        }
        if status.cloud != display { status.cloud = display }
    }

    #if DEBUG
    /// `-WCCloudStatus <case>`: joined, sending, signedout, full, choice, newer, erased, waitinghub, direct. The
    /// screens show that iCloud state (for screenshots) and no link runs at all.
    private func forceCloudStatus(_ name: String) {
        forcedCloud = true
        let now = Date()
        let evening = Calendar.current.date(bySettingHour: 21, minute: 41, second: 0, of: now) ?? now
        var display = CloudDisplay(role: cloudRole, active: cloudRole == .phone ? .cloud : .hub, joined: true,
                                   preferHub: false, wait: nil, lastSync: now.addingTimeInterval(-120),
                                   macHubAt: evening <= now ? evening : evening.addingTimeInterval(-86_400))
        switch name.lowercased() {
        case "sending": display.wait = .sendingPhotos(done: 120, of: 260)
        case "signedout": display.wait = .noAccount
        case "full": display.wait = .full
        case "choice": display.otherConflicts = 1
        case "newer": display.wait = .newerFormat
        case "erased": display.wait = .erased
        case "waitinghub": display.wait = .needsHubFirst
        case "direct":
            display.preferHub = true
            display.active = .hub
        default: break
        }
        status.cloud = display
        syncMessage = "Up to date"
        status.lastSync = cloudRole == .phone && display.active == .cloud ? display.lastSync : now.addingTimeInterval(-60)
        if cloudRole == .mac { status.lastPhoneSync = now.addingTimeInterval(-120) }
    }
    #endif

    /// Records what the hub of a completed sync keeps.
    private func noteHub(_ snapshot: SyncSnapshot) {
        if hubSupportsBoxes != snapshot.supportsBoxes { hubSupportsBoxes = snapshot.supportsBoxes }
    }

    func saveWatch(_ watch: Watch, isNew: Bool = false, initialPhotos: [LocalPhotoUpload] = [], baseline: Watch? = nil) async -> Watch? {
        do {
            var saved = watch
            saved.name = saved.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !saved.name.isEmpty else { throw LocalStoreError.invalidOperation }
            saved.diameter = positiveOrNil(saved.diameter)
            saved.lugToLug = positiveOrNil(saved.lugToLug)
            guard saved.price.isFinite, saved.price >= 0 else { throw LocalStoreError.invalidOperation }
            // Photo writes await; re-read the collection afterwards so a sync landing meanwhile isn't reverted.
            var stored: [String] = []
            let newID = isNew ? uniqueID(for: saved.name, existing: try requireData().watches.map(\.id)) : saved.id
            for photo in isNew ? initialPhotos : [] {
                let extensionName = safePhotoExtension(filename: photo.filename, mimeType: photo.mimeType)
                let storedFilename = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased() + extensionName
                guard let asset = PhotoStore.asset(
                    itemID: newID,
                    filename: storedFilename,
                    wishlist: false,
                    baseURL: nil
                ) else { throw LocalStoreError.invalidOperation }
                try await PhotoStore.shared.storeUploaded(photo.data, as: asset)
                stored.append(storedFilename)
            }
            var updated = try requireData()
            if isNew || (baseline != nil && baseline?.purchased != watch.purchased) {
                saved.purchasedText = purchaseMonthLabel(saved.purchased)
            }
            saved.wearSessions = wearSessions(for: saved)
            saved.wearDates = nil
            saved.serviceRecords = serviceRecords(for: saved)
            if isNew {
                guard !updated.watches.contains(where: { $0.id == newID }) else { throw LocalStoreError.duplicateValue }
                saved = Watch(
                    id: newID,
                    name: saved.name,
                    story: watch.story,
                    purchased: watch.purchased,
                    purchasedText: purchaseMonthLabel(watch.purchased),
                    diameter: saved.diameter,
                    price: watch.price,
                    original: watch.original,
                    status: watch.status,
                    statusNote: watch.statusNote,
                    photos: stored,
                    category: watch.category,
                    dialColor: watch.dialColor,
                    lugToLug: saved.lugToLug,
                    material: watch.material,
                    brand: watch.brand,
                    acquisitionMethod: watch.acquisitionMethod,
                    costSourceWatchID: watch.costSourceWatchID
                )
                updated.watches.append(saved)
            } else if let index = updated.watches.firstIndex(where: { $0.id == watch.id }) {
                if let baseline { saved = try mergeDraft(base: baseline, draft: saved, current: updated.watches[index]) }
                updated.watches[index] = saved
            } else {
                throw LocalStoreError.itemNotFound
            }
            try await commit(updated)
            notice = isNew ? "Watch added." : "Watch saved."
            return saved
        } catch {
            surface(error)
            return nil
        }
    }

    func saveWishlist(_ item: WishlistItem, isNew: Bool = false, baseline: WishlistItem? = nil) async -> WishlistItem? {
        do {
            var updated = try requireData()
            var saved = item
            saved.name = saved.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !saved.name.isEmpty else { throw LocalStoreError.invalidOperation }
            saved.diameter = positiveOrNil(saved.diameter)
            saved.lugToLug = positiveOrNil(saved.lugToLug)
            if saved.added.range(of: #"^\d{4}-(0[1-9]|1[0-2])$"#, options: .regularExpression) == nil {
                saved.added = Self.currentMonth
            }
            if isNew {
                saved = WishlistItem(
                    id: uniqueID(for: item.name, existing: updated.wishlist.map(\.id)),
                    name: saved.name,
                    brand: item.brand.trimmingCharacters(in: .whitespacesAndNewlines),
                    category: item.category,
                    priceExpected: item.priceExpected,
                    priceNote: item.priceNote,
                    notes: item.notes,
                    status: item.status,
                    added: saved.added,
                    dialColor: item.dialColor,
                    diameter: saved.diameter,
                    lugToLug: saved.lugToLug,
                    material: item.material,
                    photos: []
                )
                updated.wishlist.append(saved)
            } else if let index = updated.wishlist.firstIndex(where: { $0.id == item.id }) {
                if let baseline { saved = try mergeDraft(base: baseline, draft: saved, current: updated.wishlist[index]) }
                updated.wishlist[index] = saved
            } else {
                throw LocalStoreError.itemNotFound
            }
            try await commit(updated)
            notice = isNew ? "Candidate added." : "Candidate saved."
            return saved
        } catch {
            surface(error)
            return nil
        }
    }

    func deleteWatch(id: String) async {
        await mutate { data in
            guard data.watches.contains(where: { $0.id == id }) else { throw LocalStoreError.itemNotFound }
            data.watches.removeAll { $0.id == id }
            self.notice = "Watch deleted."
        }
    }

    func deleteWishlist(id: String) async {
        await mutate { data in
            guard data.wishlist.contains(where: { $0.id == id }) else { throw LocalStoreError.itemNotFound }
            data.wishlist.removeAll { $0.id == id }
            self.notice = "Candidate deleted."
        }
    }

    func passWishlist(id: String) async {
        await mutate { data in
            guard let index = data.wishlist.firstIndex(where: { $0.id == id }) else { throw LocalStoreError.itemNotFound }
            data.wishlist[index].status = "passed"
            self.notice = "Marked passed."
        }
    }

    func markBought(id: String, price: Double, purchased: String) async {
        await mutate { data in
            guard let index = data.wishlist.firstIndex(where: { $0.id == id }) else { throw LocalStoreError.itemNotFound }
            let item = data.wishlist[index]
            guard item.status != "bought" else { throw LocalStoreError.duplicateValue }
            var watch = Watch(
                id: self.uniqueID(for: item.name, existing: data.watches.map(\.id)),
                name: item.name,
                story: item.notes,
                purchased: purchased,
                purchasedText: purchaseMonthLabel(purchased),
                diameter: item.diameter,
                price: price,
                original: true,
                status: "owned",
                statusNote: "",
                photos: [],
                category: item.category,
                dialColor: item.dialColor,
                lugToLug: item.lugToLug,
                material: item.material,
                brand: item.brand
            )
            watch.photos = PhotoStore.copyPhotos(item.photos, fromWishlist: item.id, toWatch: watch.id)
            watch.photoFocus = item.photoFocus?.filter { watch.photos.contains($0.key) }
            // Tiles cost money to make: they move with the photos (the hub accepts them for a watch it has never seen).
            watch.boxTiles = PhotoStore.copyTiles(item.boxTiles, fromWishlist: item.id, toWatch: watch.id)
            watch.boxCutout = BoxModel.effectiveCutout(item.boxCutout, photos: watch.photos)
            data.watches.append(watch)
            data.wishlist[index].status = "bought"
            self.notice = "Moved into the collection."
        }
    }

    func addServiceRecord(watchID: String, record: ServiceRecord) async {
        await mutate { data in
            guard let index = data.watches.firstIndex(where: { $0.id == watchID }),
                  calendarDayDate(record.date) != nil,
                  record.nextDue == nil || calendarDayDate(record.nextDue) != nil,
                  !record.kind.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  record.cost.map({ $0.isFinite && $0 >= 0 }) ?? true
            else { throw LocalStoreError.invalidOperation }
            var records = serviceRecords(for: data.watches[index])
            guard !records.contains(where: { $0.id == record.id }) else { throw LocalStoreError.duplicateValue }
            records.append(record)
            data.watches[index].serviceRecords = records.sorted {
                if $0.date == $1.date { return $0.id < $1.id }
                return $0.date < $1.date
            }
            self.notice = "Service entry added."
        }
    }

    func deleteServiceRecord(watchID: String, recordID: String) async {
        await mutate { data in
            guard let index = data.watches.firstIndex(where: { $0.id == watchID }) else {
                throw LocalStoreError.itemNotFound
            }
            var records = serviceRecords(for: data.watches[index])
            guard records.contains(where: { $0.id == recordID }) else { throw LocalStoreError.itemNotFound }
            records.removeAll { $0.id == recordID }
            data.watches[index].serviceRecords = records
            self.notice = "Service entry removed."
        }
    }

    func findWishlistImage(id: String) async -> URL? {
        guard let item = data?.wishlist.first(where: { $0.id == id }) else {
            surface(LocalStoreError.itemNotFound)
            return nil
        }
        var components = URLComponents(string: "https://www.google.com/search")
        components?.queryItems = [
            URLQueryItem(name: "tbm", value: "isch"),
            URLQueryItem(name: "q", value: "\(item.name) watch product image"),
        ]
        notice = "Choose a photo, then add it from your library."
        return components?.url
    }

    func saveSettings(_ settings: CollectionSettings, baseline: CollectionSettings? = nil) async {
        await mutate { data in
            data.settings = try baseline.map { try mergeDraft(base: $0, draft: settings, current: data.settings) } ?? settings
            let wrist = data.settings.wrist
            if wrist.sweetSpotMin > wrist.sweetSpotMax {
                (data.settings.wrist.sweetSpotMin, data.settings.wrist.sweetSpotMax) = (wrist.sweetSpotMax, wrist.sweetSpotMin)
            }
            self.notice = "Settings saved."
        }
    }

    func backup() async -> String {
        do {
            let snapshot = try requireData()
            _ = try await Task.detached(priority: .utility) {
                try LocalBackup.createFullBackup(from: snapshot)
            }.value
            var updated = try requireData()
            updated.settings.lastBackup = ISO8601DateFormatter().string(from: Date())
            try await commit(updated)
            notice = Platform.isMac ? "Backup saved." : "Backup saved in Files."
            return Platform.isMac ? "Saved to the app's Documents / Watch Collection Backup." : "Saved to On My iPhone / Watch Collection Backup."
        } catch {
            surface(error)
            return error.localizedDescription
        }
    }

    func prepareExport(includePhotos: Bool) async -> CollectionExportDocument? {
        do {
            let data = try requireData()
            return try await Task.detached(priority: .userInitiated) {
                try CollectionExportDocument(data: data, includePhotos: includePhotos)
            }.value
        } catch {
            surface(error)
            return nil
        }
    }

    func inspectImport(from url: URL) async -> CollectionImport? {
        do {
            return try await Task.detached(priority: .userInitiated) {
                let accessing = url.startAccessingSecurityScopedResource()
                defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                return try CollectionBackupArchive.load(from: url)
            }.value
        } catch {
            surface(error)
            return nil
        }
    }

    func restore(_ imported: CollectionImport) async -> Bool {
        #if os(macOS)
        // Settings can be open while the app still waits for the library lock; a restore writes the library, so it
        // waits too (a bridge tick steps aside within a second).
        _ = await Entry.library.whenReady()
        // And for the app's own load: before `start()` the hub base is not read yet, so a save here would lose it.
        await start()
        #endif
        do {
            try await PhotoStore.shared.restore(imported.photos)
            try await commit(imported.data)
            let missing = PhotoStore.missingLocalCount(PhotoStore.assets(in: imported.data, baseURL: nil))
            notice = missing == 0
                ? "Collection restored with all photos."
                : "Collection restored; \(missing) referenced photo(s) were not in the import."
            return true
        } catch {
            surface(error)
            return false
        }
    }

    func taxonomy(_ route: TaxonomyRoute, operation: TaxonomyOperation) async {
        await mutate { data in
            var values = self.taxonomyValues(route, data: data)
            switch operation {
            case let .add(value):
                let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !clean.isEmpty else { throw LocalStoreError.invalidOperation }
                guard !values.contains(clean) else { throw LocalStoreError.duplicateValue }
                values.append(clean)
            case let .rename(from, to):
                let clean = to.trimmingCharacters(in: .whitespacesAndNewlines)
                guard let index = values.firstIndex(of: from), !clean.isEmpty else { throw LocalStoreError.invalidOperation }
                guard clean == from || !values.contains(clean) else { throw LocalStoreError.duplicateValue }
                values[index] = clean
                for watchIndex in data.watches.indices where self.taxonomyValue(route, watch: data.watches[watchIndex]) == from {
                    self.setTaxonomyValue(route, value: clean, watch: &data.watches[watchIndex])
                }
                for itemIndex in data.wishlist.indices where self.taxonomyValue(route, item: data.wishlist[itemIndex]) == from {
                    self.setTaxonomyValue(route, value: clean, item: &data.wishlist[itemIndex])
                }
                if route == .categories {
                    data.settings.suggestExclude = (data.settings.suggestExclude ?? []).map { $0 == from ? clean : $0 }
                }
            case let .delete(value):
                let uses = data.watches.filter { self.taxonomyValue(route, watch: $0) == value }.count
                    + data.wishlist.filter { self.taxonomyValue(route, item: $0) == value }.count
                guard uses == 0 else { throw LocalStoreError.valueInUse(uses) }
                guard values.contains(value) else { throw LocalStoreError.invalidOperation }
                values.removeAll { $0 == value }
                if route == .categories { data.settings.suggestExclude?.removeAll { $0 == value } }
            case let .reorder(reordered):
                guard reordered.count == values.count, Set(reordered) == Set(values) else { throw LocalStoreError.invalidOperation }
                values = reordered
            }
            self.setTaxonomyValues(route, values: values, data: &data)
            self.notice = "\(route.title) updated."
        }
    }

    func addRadarBrand(_ brand: String) async {
        await mutate { data in
            let clean = brand.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty else { throw LocalStoreError.invalidOperation }
            guard !data.brandWatchlist.contains(where: { $0.brand.caseInsensitiveCompare(clean) == .orderedSame }) else {
                throw LocalStoreError.duplicateValue
            }
            data.brandWatchlist.append(BrandRadarItem(brand: clean, notes: "", added: Self.currentMonth))
        }
    }

    func deleteRadarBrand(_ brand: String) async {
        await mutate { data in
            guard data.brandWatchlist.contains(where: { $0.brand == brand }) else { throw LocalStoreError.itemNotFound }
            data.brandWatchlist.removeAll { $0.brand == brand }
        }
    }

    func uploadPhoto(data photoData: Data, filename: String, mimeType: String, itemID: String, wishlist: Bool) async {
        do {
            let extensionName = safePhotoExtension(filename: filename, mimeType: mimeType)
            let storedFilename = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased() + extensionName
            guard let asset = PhotoStore.asset(itemID: itemID, filename: storedFilename, wishlist: wishlist, baseURL: nil) else {
                throw LocalStoreError.invalidOperation
            }
            try await PhotoStore.shared.storeUploaded(photoData, as: asset)
            var updated = try requireData()
            if wishlist {
                guard let index = updated.wishlist.firstIndex(where: { $0.id == itemID }) else { throw LocalStoreError.itemNotFound }
                updated.wishlist[index].photos.insert(storedFilename, at: 0)
            } else {
                guard let index = updated.watches.firstIndex(where: { $0.id == itemID }) else { throw LocalStoreError.itemNotFound }
                updated.watches[index].photos.insert(storedFilename, at: 0)
            }
            try await commit(updated)
            notice = "Photo added."
        } catch {
            surface(error)
        }
    }

    func setCover(itemID: String, filename: String, wishlist: Bool) async {
        await mutate { data in
            if wishlist {
                guard let index = data.wishlist.firstIndex(where: { $0.id == itemID }),
                      let photoIndex = data.wishlist[index].photos.firstIndex(of: filename) else { throw LocalStoreError.itemNotFound }
                data.wishlist[index].photos.remove(at: photoIndex)
                data.wishlist[index].photos.insert(filename, at: 0)
            } else {
                guard let index = data.watches.firstIndex(where: { $0.id == itemID }),
                      let photoIndex = data.watches[index].photos.firstIndex(of: filename) else { throw LocalStoreError.itemNotFound }
                data.watches[index].photos.remove(at: photoIndex)
                data.watches[index].photos.insert(filename, at: 0)
            }
        }
    }

    func deletePhoto(itemID: String, filename: String, wishlist: Bool) async {
        await mutate { data in
            if wishlist {
                guard let index = data.wishlist.firstIndex(where: { $0.id == itemID }),
                      data.wishlist[index].photos.contains(filename) else { throw LocalStoreError.itemNotFound }
                data.wishlist[index].photos.removeAll { $0 == filename }
                data.wishlist[index].photoFocus = Self.focusMap(data.wishlist[index].photoFocus, setting: nil, for: filename)
                if data.wishlist[index].boxCutout?.photo == filename { data.wishlist[index].boxCutout = nil }
            } else {
                guard let index = data.watches.firstIndex(where: { $0.id == itemID }),
                      data.watches[index].photos.contains(filename) else { throw LocalStoreError.itemNotFound }
                data.watches[index].photos.removeAll { $0 == filename }
                data.watches[index].photoFocus = Self.focusMap(data.watches[index].photoFocus, setting: nil, for: filename)
                if data.watches[index].boxCutout?.photo == filename { data.watches[index].boxCutout = nil }
            }
        }
    }

    /// Saves how a photo is framed (nil = default centred fill).
    func setPhotoFocus(itemID: String, filename: String, wishlist: Bool, focus: PhotoFocus?) async {
        await mutate { data in
            if wishlist {
                guard let index = data.wishlist.firstIndex(where: { $0.id == itemID }),
                      data.wishlist[index].photos.contains(filename) else { throw LocalStoreError.itemNotFound }
                data.wishlist[index].photoFocus = Self.focusMap(data.wishlist[index].photoFocus, setting: focus, for: filename)
            } else {
                guard let index = data.watches.firstIndex(where: { $0.id == itemID }),
                      data.watches[index].photos.contains(filename) else { throw LocalStoreError.itemNotFound }
                data.watches[index].photoFocus = Self.focusMap(data.watches[index].photoFocus, setting: focus, for: filename)
            }
        }
    }

    private nonisolated static func focusMap(
        _ map: [String: PhotoFocus]?,
        setting focus: PhotoFocus?,
        for filename: String
    ) -> [String: PhotoFocus]? {
        var updated = map ?? [:]
        updated[filename] = focus
        return updated.isEmpty ? nil : updated
    }

    // MARK: Boxes

    /// Moves an owned watch into a compartment (BoxModel.place: empty, swap, or the occupant to the tray).
    func placeWatch(id: String, boxID: String, slot: Int) async {
        await mutate { data in try BoxModel.place(watchID: id, boxID: boxID, slot: slot, in: &data) }
        // Dropping an owned watch on a trial space ends that trial.
        let space = BoxSpace(boxID: boxID, slot: slot)
        if let data, BoxModel.location(of: id, in: data) == space, boxTrial.candidate(at: space) != nil {
            var trial = boxTrial
            trial.end(at: space)
            storeTrial(trial)
        }
    }

    func takeOut(watchID: String) async {
        guard let data, BoxModel.location(of: watchID, in: data) != nil else { return }
        await mutate { data in BoxModel.takeOut(watchID: watchID, in: &data) }
    }

    /// Adds an empty box at the end; returns its id.
    @discardableResult
    func addBox(name: String, finish: String, columns: Int, rows: Int) async -> String? {
        var addedID: String?
        await mutate { data in
            var boxes = data.boxes ?? []
            guard boxes.count < BoxModel.boxLimit else { throw LocalStoreError.invalidOperation }
            let box = try Self.checkedBox(WatchBox(
                id: BoxModel.newBoxID(existing: boxes.map(\.id)),
                name: name, finish: finish, columns: columns, rows: rows, slots: [:]
            ))
            boxes.append(box)
            data.boxes = boxes
            addedID = box.id
            self.notice = "Box added."
        }
        guard let addedID, data?.boxes?.contains(where: { $0.id == addedID }) == true else { return nil }
        return addedID
    }

    /// Saves a box's name, finish and size. The compartments are taken from the collection as it is
    /// now, not from the edited copy, so a sync that moved a watch meanwhile is kept; a new size keeps
    /// each watch's row and column when they still exist and sends the rest to the tray. Candidates on
    /// trial in the box move the same way; one whose place is gone leaves the trial.
    func updateBox(_ box: WatchBox) async {
        let trialBefore = boxTrial
        var resized = false
        await mutate { data in
            guard var boxes = data.boxes, let index = boxes.firstIndex(where: { $0.id == box.id }) else {
                throw LocalStoreError.itemNotFound
            }
            let previous = boxes[index]
            var updated = previous
            if updated.columns != box.columns || updated.rows != box.rows {
                updated = BoxModel.resize(updated, columns: box.columns, rows: box.rows)
            }
            updated.name = box.name
            updated.finish = box.finish
            boxes[index] = try Self.checkedBox(updated)
            data.boxes = boxes
            if previous.columns != updated.columns || previous.rows != updated.rows {
                // Moved before the collection is published, whose clean-up would otherwise read the old
                // indexes against the new size.
                self.boxTrial = trialBefore.resized(previous, columns: updated.columns, rows: updated.rows)
                resized = true
            }
        }
        guard resized else { return }
        if let saved = data?.boxes?.first(where: { $0.id == box.id }), saved.columns == box.columns, saved.rows == box.rows {
            boxTrial.save()
        } else {
            boxTrial = trialBefore  // the new size was not saved
        }
    }

    /// Removes a box; its watches go to the tray.
    func deleteBox(id: String) async {
        await mutate { data in
            guard data.boxes?.contains(where: { $0.id == id }) == true else { throw LocalStoreError.itemNotFound }
            data.boxes?.removeAll { $0.id == id }
            self.notice = "Box deleted."
        }
    }

    /// Reorders the boxes (the order of their tabs), as a List's onMove reports it.
    func moveBox(from source: IndexSet, to destination: Int) async {
        await mutate { data in
            guard var boxes = data.boxes, source.allSatisfy(boxes.indices.contains), (0...boxes.count).contains(destination) else {
                throw LocalStoreError.invalidOperation
            }
            boxes.move(fromOffsets: source, toOffset: destination)
            data.boxes = boxes
        }
    }

    /// "Use the starting layout": the same seed the iPhone writes, for a collection with no boxes.
    func useStartingLayout() async {
        await mutate { data in
            guard self.canOfferStartingLayout, data.boxes?.isEmpty ?? true else { throw LocalStoreError.invalidOperation }
            data.boxes = nil
            if let seeded = BoxModel.seeding(data) { data = seeded }
        }
    }

    /// Saves how a watch's or candidate's box cutout is made; nil goes back to fully automatic.
    func setBoxCutout(itemID: String, wishlist: Bool, cutout: BoxCutout?) async {
        await mutate { data in
            let clean = cutout?.normalized
            if wishlist {
                guard let index = data.wishlist.firstIndex(where: { $0.id == itemID }),
                      clean.map({ data.wishlist[index].photos.contains($0.photo) }) ?? true
                else { throw LocalStoreError.itemNotFound }
                data.wishlist[index].boxCutout = clean
            } else {
                guard let index = data.watches.firstIndex(where: { $0.id == itemID }),
                      clean.map({ data.watches[index].photos.contains($0.photo) }) ?? true
                else { throw LocalStoreError.itemNotFound }
                data.watches[index].boxCutout = clean
            }
        }
    }

    /// Switches to the Boxes tab with a watch or candidate in hand; the screen consumes the intent.
    func openBoxes(_ intent: BoxIntent) {
        boxIntent = intent
        UserDefaults.standard.set(AppTab.boxes.rawValue, forKey: "selectedTabV4")
    }

    /// Puts a wishlist candidate on trial in a box space, on this device only.
    func tryOn(wishlistID: String, boxID: String, slot: Int) {
        guard let data, data.wishlist.contains(where: { $0.id == wishlistID && $0.status != "bought" }),
              let box = data.boxes?.first(where: { $0.id == boxID }), (0..<box.capacity).contains(slot)
        else {
            surface(LocalStoreError.itemNotFound)
            return
        }
        var trial = boxTrial
        trial.place(wishlistID, at: BoxSpace(boxID: boxID, slot: slot))
        storeTrial(trial)
    }

    func endTrial(wishlistID: String) {
        var trial = boxTrial
        trial.end(wishlistID)
        storeTrial(trial)
    }

    func clearTrial(boxID: String) {
        var trial = boxTrial
        trial.clear(boxID: boxID)
        storeTrial(trial)
    }

    /// Keeps the trial overlay in step with the collection (gone boxes and candidates drop out) and on disk.
    private func storeTrial(_ trial: BoxTrial) {
        let cleaned = data.map { trial.cleaned(for: $0) } ?? trial
        guard cleaned != boxTrial else { return }
        boxTrial = cleaned
        cleaned.save()
    }

    /// The iPhone writes the starting layout once, the first time it finds a collection that has
    /// never had boxes. The Mac never does by itself, so a first sync between the two cannot produce
    /// slot conflicts; it offers "Use the starting layout" instead.
    private func seedBoxesIfNeeded() async {
        guard !Platform.isMac, canOfferStartingLayout, let data, BoxModel.seeding(data) != nil else { return }
        await mutate { data in
            if let seeded = BoxModel.seeding(data) { data = seeded }
        }
    }

    private func seedIfWaiting() {
        guard seedAfterSync, canOfferStartingLayout else { return }
        seedAfterSync = false
        Task { await self.seedBoxesIfNeeded() }
    }

    private nonisolated static func checkedBox(_ box: WatchBox) throws -> WatchBox {
        guard let name = BoxModel.cleanName(box.name), BoxModel.finishes.contains(box.finish),
              BoxModel.columnRange.contains(box.columns), BoxModel.rowRange.contains(box.rows)
        else { throw LocalStoreError.invalidOperation }
        var checked = box
        checked.name = name
        return checked
    }

    func photoAsset(itemID: String, filename: String, wishlist: Bool) -> PhotoAsset? {
        PhotoStore.asset(itemID: itemID, filename: filename, wishlist: wishlist, baseURL: nil)
    }

    var writable: Bool { true }

    private func migrateFromLegacyServerIfNeeded() async {
        guard !UserDefaults.standard.bool(forKey: "standaloneMigrationComplete") else { return }
        let localCopyIsComplete = data.map {
            PhotoStore.missingLocalCount(PhotoStore.assets(in: $0, baseURL: nil)) == 0
        } ?? false
        guard let legacyURL = LegacyServerConfiguration.migrationURL else {
            if localCopyIsComplete { UserDefaults.standard.set(true, forKey: "standaloneMigrationComplete") }
            return
        }
        do {
            let migrated = try await APIClient(baseURL: legacyURL).fetchData()
            let remoteAssets = PhotoStore.assets(in: migrated, baseURL: legacyURL)
            await PhotoStore.shared.sync(remoteAssets)
            publish(migrated, persist: true)
            if PhotoStore.missingLocalCount(PhotoStore.assets(in: migrated, baseURL: nil)) == 0 {
                UserDefaults.standard.set(true, forKey: "standaloneMigrationComplete")
                notice = "Collection moved onto this iPhone."
            } else {
                notice = "Collection moved; some photos still need the old server once."
            }
        } catch {
            if data == nil {
                errorMessage = error.localizedDescription
            } else if localCopyIsComplete {
                UserDefaults.standard.set(true, forKey: "standaloneMigrationComplete")
            }
        }
    }

    private func requireData() throws -> CollectionData {
        guard let data else { throw LocalStoreError.missingData }
        return data
    }

    private func commit(_ updated: CollectionData) async throws {
        // Every mutation ends with the box rules: a deleted or sold watch leaves its compartment.
        let updated = BoxModel.sanitized(updated)
        guard publish(updated, persist: true) else { throw LocalStoreError.saveFailed }
        editGeneration += 1
        if updated.settings.autoBackup { _ = try? AppPaths.mirrorJSON(from: updated) }
        // Retain photo bytes until both devices acknowledge deletions. Incoming and
        // queued uploads must not be garbage-collected by a simultaneous local edit.
        Task { await self.syncNow() }
    }

    @discardableResult
    private func publish(_ rawData: CollectionData, persist: Bool) -> Bool {
        let derived = DecisionEngine.withDerivedStats(BoxModel.sanitized(rawData))
        if persist {
            do {
                try SyncDisk.save(SyncCheckpoint(data: derived, base: syncBase, server: syncAddress, lastSuccess: hubLastSuccess))
            } catch {
                errorMessage = "The collection could not be saved: \(error.localizedDescription)"
                return false
            }
        }
        data = derived
        // `contentVersion`: only the iCloud link needs it, and only a change to the synced projection moves it.
        if cloud != nil { versions.note(CloudLink.projection(derived)) }
        storeTrial(boxTrial)
        scores = DecisionEngine.scores(for: derived)
        suggestions = DecisionEngine.suggestions(for: derived)
        if isOffline { isOffline = false }
        if persist {
            CacheStore.save(derived)
            CacheStore.save(WishlistScoresResponse(scores: scores))
            if let suggestions { CacheStore.save(suggestions) }
        }
        return true
    }

    private func mutate(_ operation: (inout CollectionData) throws -> Void) async {
        do {
            var updated = try requireData()
            try operation(&updated)
            try await commit(updated)
        } catch {
            surface(error)
        }
    }

    private func uniqueID(for name: String, existing: [String]) -> String {
        let folded = name.folding(options: [.diacriticInsensitive, .widthInsensitive], locale: .current).lowercased()
        let base = folded.replacingOccurrences(of: #"[^a-z0-9]+"#, with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let stem = base.isEmpty ? "watch" : base
        var candidate = stem
        var suffix = 2
        while existing.contains(candidate) {
            candidate = "\(stem)-\(suffix)"
            suffix += 1
        }
        return candidate
    }

    private func safePhotoExtension(filename: String, mimeType: String) -> String {
        let allowed = [".jpg", ".jpeg", ".png", ".webp", ".heic"]
        let candidate = URL(fileURLWithPath: filename).pathExtension.lowercased()
        if allowed.contains(".\(candidate)") { return ".\(candidate)" }
        switch mimeType.lowercased() {
        case "image/png": return ".png"
        case "image/webp": return ".webp"
        case "image/heic", "image/heif": return ".heic"
        default: return ".jpg"
        }
    }

    private func taxonomyValues(_ route: TaxonomyRoute, data: CollectionData) -> [String] {
        switch route {
        case .categories: data.categories
        case .dialcolors: data.dialColors
        case .materials: data.materials
        }
    }

    private func setTaxonomyValues(_ route: TaxonomyRoute, values: [String], data: inout CollectionData) {
        switch route {
        case .categories: data.categories = values
        case .dialcolors: data.dialColors = values
        case .materials: data.materials = values
        }
    }

    private func taxonomyValue(_ route: TaxonomyRoute, watch: Watch) -> String? {
        switch route {
        case .categories: watch.category
        case .dialcolors: watch.dialColor
        case .materials: watch.material
        }
    }

    private func taxonomyValue(_ route: TaxonomyRoute, item: WishlistItem) -> String? {
        switch route {
        case .categories: item.category
        case .dialcolors: item.dialColor
        case .materials: item.material
        }
    }

    private func setTaxonomyValue(_ route: TaxonomyRoute, value: String, watch: inout Watch) {
        switch route {
        case .categories: watch.category = value
        case .dialcolors: watch.dialColor = value
        case .materials: watch.material = value
        }
    }

    private func setTaxonomyValue(_ route: TaxonomyRoute, value: String, item: inout WishlistItem) {
        switch route {
        case .categories: item.category = value
        case .dialcolors: item.dialColor = value
        case .materials: item.material = value
        }
    }

    private func positiveOrNil(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value > 0 else { return nil }
        return value
    }

    private func surface(_ error: Error) {
        errorMessage = error.localizedDescription
    }

    private static var currentMonth: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM"
        return formatter.string(from: Date())
    }
}
