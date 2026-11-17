# Watch Collection: resume note (lead, 2026-11-17 5:20 PM CST)

## State now: nothing in flight, nothing running
- Wishlist 120 Hz scrolling on the Mac shipped: main d8caa11 (pushed). Mac 5.1 (5) in /Applications, upToDate at
  22:32Z (349 photos, none missing). TestFlight 5.1 (35) VALID 22:34Z. Rollback: Mac copy
  ~/Offload/watch-collection/releases/mac-backup-5.1-4-20261117-1632.app; TestFlight 34.
- Mac only: VStack page, AdaptiveCardGrid with `.geometryGroup()`, cards built a row at a time, one screen-level delete
  confirmation; iPhone path unchanged. Bench (load ~290): 291 ms/s of hitches before, 0.5 to 1 after; look A/B: all 35
  card frames identical. Review: ~/Offload/watch-collection/review/perf/round1-findings.md (all fixed).
- Wishlist: 9 watches added today (5 Xeric, 2 Baltic, Zelos Comet 39 MOP, D1 Milano White Sketch), tiles rendered,
  fitted, published, in iCloud. Render ledger $9.90 of $15 (q216 closed).

## Next (no approvals needed)
1. Open item: the first-open stall of the Mac window is worse (worst frame 0.75 to 1.0 s against 0.26 s); the main
   thread is idle then, so likely the window server drawing every card. Measure on a quiet Mac with the bench
   (~/Offload/watch-collection/derived/perf/: exp.sh, launch-bg.sh uses `open -g`; throwaway hub
   scratchpad perf/run_hub.py on 8957; bundle id ...mac.perfcheck), then fix. Worktree ~/watch-collection-perf
   (branch perf/wishlist-scroll, merged) can be reused or removed.
2. Never put a test window in front of Jaden during a meeting; GUI runs launch with `open -g`.

## Earlier (12:05 PM)
## State now: nothing in flight
- iCloud polish round 2 shipped: main 449f299 (pushed). TestFlight 5.1 (34) in beta testing 18:01Z. Mac 5.1 (4) in
  /Applications, upToDate, revision fd26977f, 277/277 photos. Rollback: TestFlight 33; Mac copy
  ~/Offload/watch-collection/releases/mac-before-v5.1b4-20261117-1148. Worktree removed, branch merged and deleted.
- Phone still on 5.1 (32) at 16:33Z (has the new watches; renders-first needs 33 or 34 from TestFlight).

## Next (no approvals needed)
1. When status-iphone shows 5.1 (34) and revision fd26977f (or newer), the phone side is confirmed.
2. docs/icloud-polish.md items 18 to 21 (18 first: orphan photo files the Mac re-uploads to the hub).
3. More renders need a raised cap ($0.72 of $9 left): his word on the amount.

---

# Watch Collection: resume note (lead, 2026-11-17 9:25 AM CST, account switch checkpoint)

## State now: nothing in flight
- Renders-first shipped and verified: main 23d8467 (pushed). TestFlight 5.1 (33) VALID 15:03Z. Mac 5.1 (3) installed
  in /Applications 15:05Z, cloud-status upToDate, photos 277/277 in iCloud, revision fd26977f.
  Rollback: TestFlight 32; Mac copy in ~/Offload/watch-collection/releases/mac-before-v5.1b3-20261117-0905.
- Wishlist adds, rendered both finishes and published: AP 15707CB white ceramic (C$70,299 grey) and JLC Master Ultra
  Thin Moon Q1368430 (C$14,605 grey; prices are always grey market, never retail). Render ledger $8.28 of the $9 cap.
- Release worktree ~/watch-collection-rel removed. No agents, builds, hubs or wake-ups running; none to re-create.

## Next (no approvals needed)
1. 13 D second check: once the phone updates to 33 and syncs, status-iphone in the Mac cloud-status.json
   (~/Library/Containers/com.jadenkwek.watchcollection.mac/Data/Library/Application Support/WatchCollection/)
   should show build 5.1 (33) and revision fd26977f (it was 5.1 (32), fae23061, at 13:25Z).
