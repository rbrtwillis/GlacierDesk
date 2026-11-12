import Foundation
import SQLite3

/// A small, private-on-disk index for completed legacy Glacier inventories.
/// Callers should place the database in the app's Application Support directory.
public struct IndexedGlacierArchive: Sendable, Identifiable, Equatable {
    public let archiveID: String
    public let description: String?
    public let size: Int64?
    public let creationDate: String?
    public var id: String { archiveID }

    public init(archiveID: String, description: String? = nil, size: Int64? = nil, creationDate: String? = nil) {
        self.archiveID = archiveID
        self.description = description
        self.size = size
        self.creationDate = creationDate
    }
}

public struct GlacierInventoryScope: Sendable, Hashable {
    public let profile: String
    public let accountID: String
    public let region: String
    public let vault: String
    public init(profile: String, accountID: String, region: String, vault: String) {
        self.profile = profile; self.accountID = accountID; self.region = region; self.vault = vault
    }
}

public enum GlacierArchiveSort: Sendable {
    case description, size, creationDate, archiveID
}

public struct GlacierArchivePage: Sendable {
    public let archives: [IndexedGlacierArchive]
    public let totalCount: Int
    public let offset: Int
    public let pageSize: Int
}

public struct GlacierInventorySnapshot: Sendable, Equatable {
    public let inventoryDate: String?
    public let importedAt: Date
    public let archiveCount: Int
}

public enum InventoryIndexError: Error, LocalizedError {
    case sqlite(String)
    public var errorDescription: String? {
        switch self { case .sqlite(let message): return "Inventory index error: \(message)" }
    }
}

/// SQLite-backed index. It stores archive metadata only; it never stores archive bytes.
/// Each method opens its own connection, so an instance is safe to share across tasks.
public final class GlacierInventoryIndex: @unchecked Sendable {
    private let databaseURL: URL

    public init(databaseURL: URL) throws {
        self.databaseURL = databaseURL
        try FileManager.default.createDirectory(at: databaseURL.deletingLastPathComponent(), withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        try withDatabase { db in
            try Self.exec(db, "PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL; PRAGMA foreign_keys=ON;")
            // This is a rebuildable cache. Drop the earlier profile-only schema if present:
            // it cannot safely distinguish a profile that has since been repointed.
            let archiveColumns = try Self.columns(db, table: "archives")
            let snapshotColumns = try Self.columns(db, table: "inventory_snapshots")
            let archiveSchema: Set<String> = ["profile", "account_id", "region", "vault", "archive_id", "description", "size", "creation_date"]
            let snapshotSchema: Set<String> = ["profile", "account_id", "region", "vault", "inventory_date", "imported_at", "archive_count"]
            let incompatibleArchives = !archiveColumns.isEmpty && !archiveSchema.isSubset(of: archiveColumns)
            let incompatibleSnapshot = !snapshotColumns.isEmpty && !snapshotSchema.isSubset(of: snapshotColumns)
            if incompatibleArchives || incompatibleSnapshot {
                // These tables describe one cache snapshot; rebuilding only one
                // could leave a count/date that no longer matches its archive rows.
                if !archiveColumns.isEmpty { try Self.exec(db, "DROP TABLE archives") }
                if !snapshotColumns.isEmpty { try Self.exec(db, "DROP TABLE inventory_snapshots") }
            }
            try Self.exec(db, """
                CREATE TABLE IF NOT EXISTS archives (
                  profile TEXT NOT NULL, account_id TEXT NOT NULL, region TEXT NOT NULL, vault TEXT NOT NULL,
                  archive_id TEXT NOT NULL, description TEXT, size INTEGER, creation_date TEXT,
                  PRIMARY KEY(profile, account_id, region, vault, archive_id)
                );
                CREATE INDEX IF NOT EXISTS archives_scope_date ON archives(profile, account_id, region, vault, creation_date);
                CREATE INDEX IF NOT EXISTS archives_scope_size ON archives(profile, account_id, region, vault, size);
                CREATE INDEX IF NOT EXISTS archives_scope_id ON archives(profile, account_id, region, vault, archive_id);
                CREATE TABLE IF NOT EXISTS inventory_snapshots (
                  profile TEXT NOT NULL, account_id TEXT NOT NULL, region TEXT NOT NULL, vault TEXT NOT NULL,
                  inventory_date TEXT, imported_at TEXT NOT NULL, archive_count INTEGER NOT NULL,
                  PRIMARY KEY(profile, account_id, region, vault)
                );
                """)
        }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: databaseURL.path)
    }

