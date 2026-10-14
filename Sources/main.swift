// OneDrive Free Up Fixer — adds "Repair & Free Up Unpinned Files" to Finder's right-click menu.
// Clears the stuck "keep downloaded" policy (3 -> 1) in fileproviderd's records for the
// selected files, then evicts them with the macOS API instead of OneDrive's own action
// (which re-pins them).
import AppKit
import FileProvider
import UserNotifications

let appName = "OneDrive Free Up Fixer"
let provenOneDrive = "26.168.0830"
let provenMacOSBuild = "25G83"
let home = FileManager.default.homeDirectoryForCurrentUser
let logURL = home.appendingPathComponent("Library/Logs/OneDriveFreeUpFixer.log")
let policyScript = Bundle.main.url(forResource: "fp_set_policy", withExtension: "py")!.path

func log(_ text: String) {
    let line = "\(Date()) \(text)\n"
    if let handle = try? FileHandle(forWritingTo: logURL) {
        handle.seekToEndOfFile()
        handle.write(Data(line.utf8))
        try? handle.close()
    } else {
        try? line.write(to: logURL, atomically: true, encoding: .utf8)
    }
}

@discardableResult
func shell(_ path: String, _ args: [String]) -> (status: Int32, output: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = args
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    do { try process.run() } catch { return (-1, "\(error)") }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, String(decoding: data, as: UTF8.self))
}

// Native notifications (no "Show" button). Each gets its own ID so the start banner
// isn't replaced by the result.
final class NotificationPresenter: NSObject, UNUserNotificationCenterDelegate {
    // Show banners even while this app is the one handling the request.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list])
    }
}
let notificationPresenter = NotificationPresenter()

func notify(_ text: String) {
    let center = UNUserNotificationCenter.current()
    center.delegate = notificationPresenter
    let delivered = DispatchSemaphore(value: 0)
    center.requestAuthorization(options: [.alert]) { _, _ in
        let content = UNMutableNotificationContent()
        content.title = appName
        content.body = text
        center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)) { _ in
            delivered.signal()
        }
    }
    delivered.wait()  // don't quit before the notification is handed to macOS
}

func ask(_ title: String, _ message: String) -> Bool {
    DispatchQueue.main.sync {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }
}

func fileCount(_ count: Int) -> String { count == 1 ? "1 file" : "\(count) files" }

func fileStat(_ url: URL) -> stat? {
    var st = stat()
    return lstat(url.path, &st) == 0 ? st : nil
}

let datalessFlag: UInt32 = 0x4000_0000  // SF_DATALESS: content not on disk

func isDownloadedFile(_ url: URL) -> Bool {
    guard let st = fileStat(url), (st.st_mode & S_IFMT) == S_IFREG else { return false }
    return st.st_flags & datalessFlag == 0
}

// Every regular file in the selection, downloaded or cloud-only (Finder's .DS_Store skipped).
func regularFiles(in urls: [URL]) -> [URL] {
    func isRegular(_ url: URL) -> Bool {
        url.lastPathComponent != ".DS_Store" && (fileStat(url).map { ($0.st_mode & S_IFMT) == S_IFREG } ?? false)
    }
    var files: [URL] = []
    for url in urls {
        if isRegular(url) { files.append(url); continue }
        guard let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil) else { continue }
        for case let file as URL in walker where isRegular(file) {
            files.append(file)
        }
    }
    return files
}

func itemIdentifier(_ url: URL) -> String? {
    var identifier: String?
    let done = DispatchSemaphore(value: 0)
    NSFileProviderManager.getIdentifierForUserVisibleFile(at: url) { itemID, _, _ in
        identifier = itemID?.rawValue
        done.signal()
    }
    done.wait()
    if identifier == nil {  // fallback: ask fileproviderctl
        let out = shell("/usr/bin/fileproviderctl", ["evaluate", url.path]).output
        if let line = out.split(separator: "\n").first(where: { $0.contains("itemIdentifier =") }) {
            identifier = line.components(separatedBy: "= ").last?
                .trimmingCharacters(in: CharacterSet(charactersIn: " ;\""))
        }
    }
    return identifier
}

// macOS has no prompt for Full Disk Access, so probe a protected folder instead.
func hasFullDiskAccess() -> Bool {
    let protected = home.appendingPathComponent("Library/Application Support/FileProvider").path
    return (try? FileManager.default.contentsOfDirectory(atPath: protected)) != nil
}

