You are running the second rehearsal of the Watch Collection app's iCloud sync on real CloudKit, Development
environment, after the P8 fix round. Worktree `~/watch-collection-icloud`, branch `icloud-sync` (read
`git log --format='%h %s%n%b' -8`). The first rehearsal passed; its brief is `docs/icloud-rehearsal-brief.md` and its
evidence is in `~/Offload/watch-collection/test-evidence/icloud-rehearsal/`. Follow that brief's Setup, Scenario,
After and Rules exactly, with the changes below. Read `docs/icloud-fixes.md` (what changed) and plan section 13 B.

## Changes from the first rehearsal
1. Fresh everything: a new hub copy under `~/Offload/watch-collection/rehearsal2/hub/` (copied from
   `~/watch-collection/data/` now; shasum `~/watch-collection/data/watches.json` before and after), new data roots
   `~/Library/Containers/com.jadenkwek.watchcollection.mac/Data/rehearsal2/{mac,phone}`, evidence under
   `~/Offload/watch-collection/test-evidence/icloud-rehearsal2/`. Hub port 8952.
2. The Development zone `Collection` still holds the first rehearsal's document. Remove it so the Mac CREATES again:
   add a DEBUG-only option to `ios/Mac/CloudKitCheck.swift`, `-WCCloudKitResetZone 1`, that deletes the zone
   `Collection` and exits, and refuses (exit non-zero, says why) unless the signed environment entitlement is
   `Development`. Small change, keep it under about 40 lines, no other file. Run it once with the signed Debug
   build before the scenario. This also exercises D6 on real CloudKit: the create must answer `zoneNotFound`, make
   the zone, and retry (log it).
3. Before the scenario, take a fresh snapshot of his real app's state (prefs plist, shasums of
   `Application Support/WatchCollection/*` in his container) into
   `~/Offload/watch-collection/backups/pre-rehearsal2-<date>/`, and compare against it at the end, as the first
   rehearsal did against its snapshot.
4. Extra checks after the six steps of 13 B:
   - D1: run one Mac create where an edit lands in the Mac root mid-pass (edit its `sync.json` data between the
     photo upload finishing and the document write, or use any DEBUG hook already there). After the next pass,
     nothing the edit removed comes back and no conflict is raised. If there is no clean way to time it on real
     CloudKit, say so and rely on the unit test.
   - D7 on the signed build: while a bridge tick for the Mac root runs, `lsappinfo list` shows no new
     "Watch Collection" entry from the debug build. Do NOT `open` anything with the real bundle id.
   - No ping-pong: two settled Mac ticks in a row; the second writes nothing (revision unchanged, no new hub
     sync-history file).
   - The bridge log line names `WCBridgeEntry-v1` and build 5.1 (2).
5. The rehearsal LaunchAgent (step 5) is installed with the new `install.sh` (label
   `com.jaden.watch-collection-bridge.rehearsal2`, watch path the rehearsal2 hub's data folder) and removed at the end.

## Rules (in addition to the first brief's)
- The only code you may change is the reset option in CloudKitCheck.swift (item 2). Anything else that fails:
  diagnose it, and if the fix is in app code, STOP and report with evidence (no other code changes in this run).
- No git writes. Never port 8931. Never quit, open or touch his installed app or its data; every run of the debug
  binary passes `-WCDataRoot`, `-WCHub` and `-WCRole`.

## Report (short)
Each of the six steps and each extra check: pass or fail, with the evidence file. The D6 log line. Upload time.
The snapshot comparison and the watches.json shasum. The code you added (lines). Anything that surprised you.
