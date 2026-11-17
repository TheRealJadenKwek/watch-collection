import Foundation

/// Why the last sync attempt did not finish. Worked out from the error once, so the screens never read
/// the status sentence to guess at the cause.
enum SyncFailure: Equatable {
    /// This device has no connection at all.
    case offline
    /// The Mac did not answer: Tailscale is off on this device, or the Mac is asleep or its sync service is down.
    case unreachable
    /// The address in Settings is not one a request can be sent to.
    case invalidAddress
    /// The Mac answered, with an error or with something that could not be read.
    case hub(String)
    case other(String)

    /// Nil for an attempt that was only cut short (the app went to the background): that says nothing about the Mac.
    static func classify(_ error: Error) -> SyncFailure? {
        if error is CancellationError { return nil }
        if let sync = error as? CollectionSyncError {
            switch sync {
            case .invalidAddress: return .invalidAddress
            case .missingPhoto, .server: return .hub(sync.localizedDescription)
            }
        }
        if error is DecodingError { return .hub("The Mac's reply could not be read.") }
        // Also catches an NSError in NSURLErrorDomain.
        if let url = error as? URLError {
            switch url.code {
            case .cancelled:
                return nil
            case .notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff, .callIsActive:
                return .offline
            case .cannotConnectToHost, .timedOut, .networkConnectionLost, .cannotFindHost, .dnsLookupFailed,
                 .secureConnectionFailed, .resourceUnavailable:
                return .unreachable
            case .badServerResponse, .cannotParseResponse, .cannotDecodeContentData, .cannotDecodeRawData,
                 .zeroByteResource, .dataLengthExceedsMaximum:
                return .hub(url.localizedDescription)
            default:
                return .other(url.localizedDescription)
            }
        }
        return .other(error.localizedDescription)
    }
}

/// When the failure the notice reads is set and when it is cleared. The store runs the attempts and keeps one of
/// these; it is kept apart so the rules are tested without a network.
struct SyncFailureLog: Equatable {
    /// Why an attempt of this session did not finish: nil until one fails, and again once one reaches the Mac.
    private(set) var failure: SyncFailure?
    /// A new session starts each time the phone comes to the front and each time the sync settings change. An
    /// attempt notes the session it began in.
    private(set) var session = 0

    /// The phone came to the front, or the sync settings changed. What failed before (an earlier visit, the
    /// overnight refresh, the old address) says nothing about the next attempt, so it is dropped. An attempt still
    /// running from before cannot bring it back: see `failed(_:in:)`.
    mutating func startSession() {
        session += 1
        failure = nil
    }

    /// The Mac answered. An earlier failure no longer holds, however the rest of the attempt goes.
    mutating func reachedMac() {
        failure = nil
    }

    /// An attempt begun in `attemptSession` failed with `error`. One begun before the current session is out of
    /// date and changes nothing (the timer's first attempt of a visit is turned away while it runs, so its failure
    /// would otherwise land as if it were this visit's). One cut short says nothing about the Mac and changes
    /// nothing either.
    mutating func failed(_ error: Error, in attemptSession: Int) {
        guard let cause = SyncFailure.classify(error) else { return }
        failed(cause, in: attemptSession)
    }

    /// The same for a cause already worked out (the iCloud link reports its own).
    mutating func failed(_ cause: SyncFailure, in attemptSession: Int) {
        guard attemptSession == session else { return }
        failure = cause
    }
}

/// Whether what this device shows can be trusted to match the Mac, and if not, why.
enum SyncHealth: Equatable {
    /// Nothing to say. The screens show nothing at all.
    case healthy
    case off
    case noAddress
    case badAddress
    /// Changes made on both devices are waiting for a choice in Settings (the count still without one).
    case conflicts(Int)
    /// The last attempt failed and the last good sync is old enough to matter (or there has never been one).
    case stale(SyncFailure, since: Date?)
    // The phone syncs through iCloud (docs/icloud-plan.md section 7):
    /// No iCloud account on this device, or it could not be read.
    case cloudSignedOut
    /// iCloud storage is full: changes stay here until there is room.
    case cloudFull
    /// The other device's choices still waiting (from its `Status` record).
    case choiceOnOtherDevice(Int)
    /// The iCloud copy was written by a newer build.
    case cloudNewerFormat
    /// He erased the app's iCloud data; the Mac starts it again.
    case cloudErased

    /// How long after a good sync a failed attempt stays quiet. The phone tries when it opens and then every
    /// 60 seconds, so three minutes is three missed attempts in a row while it is open: a real outage, not a
    /// blip in a lift. A phone opened after longer than this says so on its first failed attempt.
    static let staleAfter: TimeInterval = 180