    /// Atomically replaces one vault's snapshot. The sequence is consumed incrementally;
    /// callers can stream records without building another copy of the inventory.
    public func replaceInventory<S: Sequence>(scope: GlacierInventoryScope, archives: S) throws where S.Element == IndexedGlacierArchive {
        try replaceInventoryStreaming(scope: scope) { emit in
            for archive in archives { try emit(archive) }
            return nil
        }
    }

    /// Transactional streaming replacement. If the producer throws, the previous
    /// snapshot remains intact. The closure must emit each record as it is decoded.
    @discardableResult
    func replaceInventoryStreaming(scope: GlacierInventoryScope,
                                   produce: ((IndexedGlacierArchive) throws -> Void) throws -> String?) throws -> String? {
        try withDatabase { db in
            try Self.exec(db, "BEGIN IMMEDIATE")
            do {
                let delete = try Self.prepare(db, "DELETE FROM archives WHERE profile=? AND account_id=? AND region=? AND vault=?")
                defer { sqlite3_finalize(delete) }
                Self.bind(scope.profile, at: 1, to: delete); Self.bind(scope.accountID, at: 2, to: delete); Self.bind(scope.region, at: 3, to: delete); Self.bind(scope.vault, at: 4, to: delete)
                try Self.stepDone(db, delete)
                let insert = try Self.prepare(db, "INSERT INTO archives(profile,account_id,region,vault,archive_id,description,size,creation_date) VALUES(?,?,?,?,?,?,?,?)")
                defer { sqlite3_finalize(insert) }
                var archiveCount = 0
                func emit(_ archive: IndexedGlacierArchive) throws {
                    sqlite3_reset(insert); sqlite3_clear_bindings(insert)
                    Self.bind(scope.profile, at: 1, to: insert); Self.bind(scope.accountID, at: 2, to: insert); Self.bind(scope.region, at: 3, to: insert)
                    Self.bind(scope.vault, at: 4, to: insert); Self.bind(archive.archiveID, at: 5, to: insert)
                    Self.bind(archive.description, at: 6, to: insert)
                    if let size = archive.size { sqlite3_bind_int64(insert, 7, size) } else { sqlite3_bind_null(insert, 7) }
                    Self.bind(archive.creationDate, at: 8, to: insert)
                    try Self.stepDone(db, insert)
                    archiveCount += 1
                }
                let inventoryDate = try produce(emit)
                let previous = try Self.prepare(db, "SELECT inventory_date FROM inventory_snapshots WHERE profile=? AND account_id=? AND region=? AND vault=?")
                defer { sqlite3_finalize(previous) }
                Self.bind(scope.profile, at: 1, to: previous); Self.bind(scope.accountID, at: 2, to: previous); Self.bind(scope.region, at: 3, to: previous); Self.bind(scope.vault, at: 4, to: previous)
                func inventoryTimestamp(_ value: String) -> Date? {
                    let formatter = ISO8601DateFormatter()
                    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                    if let date = formatter.date(from: value) { return date }
                    formatter.formatOptions = [.withInternetDateTime]
                    return formatter.date(from: value)
                }
                if sqlite3_step(previous) == SQLITE_ROW, let old = Self.text(previous, 0), let incoming = inventoryDate,
                   let oldDate = inventoryTimestamp(old), let newDate = inventoryTimestamp(incoming), newDate < oldDate {
                    throw InventoryIndexError.sqlite("The downloaded inventory is older than the cached snapshot; the newer snapshot was retained.")
                }
                let metadata = try Self.prepare(db, "INSERT INTO inventory_snapshots(profile,account_id,region,vault,inventory_date,imported_at,archive_count) VALUES(?,?,?,?,?,?,?) ON CONFLICT(profile,account_id,region,vault) DO UPDATE SET inventory_date=excluded.inventory_date, imported_at=excluded.imported_at, archive_count=excluded.archive_count")
                defer { sqlite3_finalize(metadata) }
                Self.bind(scope.profile, at: 1, to: metadata); Self.bind(scope.accountID, at: 2, to: metadata)
                Self.bind(scope.region, at: 3, to: metadata); Self.bind(scope.vault, at: 4, to: metadata)
                Self.bind(inventoryDate, at: 5, to: metadata)
                Self.bind(ISO8601DateFormatter().string(from: Date()), at: 6, to: metadata)
                sqlite3_bind_int64(metadata, 7, Int64(archiveCount))
                try Self.stepDone(db, metadata)
                try Self.exec(db, "COMMIT")
                return inventoryDate
            } catch { try? Self.exec(db, "ROLLBACK"); throw error }
        }
    }