func guideToFullDiskAccess() {
    DispatchQueue.main.sync {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "\(appName) needs Full Disk Access"
        alert.informativeText = "It edits macOS's File Provider records, which are protected.\n\n"
            + "In the Full Disk Access list, click + (or drag the app in from the Finder window "
            + "that opens), turn it on, then use Repair & Free Up Unpinned Files again."
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
    }
}

func versionMismatch() -> String? {
    let plist = NSDictionary(contentsOfFile: "/Applications/OneDrive.app/Contents/Info.plist")
    let oneDrive = plist?["CFBundleShortVersionString"] as? String ?? "unknown"
    var size = 0
    sysctlbyname("kern.osversion", nil, &size, nil, 0)
    var buffer = [CChar](repeating: 0, count: size)
    sysctlbyname("kern.osversion", &buffer, &size, nil, 0)
    let build = String(cString: buffer)
    if oneDrive == provenOneDrive && build == provenMacOSBuild { return nil }
    return "Installed: OneDrive \(oneDrive), macOS build \(build).\n"
        + "Proven on: OneDrive \(provenOneDrive), macOS build \(provenMacOSBuild).\n\n"
        + "Try it on one expendable file first, then update the proven versions."
}

// OneDrive's own records. Its "freed" marks (pin state 2, flag bit 8) get pushed back to macOS
// as "keep downloaded" later, so they are cleared for the files we free.
let oneDriveDB = home.appendingPathComponent(
    "Library/Group Containers/UBF8T346G9.OneDriveSyncClientSuite/OneDrive.noindex/OneDrive.dat").path
let syncEngineDB = home.appendingPathComponent(
    "Library/Containers/com.microsoft.OneDrive-mac/Data/Library/Application Support/OneDrive/settings/Personal/SyncEngineDatabase.db").path
let backupRoot = home.appendingPathComponent("Library/Application Support/OneDriveFreeUpFixer/backups")
let backupsToKeep = 5

func isRunning(_ pattern: String) -> Bool { shell("/usr/bin/pgrep", ["-f", pattern]).status == 0 }

// Quit the OneDrive app and its File Provider helper (macOS may relaunch the helper on demand).
func stopOneDrive() -> Bool {
    shell("/usr/bin/osascript", ["-e", "quit app \"OneDrive\""])
    var waited = 0
    while isRunning("/Applications/OneDrive.app/Contents/MacOS/OneDrive") && waited < 15 {
        Thread.sleep(forTimeInterval: 1)
        waited += 1
    }
    shell("/usr/bin/pkill", ["-f", "OneDrive File Provider"])
    Thread.sleep(forTimeInterval: 2)
    return !isRunning("/Applications/OneDrive.app/")
}

// Copies both OneDrive databases into a timestamped folder; keeps the newest few.
func backupOneDriveDatabases() -> URL? {
    let fm = FileManager.default
    guard fm.fileExists(atPath: oneDriveDB), fm.fileExists(atPath: syncEngineDB) else { return nil }
    let stamp = DateFormatter()
    stamp.dateFormat = "yyyyMMdd-HHmmss"
    let dir = backupRoot.appendingPathComponent(stamp.string(from: Date()))
    do {
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        for db in [oneDriveDB, syncEngineDB] {
            for path in [db, db + "-wal", db + "-shm"] where fm.fileExists(atPath: path) {
                try fm.copyItem(atPath: path, toPath: dir.appendingPathComponent((path as NSString).lastPathComponent).path)
            }
        }
        let old = try fm.contentsOfDirectory(at: backupRoot, includingPropertiesForKeys: nil)
            .sorted { $0.lastPathComponent < $1.lastPathComponent }.dropLast(backupsToKeep)
        old.forEach { try? fm.removeItem(at: $0) }
    } catch {
        log("backup failed: \(error.localizedDescription)")
        return nil
    }
    return dir
}