    /// - Parameters:
    ///   - conflicts: the changes the Mac found made on both devices.
    ///   - resolutions: the choices made so far, by conflict id.
    ///   - cloud: the iCloud link, when this device has one. Only when its screens speak for iCloud (a phone that
    ///     has joined) does it change anything: then the address does not matter, and iCloud's own states speak.
    static func evaluate(
        enabled: Bool,
        address: String,
        conflicts: [SyncConflict],
        resolutions: [String: String],
        failure: SyncFailure?,
        lastSync: Date?,
        now: Date,
        cloud: CloudDisplay? = nil
    ) -> SyncHealth {
        guard enabled else { return .off }
        if let cloud, cloud.active == .cloud {
            let waiting = conflicts.filter { resolutions[$0.id] == nil }.count
            if waiting > 0 { return .conflicts(waiting) }
            switch cloud.wait {
            case .erased?: return .cloudErased
            case .newerFormat?: return .cloudNewerFormat
            case .noAccount?: return .cloudSignedOut
            case .full?: return .cloudFull
            default: break
            }
            if cloud.otherConflicts > 0 { return .choiceOnOtherDevice(cloud.otherConflicts) }
            guard let failure else { return .healthy }
            if let lastSync, now.timeIntervalSince(lastSync) < staleAfter { return .healthy }
            return .stale(failure, since: lastSync)
        }
        guard !address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .noAddress }
        // No later attempt can succeed with this address, so it does not wait out the three minutes.
        if failure == .invalidAddress { return .badAddress }
        // Only a conflict still without a choice holds sync up. Once each has one, the attempt that sends them
        // decides, and if it fails, that failure is what shows.
        let waiting = conflicts.filter { resolutions[$0.id] == nil }.count
        if waiting > 0 { return .conflicts(waiting) }
        guard let failure else { return .healthy }
        if let lastSync, now.timeIntervalSince(lastSync) < staleAfter { return .healthy }
        return .stale(failure, since: lastSync)
    }

    /// The address is one only Tailscale can reach: an IPv4 address in 100.64.0.0/10, an IPv6 address in
    /// fd7a:115c:a1e0::/48, a MagicDNS name under ts.net, or a MagicDNS short name (one label, like "my-mac").
    static func isTailscale(_ address: String) -> Bool {
        guard var host = URL(string: address.trimmingCharacters(in: .whitespacesAndNewlines))?.host?.lowercased() else {
            return false
        }
        // An IPv6 host may come with its brackets.
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        if host.contains(":") { return isTailscaleIPv6(host) }
        // A fully qualified name may end in a dot.
        if host.hasSuffix(".") { host.removeLast() }
        if host.isEmpty { return false }
        if host.hasSuffix(".ts.net") { return true }
        // A short name, which MagicDNS completes. localhost is this device.
        if !host.contains(".") { return host != "localhost" }
        let parts = host.split(separator: ".", omittingEmptySubsequences: false).map { UInt8($0) }
        guard parts.count == 4, let first = parts[0], let second = parts[1], parts[2] != nil, parts[3] != nil else {
            return false
        }
        return first == 100 && (64...127).contains(second)
    }

    /// Tailscale's IPv6 range, fd7a:115c:a1e0::/48: the first six bytes.
    private static func isTailscaleIPv6(_ host: String) -> Bool {
        var address = in6_addr()
        guard inet_pton(AF_INET6, host, &address) == 1 else { return false }
        let prefix: [UInt8] = [0xfd, 0x7a, 0x11, 0x5c, 0xa1, 0xe0]
        return withUnsafeBytes(of: address) { Array($0.prefix(prefix.count)) } == prefix
    }
}

/// The words a screen shows for an unhealthy sync, and what its one button does.
struct SyncNotice: Equatable {
    enum Action: Equatable { case retry, settings }

    /// A few words naming the cause, set as a kicker.
    var headline: String
    /// When it last synced and what to do, as one or two plain sentences.
    var message: String
    /// nil when there is nothing to do on this device (the panel then has no pill).
    var action: Action?
    var actionLabel: String
    /// Needs attention (red dot): what is on screen may be out of date. Otherwise a setting he chose (grey dot).
    var urgent: Bool
}

