You are building part P4 of the Watch Collection app's iCloud sync: wiring the cloud link into the app. Worktree
`~/watch-collection-icloud`, branch `icloud-sync`. The design is `docs/icloud-plan.md`: read sections 1 to 9 whole and
P4 in section 11, which is your spec. `docs/icloud-p0.md` maps every caller you will touch (path:line).

## Already built and committed (use, do not rewrite)
- P1 `CollectionMerge` / `JSONValue` (the merge, twin of sync.py).
- P2 `CloudLink`, `CloudBook`, `CloudInput`, `CloudOutcome`, `CloudWait`, `CloudPause`, `CloudPhotoMarks` in
  `ios/Sources/CloudSync.swift` and `ios/Sources/CloudPhotos.swift`, tested against `FakeCloudStore`. Read
  `docs/p2-progress.md` for the decisions P4 must honour, especially:
  - the caller saves the returned book after EVERY pass (an `.upToDate` can carry a newer book);
  - section 4 step 8 is yours: if a local edit landed during the pass (`editGeneration` moved), drop both the result
    data and the book, and go round again;
  - section 4 step 9 write order: `sync.json` (data) first, `cloud.json` (book) second.
- P3 `CloudKitStore.live()` (nil unless WC_CLOUDKIT, the entitlement, a real device, not XCTest, not `-WCNoCloud`,
  and in DEBUG only with `-WCDataRoot`). P7 entitlements and the WC_CLOUDKIT flag are merged.

## Build (files as P4 lists them)
`ios/Sources/AppStore.swift`, `CollectionSync.swift`, `PhotoStore.swift`, `SyncHealth.swift`, `SyncNotice.swift`,
`SettingsView.swift`, `WatchCollectionApp.swift`, `ios/Mac/MacApp.swift`; tests `ios/UnitTests/SyncHealthTests.swift`
(extend), new `ios/UnitTests/SyncRoutingTests.swift`. New small files are fine where they keep AppStore readable
(for example `ios/Sources/CloudFiles.swift` for `cloud.json`, `cloud-photos.json`, `cloud-status.json` and the
one-time `sync-before-icloud-<time>.json`).

Everything P4 lists, plus:
- Section 9 step 2: before this device's first cloud write or install, write `sync-before-icloud-<time>.json` and run
  `LocalBackup.mirrorJSON` once regardless of `autoBackup`. Never deleted by the app.
- The narrowed drop rule in `CollectionSyncClient.exchange` (section 5, last bullet).
- `PhotoStore.load` cloud source (section 5): local file, else iCloud by name (size and sha256 checked, atomic
  write), else placeholder; hub URL only when the hub link is the active one.
- Copy from section 7, exactly. Settings on iPhone keeps one switch "Sync directly with the Mac instead". The Mac's
  erased state shows one button, "Sync through iCloud again", calling `CloudLink.restartAfterErase`.
- Perf rule in this codebase: sync state lives on `SyncStatus` (its own ObservableObject), never as `@Published` on
  `AppStore`. Keep it that way for every new status field.
- The app must behave exactly as today wherever `CloudKitStore.live()` is nil (simulators, tests, Debug without
  `-WCDataRoot`).

## Tests
As P4 lists, plus: the backup-before-first-cloud-write happens once; a pass whose edit generation moved installs
nothing and saves no book; the book is saved after an `.upToDate` that changed it; routing on the phone never runs
both links in one tick.

## Commands
```
cd ~/watch-collection-icloud/ios && xcodegen generate >/dev/null && U=$(xcrun simctl create wc-p4-test com.apple.CoreSimulator.SimDeviceType.iPhone-17 com.apple.CoreSimulator.SimRuntime.iOS-27-2) && xcodebuild test -project WatchCollection.xcodeproj -scheme WatchCollection -destination id=$U -derivedDataPath ~/Offload/watch-collection/derived/icloud/unit -only-testing:WatchCollectionTests 2>&1 | grep -E "error:|Executed [0-9]+ tests.*seconds|TEST (SUCCEEDED|FAILED)|failed \(" | tail -20; xcrun simctl delete $U && echo "sim deleted"
```
```
cd ~/watch-collection-icloud/ios && xcodebuild -project WatchCollection.xcodeproj -scheme WatchCollectionMac -destination platform=macOS -derivedDataPath ~/Offload/watch-collection/derived/icloud/mac -configuration Debug PRODUCT_BUNDLE_IDENTIFIER=com.jadenkwek.watchcollection.mac.icloudcheck CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= PROVISIONING_PROFILE_SPECIFIER= CODE_SIGN_ENTITLEMENTS=$HOME/Offload/watch-collection/derived/icloud/adhoc-mac.entitlements build 2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)"
```
The ad-hoc Mac build is sandboxed with that file (no iCloud keys: an ad-hoc signature cannot carry them), so it runs
with its own container and `CloudKitStore.live()` is nil. Never build it without an entitlements file.

Screenshots of Settings with each status forced by the DEBUG flag `-WCCloudStatus <case>`: run the iPhone app on a
throwaway simulator (iPhone 17, then delete it) and the ad-hoc Mac Debug build above, both with `-WCCloudStatus`;
neither may point at the real hub on port 8931 (leave the sync address empty or use `-WCHub http://127.0.0.1:8951`).
Save them under `~/Offload/watch-collection/test-evidence/icloud-p4/`.

## Rules
- No `git add`, `git commit` or other git writes; the lead commits.
- Touch only the files named above (and new files you add under ios/Sources or ios/UnitTests).
- Never touch the simulators named Arsenal Duo, Dentiza Duo, iPhone Duo or Arc Records; throwaway sims only, deleted.
- Never point anything at the real hub on port 8931. Never use the real bundle id for a test build.
- Do not write the Rolex name in UI copy or code. No emojis or em-dashes in copy or comments.

## Report (short)
Files and line counts; test count and result; Mac build result; screenshot paths; each place you departed from the
plan or chose something it left open, with the reason; the three spots a reviewer should read first.
