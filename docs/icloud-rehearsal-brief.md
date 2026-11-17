You are running the rehearsal of the Watch Collection app's iCloud sync (plan `docs/icloud-plan.md` section 13 B) on
real CloudKit, Development environment, with none of his live data at risk. Worktree `~/watch-collection-icloud`,
branch `icloud-sync`, HEAD `b2fcc97` (P1 to P7 built, 308 tests green). Read the plan sections 4 to 9 and 13, the
commit messages of P2, P4 and P5 (`git log --format='%h %s%n%b' -8`), `docs/icloud-polish.md`, and
`tools/bridge/install.sh`.

## Setup
1. Throwaway hub on 127.0.0.1:8951 over a fresh COPY of his data. Make `~/Offload/watch-collection/rehearsal/hub/`
   with `data/watches.json` and `data/photos/` copied from `~/watch-collection/data/` (copy, never move, never write
   to the original). Run it with a wrapper like
   `/private/tmp/claude-501/-Users-jadenkwek-watch-collection/c3086eeb-7f7b-4824-9067-e118c2843b58/scratchpad/hub/run_hub.py`
   (it imports `server` from this worktree, binds 127.0.0.1, and MUST set `EXPORT_SCRIPT` to a no-op: the real
   export rclones to his Google Drive). Point DATA_FILE and PHOTOS_DIR at the rehearsal copy. Run it in the
   background and stop it at the end.
2. Build the Mac app Debug, signed for real so CloudKit works (this is the only way: the container is tied to the
   real App ID), into `~/Offload/watch-collection/derived/icloud-rehearsal`:
   `xcodebuild -project WatchCollection.xcodeproj -scheme WatchCollectionMac -configuration Debug -destination platform=macOS -derivedDataPath ~/Offload/watch-collection/derived/icloud-rehearsal -allowProvisioningUpdates -authenticationKeyPath ~/.appstoreconnect/private_keys/AuthKey_93RU83ZB8C.p8 -authenticationKeyID 93RU83ZB8C -authenticationKeyIssuerID b9aceb46-4ef8-4e04-818a-a62f670aede9 build`
   Check `codesign -d --entitlements -` shows `icloud-container-environment` = Development.
3. It shares the sandbox container and UserDefaults domain with his installed app (same bundle id, which is running
   right now: never quit, open or touch it). So EVERY run of the debug binary passes all of:
   `-WCDataRoot <root> -WCHub <address> -WCRole <mac|phone>`, with roots
   `~/Library/Containers/com.jadenkwek.watchcollection.mac/Data/rehearsal/mac` and `.../rehearsal/phone`.
   `-WCHub` is `http://127.0.0.1:8951` or `""`, never omitted: with no address the app falls back to the REAL hub on
   8931. Run the binary directly (`.../Contents/MacOS/Watch Collection`) with `-WCBridge 1` for ticks. Check first
   that `SyncLock`'s lock file lives under the data root; if it does not, stop and report (his running app would
   otherwise be affected later).

## Scenario (section 13 B, all six)
- Phone root first syncs with the throwaway hub through the hub link (no cloud document exists yet), so it has data
  and a hub base. Then make it stale: through the throwaway hub's API remove one wishlist item (the Mac side
  changes); in the phone root's own data (its `sync.json` data only, not its base) edit one watch's note and add one
  photo file plus its reference (that is the phone's own offline edit). Keep a copy of each file you edit by hand.
- Mac root: ticks until the document is created (photos first; about 147 MB to upload, so expect many 40 s ticks;
  loop ticks, log each tick's `cloud-status.json`).
- Then 1 to 6 of section 13 B exactly. For 5 (launchd), install a REHEARSAL LaunchAgent with its own label
  (`com.jaden.watch-collection-bridge.rehearsal`), the debug binary, the Mac root's args, and `WatchPaths` = the
  rehearsal hub's `data` folder (never the real one). Extend `install.sh` with options for label, watch path and
  extra args if it lacks them (that is a code change: keep it small and say so). Bootout and delete it at the end.
- Also check: a second Mac tick right after a settled one writes nothing (no ping-pong); the phone root's
  `sync-before-icloud-*.json` exists; the Mac root's too.

## After
- Compare his real app's state with the snapshot in `~/Offload/watch-collection/backups/pre-rehearsal-20261116/`:
  the preferences plist (keys and values; window frames may differ only if he used the app) and the shasums in
  `appsupport-files.sha` for `Application Support/WatchCollection/*`. Report any difference.
- `~/watch-collection/data/watches.json` must be byte-identical to before you started (shasum it first).
- Leave the Development CloudKit data as it is. Stop the hub. Remove the rehearsal LaunchAgent. Leave the rehearsal
  folders for the lead.
- Evidence (tick logs, the cloud-status files, the three fingerprints, the hub's sync-history listing) under
  `~/Offload/watch-collection/test-evidence/icloud-rehearsal/`.

## If something fails
Diagnose it. If the fix is in the app code and small (under about 50 lines), make it, add a unit test, rerun the suite
(commands in `docs/icloud-p4-brief.md`), and rerun the rehearsal step. Larger: stop and report with evidence.

## Rules
- No `git add`, `git commit` or other git writes; the lead commits.
- Never point anything at port 8931. Never quit, launch or modify his installed app or its data. Never load a
  LaunchAgent other than the rehearsal one, and remove that one.
- Never touch the simulators named Arsenal Duo, Dentiza Duo, iPhone Duo or Arc Records.
- No emojis or em-dashes in code comments.

## Report (short)
Each of the six steps: pass or fail, with the evidence file. Upload time for the photos. Any code you changed (files,
lines, why, tests). The snapshot comparison. Anything that surprised you.
