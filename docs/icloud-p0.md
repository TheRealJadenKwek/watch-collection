# iCloud P0 facts (two scouts compared, 2026-11-16)

Paths relative to ios/ unless noted. Line numbers at 2c7353a.

## Hub for the rehearsal
- server.py has no env or args: HOST/PORT/ROOT/DATA_FILE/PHOTOS_DIR/EXPORT_SCRIPT are module constants (server.py:34-39); main() reads them at call time.
- A wrapper that reassigns them and calls main() works. It MUST set EXPORT_SCRIPT to a no-op: /api/backup runs export_sheet.py --force with its own constants, which rclones the real data/watches.json to gdrive.
- Prior art: scratchpad/hub/run_hub.py (sets EXPORT_SCRIPT to noop.py, binds 127.0.0.1). It imports server from ~/watch-collection-full-tiles; point it at this worktree.
- last-remote-sync.txt and sync-history/ follow DATA_FILE.

## Fastlane
- get_provisioning_profile (sigh, no force) with the ASC API key; export is manual with that profile; xcodebuild gets -allowProvisioningUpdates plus the key. iOS lane only; the Mac target is in no lane.
- Adding the iCloud capability changes the App ID, so the AppStore profile must be regenerated: P7 must make sigh fetch a fresh one (force: true once, or delete the stale profile) or the archive fails on a profile without the container.

## Installed Mac app
- Built Release from the release folder, Apple Development signed, sandbox + network.client + files rw; installed by quit, ditto, reopen.

## Callers
- SyncHealth.evaluate: SyncHealth.swift:99; only caller SyncNotice.swift:37; tests SyncHealthTests.swift:33-34, 159, 200.
- SyncNoticeBar: CollectionView.swift:144, 175, 238; WishlistView.swift:101, 212, 235. SyncNoticePanel only inside SyncNoticeBar (SyncNotice.swift:48).
- lastPhoneSync: AppStore.swift:38 (SyncStatus), :70-72 proxy, :270 set in syncNow; Mac/MacApp.swift:259 SyncStatusBar.
- hubSupportsBoxes: AppStore.swift:104, :110, :166 (reset in configureSync), :298 (BoxModel.installing), :334 (noteHub). Tests BoxCodableTests.swift:122-142.
- canOfferStartingLayout: AppStore.swift:109 (wraps static startingLayoutAllowed :113), :139, :857, :924, :931; BoxesScreen.swift:1693.
- PhotoStore.shared.load: PhotoStore.swift:148, CollectionSync.swift:168, Components.swift:102, PhotoFraming.swift:147.
- syncNow: AppStore.swift :135 :157 :178 :186 :193 :198 :215 :244 :993 (commit); SettingsView.swift:133; SyncNotice.swift:31; WatchCollectionApp.swift:31 (BG task).
- configureSync: SettingsView.swift:123. resolveSyncConflict: SettingsView.swift:158.
- CollectionSyncClient construction: AppStore.swift:262 only.
- SyncDisk: AppStore.swift:125 (load), :305 and :1001 (save).
- Mac sync line is MacApp.swift SyncStatusBar (:241-274), not SyncNoticeBar.
