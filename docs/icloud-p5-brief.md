You are building part P5 of the Watch Collection app's iCloud sync: the headless bridge that keeps the Mac's link
between the hub and iCloud running while the Mac app is closed. Worktree `~/watch-collection-icloud`, branch
`icloud-sync`. The design is `docs/icloud-plan.md`: read sections 1, 4, 6, 8, 9 and P5 in section 11, which is your
spec. P4 (the app wiring: `AppStore.cloudPass`, the per-link settle state, `cloud.json`, `cloud-status.json`) is
committed; read its commit message and `docs/icloud-resume.md` first.

## Build (files as P5 lists them)
`ios/Mac/MacApp.swift` (entry), new `ios/Mac/Bridge.swift`, new `ios/Sources/SyncLock.swift`, new
`tools/bridge/com.jaden.watch-collection-bridge.plist`, new `tools/bridge/install.sh`; test
`ios/UnitTests/SyncLockTests.swift`.
- `@main enum Entry` replaces `@main` on `WatchCollectionMacApp` and decides before SwiftUI starts:
  `-WCCloudKitCheck` (DEBUG) -> `CloudKitCheck.runAndExit`; `-WCBridge` -> `Bridge.runAndExit()`; else
  `WatchCollectionMacApp.main()`. Remove the one-line check hook P6 put in the App's `init()`.
- `SyncLock` exactly as P5 says (flock on `Application Support/WatchCollection/sync.lock`, the `want` file, the GUI
  holds it for life, the bridge never blocks). The GUI must still start if the lock file cannot be opened (log it,
  carry on): a lock problem must never stop him using the app.
- `Bridge`: no window, `NSApp` never activates, no Dock icon (set the activation policy to prohibited before anything
  else), one tick = hub pass, cloud pass, hub pass again only if the cloud pass installed; `Status` write;
  `cloud-status.json`; exit 0. Watchdog exits at 50 s whatever is running. Conflicts are counted into
  `status-mac.conflicts`, never answered. It reuses `AppStore`'s passes; do not fork a second copy of the sync logic.
- LaunchAgent per P5 (`StartInterval` 60, `RunAtLoad`, `WatchPaths` = the hub's data FOLDER
  `/Users/jadenkwek/watch-collection/data`, `ThrottleInterval` 10, `ProcessType` Background, logs to
  `~/Library/Logs/watch-collection-bridge.log`). `install.sh` writes it to `~/Library/LaunchAgents` and bootstraps it
  into `gui/$(id -u)`; `install.sh remove` boots it out and deletes the plist. `install.sh` takes an optional binary
  path (default `/Applications/Watch Collection.app/Contents/MacOS/Watch Collection`) so the rehearsal can point it
  at a debug build. Do NOT run `install.sh` against the real app; the lead installs it at rollout.

## Tests and checks
- `SyncLockTests` as P5 lists them.
- The full unit suite green; the ad-hoc Mac Debug build green.
- Run the ad-hoc Debug build with `-WCBridge 1` once from the shell with no hub address configured for its throwaway
  bundle id: it must exit 0 within 50 s, show no window and no Dock icon, and write `cloud-status.json` saying the
  cloud link is off (the gate is nil in an ad-hoc build). With the GUI of that same build open, `-WCBridge 1` must
  exit at once.

## Commands
Unit tests and the ad-hoc Mac build: exactly the two commands in `docs/icloud-p4-brief.md` (they use a sandbox-only
entitlements file for the ad-hoc build; never build it without one).

## Rules
- No `git add`, `git commit` or other git writes; the lead commits.
- Touch only the files named above.
- Never touch the simulators named Arsenal Duo, Dentiza Duo, iPhone Duo or Arc Records; throwaway sims only, deleted.
- Never point anything at the real hub on port 8931; never run anything with the real bundle id; never load a
  LaunchAgent.
- No emojis or em-dashes in comments or copy.

## Report (short)
Files and line counts; test count and result; the two bridge runs (exit codes, times, what `cloud-status.json`
said); each place you departed from the plan, with the reason; the three spots a reviewer should read first.