extension SyncHealth {
    /// What to show for this state, or nil while sync is healthy.
    /// - Parameters:
    ///   - address: the Mac's address, to tell a Tailscale address from one on the local network.
    ///   - device: what this device is called in copy ("iPhone").
    func notice(
        address: String,
        device: String,
        now: Date,
        calendar: Calendar = .current,
        locale: Locale = .current
    ) -> SyncNotice? {
        switch self {
        case .healthy:
            return nil
        case .off:
            return SyncNotice(
                headline: "Sync is off",
                message: "Changes stay on this \(device) until you turn sync on.",
                action: .settings, actionLabel: "Settings", urgent: false
            )
        case .noAddress:
            return SyncNotice(
                headline: "Sync not set up",
                message: "Add your Mac's address to share changes with it.",
                action: .settings, actionLabel: "Settings", urgent: false
            )
        case .badAddress:
            return SyncNotice(
                headline: "Sync not set up",
                message: "The Mac's address should look like http://your-mac:8931.",
                action: .settings, actionLabel: "Settings", urgent: true
            )
        case let .conflicts(count):
            return SyncNotice(
                headline: "Sync paused",
                message: count == 1
                    ? "1 change was made on both devices. Choose which one to keep."
                    : "\(count) changes were made on both devices. Choose which to keep.",
                action: .settings, actionLabel: "Choose", urgent: true
            )
        case let .stale(failure, since):
            let last = Self.lastSynced(since, now: now, calendar: calendar, locale: locale)
            let headline: String
            let fix: String
            switch failure {
            case .offline:
                headline = "\(device) is offline"
                fix = "Sync picks up again when this \(device) is back online."
            case .unreachable:
                headline = "Can't reach your Mac"
                fix = Self.isTailscale(address)
                    ? "Turn on Tailscale on this \(device) and check your Mac is awake."
                    : "Check your Mac is awake and on the same network as this \(device)."
            case .hub:
                headline = "Sync did not finish"
                fix = "Your Mac answered but could not finish. It will keep trying."
            case .other(CloudSyncCopy.missing):
                headline = "iCloud copy missing"
                fix = CloudSyncCopy.missing
            case .invalidAddress, .other:
                headline = "Sync did not finish"
                fix = "It will keep trying."
            }
            return SyncNotice(
                headline: headline,
                message: "\(last) \(fix)",
                action: .retry, actionLabel: "Try again", urgent: true
            )
        case .cloudSignedOut:
            return SyncNotice(
                headline: "Signed out of iCloud",
                message: CloudSyncCopy.signedOut(device: device),
                action: .retry, actionLabel: "Try again", urgent: true
            )
        case .cloudFull:
            return SyncNotice(
                headline: "iCloud is full",
                message: CloudSyncCopy.full(device: device),
                action: nil, actionLabel: "", urgent: true
            )
        case let .choiceOnOtherDevice(count):
            return SyncNotice(
                headline: "Choice waiting",
                message: CloudSyncCopy.choiceWaiting(count, device: device),
                action: nil, actionLabel: "", urgent: true
            )
        case .cloudNewerFormat:
            return SyncNotice(
                headline: "Update needed",
                message: CloudSyncCopy.newerFormat(device: device),
                action: nil, actionLabel: "", urgent: true
            )
        case .cloudErased:
            return SyncNotice(
                headline: "iCloud copy erased",
                message: CloudSyncCopy.erased(device: device),
                action: nil, actionLabel: "", urgent: true
            )
        }
    }

    /// "Last synced at 10:22 AM." today, "Last synced yesterday at 10:22 AM.", "Last synced on Nov 14." before that,
    /// and "Not synced with your Mac yet." when there has never been one.
    static func lastSynced(_ date: Date?, now: Date, calendar: Calendar = .current, locale: Locale = .current) -> String {
        guard let date else { return "Not synced with your Mac yet." }
        var time = Date.FormatStyle(date: .omitted, time: .shortened)
        time.locale = locale
        time.calendar = calendar
        time.timeZone = calendar.timeZone
        if calendar.isDate(date, inSameDayAs: now) { return "Last synced at \(date.formatted(time))." }
        if let dayBefore = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: dayBefore) {
            return "Last synced yesterday at \(date.formatted(time))."
        }
        var day = Date.FormatStyle().month(.abbreviated).day()
        day.locale = locale
        day.calendar = calendar
        day.timeZone = calendar.timeZone
        return "Last synced on \(date.formatted(day))."
    }
}

/// The words for the iCloud link, from docs/icloud-plan.md section 7, for this device ("iPhone" or "Mac").
enum CloudSyncCopy {
    /// The device on the other side of iCloud.
    static func other(_ device: String) -> String { device == "Mac" ? "iPhone" : "Mac" }