// Pin state 2/empty -> 0, flag bit 8 off and capabilities 47 -> -1 for these items (files only);
// both databases checked after. Capabilities 47 is left over from "Always Keep on This Device"
// (no "allows evicting"); with it, OneDrive's own Free Up Space tells macOS "keep downloaded".
// Normal files have -1.
func clearOneDriveMarks(_ ids: [String]) -> Bool {
    let numeric = ids.filter { !$0.isEmpty && $0.allSatisfy(\.isNumber) }
    guard !numeric.isEmpty else { return true }
    let list = numeric.joined(separator: ",")
    let sql = """
        .bail on
        ATTACH '\(oneDriveDB)' AS fp;
        BEGIN IMMEDIATE;
        UPDATE od_ClientFile_Records SET lastKnownPinState = 0
         WHERE lastKnownPinState = 2 AND itemIndex IN (SELECT fsid FROM fp.dbfs_files WHERE itemid IN (\(list)));
        SELECT 'pin state 2 -> 0: ' || changes();
        UPDATE od_ClientFile_Records SET lastKnownPinState = 0
         WHERE lastKnownPinState IS NULL AND itemIndex IN (SELECT fsid FROM fp.dbfs_files WHERE itemid IN (\(list)));
        SELECT 'pin state empty -> 0: ' || changes();
        UPDATE fp.dbfs_files SET state_flags = state_flags & ~8
         WHERE itemid IN (\(list)) AND filetype = 0 AND (state_flags & 8) != 0 AND (state_flags & 32) != 0;
        SELECT 'mark cleared: ' || changes();
        UPDATE fp.dbfs_files SET capabilities = -1
         WHERE itemid IN (\(list)) AND filetype = 0 AND capabilities = 47;
        SELECT 'capabilities 47 -> -1: ' || changes();
        COMMIT;
        PRAGMA main.integrity_check;
        PRAGMA fp.integrity_check;
        """
    let script = FileManager.default.temporaryDirectory.appendingPathComponent("clear-marks-\(UUID().uuidString).sql")
    guard (try? sql.write(to: script, atomically: true, encoding: .utf8)) != nil else { return false }
    defer { try? FileManager.default.removeItem(at: script) }
    let result = shell("/usr/bin/sqlite3", [syncEngineDB, ".read \(script.path)"])
    event("OneDrive records: status \(result.status): \(result.output.replacingOccurrences(of: "\n", with: " | "))")
    let okCount = result.output.split(separator: "\n").filter { $0 == "ok" }.count
    return result.status == 0 && okCount == 2
}

// MARK: - Detailed per-run log

// Each run writes ~/Library/Logs/OneDriveFreeUpFixer/run-<stamp>.tsv: one line per file per stage
// plus timestamped events, so the whole run can be reviewed afterwards.
let runLogDir = home.appendingPathComponent("Library/Logs/OneDriveFreeUpFixer")
var runLogURL: URL?

func runLog(_ line: String) {
    guard let url = runLogURL else { return }
    let data = Data((line + "\n").utf8)
    if let handle = try? FileHandle(forWritingTo: url) {
        handle.seekToEndOfFile()
        handle.write(data)
        try? handle.close()
    } else {
        try? data.write(to: url)
    }
}

func timeOfDay() -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm:ss"
    return formatter.string(from: Date())
}

// A step of the run: goes to the main log and the run log.
func event(_ text: String) {
    log(text)
    runLog("event\t\(timeOfDay())\t\(text)")
}

// Read-only query returning tab-separated rows. A stopped OneDrive leaves its databases
// without a -shm file, which read-only WAL mode needs, so fall back to immutable mode.
func query(_ db: String, _ sql: String) -> [[String]] {
    for uri in ["file:\(db)?mode=ro", "file:\(db)?immutable=1"] {
        let result = shell("/usr/bin/sqlite3", ["-separator", "\t", uri, sql])
        if result.status == 0 {
            return result.output.split(separator: "\n")
                .map { $0.split(separator: "\t", omittingEmptySubsequences: false).map(String.init) }
        }
    }
    return []
}

