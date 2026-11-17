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
        guard attemptSession == session, let cause = SyncFailure.classify(error) else { return }
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

    /// How long after a good sync a failed attempt stays quiet. The phone tries when it opens and then every
    /// 60 seconds, so three minutes is three missed attempts in a row while it is open: a real outage, not a
    /// blip in a lift. A phone opened after longer than this says so on its first failed attempt.
    static let staleAfter: TimeInterval = 180

    /// - Parameters:
    ///   - conflicts: the changes the Mac found made on both devices.
    ///   - resolutions: the choices made so far, by conflict id.
    static func evaluate(
        enabled: Bool,
        address: String,
        conflicts: [SyncConflict],
        resolutions: [String: String],
        failure: SyncFailure?,
        lastSync: Date?,
        now: Date
    ) -> SyncHealth {
        guard enabled else { return .off }
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
    var action: Action
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
            case .invalidAddress, .other:
                headline = "Sync did not finish"
                fix = "It will keep trying."
            }
            return SyncNotice(
                headline: headline,
                message: "\(last) \(fix)",
                action: .retry, actionLabel: "Try again", urgent: true
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