    /// Searches description and archive ID, returning only one bounded page.
    /// `search` is literal substring matching; SQL wildcard characters are escaped.
    public func search(scope: GlacierInventoryScope, search: String = "", offset: Int = 0,
                       pageSize: Int = 100, sort: GlacierArchiveSort = .creationDate,
                       ascending: Bool = false) throws -> GlacierArchivePage {
        let safeOffset = max(0, offset), safeLimit = min(500, max(1, pageSize))
        let orderColumn: String
        switch sort { case .description: orderColumn = "description"; case .size: orderColumn = "size"; case .creationDate: orderColumn = "creation_date"; case .archiveID: orderColumn = "archive_id" }
        let direction = ascending ? "ASC" : "DESC"
        let terms = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let whereSQL = "profile=? AND account_id=? AND region=? AND vault=?" + (terms.isEmpty ? "" : " AND (archive_id LIKE ? ESCAPE '\\' COLLATE NOCASE OR description LIKE ? ESCAPE '\\' COLLATE NOCASE)")
        let pattern = "%" + terms.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_") + "%"
        return try withDatabase { db in
            let countStmt = try Self.prepare(db, "SELECT COUNT(*) FROM archives WHERE \(whereSQL)")
            defer { sqlite3_finalize(countStmt) }
            try Self.bindSearch(scope, terms: terms, pattern: pattern, statement: countStmt)
            guard sqlite3_step(countStmt) == SQLITE_ROW else { throw Self.failure(db) }
            let count = Int(sqlite3_column_int64(countStmt, 0))
            let query = "SELECT archive_id,description,size,creation_date FROM archives WHERE \(whereSQL) ORDER BY \(orderColumn) \(direction) NULLS LAST, archive_id ASC LIMIT ? OFFSET ?"
            let stmt = try Self.prepare(db, query)
            defer { sqlite3_finalize(stmt) }
            try Self.bindSearch(scope, terms: terms, pattern: pattern, statement: stmt)
            let base = terms.isEmpty ? 5 : 7
            sqlite3_bind_int(stmt, Int32(base), Int32(safeLimit)); sqlite3_bind_int64(stmt, Int32(base + 1), Int64(safeOffset))
            var rows: [IndexedGlacierArchive] = []; rows.reserveCapacity(safeLimit)
            while true {
                let result = sqlite3_step(stmt)
                if result == SQLITE_DONE { break }; guard result == SQLITE_ROW else { throw Self.failure(db) }
                rows.append(IndexedGlacierArchive(archiveID: Self.text(stmt, 0) ?? "", description: Self.text(stmt, 1),
                    size: sqlite3_column_type(stmt, 2) == SQLITE_NULL ? nil : sqlite3_column_int64(stmt, 2), creationDate: Self.text(stmt, 3)))
            }
            return GlacierArchivePage(archives: rows, totalCount: count, offset: safeOffset, pageSize: safeLimit)
        }
    }

    /// Visits matching rows directly from a SQLite cursor. This is intended for
    /// comparisons/exports that need every row without materializing a large array
    /// or issuing increasingly expensive OFFSET queries.
    public func forEachArchive(scope: GlacierInventoryScope, search: String = "",
                               sort: GlacierArchiveSort = .creationDate, ascending: Bool = false,
                               visit: (IndexedGlacierArchive) throws -> Void) throws {
        let terms = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let orderColumn: String
        switch sort { case .description: orderColumn = "description"; case .size: orderColumn = "size"; case .creationDate: orderColumn = "creation_date"; case .archiveID: orderColumn = "archive_id" }
        let direction = ascending ? "ASC" : "DESC"
        let whereSQL = "profile=? AND account_id=? AND region=? AND vault=?" + (terms.isEmpty ? "" : " AND (archive_id LIKE ? ESCAPE '\\' COLLATE NOCASE OR description LIKE ? ESCAPE '\\' COLLATE NOCASE)")
        let pattern = "%" + terms.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_") + "%"
        try withDatabase { db in
            let stmt = try Self.prepare(db, "SELECT archive_id,description,size,creation_date FROM archives WHERE \(whereSQL) ORDER BY \(orderColumn) \(direction) NULLS LAST, archive_id ASC")
            defer { sqlite3_finalize(stmt) }
            Self.bindScopeAndSearch(scope, terms: terms, pattern: pattern, statement: stmt)
            while true {
                let result = sqlite3_step(stmt)
                if result == SQLITE_DONE { return }
                guard result == SQLITE_ROW else { throw Self.failure(db) }
                try visit(IndexedGlacierArchive(archiveID: Self.text(stmt, 0) ?? "", description: Self.text(stmt, 1),
                    size: sqlite3_column_type(stmt, 2) == SQLITE_NULL ? nil : sqlite3_column_int64(stmt, 2), creationDate: Self.text(stmt, 3)))
            }
        }
    }

