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

## Checkpoint state
- The worktree is on branch `icloud-p2-wip` (local only), commit a43c861 = P2 files written, NOT yet compiled.
  `icloud-sync` stays at a0c3fdf (pushed). Squash the WIP into one P2 commit on icloud-sync when green.
- Open P3 gap found by the P2 builder: after an erase (`.purged`), `uploadPhoto`/`writeStatus` keep throwing
  `.purged` and only `write(over: nil)` re-saves the zone, after the photos. The Mac's "Sync through iCloud again"
  must re-create the zone first: add a `CloudStore.prepareZone()` (save the zone; never called on its own after an
  erase, only from the button's restart path), use it in `CloudLink.restartAfterErase`, and drop the fake's
  stand-in. P2's test 20 covers it.

## Exact next step
1. Read docs/p2-progress.md. Start a fresh builder (opus xhigh) in ~/watch-collection-icloud on icloud-p2-wip to
   compile, fix and get P2 green, and to close the P3 gap above. It must not redo P1/P3. Baseline before P2: 246
   tests green.
2. When P2 is green: lead reads the diff (or reviewer on opus xhigh if large), commit on icloud-sync, then
   `git merge icloud-p7` into icloud-sync, rerun tests (sim builds with the entitlements), push.
3. P4 (app wiring; plan section 11 P4, sections 4, 6, 7, 9), then P5 (bridge + LaunchAgent), then rehearsal
   (section 13 B, throwaway hub via scratchpad hub/run_hub.py, now pointing at this worktree), P8 review on opus
   xhigh, P9 rollout (backups first, section 9; fastlane AppStore profile must be regenerated).

## Rules that bind this work
No git add while agents run. Never commit data/ or exports/. Test builds never hit the real hub :8931. Throwaway sims
only, deleted after. Don't touch Arsenal/Dentiza/iPhone Duo/Arc Records sims. OpenAI key only via
WATCH_BOX_KEY_FILE. Personal project: review on opus xhigh, not Fable.
