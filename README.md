# Watch Collection

A local-first watch collection tracker with a standalone native iOS app, an optional self-hosted web app, and a
six-lens **purchase-decision engine** that tells you what your collection is missing — and what to
hunt next.

No accounts, cloud service, or analytics are required. The iOS app stores its JSON and photos on the
phone and can automatically sync with the stdlib-only desktop server through Tailscale.

## Features

- **Collection & history** — current rotation and every watch you've ever owned (sold, gifted,
  broken, traded…), with photo galleries, stories, and prices.
- **Stats that audit** — spend distribution, percentiles, size histograms against your wrist
  profile, brand breadth, a price ledger with running subtotals, and tappable charts (iOS).
- **Six-lens wishlist scoring** — every candidate scored live against your actual collection:
  category gaps, price-tier holes, brand novelty, dial-colour variety, case-material variety, and
  wrist fit (lug-to-lug aware — L2L beats diameter when known).
- **"Next move" suggestions** — deterministic recommendations composed from your gaps: *"Bronze
  field watch, green or brown dial, 36–41mm — you've never owned either, and your $1000–2500 tier
  is empty"*, complete with curated brands to explore, filtered by what you're already saturated in.
- **Wishlist with auto-images** — candidates fetch their own product shots (best-effort scrape;
  clipboard-paste always works), and a "Bought" flow converts them into collection entries and
  re-ranks everything else.
- **Editable taxonomies** — categories, dial colours, and materials are your lists, not the app's.
  Renames propagate atomically.
- **Daily backup** — CSV + JSON export, optionally rclone'd to your own cloud remote on a launchd
  schedule.
- **Standalone native iOS app** — full feature parity, camera-roll uploads, local scoring, and
  writable on-device storage. It does not need a Mac or server after its one-time migration.
- **Files backup** — keeps a portable JSON copy under On My iPhone and can copy the complete photo
  library there on demand.
- **Two-way automatic sync** — shares collection, wishlist, photos, wear logs, and service records;
  keeps offline edits; asks before resolving concurrent edits to the same field.
- **Purchase timeline** — chronological current-collection purchases in both Mac and iPhone Stats.

## Quick start

```bash
git clone https://github.com/TheRealJadenKwek/watch-collection.git
cd watch-collection
cp data.sample/watches.json data/watches.json   # then make it yours
python3 server.py                                # http://localhost:8931
```

Python 3.11+, no dependencies. Set `settings.ownerName` in your data file to put your name over
the door.

### iOS app

```bash
cd ios
xcodegen generate        # brew install xcodegen
open WatchCollection.xcodeproj
```

Set your own development team + bundle identifier in `project.yml`, run it on your phone, and point
the first v2 launch at the previous server with the `WATCH_MIGRATION_URL` launch environment variable.
The app imports the latest JSON and every referenced photo, then becomes completely standalone.
Updates from an older installed version normally reuse its existing Application Support cache without
needing a fresh import.

### Automatic sync (iOS 2.4)

Install the updated iPhone app and run the updated `server.py`. In iPhone Settings, enable
**Sync with my Mac** and enter `http://<Mac Tailscale IP or hostname>:8931`, then tap
**Apply sync settings**. The app reuses a previously saved server address when available.
Both devices need Tailscale connected and the Mac must be awake. Ordinary Wi-Fi alone does
not grant access: the server still accepts only loopback and Tailscale clients.

Sync runs at launch, when the app becomes active, after local edits, when network connectivity
returns, and every minute while active. Background refresh is also requested, but iOS determines
its timing; reconnecting Wi-Fi cannot guarantee an immediate refresh while the app is suspended.
Open the app for a foreground catch-up. The Mac web page checks for new data every 15 seconds
while visible, and defers refreshing while an editor is open.

On the first sync, records present on only one device are retained. Later syncs use a saved
baseline to merge independent field changes and propagate deletions. Same-field and delete/edit
conflicts pause the exchange and appear in Settings with **Keep iPhone** / **Keep Mac** choices.
Choices are bound to the exact values reviewed, so a newer change requires another review.
The web editor also rejects overwriting a field changed while its form was open.

Photo uploads use immutable names, verify duplicate bytes, and finish before records reference
them. Incoming photos download before the phone acknowledges the new baseline. The phone saves
its collection and baseline together atomically, retains edits made while requests are in flight,
and retries interrupted exchanges. Server snapshots before sync writes are kept under
`data/sync-history/`; the phone's portable Files backup remains available. Device-specific backup
preferences are not synced. Sync is replication, not a replacement for a separate backup.

### Backups

`python3 export_sheet.py` writes a detailed CSV + JSON snapshot to `exports/`; with
`settings.autoBackup` on (and [rclone](https://rclone.org) configured) it also copies them to the
remote in `settings.backupRemote`. Templates for daily launchd scheduling are in `launchd/`.

## Tests

```bash
python3 -m unittest tests.test_watch_app tests.test_sync
```

The suite runs against whatever `data/watches.json` you have; a handful of regression assertions
pinned to the author's personal dataset skip themselves elsewhere.

## Architecture

```
server.py          optional desktop/legacy-import server (port 8931)
app.js/index.html  vanilla-JS single-page web app
export_sheet.py    stats/scoring/suggestion engine + CSV exporter (single source of truth)
data/watches.json  ALL your data — one atomic-write JSON file (gitignored)
ios/               standalone SwiftUI app (xcodegen project; on-device JSON + photos)
```

The Python scoring engine lives in `export_sheet.py`; its Swift port lives in
`ios/Sources/DecisionEngine.swift`. Regression verification compares both implementations against the
same collection data.

## License

MIT