    /// The phone's sync line once iCloud carries it.
    static func carrier(device: String) -> String { "Syncs with your \(other(device)) through iCloud." }

    static func signedOut(device: String) -> String { "Sign in to iCloud to sync with your \(other(device))." }

    static func full(device: String) -> String { "iCloud storage is full, so changes stay on this \(device)." }

    static func choiceWaiting(_ count: Int, device: String) -> String {
        count == 1
            ? "1 change needs your choice on your \(other(device))."
            : "\(count) changes need your choice on your \(other(device))."
    }

    static func newerFormat(device: String) -> String { "Update Watch Collection on this \(device) to keep syncing." }

    /// On the Mac it comes with the one button, "Sync through iCloud again"; the phone can only point at the Mac.
    static func erased(device: String) -> String {
        let base = "The iCloud copy was erased. Nothing on this \(device) was removed."
        return device == "Mac" ? base : "\(base) Open Watch Collection on your Mac to start iCloud sync again."
    }

    static let restartButton = "Sync through iCloud again"

    static func sending(_ done: Int, of total: Int) -> String { "Sending \(done) of \(total) photos to iCloud." }

    /// The Mac with no document and no clean hub pass to make it from (section 6).
    static let needsHubFirst = "iCloud sync starts once this Mac reaches its library."

    /// A joined phone finds no iCloud copy (docs/icloud-fixes.md D10).
    static let missing = "The iCloud copy is missing. Open Watch Collection on your Mac to start iCloud sync again."

    /// The sentence the sync line adds for the iCloud link's state, or nil when there is nothing to say (settled,
    /// or a pause the next tick deals with quietly). The phone's banner says the same for the states it covers.
    static func sentence(_ cloud: CloudDisplay, device: String) -> String? {
        switch cloud.wait {
        case .noAccount?: return signedOut(device: device)
        case .full?: return full(device: device)
        case .newerFormat?: return newerFormat(device: device)
        case .erased?: return erased(device: device)
        case let .sendingPhotos(done, total)?: return sending(done, of: total)
        case .needsHubFirst?: return needsHubFirst
        // A phone that has joined finds no copy: not settled, it says so (docs/icloud-fixes.md D10). One that has
        // not joined keeps its hub link and has nothing to say.
        case .noDocument?: if cloud.role == .phone, cloud.joined { return missing }
        case .offline?, .busy?, .failed?, nil: break
        }
        return cloud.otherConflicts > 0 ? choiceWaiting(cloud.otherConflicts, device: device) : nil
    }

    /// Settings' iCloud sentence. With the phone's "Sync directly with the Mac instead" on, no cloud pass runs, so the
    /// iCloud state is frozen where it was: Settings then shows the hub's lines only (C2#6).
    static func settingsSentence(_ cloud: CloudDisplay, device: String) -> String? {
        if cloud.role == .phone, cloud.preferHub { return nil }
        return sentence(cloud, device: device)
    }

    /// The Mac sidebar's line when the iCloud link has not settled for `SyncHealth.staleAfter`: "Last synced
    /// through iCloud 3 hr ago. It will keep trying."
    static func notSettled(since date: Date?, now: Date) -> String {
        let last = date.map { "Last synced through iCloud \(ago($0, now: now))." } ?? "Not synced through iCloud yet."
        return "\(last) It will keep trying."
    }

    /// "Last synced 2 min ago".
    static func lastSynced(_ date: Date?, now: Date) -> String? {
        date.map { "Last synced \(ago($0, now: now))" }
    }

    /// "Mac's library checked in 9:41 PM": when the Mac last reached the hub (`status-mac.hubAt`). Information only;
    /// the MacBook sleeping overnight is normal.
    static func macCheckedIn(_ date: Date?, now: Date, calendar: Calendar = .current, locale: Locale = .current) -> String? {
        date.map { "Mac's library checked in \(checkedInTime($0, now: now, calendar: calendar, locale: locale))" }
    }

    /// The same as the value of Settings' "Mac's library" row: "Checked in 9:41 PM".
    static func checkedIn(_ date: Date?, now: Date, calendar: Calendar = .current, locale: Locale = .current) -> String? {
        date.map { "Checked in \(checkedInTime($0, now: now, calendar: calendar, locale: locale))" }
    }

