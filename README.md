# OneDrive Free Up Fixer

<img src="docs/icon.png" width="128" alt="App icon">

Adds **Force Free Up Space** to Finder's right-click menu for OneDrive files and folders
on macOS. It frees files that OneDrive's own "Free Up Space" can't, or that
re-download right after being freed.

## The problem

With OneDrive on Apple's File Provider (`~/Library/CloudStorage/OneDrive-*`), each file
has two records:

- **macOS's** content policy (`fileproviderd`): 1 = download on demand, 3 = download and
  keep downloaded.
- **OneDrive's** own state: pin state (`lastKnownPinState`: empty/0 normal, 1 "Always
  Keep", 2 "freed") and a flag in its File Provider database.

Files can get stuck with macOS **policy 3** while "Always Keep on This Device" is off.
macOS then refuses to evict them, so OneDrive's "Free Up Space" does nothing, or evicts a
file and immediately downloads it again.

Check a file:

```sh
fileproviderctl evaluate "<file>" | grep -E "isKeepDownloaded|Content Policy"
# stuck: isKeepDownloaded = 0, Content Policy: 3, Inherited Content Policy: 1
```

## What the app does

For the selected files and folders it:

1. Checks the selection is inside OneDrive, that it has Full Disk Access, and the
   OneDrive/macOS versions against the proven ones. It asks before continuing if they
   differ.
2. **Stops OneDrive** (app and File Provider helper) for the whole run and backs up its
   two databases to `~/Library/Application Support/OneDriveFreeUpFixer/backups/`
   (newest 5 kept).
3. Sets macOS policy 3 → 1 for **every** file in the selection, downloaded or cloud-only
   (`Resources/fp_set_policy.py`, only rows actually at 3). If anything changed, it
   restarts `fileproviderd` and waits 30 s.
4. Evicts the downloaded files with `FileManager.evictUbiquitousItem`, not OneDrive's
   action. Finder's `.DS_Store` files are skipped.
5. Clears OneDrive's "freed" marks for those files (pin state 2 → 0, flag off), with
   integrity checks, then **starts OneDrive** again. OneDrive is always restarted,
   even if a step fails.
6. Waits 60 s and reports what came back (files on disk again or at policy 3) in the
   notification. Details, including the item IDs for rollback, go to
   `~/Library/Logs/OneDriveFreeUpFixer.log`.

A run takes about 1.5–2 minutes, and OneDrive is quit for most of it.

## Proven on

| Component | Version |
|---|---|
| OneDrive | 26.168.0830 (build 26168.0830.0006) |
| macOS | 26.6.2 (25G83) |
| File Provider | 4018.160.6 |

This edits a private Apple database, so a OneDrive or macOS update can change the
behaviour. On other versions the app asks before running. Test on one expendable file,
then update `provenOneDrive` / `provenMacOSBuild` in `Sources/main.swift`.

## Install

Requires the Xcode Command Line Tools (`swiftc`, `python3`).

```sh
./scripts/install.sh
```

This builds the app, installs it to `~/Applications`, registers the Finder service and
shows the app in Finder. Then give it Full Disk Access, which it needs to edit the File
Provider database:

1. Open **System Settings → Privacy & Security → Full Disk Access**.
2. Drag **OneDrive Free Up Fixer** from the Finder window into the list, or click **+**,
   press Cmd+Shift+G, enter `~/Applications` and pick the app.
3. Make sure its switch is on.

- macOS has no permission prompt for Full Disk Access, so the app can't ask for it. It
  checks before doing anything, and if access is missing it explains and opens the
  settings page for you.
- The build is ad-hoc signed, so each re-install changes its signature. Remove the old
  entry (**−**) and add the app again, because toggling the switch isn't enough.
- If the menu item doesn't appear, enable it under **System Settings → Keyboard →
  Keyboard Shortcuts → Services → Files and Folders**.

Uninstall with `./scripts/uninstall.sh`.

## Rollback

**macOS records:** take the item IDs for a run from the log. Then, in a terminal with
Full Disk Access:

```sh
python3 -I Resources/fp_set_policy.py --from 1 --to 3 auto <ids...>; killall fileproviderd
```

**OneDrive records:** quit OneDrive, copy the files from the run's backup folder
(`~/Library/Application Support/OneDriveFreeUpFixer/backups/<timestamp>/`) back to their
places, then start OneDrive:

- `OneDrive.dat*` → `~/Library/Group Containers/UBF8T346G9.OneDriveSyncClientSuite/OneDrive.noindex/`
- `SyncEngineDatabase.db*` → `~/Library/Containers/com.microsoft.OneDrive-mac/Data/Library/Application Support/OneDrive/settings/Personal/`

## Don't

- Toggle "Always Keep on This Device" on stuck files: it re-downloads them.
- Rely on OneDrive's own "Free Up Space" for folders that contain previously downloaded
  files: it sometimes downloads some of them instead (see below). Use Force Free Up
  Space instead.
- Reset or unlink OneDrive to "fix" this: it drops every locally kept file.

## What we know (2026-10-14)

Found while building this; small samples, so treat it as working knowledge:

- **Cloud-only files at macOS policy 3 are time bombs.** Nothing happens until macOS
  re-checks them (a `fileproviderd` or OneDrive restart, OneDrive's own Free Up), then
  they download. That's why the app fixes cloud-only files in the selection too. To find
  them anywhere (read-only, needs Full Disk Access):

  ```sh
  DB="$HOME/Library/Application Support/FileProvider/<domain-uuid>/database/db"
  sqlite3 "file:$DB?mode=ro" "SELECT p.decoration_content_policy, s.metadata_is_dataless, count(*) FROM FP_snapshot p JOIN reconciliation_table r ON r.fp_id = p.id JOIN FS_snapshot s ON s.id = r.fs_id WHERE p.metadata_kind = 0 GROUP BY 1, 2;"
  ```

  A row with policy `3` and dataless `1` means time bombs.
- **With OneDrive running, freeing a file makes OneDrive mark it** (pin state 2 plus a
  flag). Later, OneDrive can push that back to macOS as policy 3, and the file downloads
  again. With OneDrive stopped during the run, no marks were created.
- **OneDrive's own Free Up Space downloads some cloud-only files** instead of leaving
  them alone. In tests it hit files that had been downloaded and freed before, but not
  files that were never downloaded. The exact rule is not known.

## Icon

Drawn in code by `scripts/make_icon.swift`; regenerate `Resources/AppIcon.icns` with
`./scripts/make_icon.sh`.

## License

MIT
