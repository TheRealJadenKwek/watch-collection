import Foundation

// Which sync link runs when, and the bookkeeping that keeps the two links from undoing each other
// (docs/icloud-plan.md sections 1, 4 and 6). Pure: AppStore holds one of each and the tests drive them directly.

/// The two ways a device syncs: with the hub over the network (Tailscale or the Mac itself), or through iCloud.
enum SyncLinkKind: String, Codable, Sendable {
    case hub, cloud
}

/// What one sync tick runs. The Mac is the only bridge between the hub and iCloud, so it runs both, the hub first;
/// the phone runs one link, never both, so the same change is never asked about twice (section 1, Rejected).
enum SyncRoute: Equatable, Sendable {
    /// No iCloud link on this device (simulators, tests, a build without the entitlement), or the phone's
    /// "Sync directly with the Mac instead" is on: today's hub sync and nothing else.
    case hubOnly
    /// A phone that has synced through iCloud before: iCloud only, the hub is never asked.
    case cloudOnly
    /// A phone that has not joined iCloud yet: the cloud pass looks for the document first, and the hub runs as
    /// today only when that pass did nothing (no document, or iCloud could not be used). See `hubFollows`.
    case cloudElseHub
    /// The Mac: the hub pass, then the cloud pass, then the hub again if the cloud pass installed something.
    case hubThenCloud

    static func plan(role: CloudRole, cloudLink: Bool, joined: Bool, preferHub: Bool) -> SyncRoute {
        guard cloudLink else { return .hubOnly }
        switch role {
        case .mac: return .hubThenCloud
        case .phone:
            if preferHub { return .hubOnly }
            return joined ? .cloudOnly : .cloudElseHub
        }
    }

    /// The tick's next link, given the links it has run so far and what its cloud pass did; nil when the tick is
    /// done. `AppStore.syncNow` runs exactly this sequence.
    func next(after ran: [SyncLinkKind], cloud tick: CloudTick?) -> SyncLinkKind? {
        switch self {
        case .hubOnly:
            return ran.isEmpty ? .hub : nil
        case .cloudOnly:
            return ran.isEmpty ? .cloud : nil
        case .cloudElseHub:
            if ran.isEmpty { return .cloud }
            return ran == [.cloud] && Self.hubFollows(tick) ? .hub : nil
        case .hubThenCloud:
            if ran.isEmpty { return .hub }
            if ran == [.hub] { return .cloud }
            // What came in from iCloud goes on to the hub in the same tick; a pass that only sent this Mac's own
            // collection up brought nothing in (C1 9).
            if ran == [.hub, .cloud], tick?.installed == true { return .hub }
            return nil
        }
    }

    /// The link the phone's screens speak for. The Mac's screens speak for the hub, with iCloud on a line of its own.
    var active: SyncLinkKind {
        switch self {
        case .hubOnly, .cloudElseHub, .hubThenCloud: return .hub
        case .cloudOnly: return .cloud
        }
    }

    /// `cloudElseHub`: whether the hub runs after this cloud pass. Only when the cloud pass changed nothing here
    /// and wrote no document: there was none, or iCloud could not be used. Once a document is being joined
    /// (photos going up, a choice to make, an install) the tick belongs to iCloud alone; so does a tick whose pass
    /// wrote the document in any round, even one it then dropped for an edit or that failed afterwards (C1 8).
    static func hubFollows(_ tick: CloudTick?) -> Bool {
        guard let tick else { return true }
        if tick.wrote { return false }
        switch tick.outcome {
        case .installed, .upToDate, .conflicts:
            return false
        case let .waiting(wait):
            switch wait {
            case .sendingPhotos: return false
            case .noAccount, .noDocument, .needsHubFirst, .erased, .full, .newerFormat, .offline, .busy, .failed:
                return true
            }
        }
    }

    /// The phone's first settled cloud pass makes iCloud its link from then on (`cloudJoinedOnce`).
    static func joins(_ outcome: CloudOutcome) -> Bool {
        switch outcome {
        case .installed, .upToDate: return true
        case .conflicts, .waiting: return false
        }
    }

    /// D5: the link whose first pass after the phone's "Sync directly with the Mac instead" flipped merges with no
    /// base (union, nothing deleted, differing fields ask); nil when the flip leaves the same link active.
    static func baselessAfterFlip(from old: SyncRoute, to new: SyncRoute) -> SyncLinkKind? {
        old.active == new.active ? nil : new.active
    }
}

/// What a tick's cloud pass did, as the route reads it.
struct CloudTick: Sendable {
    var outcome: CloudOutcome
    /// It installed a collection that changed something here (not one that only sent this device's own up).
    var installed: Bool
    /// It wrote the document in some round, or tried to and cannot know whether the save landed.
    var wrote: Bool

    /// Unless given, both are read from the outcome.
    init(_ outcome: CloudOutcome, installed: Bool? = nil, wrote: Bool? = nil) {
        self.outcome = outcome
        if case let .installed(_, wroteCloud) = outcome {
            self.installed = installed ?? true
            self.wrote = wrote ?? wroteCloud
        } else {
            self.installed = installed ?? false
            self.wrote = wrote ?? false
        }
    }
}

/// What a cloud pass means for the rest of the app beyond the link itself (docs/icloud-fixes.md D10, C1 5 and 7).
struct CloudPassEffects: Equatable {
    enum Notice: Equatable {
        /// The failure on record stands: a pass cut short or throttled says nothing new.
        case keep
        /// iCloud answered: no failure holds.
        case clear
        /// This failure goes on record, for the notice once it lasts.
        case record(SyncFailure)
    }