    /// "9:41 PM" today, "yesterday at 9:41 PM", else "on Nov 3".
    private static func checkedInTime(_ date: Date, now: Date, calendar: Calendar, locale: Locale) -> String {
        var time = Date.FormatStyle(date: .omitted, time: .shortened)
        time.locale = locale
        time.calendar = calendar
        time.timeZone = calendar.timeZone
        if calendar.isDate(date, inSameDayAs: now) { return date.formatted(time) }
        if let dayBefore = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: dayBefore) {
            return "yesterday at \(date.formatted(time))"
        }
        var day = Date.FormatStyle().month(.abbreviated).day()
        day.locale = locale
        day.calendar = calendar
        day.timeZone = calendar.timeZone
        return "on \(date.formatted(day))"
    }

    /// The value of Settings' "Status" row while iCloud carries the phone.
    static let throughICloud = "Through iCloud"

    /// The Mac's line for the phone: "iPhone, 2 min ago".
    static func phoneSeen(_ date: Date, now: Date) -> String { "iPhone, \(ago(date, now: now))" }

    /// "just now", "2 min ago", "3 hr ago", "2 days ago". A clock set back reads as just now.
    static func ago(_ date: Date, now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        if seconds < 60 { return "just now" }
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "\(minutes) min ago" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours) hr ago" }
        let days = hours / 24
        return days == 1 ? "1 day ago" : "\(days) days ago"
    }
}

/// The Mac sidebar's sync line (docs/icloud-fixes.md D11): the worse of the hub link and the iCloud link. iCloud
/// paused (erased), stopped (a newer format), signed out, full, or a choice waiting on the iPhone shows at once;
/// offline, failed or throttled only once the iCloud link has not settled for `SyncHealth.staleAfter`, the same wait
/// the phone's notice has. A tie goes to the hub: the Mac's own library first.
struct MacSyncLine: Equatable {
    /// The first line, by the dot.
    var headline: String
    /// Green dot: the hub is up to date and iCloud has nothing to say. Amber otherwise.
    var settled: Bool
    /// The hub's own words, kept on the line under the headline when iCloud has taken it.
    var hubLine: String?
    /// The iCloud sentence, under the times.
    var cloudLine: String?

    /// What the hub link says today, as it always has.
    static let hubSettledMessage = "Up to date"

    static func evaluate(hubMessage: String, conflicts: Int, cloud: CloudDisplay?, now: Date) -> MacSyncLine {
        let hubHeadline = conflicts == 0 ? hubMessage : "\(conflicts) changes need a choice"
        let hubSettled = conflicts == 0 && hubMessage == hubSettledMessage
        guard let cloud else { return MacSyncLine(headline: hubHeadline, settled: hubSettled) }
        guard let alert = alert(cloud, now: now) else {
            return MacSyncLine(headline: hubHeadline, settled: hubSettled,
                               cloudLine: CloudSyncCopy.sentence(cloud, device: "Mac"))
        }
        // 2: a choice waits on this Mac. 1: the hub has not finished. 0: settled.
        let hubRank = conflicts > 0 ? 2 : (hubSettled ? 0 : 1)
        if hubRank >= alert.rank {
            return MacSyncLine(headline: hubHeadline, settled: false, cloudLine: alert.line)
        }
        return MacSyncLine(headline: alert.headline, settled: false, hubLine: hubHeadline, cloudLine: alert.line)
    }

    /// The iCloud state that needs a word in the headline, with its rank: 2 needs him now, 1 has not settled for too
    /// long. nil while the link is settled, sending photos, or in a pause the next tick deals with quietly.
    private static func alert(_ cloud: CloudDisplay, now: Date) -> (rank: Int, headline: String, line: String)? {
        switch cloud.wait {
        case .erased?: return (2, "iCloud paused", CloudSyncCopy.erased(device: "Mac"))
        case .newerFormat?: return (2, "iCloud sync stopped", CloudSyncCopy.newerFormat(device: "Mac"))
        case .noAccount?: return (2, "Signed out of iCloud", CloudSyncCopy.signedOut(device: "Mac"))
        case .full?: return (2, "iCloud is full", CloudSyncCopy.full(device: "Mac"))
        default: break
        }
        if cloud.otherConflicts > 0 {
            return (2, "Choice waiting", CloudSyncCopy.choiceWaiting(cloud.otherConflicts, device: "Mac"))
        }
        switch cloud.wait {
        case .offline?, .busy?, .failed?:
            if let last = cloud.lastSync, now.timeIntervalSince(last) < SyncHealth.staleAfter { return nil }
            let headline = cloud.wait == .offline ? "Can't reach iCloud" : "iCloud sync did not finish"
            return (1, headline, CloudSyncCopy.notSettled(since: cloud.lastSync, now: now))
        default:
            return nil
        }
    }
}