    public func removeInventory(scope: GlacierInventoryScope) throws {
        try withDatabase { db in
            let metadata = try Self.prepare(db, "DELETE FROM inventory_snapshots WHERE profile=? AND account_id=? AND region=? AND vault=?")
            defer { sqlite3_finalize(metadata) }
            Self.bind(scope.profile, at: 1, to: metadata); Self.bind(scope.accountID, at: 2, to: metadata)
            Self.bind(scope.region, at: 3, to: metadata); Self.bind(scope.vault, at: 4, to: metadata)
            try Self.stepDone(db, metadata)
            let stmt = try Self.prepare(db, "DELETE FROM archives WHERE profile=? AND account_id=? AND region=? AND vault=?")
            defer { sqlite3_finalize(stmt) }
            Self.bind(scope.profile, at: 1, to: stmt); Self.bind(scope.accountID, at: 2, to: stmt); Self.bind(scope.region, at: 3, to: stmt); Self.bind(scope.vault, at: 4, to: stmt)
            try Self.stepDone(db, stmt)
        }
    }

    /// Nil means no complete inventory snapshot is cached for this exact AWS scope.
    public func snapshot(scope: GlacierInventoryScope) throws -> GlacierInventorySnapshot? {
        try withDatabase { db in
            let stmt = try Self.prepare(db, "SELECT inventory_date, imported_at, archive_count FROM inventory_snapshots WHERE profile=? AND account_id=? AND region=? AND vault=?")
            defer { sqlite3_finalize(stmt) }
            Self.bind(scope.profile, at: 1, to: stmt); Self.bind(scope.accountID, at: 2, to: stmt)
            Self.bind(scope.region, at: 3, to: stmt); Self.bind(scope.vault, at: 4, to: stmt)
            guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
            let date = Self.text(stmt, 1).flatMap(ISO8601DateFormatter().date(from:))
            guard let date else { throw InventoryIndexError.sqlite("Invalid cached inventory timestamp") }
            return GlacierInventorySnapshot(inventoryDate: Self.text(stmt, 0), importedAt: date, archiveCount: Int(sqlite3_column_int64(stmt, 2)))
        }
    }

    fileprivate func withDatabase<T>(_ body: (OpaquePointer) throws -> T) throws -> T {
        var db: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK, let db else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "Unable to open database"
            if let db { sqlite3_close(db) }; throw InventoryIndexError.sqlite(message)
        }
        defer { sqlite3_close(db) }
        return try body(db)
    }
    fileprivate static func prepare(_ db: OpaquePointer, _ sql: String) throws -> OpaquePointer {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { throw failure(db) }
        return stmt
    }
    private static func columns(_ db: OpaquePointer, table: String) throws -> Set<String> {
        let stmt = try prepare(db, "PRAGMA table_info(\(table))")
        defer { sqlite3_finalize(stmt) }
        var names = Set<String>()
        while true {
            let result = sqlite3_step(stmt)
            if result == SQLITE_DONE { return names }
            guard result == SQLITE_ROW else { throw failure(db) }
            if let name = text(stmt, 1) { names.insert(name) }
        }
    }
    fileprivate static func exec(_ db: OpaquePointer, _ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(db)); sqlite3_free(error)
            throw InventoryIndexError.sqlite(message)
        }
    }
    fileprivate static func stepDone(_ db: OpaquePointer, _ stmt: OpaquePointer) throws {
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw failure(db) }
    }
    fileprivate static func failure(_ db: OpaquePointer) -> InventoryIndexError { .sqlite(String(cString: sqlite3_errmsg(db))) }
    fileprivate static func bind(_ value: String, at index: Int32, to stmt: OpaquePointer) { sqlite3_bind_text(stmt, index, value, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
    fileprivate static func bind(_ value: String?, at index: Int32, to stmt: OpaquePointer) {
        if let value { bind(value, at: index, to: stmt) } else { sqlite3_bind_null(stmt, index) }
    }
    private static func text(_ stmt: OpaquePointer, _ index: Int32) -> String? {
        guard let value = sqlite3_column_text(stmt, index) else { return nil }; return String(cString: value)
    }
    private static func bindSearch(_ scope: GlacierInventoryScope, terms: String, pattern: String, statement: OpaquePointer) throws {
        bindScopeAndSearch(scope, terms: terms, pattern: pattern, statement: statement)
    }
    private static func bindScopeAndSearch(_ scope: GlacierInventoryScope, terms: String, pattern: String, statement: OpaquePointer) {
        bind(scope.profile, at: 1, to: statement); bind(scope.accountID, at: 2, to: statement)
        bind(scope.region, at: 3, to: statement); bind(scope.vault, at: 4, to: statement)
        if !terms.isEmpty { bind(pattern, at: 5, to: statement); bind(pattern, at: 6, to: statement) }
    }
}