    /// The phone's first settled pass: iCloud is its link from now on (`cloudJoinedOnce`).
    var joins: Bool
    /// The hub link's waiting changes go with the join; its merge asks again about anything real (C1 5).
    var clearsHubConflicts: Bool
    /// What the pass does to the failure the sync notice reads. Only a pass the screens speak for touches it.
    var notice: Notice

    static func of(_ outcome: CloudOutcome, role: CloudRole, joinedBefore: Bool,
                   speaksForCloud: Bool) -> CloudPassEffects {
        let joins = role == .phone && !joinedBefore && SyncRoute.joins(outcome)
        var notice = Notice.keep
        if speaksForCloud {
            switch outcome {
            case .waiting(.offline):
                notice = .record(.offline)
            case let .waiting(.failed(reason)):
                notice = .record(.other(reason))
            case .waiting(.noDocument) where role == .phone && joinedBefore:
                // D10: a joined phone whose document is gone syncs with nothing; say so once it lasts.
                notice = .record(.other(CloudSyncCopy.missing))
            case .waiting(.busy):
                // A throttle, or a pass cut short (the app left the screen): neither a failure nor an answer.
                notice = .keep
            default:
                notice = .clear
            }
        }
        return CloudPassEffects(joins: joins, clearsHubConflicts: joins, notice: notice)
    }
}

/// `contentVersion` and the version each link last settled at (section 4). The version moves only when the synced
/// projection of the data moves: an edit, or an install by either link that changed something. A link whose settled
/// version is not the current one has something to send, so its fast path does not apply. That is what carries a hub
/// change through the Mac to iCloud and back, and why it cannot ping-pong: the second link's pass finds nothing
/// new, installs nothing, and moves nothing.
struct SyncVersions: Equatable, Sendable {
    private(set) var content = 0
    /// The fingerprint of the synced projection last noted (nil for no collection).
    private(set) var projection: String?
    private var settled: [SyncLinkKind: Int] = [:]

    /// Notes the projection of the collection now shown. Returns whether it moved, and with it the version.
    @discardableResult
    mutating func note(_ projection: String?) -> Bool {
        guard projection != self.projection else { return false }
        self.projection = projection
        content += 1
        return true
    }

    /// The link is in step with the data as of `version` (the current version when nil).
    mutating func settle(_ link: SyncLinkKind, at version: Int? = nil) {
        settled[link] = version ?? content
    }

    /// The link has nothing new of ours to send.
    func isCurrent(_ link: SyncLinkKind) -> Bool {
        settled[link] == content
    }
}

/// The changes waiting for a choice, kept per link: each answer goes back to the link that asked, in that link's
/// own `resolutions` (section 3).
struct SyncConflictSet {
    private var conflicts: [SyncLinkKind: [SyncConflict]] = [:]
    private var choices: [SyncLinkKind: [String: String]] = [:]

    /// Every waiting change, the hub's first.
    var all: [SyncConflict] { (conflicts[.hub] ?? []) + (conflicts[.cloud] ?? []) }

    /// Every choice made so far, by conflict id.
    var resolutions: [String: String] {
        (choices[.hub] ?? [:]).merging(choices[.cloud] ?? [:]) { first, _ in first }
    }

    func conflicts(for link: SyncLinkKind) -> [SyncConflict] { conflicts[link] ?? [] }

    func resolutions(for link: SyncLinkKind) -> [String: String] { choices[link] ?? [:] }

    /// What a link's pass asked about. Choices already made for it are kept, as today.
    mutating func set(_ list: [SyncConflict], for link: SyncLinkKind) {
        conflicts[link] = list.map { $0.tagged(link) }
    }

    /// A link settled: its questions and answers are spent.
    mutating func clear(_ link: SyncLinkKind) {
        conflicts[link] = nil
        choices[link] = nil
    }

    /// Records a choice for a waiting change. Returns the link it belongs to once every one of that link's changes
    /// has a choice (its next pass sends them), else nil.
    @discardableResult
    mutating func resolve(_ id: String, choice: String) -> SyncLinkKind? {
        guard let link = [SyncLinkKind.hub, .cloud].first(where: { conflicts(for: $0).contains { $0.id == id } }) else {
            return nil
        }
        choices[link, default: [:]][id] = choice
        let answered = choices[link] ?? [:]
        return conflicts(for: link).allSatisfy { answered[$0.id] != nil } ? link : nil
    }
}

/// What the screens show about the iCloud link, on `SyncStatus` (never on `AppStore`, so a pass redraws only the
/// places that show sync). nil on a device with no iCloud link, where everything reads as it does today.
struct CloudDisplay: Equatable, Sendable {
    var role: CloudRole
    /// The link this device's screens speak for (`SyncRoute.active`).
    var active: SyncLinkKind
    /// The phone has synced through iCloud before.
    var joined: Bool
    /// The phone's "Sync directly with the Mac instead".
    var preferHub: Bool
    /// Why the last cloud pass stopped short; nil once one settles.
    var wait: CloudWait?
    /// When the cloud link last settled.
    var lastSync: Date?
    /// `status-mac.hubAt`: when the Mac's library last checked in with the hub (shown on the phone).
    var macHubAt: Date?
    /// The other device's choices still waiting, from its `Status` record.
    var otherConflicts = 0

    /// The phone's screens speak for iCloud.
    var carriesPhone: Bool { role == .phone && active == .cloud }
}