func findFileProviderDB(containing id: String) -> String? {
    let root = home.appendingPathComponent("Library/Application Support/FileProvider")
    for dir in (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? [] {
        let db = root.appendingPathComponent(dir).appendingPathComponent("database/db").path
        guard FileManager.default.fileExists(atPath: db) else { continue }
        if query(db, "SELECT 1 FROM FP_snapshot WHERE id = CAST('\(id)' AS BLOB) LIMIT 1;").first?.first == "1" {
            return db
        }
    }
    return nil
}

struct Item {
    let url: URL
    let id: String?
}

struct FileState {
    let onDisk: Bool
    let policy: String  // macOS content policy: 1 normal, 3 keep downloaded
    let pin: String     // OneDrive lastKnownPinState: empty/0 normal, 1 always keep, 2 freed
    let flags: String   // OneDrive dbfs state_flags; bit 8 = "freed" mark
    let caps: String    // OneDrive dbfs capabilities: -1 normal, 47 left over from a pin
    var marked: Bool { Int(flags).map { $0 & 8 != 0 } ?? false }
    // "Always Keep on This Device", set on the file or inherited from a pinned folder.
    var pinnedByUser: Bool { Int(flags).map { $0 & 4 != 0 } ?? false }
}

func relativePath(_ url: URL) -> String {
    let root = home.appendingPathComponent("Library/CloudStorage").path + "/"
    return url.path.hasPrefix(root) ? String(url.path.dropFirst(root.count)) : url.path
}

// Records every file's state on disk, in macOS's records and in OneDrive's records.
@discardableResult
func snapshot(_ stage: String, _ items: [Item], fileProviderDB: String?) -> [FileState] {
    let ids = items.compactMap(\.id).filter { !$0.isEmpty && $0.allSatisfy(\.isNumber) }
    var policy: [String: String] = [:], fsid: [String: String] = [:]
    var flags: [String: String] = [:], pin: [String: String] = [:], caps: [String: String] = [:]
    if !ids.isEmpty {
        if let db = fileProviderDB {
            let blobs = ids.map { "CAST('\($0)' AS BLOB)" }.joined(separator: ",")
            for row in query(db, "SELECT CAST(id AS TEXT), decoration_content_policy FROM FP_snapshot WHERE id IN (\(blobs));")
            where row.count == 2 { policy[row[0]] = row[1] }
        }
        for row in query(oneDriveDB, "SELECT itemid, fsid, state_flags, capabilities FROM dbfs_files WHERE itemid IN (\(ids.joined(separator: ",")));")
        where row.count == 4 { fsid[row[0]] = row[1]; flags[row[0]] = row[2]; caps[row[0]] = row[3] }
        if !fsid.isEmpty {
            let list = fsid.values.joined(separator: ",")
            for row in query(syncEngineDB, "SELECT itemIndex, coalesce(lastKnownPinState, '') FROM od_ClientFile_Records WHERE itemIndex IN (\(list));")
            where row.count == 2 { pin[row[0]] = row[1] }
        }
    }
    let time = timeOfDay()
    var states: [FileState] = []
    for item in items {
        let st = fileStat(item.url)
        let onDisk = st.map { $0.st_flags & datalessFlag == 0 } ?? false
        let bytes = Int64(st?.st_blocks ?? 0) * 512
        let id = item.id ?? ""
        let pinValue = fsid[id].flatMap { pin[$0] }.map { $0.isEmpty ? "empty" : $0 } ?? "?"
        let state = FileState(onDisk: onDisk, policy: policy[id] ?? "?", pin: pinValue, flags: flags[id] ?? "?",
                              caps: caps[id] ?? "?")
        states.append(state)
        runLog([stage, time, relativePath(item.url), id, onDisk ? "on-disk" : "cloud-only", String(bytes),
                state.policy, state.pin, state.flags, state.caps].joined(separator: "\t"))
    }
    event("\(stage): \(states.filter(\.onDisk).count) on disk, \(states.filter { $0.policy == "3" }.count) at policy 3, "
          + "\(states.filter(\.marked).count) marked by OneDrive, \(states.filter { $0.caps == "47" }.count) with pin capabilities "
          + "(of \(items.count) files)")
    return states
}

func forceFreeUp(_ urls: [URL]) {
    log("request: \(urls.map(\.path))")
    let oneDriveRoot = home.appendingPathComponent("Library/CloudStorage").path + "/OneDrive"
    guard !urls.isEmpty, urls.allSatisfy({ $0.path.hasPrefix(oneDriveRoot) }) else {
        notify("Only works on files inside OneDrive.")
        return
    }
    guard hasFullDiskAccess() else {
        log("no Full Disk Access")
        guideToFullDiskAccess()
        return
    }
    if let mismatch = versionMismatch(),
       !ask("Versions differ from the proven ones", mismatch) {
        log("cancelled: version mismatch")
        return
    }

    // OneDrive must be quit by the user first: stopping it mid-download made it look like it
    // crashed. The app never starts OneDrive; the user starts it when done.
    guard !isRunning("/Applications/OneDrive.app/Contents/MacOS/OneDrive") else {
        log("refused: OneDrive is running")
        notify("Quit OneDrive first, then run this again.")
        return
    }

    let stamp = DateFormatter()
    stamp.dateFormat = "yyyyMMdd-HHmmss"
    try? FileManager.default.createDirectory(at: runLogDir, withIntermediateDirectories: true)
    runLogURL = runLogDir.appendingPathComponent("run-\(stamp.string(from: Date())).tsv")
    runLog("stage\ttime\tfile\titem_id\tlocation\tbytes_on_disk\tmacos_policy\tonedrive_pin\tonedrive_flags\tonedrive_caps")
    event("run log: \(runLogURL!.path)")
    event("selection: \(urls.map(relativePath).joined(separator: ", "))")

    // All files in the selection: cloud-only ones still at policy 3 would download on the next
    // fileproviderd restart, so they get fixed too.
    let allFiles = regularFiles(in: urls)
    let items = allFiles.map { Item(url: $0, id: itemIdentifier($0)) }
    var fileProviderDB = items.lazy.compactMap(\.id).first.flatMap { findFileProviderDB(containing: $0) }
    let before = snapshot("before", items, fileProviderDB: fileProviderDB)

    // Intentionally pinned files are left completely alone: freeing them without a real unpin
    // would leave OneDrive believing they're pinned. Unpin in OneDrive first to free them.
    let pinnedPaths = Set(zip(items, before).filter { $0.1.pinnedByUser }.map { $0.0.url.path })
    for item in items where pinnedPaths.contains(item.url.path) {
        event("skipped: intentionally pinned: \(relativePath(item.url))")
    }
    let work = zip(items, before).filter { !$0.1.pinnedByUser }
    guard !work.isEmpty else {
        event("nothing to do: all \(allFiles.count) files are intentionally pinned")
        notify("Nothing to do: all files are kept on this device (\"Always Keep on This Device\").")
        return
    }
    let files = work.map(\.0.url).filter(isDownloadedFile)
    let ids = work.compactMap(\.0.id)
    event("item ids (for rollback): \(ids.joined(separator: " "))")

    // Even with nothing downloaded, records may need repair: macOS policy 3 (time bombs), or
    // OneDrive pin state empty/2, its mark or capabilities 47 (its own Free Up Space then
    // pushes "keep downloaded").
    let needsRepair = work.contains {
        $0.1.policy == "3" || $0.1.marked || $0.1.pin == "empty" || $0.1.pin == "2" || $0.1.caps == "47"
    }
    guard !files.isEmpty || needsRepair else {
        event("nothing to do: all \(work.count) unpinned files cloud-only with clean records")
        notify("Nothing to free: already cloud-only.")
        return
    }
    notify(files.isEmpty ? "Nothing to free, repairing records of \(fileCount(work.count))…"
                         : "Freeing \(fileCount(files.count))…")

    // 1. OneDrive is quit; make sure its File Provider helper (which macOS may relaunch) is
    // stopped too, then back up OneDrive's databases.
    guard stopOneDrive() else {
        event("couldn't stop OneDrive's File Provider helper, nothing changed")
        notify("Couldn't stop OneDrive's helper, nothing changed. Try again in a minute.")
        return
    }
    event("OneDrive's helper stopped")
    guard let backup = backupOneDriveDatabases() else {
        event("backup failed, nothing changed")
        notify("Couldn't back up OneDrive's databases, nothing changed.")
        return
    }
    event("OneDrive backup: \(backup.path)")

    // 2. macOS records: policy 3 -> 1, then let fileproviderd reload and settle.
    let result = shell("/usr/bin/python3", ["-I", policyScript, "auto"] + ids)
    event("fp_set_policy: status \(result.status): \(result.output.replacingOccurrences(of: "\n", with: " | "))")
    guard result.status == 0 else {
        notify("Couldn't update File Provider records. Grant Full Disk Access to \(appName). Log: ~/Library/Logs/OneDriveFreeUpFixer.log")
        return
    }
    if let db = result.output.split(separator: "\n").first(where: { $0.hasPrefix("database: ") }) {
        fileProviderDB = String(db.dropFirst("database: ".count))
    }
    let changed = result.output.range(of: #"updated (\d+) of"#, options: .regularExpression)
        .flatMap { Int(result.output[$0].split(separator: " ")[1]) } ?? 0
    if changed > 0 {
        shell("/usr/bin/killall", ["fileproviderd"])
        event("fileproviderd restarted, waiting 30 s")
        Thread.sleep(forTimeInterval: 30)
    }
    snapshot("after-macos-fix", items, fileProviderDB: fileProviderDB)

    // 3. Free the downloaded files with the macOS call (none when only repairing records).
    var freed: Int64 = 0, failed = 0
    if files.isEmpty { event("no downloaded files, skipping evict") }
    for file in files {
        let size = Int64(fileStat(file)?.st_blocks ?? 0) * 512
        do {
            try FileManager.default.evictUbiquitousItem(at: file)
            freed += size
        } catch {
            failed += 1
            event("evict failed: \(relativePath(file)): \(error.localizedDescription)")
        }
    }
    event("evicted \(files.count - failed) of \(files.count) downloaded files")
    snapshot("after-evict", items, fileProviderDB: fileProviderDB)

    // 4. OneDrive records: clear its "freed" marks and set pin state to 0, so neither OneDrive nor
    // its own Free Up Space pushes "keep downloaded" back later.
    // The helper may have been relaunched while freeing; only edit once it's really stopped.
    let stoppedAgain = stopOneDrive()
    event(stoppedAgain ? "OneDrive stopped again for its records" : "OneDrive helper still running, its records NOT changed")
    let marksCleared = stoppedAgain && clearOneDriveMarks(ids)
    snapshot("after-onedrive-fix", items, fileProviderDB: fileProviderDB)

    // 5. Record the final state. OneDrive stays quit; the user starts it when done.
    let final = snapshot("final", items, fileProviderDB: fileProviderDB)

    var backOnDisk = 0, atPolicyThree = 0
    for (item, state) in zip(items, final) where !pinnedPaths.contains(item.url.path)
        && (state.onDisk || state.policy == "3" || state.marked || state.caps == "47") {
        var issues: [String] = []
        if state.onDisk { issues.append("on disk"); backOnDisk += 1 }
        if state.policy == "3" { issues.append("policy 3"); atPolicyThree += 1 }
        if state.marked { issues.append("marked by OneDrive") }
        if state.caps == "47" { issues.append("pin capabilities") }
        event("problem: \(relativePath(item.url)): \(issues.joined(separator: ", "))")
    }

    let freedText = ByteCountFormatter.string(fromByteCount: freed, countStyle: .file)
    var summary = files.isEmpty ? "Nothing to free, records of \(fileCount(work.count)) repaired"
                                : "Freed \(freedText) from \(fileCount(files.count - failed))"
    if failed > 0 { summary += ", \(failed) failed" }
    if backOnDisk > 0 { summary += ", \(fileCount(backOnDisk)) back on disk" }
    if atPolicyThree > 0 { summary += ", \(fileCount(atPolicyThree)) at keep-downloaded" }
    if !pinnedPaths.isEmpty { summary += ", \(fileCount(pinnedPaths.count)) kept on device (pinned) skipped" }
    if !marksCleared { summary += ". OneDrive records not updated, see log" }
    summary += ". Start OneDrive when you're done"
    event(summary)
    notify(summary)
}

final class ServiceProvider: NSObject {
    // Called by macOS when "Repair & Free Up Unpinned Files" is picked in Finder's right-click menu.
    @objc func forceFreeUp(_ pasteboard: NSPasteboard, userData: String, error: AutoreleasingUnsafeMutablePointer<NSString>) {
        let urls = pasteboard.readObjects(forClasses: [NSURL.self],
                                          options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        busy = true
        DispatchQueue.global(qos: .userInitiated).async {
            OneDriveFreeUpFixer.forceFreeUp(urls)
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
}

var busy = false
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let provider = ServiceProvider()
app.servicesProvider = provider
NSUpdateDynamicServices()
// Launched without a request (e.g. double-clicked): quit after a while.
DispatchQueue.main.asyncAfter(deadline: .now() + 30) { if !busy { NSApp.terminate(nil) } }
app.run()
