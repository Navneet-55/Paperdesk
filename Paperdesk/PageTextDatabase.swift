import Foundation
import SQLite3

struct PageTextDatabaseError: LocalizedError {
    let message: String
    var errorDescription: String? { "The page text database could not be read or saved: \(message). Existing OCR has been kept." }
}

/// A connection is used synchronously by its owning service actor. Every statement and
/// transaction finishes before that actor awaits progress. DELETE journaling makes one
/// portable database; use SQLite's backup API rather than copying a file being written.
final class PageTextDatabase {
    private var handle: OpaquePointer?
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(url: URL) throws {
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "cannot open database"
            sqlite3_close(handle); handle = nil
            throw PageTextDatabaseError(message: message)
        }
        do {
            sqlite3_busy_timeout(handle, 5_000)
            try execute("PRAGMA journal_mode=DELETE")
            try execute("PRAGMA foreign_keys=ON")
            try execute("PRAGMA synchronous=FULL")
            try execute("CREATE TABLE IF NOT EXISTS metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL)")
            try execute("CREATE TABLE IF NOT EXISTS native_pages (page_index INTEGER PRIMARY KEY, text TEXT NOT NULL)")
            try execute("CREATE TABLE IF NOT EXISTS ocr_versions (id INTEGER PRIMARY KEY, fingerprint TEXT NOT NULL, page_count INTEGER NOT NULL, UNIQUE(fingerprint, page_count))")
            try execute("CREATE TABLE IF NOT EXISTS ocr_pages (version_id INTEGER NOT NULL REFERENCES ocr_versions(id), page_index INTEGER NOT NULL, payload BLOB NOT NULL, coverage BLOB, PRIMARY KEY(version_id, page_index))")
        } catch {
            sqlite3_close(handle); handle = nil
            throw error
        }
    }
    deinit { sqlite3_close(handle) }

    private func failure() -> PageTextDatabaseError {
        PageTextDatabaseError(message: handle.map { String(cString: sqlite3_errmsg($0)) } ?? "database closed")
    }
    private func execute(_ sql: String) throws {
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else { throw failure() }
    }
    private func statement(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw failure() }
        return statement
    }
    private func bind(_ text: String, at position: Int32, to statement: OpaquePointer) throws {
        guard text.withCString({ sqlite3_bind_text(statement, position, $0, -1, Self.transient) }) == SQLITE_OK else { throw failure() }
    }
    private func bind(_ data: Data, at position: Int32, to statement: OpaquePointer) throws {
        guard data.withUnsafeBytes({ sqlite3_bind_blob(statement, position, $0.baseAddress, Int32($0.count), Self.transient) }) == SQLITE_OK else { throw failure() }
    }
    private func run(_ statement: OpaquePointer) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else { throw failure() }
    }
    private func text(_ statement: OpaquePointer, _ column: Int32) -> String {
        sqlite3_column_text(statement, column).map { String(cString: $0) } ?? ""
    }
    private func data(_ statement: OpaquePointer, _ column: Int32) -> Data? {
        guard let pointer = sqlite3_column_blob(statement, column) else { return nil }
        return Data(bytes: pointer, count: Int(sqlite3_column_bytes(statement, column)))
    }
    private func transaction<T>(_ work: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do { let value = try work(); try execute("COMMIT"); return value }
        catch { try? execute("ROLLBACK"); throw error }
    }
    private func metadata(_ key: String) throws -> String? {
        let query = try statement("SELECT value FROM metadata WHERE key=?")
        defer { sqlite3_finalize(query) }
        try bind(key, at: 1, to: query)
        switch sqlite3_step(query) {
        case SQLITE_ROW: return text(query, 0)
        case SQLITE_DONE: return nil
        default: throw failure()
        }
    }
    private func setMetadata(_ key: String, value: String) throws {
        let query = try statement("INSERT INTO metadata(key,value) VALUES (?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value")
        defer { sqlite3_finalize(query) }
        try bind(key, at: 1, to: query); try bind(value, at: 2, to: query); try run(query)
    }

    func prepareNative(fingerprint: String, pageCount: Int) throws {
        if try metadata("native_fingerprint") == fingerprint, try metadata("native_page_count") == String(pageCount) { return }
        try transaction {
            try execute("DELETE FROM native_pages")
            try setMetadata("native_fingerprint", value: fingerprint)
            try setMetadata("native_page_count", value: String(pageCount))
        }
    }
    func nativeText(pageIndex: Int) throws -> String? {
        let query = try statement("SELECT text FROM native_pages WHERE page_index=?")
        defer { sqlite3_finalize(query) }
        sqlite3_bind_int64(query, 1, Int64(pageIndex))
        switch sqlite3_step(query) {
        case SQLITE_ROW: return text(query, 0)
        case SQLITE_DONE: return nil
        default: throw failure()
        }
    }
    func storeNativePages(_ pages: [(Int, String)], fingerprint: String? = nil) throws {
        guard !pages.isEmpty else { return }
        try transaction {
            if let fingerprint, try metadata("native_fingerprint") != fingerprint { throw DocumentTextError.incompatibleIndex }
            let query = try statement("INSERT INTO native_pages(page_index,text) VALUES (?,?) ON CONFLICT(page_index) DO UPDATE SET text=excluded.text")
            defer { sqlite3_finalize(query) }
            for (index, text) in pages {
                sqlite3_reset(query); sqlite3_clear_bindings(query)
                sqlite3_bind_int64(query, 1, Int64(index)); try bind(text, at: 2, to: query); try run(query)
            }
        }
    }
    func nativePageCount() throws -> Int {
        let query = try statement("SELECT COUNT(*) FROM native_pages")
        defer { sqlite3_finalize(query) }
        guard sqlite3_step(query) == SQLITE_ROW else { throw failure() }
        return Int(sqlite3_column_int64(query, 0))
    }
    func ocrGeneration(fingerprint: String, pageCount: Int, create: Bool = false) throws -> Int64? {
        let query = try statement("SELECT id FROM ocr_versions WHERE fingerprint=? AND page_count=?")
        defer { sqlite3_finalize(query) }
        try bind(fingerprint, at: 1, to: query); sqlite3_bind_int64(query, 2, Int64(pageCount))
        switch sqlite3_step(query) {
        case SQLITE_ROW: return sqlite3_column_int64(query, 0)
        case SQLITE_DONE: break
        default: throw failure()
        }
        guard create else { return nil }
        let insert = try statement("INSERT OR IGNORE INTO ocr_versions(fingerprint,page_count) VALUES (?,?)")
        defer { sqlite3_finalize(insert) }
        try bind(fingerprint, at: 1, to: insert); sqlite3_bind_int64(insert, 2, Int64(pageCount)); try run(insert)
        return try ocrGeneration(fingerprint: fingerprint, pageCount: pageCount)
    }
    func ocrPage(generation: Int64, pageIndex: Int) throws -> OCRPageText? {
        let query = try statement("SELECT payload FROM ocr_pages WHERE version_id=? AND page_index=?")
        defer { sqlite3_finalize(query) }
        sqlite3_bind_int64(query, 1, generation); sqlite3_bind_int64(query, 2, Int64(pageIndex))
        switch sqlite3_step(query) {
        case SQLITE_ROW:
            guard let payload = data(query, 0) else { throw failure() }
            return try JSONDecoder().decode(OCRPageText.self, from: payload)
        case SQLITE_DONE: return nil
        default: throw failure()
        }
    }
    func hasOCRPage(generation: Int64, pageIndex: Int) throws -> Bool {
        let query = try statement("SELECT 1 FROM ocr_pages WHERE version_id=? AND page_index=?")
        defer { sqlite3_finalize(query) }
        sqlite3_bind_int64(query, 1, generation); sqlite3_bind_int64(query, 2, Int64(pageIndex))
        switch sqlite3_step(query) {
        case SQLITE_ROW: return true
        case SQLITE_DONE: return false
        default: throw failure()
        }
    }
    func ocrCount(generation: Int64) throws -> Int {
        let query = try statement("SELECT COUNT(*) FROM ocr_pages WHERE version_id=?")
        defer { sqlite3_finalize(query) }
        sqlite3_bind_int64(query, 1, generation)
        guard sqlite3_step(query) == SQLITE_ROW else { throw failure() }
        return Int(sqlite3_column_int64(query, 0))
    }
    func ocrPreview(generation: Int64, limit: Int = 250) throws -> [OCRPageText] {
        let query = try statement("SELECT payload FROM ocr_pages WHERE version_id=? ORDER BY page_index LIMIT ?")
        defer { sqlite3_finalize(query) }
        sqlite3_bind_int64(query, 1, generation); sqlite3_bind_int64(query, 2, Int64(max(0, min(limit, 250))))
        var pages: [OCRPageText] = []
        while true {
            switch sqlite3_step(query) {
            case SQLITE_ROW:
                guard let payload = data(query, 0) else { throw failure() }
                pages.append(try JSONDecoder().decode(OCRPageText.self, from: payload))
            case SQLITE_DONE: return pages
            default: throw failure()
            }
        }
    }
    func storeOCRPages(_ pages: [OCRPageText], generation: Int64, replace: Bool = true) throws {
        guard !pages.isEmpty else { return }
        try transaction {
            let sql = replace
                ? "INSERT INTO ocr_pages(version_id,page_index,payload,coverage) VALUES (?,?,?,NULL) ON CONFLICT(version_id,page_index) DO UPDATE SET payload=excluded.payload,coverage=NULL"
                : "INSERT OR IGNORE INTO ocr_pages(version_id,page_index,payload,coverage) VALUES (?,?,?,NULL)"
            let query = try statement(sql)
            defer { sqlite3_finalize(query) }
            for page in pages {
                sqlite3_reset(query); sqlite3_clear_bindings(query)
                sqlite3_bind_int64(query, 1, generation); sqlite3_bind_int64(query, 2, Int64(page.pageIndex))
                try bind(JSONEncoder().encode(page), at: 3, to: query); try run(query)
            }
        }
    }
    func ocrCoverage(generation: Int64, pageIndex: Int) throws -> [Bool]? {
        let query = try statement("SELECT coverage FROM ocr_pages WHERE version_id=? AND page_index=?")
        defer { sqlite3_finalize(query) }
        sqlite3_bind_int64(query, 1, generation); sqlite3_bind_int64(query, 2, Int64(pageIndex))
        switch sqlite3_step(query) {
        case SQLITE_ROW: return try data(query, 0).map { try JSONDecoder().decode([Bool].self, from: $0) }
        case SQLITE_DONE: return nil
        default: throw failure()
        }
    }
    func storeOCRCoverage(_ coverage: [Bool], generation: Int64, pageIndex: Int) throws {
        let query = try statement("UPDATE ocr_pages SET coverage=? WHERE version_id=? AND page_index=?")
        defer { sqlite3_finalize(query) }
        try bind(JSONEncoder().encode(coverage), at: 1, to: query)
        sqlite3_bind_int64(query, 2, generation); sqlite3_bind_int64(query, 3, Int64(pageIndex)); try run(query)
    }

    func legacyMigrationComplete(fingerprint: String) throws -> Bool {
        try metadata("legacy_migration") == fingerprint
    }
    func markLegacyMigrationComplete(fingerprint: String) throws {
        try setMetadata("legacy_migration", value: fingerprint)
    }

    /// Known annotation-only saves and byte-identical backup restores may rebase a cache.
    /// Archived OCR for unrelated content versions is deliberately left untouched.
    func rebase(from previousFingerprint: String, to newFingerprint: String, pageCount: Int) throws {
        try transaction {
            if try metadata("native_fingerprint") == previousFingerprint, try metadata("native_page_count") == String(pageCount) {
                try setMetadata("native_fingerprint", value: newFingerprint)
            }
            if try metadata("legacy_migration") == previousFingerprint { try setMetadata("legacy_migration", value: newFingerprint) }
            let query = try statement("UPDATE OR IGNORE ocr_versions SET fingerprint=? WHERE fingerprint=? AND page_count=?")
            defer { sqlite3_finalize(query) }
            try bind(newFingerprint, at: 1, to: query); try bind(previousFingerprint, at: 2, to: query)
            sqlite3_bind_int64(query, 3, Int64(pageCount)); try run(query)
        }
    }
    func mostRecentFingerprint(pageCount: Int) throws -> String? {
        if try metadata("native_page_count") == String(pageCount), let fingerprint = try metadata("native_fingerprint") { return fingerprint }
        let query = try statement("SELECT fingerprint FROM ocr_versions WHERE page_count=? ORDER BY id DESC LIMIT 1")
        defer { sqlite3_finalize(query) }
        sqlite3_bind_int64(query, 1, Int64(pageCount))
        switch sqlite3_step(query) {
        case SQLITE_ROW: return text(query, 0)
        case SQLITE_DONE: return nil
        default: throw failure()
        }
    }

    /// A consistent, portable snapshot even if another connection is finishing an OCR page.
    /// The caller must also verify the associated PDF did not change during its backup.
    static func snapshot(from source: URL, to destination: URL) throws {
        guard !FileManager.default.fileExists(atPath: destination.path) else { throw CocoaError(.fileWriteFileExists) }
        var reader: OpaquePointer?, writer: OpaquePointer?
        var completed = false
        defer {
            sqlite3_close(reader); sqlite3_close(writer)
            if !completed { try? FileManager.default.removeItem(at: destination) }
        }
        guard sqlite3_open_v2(source.path, &reader, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
            sqlite3_open_v2(destination.path, &writer, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK
        else { throw PageTextDatabaseError(message: "cannot open backup database") }
        sqlite3_busy_timeout(reader, 5_000); sqlite3_busy_timeout(writer, 5_000)
        guard let backup = sqlite3_backup_init(writer, "main", reader, "main") else { throw PageTextDatabaseError(message: "cannot create a database backup") }
        var finished = false
        defer { if !finished { sqlite3_backup_finish(backup) } }
        var retries = 0
        while true {
            try Task.checkCancellation()
            switch sqlite3_backup_step(backup, 128) {
            case SQLITE_DONE:
                guard sqlite3_backup_finish(backup) == SQLITE_OK else { finished = true; throw PageTextDatabaseError(message: "cannot finish a database backup") }
                finished = true; completed = true; return
            case SQLITE_OK: retries = 0
            case SQLITE_BUSY, SQLITE_LOCKED:
                guard retries < 100 else { throw PageTextDatabaseError(message: "database is busy; try backup again") }
                retries += 1; Thread.sleep(forTimeInterval: 0.01)
            default: throw PageTextDatabaseError(message: "cannot copy the database")
            }
        }
    }
}
