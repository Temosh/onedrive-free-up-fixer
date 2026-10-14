// OneDrive Free Up Fixer — adds "Force Free Up Space" to Finder's right-click menu.
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
            + "that opens), turn it on, then use Force Free Up Space again."
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

func startOneDrive() {
    shell("/usr/bin/open", ["-a", "OneDrive"])
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

// Pin state 2 -> 0 and flag bit 8 off for these items (files only), both databases checked after.
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
        UPDATE fp.dbfs_files SET state_flags = state_flags & ~8
         WHERE itemid IN (\(list)) AND filetype = 0 AND (state_flags & 8) != 0 AND (state_flags & 32) != 0;
        SELECT 'mark cleared: ' || changes();
        COMMIT;
        PRAGMA main.integrity_check;
        PRAGMA fp.integrity_check;
        """
    let script = FileManager.default.temporaryDirectory.appendingPathComponent("clear-marks-\(UUID().uuidString).sql")
    guard (try? sql.write(to: script, atomically: true, encoding: .utf8)) != nil else { return false }
    defer { try? FileManager.default.removeItem(at: script) }
    let result = shell("/usr/bin/sqlite3", [syncEngineDB, ".read \(script.path)"])
    log("OneDrive records: status \(result.status): \(result.output)")
    let okCount = result.output.split(separator: "\n").filter { $0 == "ok" }.count
    return result.status == 0 && okCount == 2
}

// How many of these items macOS still has at policy 3 ("keep downloaded").
func policyThreeCount(_ ids: [String], fileProviderDB: String) -> Int? {
    let numeric = ids.filter { !$0.isEmpty && $0.allSatisfy(\.isNumber) }
    guard !numeric.isEmpty else { return 0 }
    let list = numeric.map { "CAST('\($0)' AS BLOB)" }.joined(separator: ",")
    let result = shell("/usr/bin/sqlite3", ["-readonly", fileProviderDB,
        "SELECT count(*) FROM FP_snapshot WHERE decoration_content_policy = 3 AND id IN (\(list));"])
    return result.status == 0 ? Int(result.output.trimmingCharacters(in: .whitespacesAndNewlines)) : nil
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

    // All files in the selection: cloud-only ones still at policy 3 would download on the next
    // fileproviderd restart, so they get fixed too.
    let allFiles = regularFiles(in: urls)
    let files = allFiles.filter(isDownloadedFile)
    guard !files.isEmpty else {
        notify("Nothing to free: already cloud-only.")
        return
    }
    notify("Freeing \(fileCount(files.count))…")
    let ids = allFiles.compactMap(itemIdentifier)
    log("item ids (for rollback): \(ids.joined(separator: " "))")

    // 1. Stop OneDrive for the whole run and back up its databases.
    guard stopOneDrive() else {
        startOneDrive()
        notify("Couldn't stop OneDrive, nothing changed.")
        return
    }
    var oneDriveStarted = false
    defer { if !oneDriveStarted { startOneDrive() } }  // always restart OneDrive, even on early exit
    guard let backup = backupOneDriveDatabases() else {
        notify("Couldn't back up OneDrive's databases, nothing changed.")
        return
    }
    log("OneDrive backup: \(backup.path)")

    // 2. macOS records: policy 3 -> 1, then let fileproviderd reload and settle.
    let result = shell("/usr/bin/python3", ["-I", policyScript, "auto"] + ids)
    log("fp_set_policy: status \(result.status): \(result.output)")
    guard result.status == 0 else {
        notify("Couldn't update File Provider records. Grant Full Disk Access to \(appName). Log: ~/Library/Logs/OneDriveFreeUpFixer.log")
        return
    }
    let fileProviderDB = result.output.split(separator: "\n").first { $0.hasPrefix("database: ") }
        .map { String($0.dropFirst("database: ".count)) }
    let changed = result.output.range(of: #"updated (\d+) of"#, options: .regularExpression)
        .flatMap { Int(result.output[$0].split(separator: " ")[1]) } ?? 0
    if changed > 0 {
        shell("/usr/bin/killall", ["fileproviderd"])
        Thread.sleep(forTimeInterval: 30)
    }

    // 3. Free the downloaded files with the macOS call.
    var freed: Int64 = 0, failed = 0
    for file in files {
        let size = Int64(fileStat(file)?.st_blocks ?? 0) * 512
        do {
            try FileManager.default.evictUbiquitousItem(at: file)
            freed += size
        } catch {
            failed += 1
            log("evict failed: \(file.path): \(error.localizedDescription)")
        }
    }

    // 4. OneDrive records: clear its "freed" marks so it can't push "keep downloaded" back later.
    // The helper may have been relaunched while freeing; only edit once it's really stopped.
    let marksCleared = stopOneDrive() && clearOneDriveMarks(ids)

    // 5. Start OneDrive, then 6. check what came back.
    startOneDrive()
    oneDriveStarted = true
    Thread.sleep(forTimeInterval: 60)
    let backOnDisk = files.filter(isDownloadedFile).count
    let stillPolicyThree = fileProviderDB.flatMap { policyThreeCount(ids, fileProviderDB: $0) } ?? 0

    let freedText = ByteCountFormatter.string(fromByteCount: freed, countStyle: .file)
    var summary = "Freed \(freedText) from \(fileCount(files.count - failed))"
    if failed > 0 { summary += ", \(failed) failed" }
    if backOnDisk > 0 { summary += ", \(fileCount(backOnDisk)) back on disk" }
    if stillPolicyThree > 0 { summary += ", \(fileCount(stillPolicyThree)) at keep-downloaded" }
    if !marksCleared { summary += ". OneDrive records not updated, see log" }
    log(summary)
    notify(summary)
}

final class ServiceProvider: NSObject {
    // Called by macOS when "Force Free Up Space" is picked in Finder's right-click menu.
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
