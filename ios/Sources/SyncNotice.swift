import SwiftUI

/// The line a main screen shows under its masthead when this device may not match the Mac: the cause as a kicker,
/// when it last synced and what to do, and one pill that tries again (or opens Settings). While sync is healthy it
/// draws nothing and takes no room.
///
/// It watches only the sync status, so a sync tick redraws this panel and not the screen around it. Whether sync is
/// on and the Mac's address come from the screen, which already redraws when Settings change them. Once iCloud
/// carries the phone (`status.cloud`), the panel speaks for iCloud and the address no longer matters.
struct SyncNoticeBar: View {
    @ObservedObject var status: SyncStatus
    let enabled: Bool
    let address: String
    /// One row, the kicker and the pill: for the short pane above the crease of a half-open folding iPhone.
    var compact = false
    /// Space around the panel, taken only while it shows.
    var insets = EdgeInsets()
    let retry: () -> Void
    let openSettings: () -> Void

    init(
        store: AppStore,
        compact: Bool = false,
        insets: EdgeInsets = EdgeInsets(),
        openSettings: @escaping () -> Void
    ) {
        status = store.status
        enabled = store.syncEnabled
        address = store.syncAddress
        self.compact = compact
        self.insets = insets
        retry = { Task { await store.syncNow() } }
        self.openSettings = openSettings
    }

    var body: some View {
        let now = Date()
        let health = SyncHealth.evaluate(
            enabled: enabled,
            address: address,
            conflicts: status.conflicts,
            resolutions: status.resolutions,
            failure: status.failure,
            lastSync: status.lastSync,
            now: now,
            cloud: status.cloud
        )
        Group {
            if let notice = health.notice(address: address, device: Platform.deviceName, now: now) {
                SyncNoticePanel(
                    notice: notice,
                    compact: compact,
                    busy: status.isSyncing,
                    act: notice.action == .settings ? openSettings : retry
                )
                .padding(insets)
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: health)
    }
}

/// The panel itself: a square panel on the card colour, like the wishlist's total above the cards.
struct SyncNoticePanel: View {
    let notice: SyncNotice
    var compact = false
    /// A sync attempt is running: the retry pill shows a spinner in place of its label and keeps its width.
    var busy = false
    let act: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Circle()
                    .fill(notice.urgent ? WatchTheme.warning : WatchTheme.muted)
                    .frame(width: 7, height: 7)
                    .accessibilityHidden(true)
                Text(notice.headline.uppercased())
                    .font(AtelierType.kicker)
                    .tracking(1.4)
                    .foregroundStyle(WatchTheme.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                Spacer(minLength: 8)
                // Some iCloud states have nothing to do on this device: no pill then.
                if notice.action != nil {
                    Button(action: act) {
                        Text(notice.actionLabel)
                            .opacity(spins ? 0 : 1)
                            .overlay {
                                if spins { ProgressView().controlSize(.small) }
                            }
                    }
                    .quietButton()
                    .controlSize(.small)
                    .accessibilityLabel(spins ? "Syncing" : notice.actionLabel)
                }
            }
            if !compact {
                Text(notice.message)
                    .font(AtelierType.caption)
                    .foregroundStyle(WatchTheme.ink)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, WatchTheme.panelPadding)
        .padding(.top, 12)
        .padding(.bottom, compact ? 12 : 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(WatchTheme.card)
        .accessibilityElement(children: .contain)
    }

    private var spins: Bool { busy && notice.action == .retry }
}
