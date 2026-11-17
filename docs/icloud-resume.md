# iCloud sync: resume note (lead, 2026-11-16 ~10:40 PM CST, account switch checkpoint)

## Done
- Shipped tonight (main 2c7353a, pushed): full straps, wishlist price sort, phone not-synced notice. TestFlight 31 VALID;
  Mac Release installed. Rollback: TestFlight 30, Mac ~/Offload/watch-collection/releases/v5.0-mac-wlprice-20261116-1702.
- Box tiles: refit with the lug fix (121 fitted), checked, published; Mac app shows them.
- iCloud branch `icloud-sync` (worktree ~/watch-collection-icloud, pushed to origin):
  - 371b957 P3+P6: CloudKitStore, CloudRecords, CloudSync.swift shared types (incl. `photoFileMissing`), DEBUG
    CloudKit check, docs/icloud-plan.md and docs/icloud-p0.md.
  - a0c3fdf P1: JSONValue, CollectionMerge (355/355 vectors equal sync.py), tools/merge_vectors.py.
- Branch `icloud-p7` (worktree ~/watch-collection-icloud-p7, f89dbd6, not pushed): iCloud entitlements, WC_CLOUDKIT
  flag, Mac WC_CLOUDKIT_ENV Debug=Development / Release=Production. Merge into icloud-sync AFTER P2 lands.
- Apple web setup, all done by Codex in his signed-in Safari (no ask needed): container registered; iCloud on
  com.jadenkwek.watchcollection; new App ID com.jadenkwek.watchcollection.mac with iCloud; schema deployed to
  Production. P6 check passed in Development and Production. Profiles carry the container and allow Production.

## In flight at the checkpoint
- P2 builder (cloud link: CloudSync.swift additions, CloudPhotos.swift, CloudLinkTests.swift, FakeCloudStore.swift)
  in ~/watch-collection-icloud, uncommitted. It was asked to write docs/p2-progress.md before stopping.
  Its brief: docs/icloud-p2-brief.md.

## State (2026-11-16 ~11:15 PM, after the account switch)
- icloud-sync = dec6286: P3+P6, P1, P2 (809243d, 274 tests green, erase-restart gap closed with
  `CloudStore.prepareZone()` called only by `CloudLink.restartAfterErase`), P7 merged.
- Known residual risk for the P8 review: `CloudKitStore.write(over: nil)` saves the zone itself; if he erases the zone
  between a pass's head fetch and its create, and the Mac had no photos to send, the create re-makes the zone.
- Test 10b was changed to match the plan: a same-name, other-bytes photo is only detected when the upload is refused.

## Exact next step
1. P4 builder (opus xhigh) from docs/icloud-p4-brief.md, in this worktree.
2. Lead commits P4; then P5 (bridge + LaunchAgent; plan section 11 P5).
3. Rehearsal (section 13 B, throwaway hub via scratchpad hub/run_hub.py pointing at this worktree, Development
   environment, data roots under the Mac app's container), P8 review on opus xhigh over the whole diff in three
   sittings, P9 rollout (backups first, section 9; fastlane AppStore profile must be regenerated).

## Rules that bind this work
No git add while agents run. Never commit data/ or exports/. Test builds never hit the real hub :8931. Throwaway sims
only, deleted after. Don't touch Arsenal/Dentiza/iPhone Duo/Arc Records sims. OpenAI key only via
WATCH_BOX_KEY_FILE. Personal project: review on opus xhigh, not Fable.