2. Optional polish: docs/icloud-polish.md items 8 to 17.
3. More renders need a raised cap (only $0.72 left): his word on the amount.

---

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

## State (2026-11-17, fix round)
- icloud-sync = 0f7fc97 (pushed): P4, P5, rehearsal install.sh options (11befac), fix-round spec
  `docs/icloud-fixes.md` with lead decisions D1 to D12, `CloudSyncCopy.missing`.
- Rehearsal on Development passed all six steps of 13 B (evidence ~/Offload/watch-collection/test-evidence/icloud-rehearsal/).
- P8 review (opus xhigh) findings in ~/Offload/watch-collection/review/icloud-p8/: A ship with test gaps; B, C1, C2 fix first.
- Fix round running: builder E in this worktree (engine, wiring), U in ~/watch-collection-icloud-u (branch
  icloud-fix-u: bridge, lock, install.sh, status UI, versions 5.1 / Mac build 2), M in ~/watch-collection-icloud-m
  (branch icloud-fix-m: merge vectors). All uncommitted until the lead commits.

## Next
1. Commit E here; commit U and M on their branches; merge both into icloud-sync; xcodegen; full suite.
2. Re-review on opus xhigh: each P8 reviewer's area gets only its fix diff plus its own findings file.
3. Re-rehearse create and join on Development (fresh zone: erase the rehearsal document first, or use a new zone).
4. P9 rollout per plan section 9 and 13 C/D (backups first; fastlane AppStore profile must be regenerated).
5. Remove ~/watch-collection-icloud-review, -u, -m worktrees after merge.

## State (2026-11-17 ~2 AM CST)
- Fix round merged (E 4308314, U 2ee0dea, M eb91fcd), lead follow-ups a968b18 and 32c7bc9. 358 tests green.
- Round-two reviews (opus xhigh): B ship, C2 ship, C1 ship after two tests. Rehearsal 2 (Development, fresh zone)
  passed all six 13 B steps plus D1/D7/no-ping-pong/log-line checks (evidence test-evidence/icloud-rehearsal2/).
- Round 3 builder running: docs/icloud-fixes.md "Round 3" (R1 overtaken-round rule for confirmed writes, R2 D5 only
  until a base exists, R3 missing tests, R4 hub-link unreadable photo, R5 damaged photos together, R6 plan wording).
- After R3: lead reads the diff (third review round, no more reviewer loops), full suite, then P9 rollout:
  scratchpad rollout/backup.sh (section 9 step 1), merge icloud-sync into main (stash the 7 old local edits across
  the merge, as at v5.0), Mac Release signed (Production) installed, P6 check in Production, 13 C, LaunchAgent via
  tools/bridge/install.sh, fastlane beta (LC_ALL=en_US.UTF-8; sigh regenerates the AppStore profile), 13 D needs him
  to open the TestFlight build once (ask-jaden).

## ROLLED OUT 2026-11-17 ~2:25 AM CST (main 1ad2f74)
- Backups: ~/Offload/watch-collection/backups/pre-icloud-20261117-0209/ (hub watches.json, sync-history, photos; Mac
  container Application Support and prefs; manifest.sha).
- P6 check in Production: roundTrip, conflictSeen, environment Production.
- Mac Release 5.1 (2), Production, installed at /Applications; copy in releases/v5.1-mac-icloud-20261117-0211.
  First open created the Production document: 266/266 photos, epoch 14C5D619, revision fae23061 = hub projection =
  Mac data. LaunchAgent com.jaden.watch-collection-bridge installed (tools/bridge/install.sh). Test wishlist item
  through the hub reached iCloud in 4 s via the bridge; removed in 4 s; fingerprints back to fae23061.
- TestFlight 5.1 (32) VALID. 13 D waits on him opening the phone app once (ask-jaden Q186, sends 8 AM): then check
  status-iphone in the Mac's cloud-status.json (at fresh, revision equal) and a hub wishlist add reaching the phone.
- Rollback: `tools/bridge/install.sh remove`; Mac app from releases/mac-before-v5.1-icloud-20261117-0211; TestFlight
  build 31. Hub untouched. Cloud data can stay.
- Later items: docs/icloud-polish.md 8 to 17.
