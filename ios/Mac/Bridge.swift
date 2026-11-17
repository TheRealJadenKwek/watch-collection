import Foundation
import os

/// `-WCBridge 1`: one headless sync tick, run by the LaunchAgent every 60 s and whenever the hub's data folder
/// changes, so the hub and iCloud stay linked while the app is closed (docs/icloud-plan.md section 1 decision 4,
/// section 11 P5; `tools/bridge/`).
///
/// - No `NSApplication`, ever (docs/icloud-fixes.md D7). Making one checks the process in with LaunchServices as a
///   running copy of the app, so opening the app while a tick runs was handed to the tick, which never answers
///   (error -600), and the app could not start. With no app object there is no window, no menu bar and no Dock icon,
///   and nothing in a tick needs one (the CloudKit check runs the same way).
/// - It takes `SyncLock` without waiting: with the app open it leaves at once, and when the app starts during a tick
///   it stops at its next step. Every step is resumable, so stopping anywhere costs only time.
/// - The tick is the app's own: `AppStore.start()` reads the library and runs `syncNow` once, which on the Mac is the
///   hub pass, the cloud pass, and the hub pass again only if the cloud pass installed. The cloud pass writes
///   `status-mac` when due and `cloud-status.json`; with no iCloud link in the build the bridge writes that report.
/// - Changes that need a choice are never answered here: a fresh process has no choices, so the cloud pass counts
///   them into `status-mac.conflicts` and they wait for a screen.
/// - A watchdog ends the process at 50 s whatever is running.
///
/// Exit status: 0 after a tick, when the app holds the library, or at the watchdog; 1 when the lock file cannot be
/// opened (no tick runs without the lock). Each run logs a line or two to stderr, which the LaunchAgent sends to
/// `~/Library/Logs/watch-collection-bridge.log`.
enum Bridge {
    static let watchdog: TimeInterval = 50
    /// How often a tick checks whether the app is waiting for the library. Checked on the main actor, so only while
    /// the app's passes are waiting on the network (or on the iCloud link), never in the middle of an install.
    static let wantPoll: Duration = .milliseconds(200)
    private static let logger = Logger(subsystem: "com.jadenkwek.watchcollection", category: "bridge")

    /// `-WCBridge 1` (or YES) on the command line. Only the command line counts: a saved default must never turn
    /// the app itself headless.
    static var requested: Bool {
        switch UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)["WCBridge"] {
        case let text as String: return (text as NSString).boolValue
        case let number as NSNumber: return number.boolValue
        default: return false
        }
    }

    /// - Parameter entry: `Entry.bridgeMarker`, which the tick's summary line names, so the log says which build ran.
    static func runAndExit(entry: String) -> Never {
        let began = Date()
        let limit = watchdogLimit
        DispatchQueue.global().asyncAfter(deadline: .now() + limit) {
            log("stopped by the \(Int(limit)) s watchdog; the next tick carries on")
            exit(0)
        }

        let lock = SyncLock(url: SyncLock.appURL)
        do {
            guard try lock.tryLock() else {
                log("the app has the library open; no tick")
                exit(0)
            }
        } catch {
            log("no tick: the sync lock is unavailable (\(error))")
            exit(1)
        }
        if lock.isWanted {
            log("the app is opening; no tick")
            exit(0)
        }

        Task { @MainActor in
            while true {
                try? await Task.sleep(for: wantPoll)
                if lock.isWanted {
                    log("the app is opening; tick stopped after \(seconds(since: began))")
                    exit(0)
                }
            }
        }
        Task { @MainActor in
            #if DEBUG
            await holdForProof()
            #endif
            await tick(began: began, entry: entry)
            exit(0)
        }
        dispatchMain()
    }

    @MainActor
    private static func tick(began: Date, entry: String) async {
        let store = AppStore()
        await store.start()
        let cloudOn = store.status.cloud != nil
        if !cloudOn { writeOffReport(store.data) }
        let cloud = cloudOn ? (CloudFiles.app.loadReport()?.outcome ?? "no report") : "off"
        log("tick done in \(seconds(since: began)) (\(entry), build \(CloudLink.currentBuild)): \(store.syncMessage); "
            + "iCloud \(cloud); \(store.syncConflicts.count) waiting for a choice")
    }

    #if DEBUG
    /// DEBUG `-WCBridgeHold <seconds>` holds the tick open that long before it starts, waiting as a slow network call
    /// does (the want poll keeps running), so a proof can open the app while a tick runs (docs/icloud-fixes.md D7).
    /// The watchdog still ends the process at 50 s.
    @MainActor
    private static func holdForProof() async {
        let hold = UserDefaults.standard.double(forKey: "WCBridgeHold")
        guard hold > 0 else { return }
        log("holding the tick open for \(Int(min(hold, watchdog))) s (-WCBridgeHold)")
        try? await Task.sleep(for: .seconds(min(hold, watchdog)))
    }
    #endif

    /// `cloud-status.json` when this build has no iCloud link (`CloudKitStore.live()` is nil), which the cloud pass
    /// would otherwise write: the link is off, with what the book and the marks on disk say.
    private static func writeOffReport(_ data: CollectionData?) {
        let files = CloudFiles.app
        let book = files.loadBook()
        let marks = files.loadMarks()
        let names = data.map { CloudLink.photoNames(in: $0) } ?? []
        let photos = AppPhotoFiles()
        let role = self.role
        let report = CloudStatusReport(
            at: Date(), role: role == .mac ? "mac" : "phone", build: CloudLink.currentBuild, outcome: "off",
            activeLink: SyncLinkKind.hub.rawValue,
            joined: role == .phone && UserDefaults.standard.bool(forKey: AppPaths.defaultsKey("cloudJoinedOnce")),
            epoch: book.epoch, revision: book.revision, tag: book.tag, lastSuccess: book.lastSuccess,
            paused: book.paused?.rawValue,
            photos: .init(referenced: names.count, held: names.filter { photos.exists($0) }.count,
                          inCloud: marks.inCloud.count, notInCloud: marks.notInCloud.count,
                          mismatched: marks.mismatched.count),
            lastError: "no iCloud link in this build: CloudKitStore.live() is nil (no WC_CLOUDKIT, no container "
                + "entitlement, -WCNoCloud, or a DEBUG run without -WCDataRoot)",
            statuses: [:]
        )
        files.saveReport(report)
    }

    /// The side of the cloud link this run plays: the Mac, or in DEBUG `-WCRole` (the rehearsal's "phone" root).
    private static var role: CloudRole {
        #if DEBUG
        if let role = AppPaths.role { return role }
        #endif
        return .mac
    }

    /// DEBUG `-WCBridgeWatchdog <seconds>` shortens the watchdog, to prove it.
    private static var watchdogLimit: TimeInterval {
        #if DEBUG
        let override = UserDefaults.standard.double(forKey: "WCBridgeWatchdog")
        if override > 0 { return min(override, watchdog) }
        #endif
        return watchdog
    }

    private static func seconds(since start: Date) -> String {
        String(format: "%.1f s", Date().timeIntervalSince(start))
    }

    /// One line to stderr (the LaunchAgent's log file) and the unified log.
    static func log(_ line: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        FileHandle.standardError.write(Data("\(stamp) bridge[\(getpid())] \(line)\n".utf8))
        logger.notice("\(line, privacy: .public)")
    }
}
