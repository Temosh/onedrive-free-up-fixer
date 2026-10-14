# OneDrive Free Up Fixer

<img src="docs/icon.png" width="128" alt="App icon">

Adds **Force Free Up Space** to Finder's right-click menu for OneDrive files and folders
on macOS. It frees files that OneDrive's own "Free Up Space" can't, or that
re-download right after being freed.

## The problem

With OneDrive on Apple's File Provider (`~/Library/CloudStorage/OneDrive-*`), files can
get stuck with macOS **Content Policy 3** ("download and keep downloaded") even though
"Always Keep on This Device" is off. macOS then refuses to evict them. OneDrive mirrors
that state as pin state 2, and its "Free Up Space" sets it again. So clicking it
either does nothing or evicts the file and immediately downloads it again.

Check a file:

```sh
fileproviderctl evaluate "<file>" | grep -E "isKeepDownloaded|Content Policy"
# stuck: isKeepDownloaded = 0, Content Policy: 3, Inherited Content Policy: 1
```

## What the app does

For the selected files and folders it:

1. Checks the selection is inside OneDrive, and the OneDrive/macOS versions against the
   proven ones. It asks before continuing if they differ.
2. Finds files that are still downloaded.
3. Changes their policy from 3 to 1 in `fileproviderd`'s database
   (`~/Library/Application Support/FileProvider/<domain>/database/db`, table
   `FP_snapshot`), only for rows that are actually 3 (`Resources/fp_set_policy.py`).
4. Restarts `fileproviderd`, only if something changed, so it reloads its records.
5. Evicts the files with `FileManager.evictUbiquitousItem`, not OneDrive's action.
6. Shows a notification with the space freed. Details, including the changed item IDs
   for rollback, go to `~/Library/Logs/OneDriveFreeUpFixer.log`.

OneDrive's own databases are not touched, and OneDrive keeps running.

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

Take the item IDs for a run from the log. Then, in a terminal with Full Disk Access:

```sh
python3 -I Resources/fp_set_policy.py --from 1 --to 3 auto <ids...>; killall fileproviderd
```

## Don't

- Toggle "Always Keep on This Device" on stuck files: it re-downloads them.
- Use OneDrive's "Free Up Space" on fixed files: it re-pins them.
- Reset or unlink OneDrive to "fix" this: it drops every locally kept file.

## Icon

Drawn in code by `scripts/make_icon.swift`; regenerate `Resources/AppIcon.icns` with
`./scripts/make_icon.sh`.

## License

MIT
