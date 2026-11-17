# Polish queued for the P8 fix round (lead, from the P4 screenshots)

1. iPhone Settings, iCloud joined: "Last synced 2 min ago" and "Mac's library checked in 9:41 PM" are plain small-text
   rows, while the hub mode uses label/value rows ("Status / Up to date", "Last synced / <date>"). Use the same
   label/value rows in iCloud mode: Status / "Through iCloud"; Last synced / "2 min ago"; Mac's library / "Checked in
   9:41 PM". Keep the section 7 sentence "Syncs with your Mac through iCloud." as the first row.
2. Mac sidebar, iCloud erased (and full, signed out, newer format): the headline still reads "Up to date" (the hub
   link) above the erased sentence. When the iCloud link is paused or blocked, the headline names that state
   ("iCloud paused") and the dot is amber; the hub line stays below it.
Evidence: ~/Offload/watch-collection/test-evidence/icloud-p4/phone-joined.png, mac-erased-window.png.
3. Bridge backup churn (P5 finding): `AppStore.start()` rewrites the JSON mirror at every launch when autoBackup is on
   (AppStore.swift:212), so the bridge would rewrite it every 60 s. In bridge mode, mirror only after a tick that
   installed something.
4. Bridge Dock-icon guard (P5, kept by the lead): Bridge.swift marks the process background-only by mutating the
   in-memory Info dictionary before AppKit starts. If a future macOS breaks that, only the bridge fails, visibly
   (status-mac.at goes stale). Review it in P8; the fallback is a bridge without NSApplication.
5. Rehearsal and any debug run must pass `-WCHub` explicitly: with no saved address the Mac app falls back to the real
   hub http://127.0.0.1:8931 (Theme.swift:16).
6. Rehearsal finding: each bridge process does a full hub exchange and rewrites the Mac's `sync.json` every tick
   though only `lastSuccess` changed. Skip the rewrite (and the hub POST if the hub fast path allows) when nothing
   but `lastSuccess` moved. Low priority; local disk churn only.
7. Rehearsal: `tools/bridge/install.sh` gained `--label` and `--watch` (uncommitted until the fix round; commit it).
Rehearsal evidence: ~/Offload/watch-collection/test-evidence/icloud-rehearsal/ (all six of 13 B pass).
