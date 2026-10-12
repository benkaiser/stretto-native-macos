import Foundation
import CSQLite

public struct LocalState: Codable, Equatable, Sendable {
    public var library: Library
    public var base: Library?
    public var pendingChanges: [String]
    public var dirty: Bool { !pendingChanges.isEmpty }
    public init(library: Library = Library(), base: Library? = nil, pendingChanges: [String] = []) {
        self.library = library; self.base = base; self.pendingChanges = pendingChanges
    }
}

public final class LibraryStore {
    private var database: OpaquePointer?
    public init(url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            let error = failure()
            if database != nil { sqlite3_close(database) }
            throw error
        }
        do {
            try execute("PRAGMA journal_mode=WAL")
            try execute("CREATE TABLE IF NOT EXISTS libraries (account TEXT PRIMARY KEY, snapshot BLOB NOT NULL)")
            try execute("CREATE TABLE IF NOT EXISTS backups (id INTEGER PRIMARY KEY, account TEXT NOT NULL, created_at REAL NOT NULL, snapshot BLOB NOT NULL)")
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch { sqlite3_close(database); database = nil; throw error }
    }
    deinit { if database != nil { sqlite3_close(database) } }
    private func failure() -> StrettoError {
        .message("Local library database: \(database.map { String(cString: sqlite3_errmsg($0)) } ?? "Could not open database")")
    }
    private func execute(_ sql: String) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else { throw failure() }
    }
    private func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw failure() }
        return statement
    }
    private func bind(_ string: String, to statement: OpaquePointer, index: Int32) throws {
        let result = string.withCString { sqlite3_bind_text(statement, index, $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
        guard result == SQLITE_OK else { throw failure() }
    }
    private func bind(_ data: Data, to statement: OpaquePointer, index: Int32) throws {
        let result = data.withUnsafeBytes { sqlite3_bind_blob(statement, index, $0.baseAddress, Int32(data.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
        guard result == SQLITE_OK else { throw failure() }
    }
    public func load(account: String) throws -> LocalState {
        let statement = try prepare("SELECT snapshot FROM libraries WHERE account = ?")
        defer { sqlite3_finalize(statement) }
        try bind(account, to: statement, index: 1)
        let result = sqlite3_step(statement)
        if result == SQLITE_DONE { return LocalState() }
        guard result == SQLITE_ROW, let bytes = sqlite3_column_blob(statement, 0) else { throw failure() }
        return try JSONDecoder().decode(LocalState.self, from: Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0))))
    }
    public func save(_ state: LocalState, account: String) throws {
        let statement = try prepare("INSERT INTO libraries(account, snapshot) VALUES(?,?) ON CONFLICT(account) DO UPDATE SET snapshot=excluded.snapshot")
        defer { sqlite3_finalize(statement) }
        try bind(account, to: statement, index: 1)
        try bind(JSONEncoder().encode(state), to: statement, index: 2)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw failure() }
    }
    public func backup(_ library: Library, account: String) throws {
        let statement = try prepare("INSERT INTO backups(account, created_at, snapshot) VALUES(?,?,?)")
        defer { sqlite3_finalize(statement) }
        try bind(account, to: statement, index: 1)
        guard sqlite3_bind_double(statement, 2, Date().timeIntervalSince1970) == SQLITE_OK else { throw failure() }
        try bind(JSONEncoder().encode(library), to: statement, index: 3)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw failure() }
    }
    public func backups(account: String) throws -> [Library] {
        let statement = try prepare("SELECT snapshot FROM backups WHERE account = ? ORDER BY id DESC")
        defer { sqlite3_finalize(statement) }
        try bind(account, to: statement, index: 1)
        var values: [Library] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { return values }
            guard result == SQLITE_ROW, let bytes = sqlite3_column_blob(statement, 0) else { throw failure() }
            values.append(try JSONDecoder().decode(Library.self, from: Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0)))))
        }
    }
}
