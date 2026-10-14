// Changes macOS File Provider content policies directly in fileproviderd's database.
// Content policy: 1 = download on demand (normal), 3 = download and keep downloaded.
import Foundation
import SQLite3

struct ContentPolicyError: Error, CustomStringConvertible {
    let description: String
}

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Sets `decoration_content_policy` from `from` to `to` for the given item IDs, in one transaction.
/// Only rows currently at `from` change. Returns how many rows changed.
func setContentPolicy(_ ids: [String], from: Int32 = 3, to: Int32 = 1, database path: String) throws -> Int {
    var db: OpaquePointer?
    guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
        defer { sqlite3_close(db) }
        throw ContentPolicyError(description: "can't open \(path): \(String(cString: sqlite3_errmsg(db)))")
    }
    defer { sqlite3_close(db) }
    sqlite3_busy_timeout(db, 10_000)

    // FP_snapshot's triggers call functions only fileproviderd provides. PROPAGATION_DATE_CHANGED
    // stamps a change time (nanoseconds since 1970, like reconciliation_table.last_change).
    // NEXT_ANCHOR isn't expected for this update; if a trigger calls it, abort and change nothing.
    sqlite3_create_function(db, "PROPAGATION_DATE_CHANGED", 2, SQLITE_UTF8, nil, { context, _, _ in
        sqlite3_result_int64(context, Int64(clock_gettime_nsec_np(CLOCK_REALTIME)))
    }, nil, nil)
    sqlite3_create_function(db, "NEXT_ANCHOR", 1, SQLITE_UTF8, nil, { context, _, _ in
        sqlite3_result_error(context, "NEXT_ANCHOR called - aborting, nothing changed", -1)
    }, nil, nil)

    func fail(_ what: String) -> ContentPolicyError {
        ContentPolicyError(description: "\(what): \(String(cString: sqlite3_errmsg(db)))")
    }
    guard sqlite3_exec(db, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK else { throw fail("begin") }

    // Policy 3 items are stored with metadata_is_evictable = 5, normal (policy 1) ones with 4.
    let evictable: Int32 = to == 3 ? 5 : 4
    var statement: OpaquePointer?
    let sql = "UPDATE FP_snapshot SET decoration_content_policy = ?, metadata_is_evictable = ? "
        + "WHERE id = ? AND decoration_content_policy = ?"
    guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
        let error = fail("prepare")
        sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
        throw error
    }
    defer { sqlite3_finalize(statement) }

    var changed = 0
    for id in ids {
        let bytes = Array(id.utf8)  // FP_snapshot.id is the item ID as an ASCII blob
        sqlite3_bind_int(statement, 1, to)
        sqlite3_bind_int(statement, 2, evictable)
        sqlite3_bind_blob(statement, 3, bytes, Int32(bytes.count), sqliteTransient)
        sqlite3_bind_int(statement, 4, from)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            let error = fail("update \(id)")
            sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
            throw error
        }
        changed += Int(sqlite3_changes(db))
        sqlite3_reset(statement)
        sqlite3_clear_bindings(statement)
    }
    guard sqlite3_exec(db, "COMMIT", nil, nil, nil) == SQLITE_OK else {
        let error = fail("commit")
        sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
        throw error
    }
    return changed
}
