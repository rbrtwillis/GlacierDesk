import Foundation
import SQLite3

/// The durable, non-secret description of one transfer session. Never store credentials here.
struct DurableTransferSession: Codable, Equatable, Identifiable, Sendable {
    enum Kind: String, Codable, Sendable { case s3Upload, legacyArchiveUpload, legacyDownload }

    let id: UUID
    let kind: Kind
    let accountID: String
    let profile: String
    let destination: String
    let createdAt: Date
    let thresholdMiB: Int?
    let partSizeMiB: Int?
    let connections: Int?
    let bucket: String?
    let prefix: String?
    let storageClass: String?
    let vault: String?
    let region: String?
    var items: [DurableTransferItem]

    init(id: UUID = UUID(), kind: Kind, accountID: String, profile: String,
         destination: String, createdAt: Date = Date(), thresholdMiB: Int? = nil,
         partSizeMiB: Int? = nil, connections: Int? = nil, bucket: String? = nil,
         prefix: String? = nil, storageClass: String? = nil, vault: String? = nil,
         region: String? = nil, items: [DurableTransferItem]) {
        self.id = id; self.kind = kind; self.accountID = accountID; self.profile = profile
        self.destination = destination; self.createdAt = createdAt
        self.thresholdMiB = thresholdMiB; self.partSizeMiB = partSizeMiB; self.connections = connections
        self.bucket = bucket; self.prefix = prefix; self.storageClass = storageClass; self.vault = vault; self.region = region
        self.items = items
    }
}

/// Bookmark and file identity are retained for later reauthorization. `sourcePath` is
/// informational; callers must resolve the bookmark and verify identity before opening it.
struct DurableTransferItem: Codable, Equatable, Identifiable, Sendable {
    enum State: String, Codable, Sendable { case queued, inProgress, completed, failed, interrupted, outcomeUnknown, cancelled }

    let id: UUID
    let sourcePath: String
    let sourceBookmark: Data
    let sourceDevice: UInt64?
    let sourceInode: UInt64?
    let target: String
    let rootPath: String?
    let rootBookmark: Data?
    let rootDevice: UInt64?
    let rootInode: UInt64?
    let relativeComponents: [String]
    var state: State
    var detail: String?
    var updatedAt: Date

    init(id: UUID = UUID(), sourcePath: String, sourceBookmark: Data,
         sourceDevice: UInt64? = nil, sourceInode: UInt64? = nil,
         target: String, rootPath: String? = nil, rootBookmark: Data? = nil,
         rootDevice: UInt64? = nil, rootInode: UInt64? = nil, relativeComponents: [String] = [],
         state: State = .queued, detail: String? = nil, updatedAt: Date = Date()) {
        self.id = id; self.sourcePath = sourcePath; self.sourceBookmark = sourceBookmark
        self.sourceDevice = sourceDevice; self.sourceInode = sourceInode; self.target = target
        self.rootPath = rootPath; self.rootBookmark = rootBookmark; self.rootDevice = rootDevice
        self.rootInode = rootInode; self.relativeComponents = relativeComponents
        self.state = state; self.detail = detail; self.updatedAt = updatedAt
    }
}

enum DurableTransferQueueError: LocalizedError {
    case accountMismatch(expected: String, actual: String)
    case profileMismatch(expected: String, actual: String)
    case noRetryableItems
    case database(String)
    case invalidSource(String)

    var errorDescription: String? {
        switch self {
        case let .accountMismatch(expected, actual): return "This saved transfer belongs to AWS account \(expected), but the selected profile is account \(actual). Reauthorize with the original account."
        case let .profileMismatch(expected, actual): return "This saved transfer was prepared with profile \(expected), but profile \(actual) is selected. Select and reauthorize the original profile before resuming."
        case .noRetryableItems: return "There are no unfinished transfers that are safe to retry."
        case .database(let message): return "Could not update the durable transfer queue: \(message)"
        case .invalidSource(let message): return message
        }
    }
}

/// SQLite-backed persistent transfer metadata. Per-item state changes are single-row
/// transactions, so large queues do not rewrite all prior queue data on each transition.
/// The database contains no AWS credentials and is protected by a private parent directory.
actor DurableTransferQueue {
    private static let registry = DurableTransferQueueRegistry()
    private let fileURL: URL
    private var database: OpaquePointer?

    /// Returns one process-wide connection for a store path. Use this from UI flows so that
    /// opening another view never reclassifies an active transfer as interrupted.
    static func shared(fileURL: URL) throws -> DurableTransferQueue {
        try registry.queue(fileURL: fileURL)
    }

    init(fileURL: URL) throws {
        self.fileURL = fileURL
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        var handle: OpaquePointer?
        guard sqlite3_open_v2(fileURL.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "SQLite could not open the queue file."
            if let handle { sqlite3_close(handle) }
            throw DurableTransferQueueError.database(message)
        }
        database = handle
        do {
            try Self.execute(handle, "PRAGMA journal_mode=WAL;")
            try Self.execute(handle, "PRAGMA synchronous=FULL;")
            try Self.execute(handle, "PRAGMA foreign_keys=ON;")
            try Self.execute(handle, """
                CREATE TABLE IF NOT EXISTS sessions (
                    id TEXT PRIMARY KEY, kind TEXT NOT NULL, account_id TEXT NOT NULL,
                    profile TEXT NOT NULL, destination TEXT NOT NULL, created_at REAL NOT NULL,
                    threshold_mib INTEGER, part_size_mib INTEGER, connections INTEGER,
                    bucket TEXT, prefix TEXT, storage_class TEXT, vault TEXT, region TEXT
                );
                CREATE TABLE IF NOT EXISTS items (
                    id TEXT PRIMARY KEY, session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
                    source_path TEXT NOT NULL, source_bookmark BLOB NOT NULL,
                    source_device INTEGER, source_inode INTEGER, target TEXT NOT NULL,
                    root_path TEXT, root_bookmark BLOB, root_device INTEGER, root_inode INTEGER,
                    relative_components BLOB NOT NULL,
                    state TEXT NOT NULL, detail TEXT, updated_at REAL NOT NULL
                );
                CREATE INDEX IF NOT EXISTS items_session_idx ON items(session_id);
                """)
            // A legacy archive upload may have committed remotely before the process died.
            // It must never be automatically offered for retry. S3 retry requires a separate
            // explicit confirmation from the UI because a PUT can also have committed.
            // Classify any interrupted work as one atomic recovery step. SQLite otherwise
            // commits each statement separately, leaving a partially recovered queue if
            // the process exits between transfer kinds.
            try Self.execute(handle, "BEGIN IMMEDIATE;")
            do {
                try Self.execute(handle, """
                UPDATE items SET state='outcomeUnknown',
                    detail='The app stopped during a legacy archive upload. The archive may have been created; inspect Glacier before taking any further action. Multipart progress cannot be resumed.',
                    updated_at=\(Date().timeIntervalSince1970)
                WHERE state='inProgress' AND session_id IN (SELECT id FROM sessions WHERE kind='legacyArchiveUpload');
                UPDATE items SET state='interrupted',
                    detail='The app stopped during this transfer. Remote completion was not confirmed. Inspect the destination before explicitly confirming a retry; multipart progress cannot be resumed.',
                    updated_at=\(Date().timeIntervalSince1970)
                WHERE state='inProgress' AND session_id IN (SELECT id FROM sessions WHERE kind='s3Upload');
                UPDATE items SET state='interrupted',
                    detail='The app stopped during this transfer. Reauthorize the source and destination before retrying.',
                    updated_at=\(Date().timeIntervalSince1970)
                WHERE state='inProgress' AND session_id IN (SELECT id FROM sessions WHERE kind='legacyDownload');
                """)
                try Self.execute(handle, "COMMIT;")
            } catch {
                try? Self.execute(handle, "ROLLBACK;")
                throw error
            }
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        } catch {
            sqlite3_close(handle); database = nil
            throw error
        }
    }

    deinit { if let database { sqlite3_close(database) } }

    func allSessions() throws -> [DurableTransferSession] {
        let db = try requireDatabase()
        var statement: OpaquePointer?
        try prepare(db, "SELECT id, kind, account_id, profile, destination, created_at, threshold_mib, part_size_mib, connections, bucket, prefix, storage_class, vault, region FROM sessions ORDER BY created_at, id", into: &statement)
        defer { sqlite3_finalize(statement) }
        var sessions: [DurableTransferSession] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let id = UUID(uuidString: Self.text(statement, 0)),
                  let kind = DurableTransferSession.Kind(rawValue: Self.text(statement, 1)) else { continue }
            sessions.append(DurableTransferSession(id: id, kind: kind, accountID: Self.text(statement, 2),
                profile: Self.text(statement, 3), destination: Self.text(statement, 4),
                createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 5)),
                thresholdMiB: Self.optionalInt(statement, 6), partSizeMiB: Self.optionalInt(statement, 7),
                connections: Self.optionalInt(statement, 8), bucket: Self.optionalText(statement, 9),
                prefix: Self.optionalText(statement, 10), storageClass: Self.optionalText(statement, 11),
                vault: Self.optionalText(statement, 12), region: Self.optionalText(statement, 13), items: []))
        }
        var itemStatement: OpaquePointer?
        try prepare(db, "SELECT id, session_id, source_path, source_bookmark, source_device, source_inode, target, root_path, root_bookmark, root_device, root_inode, relative_components, state, detail, updated_at FROM items ORDER BY rowid", into: &itemStatement)
        defer { sqlite3_finalize(itemStatement) }
        let indices = Dictionary(uniqueKeysWithValues: sessions.enumerated().map { ($0.element.id, $0.offset) })
        while sqlite3_step(itemStatement) == SQLITE_ROW {
            guard let id = UUID(uuidString: Self.text(itemStatement, 0)),
                  let sessionID = UUID(uuidString: Self.text(itemStatement, 1)),
                  let sessionIndex = indices[sessionID],
                  let state = DurableTransferItem.State(rawValue: Self.text(itemStatement, 12)) else { continue }
            let bookmark = Self.blob(itemStatement, 3) ?? Data()
            let device = sqlite3_column_type(itemStatement, 4) == SQLITE_NULL ? nil : UInt64(bitPattern: sqlite3_column_int64(itemStatement, 4))
            let inode = sqlite3_column_type(itemStatement, 5) == SQLITE_NULL ? nil : UInt64(bitPattern: sqlite3_column_int64(itemStatement, 5))
            let componentsData = Self.blob(itemStatement, 11) ?? Data("[]".utf8)
            let components = (try? JSONDecoder().decode([String].self, from: componentsData)) ?? []
            sessions[sessionIndex].items.append(DurableTransferItem(id: id, sourcePath: Self.text(itemStatement, 2),
                sourceBookmark: bookmark, sourceDevice: device, sourceInode: inode, target: Self.text(itemStatement, 6),
                rootPath: Self.optionalText(itemStatement, 7), rootBookmark: Self.blob(itemStatement, 8),
                rootDevice: Self.optionalUInt64(itemStatement, 9), rootInode: Self.optionalUInt64(itemStatement, 10),
                relativeComponents: components, state: state, detail: Self.optionalText(itemStatement, 13),
                updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(itemStatement, 14))))
        }
        return sessions
    }

    func add(_ session: DurableTransferSession) throws {
        let db = try requireDatabase()
        try Self.execute(db, "BEGIN IMMEDIATE")
        do {
            try withStatement(db, "INSERT INTO sessions(id,kind,account_id,profile,destination,created_at,threshold_mib,part_size_mib,connections,bucket,prefix,storage_class,vault,region) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?)") { statement in
                Self.bind(session.id.uuidString, to: statement, at: 1); Self.bind(session.kind.rawValue, to: statement, at: 2)
                Self.bind(session.accountID, to: statement, at: 3); Self.bind(session.profile, to: statement, at: 4)
                Self.bind(session.destination, to: statement, at: 5); sqlite3_bind_double(statement, 6, session.createdAt.timeIntervalSince1970)
                Self.bindOptional(session.thresholdMiB, to: statement, at: 7); Self.bindOptional(session.partSizeMiB, to: statement, at: 8)
                Self.bindOptional(session.connections, to: statement, at: 9); Self.bindOptional(session.bucket, to: statement, at: 10)
                Self.bindOptional(session.prefix, to: statement, at: 11); Self.bindOptional(session.storageClass, to: statement, at: 12)
                Self.bindOptional(session.vault, to: statement, at: 13); Self.bindOptional(session.region, to: statement, at: 14)
                try Self.step(statement, db: db)
            }
            try withStatement(db, "INSERT INTO items(id,session_id,source_path,source_bookmark,source_device,source_inode,target,root_path,root_bookmark,root_device,root_inode,relative_components,state,detail,updated_at) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)") { statement in
                for item in session.items {
                    sqlite3_reset(statement); sqlite3_clear_bindings(statement)
                    Self.bind(item.id.uuidString, to: statement, at: 1); Self.bind(session.id.uuidString, to: statement, at: 2)
                    Self.bind(item.sourcePath, to: statement, at: 3); Self.bind(item.sourceBookmark, to: statement, at: 4)
                    Self.bindOptional(item.sourceDevice, to: statement, at: 5); Self.bindOptional(item.sourceInode, to: statement, at: 6)
                    Self.bind(item.target, to: statement, at: 7); Self.bindOptional(item.rootPath, to: statement, at: 8)
                    if let bookmark = item.rootBookmark { Self.bind(bookmark, to: statement, at: 9) } else { sqlite3_bind_null(statement, 9) }
                    Self.bindOptional(item.rootDevice, to: statement, at: 10); Self.bindOptional(item.rootInode, to: statement, at: 11)
                    Self.bind((try? JSONEncoder().encode(item.relativeComponents)) ?? Data("[]".utf8), to: statement, at: 12)
                    Self.bind(item.state.rawValue, to: statement, at: 13); Self.bindOptional(item.detail, to: statement, at: 14)
                    sqlite3_bind_double(statement, 15, item.updatedAt.timeIntervalSince1970)
                    try Self.step(statement, db: db)
                }
            }
            try Self.execute(db, "COMMIT")
        } catch { try? Self.execute(db, "ROLLBACK"); throw error }
    }

    func updateItem(sessionID: UUID, itemID: UUID, state: DurableTransferItem.State, detail: String? = nil) throws {
        let db = try requireDatabase()
        try withStatement(db, "UPDATE items SET state=?, detail=?, updated_at=? WHERE id=? AND session_id=?") { statement in
            Self.bind(state.rawValue, to: statement, at: 1); Self.bindOptional(detail, to: statement, at: 2)
            sqlite3_bind_double(statement, 3, Date().timeIntervalSince1970)
            Self.bind(itemID.uuidString, to: statement, at: 4); Self.bind(sessionID.uuidString, to: statement, at: 5)
            try Self.step(statement, db: db)
        }
    }

    /// Remove only never-started legacy items for this exact vault and account.
    /// Active and uncertain uploads must remain in history for reconciliation.
    func clearPendingLegacy(profile: String, accountID: String, region: String, vault: String) throws -> Int {
        let db = try requireDatabase()
        try withStatement(db, """
            DELETE FROM items WHERE state='queued' AND session_id IN (
                SELECT id FROM sessions WHERE kind='legacyArchiveUpload' AND profile=? AND account_id=? AND region=? AND vault=?
            )
            """) { statement in
            Self.bind(profile, to: statement, at: 1); Self.bind(accountID, to: statement, at: 2)
            Self.bind(region, to: statement, at: 3); Self.bind(vault, to: statement, at: 4)
            try Self.step(statement, db: db)
        }
        return Int(sqlite3_changes(db))
    }

    /// Cancel or clear only eligible rows in the displayed vault. Unknown outcomes are retained.
    func editLegacyQueue(profile: String, accountID: String, region: String, vault: String,
                         selected: Set<UUID>, clear: Bool) throws -> Int {
        let db = try requireDatabase()
        let action = clear ? "DELETE FROM items" : "UPDATE items SET state='cancelled', detail='Cancelled by operator', updated_at=\(Date().timeIntervalSince1970)"
        let states = clear ? "('cancelled','completed','failed')" : "('queued')"
        let filter = selected.isEmpty ? "" : " AND id IN (" + Array(repeating: "?", count: selected.count).joined(separator: ",") + ")"
        let sql = action + " WHERE state IN " + states + " AND session_id IN (SELECT id FROM sessions WHERE kind='legacyArchiveUpload' AND profile=? AND account_id=? AND region=? AND vault=?)" + filter
        try withStatement(db, sql) { statement in
            Self.bind(profile, to: statement, at: 1); Self.bind(accountID, to: statement, at: 2)
            Self.bind(region, to: statement, at: 3); Self.bind(vault, to: statement, at: 4)
            for (index, id) in selected.sorted(by: { $0.uuidString < $1.uuidString }).enumerated() { Self.bind(id.uuidString, to: statement, at: Int32(index + 5)) }
            try Self.step(statement, db: db)
        }
        return Int(sqlite3_changes(db))
    }

    /// Removes only explicitly selected uncertain records in the matching vault.
    func clearReviewedUnknown(profile: String, accountID: String, region: String, vault: String, selected: Set<UUID>) throws -> Int {
        guard !selected.isEmpty else { return 0 }
        let db = try requireDatabase()
        let placeholders = Array(repeating: "?", count: selected.count).joined(separator: ",")
        let sql = "DELETE FROM items WHERE state='outcomeUnknown' AND session_id IN (SELECT id FROM sessions WHERE kind='legacyArchiveUpload' AND profile=? AND account_id=? AND region=? AND vault=?) AND id IN (" + placeholders + ")"
        try withStatement(db, sql) { statement in
            Self.bind(profile, to: statement, at: 1); Self.bind(accountID, to: statement, at: 2)
            Self.bind(region, to: statement, at: 3); Self.bind(vault, to: statement, at: 4)
            for (index, id) in selected.sorted(by: { $0.uuidString < $1.uuidString }).enumerated() { Self.bind(id.uuidString, to: statement, at: Int32(index + 5)) }
            try Self.step(statement, db: db)
        }
        return Int(sqlite3_changes(db))
    }

    /// Atomically claim an eligible item so cancellation cannot be overwritten by the uploader.
    func claimLegacyItem(sessionID: UUID, itemID: UUID) throws -> Bool {
        let db = try requireDatabase()
        try withStatement(db, "UPDATE items SET state='inProgress', detail='Preparing upload', updated_at=? WHERE session_id=? AND id=? AND state IN ('queued','failed')") { statement in
            sqlite3_bind_double(statement, 1, Date().timeIntervalSince1970)
            Self.bind(sessionID.uuidString, to: statement, at: 2); Self.bind(itemID.uuidString, to: statement, at: 3)
            try Self.step(statement, db: db)
        }
        return sqlite3_changes(db) == 1
    }

    func authorize(sessionID: UUID, selectedProfile: String, currentAccountID: String) throws {
        guard let session = try allSessions().first(where: { $0.id == sessionID }) else { return }
        guard session.accountID == currentAccountID else { throw DurableTransferQueueError.accountMismatch(expected: session.accountID, actual: currentAccountID) }
        guard session.profile == selectedProfile else { throw DurableTransferQueueError.profileMismatch(expected: session.profile, actual: selectedProfile) }
    }

    /// Interrupted S3 PUTs are returned only after the caller presents explicit user confirmation.
    /// Legacy archive uploads with unknown completion are never eligible for retry.
    func retryableItems(sessionID: UUID, selectedProfile: String, currentAccountID: String,
                        confirmInterruptedS3: Bool = false) throws -> [DurableTransferItem] {
        try authorize(sessionID: sessionID, selectedProfile: selectedProfile, currentAccountID: currentAccountID)
        guard let session = try allSessions().first(where: { $0.id == sessionID }) else { throw DurableTransferQueueError.noRetryableItems }
        let eligible = session.items.filter { item in
            switch item.state {
            case .queued, .failed: return true
            case .interrupted:
                if session.kind == .s3Upload { return confirmInterruptedS3 }
                return session.kind == .legacyDownload
            case .inProgress, .completed, .outcomeUnknown, .cancelled: return false
            }
        }
        guard !eligible.isEmpty else { throw DurableTransferQueueError.noRetryableItems }
        return eligible
    }

    private func requireDatabase() throws -> OpaquePointer {
        guard let database else { throw DurableTransferQueueError.database("Database is closed.") }
        return database
    }

    private func prepare(_ db: OpaquePointer, _ sql: String, into statement: inout OpaquePointer?) throws {
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw Self.dbError(db) }
    }

    private func withStatement(_ db: OpaquePointer, _ sql: String, body: (OpaquePointer) throws -> Void) throws {
        var statement: OpaquePointer?
        try prepare(db, sql, into: &statement)
        defer { sqlite3_finalize(statement) }
        guard let statement else { throw Self.dbError(db) }
        try body(statement)
    }

    private static func execute(_ db: OpaquePointer, _ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(db))
            sqlite3_free(error)
            throw DurableTransferQueueError.database(message)
        }
    }

    private static func step(_ statement: OpaquePointer, db: OpaquePointer) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else { throw dbError(db) }
    }

    private static func dbError(_ db: OpaquePointer) -> DurableTransferQueueError { .database(String(cString: sqlite3_errmsg(db))) }
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    private static func bind(_ value: String, to statement: OpaquePointer, at index: Int32) {
        sqlite3_bind_text(statement, index, value, -1, transient)
    }
    private static func bind(_ value: Data, to statement: OpaquePointer, at index: Int32) {
        _ = value.withUnsafeBytes { bytes in sqlite3_bind_blob(statement, index, bytes.baseAddress, Int32(bytes.count), transient) }
    }
    private static func bindOptional(_ value: String?, to statement: OpaquePointer, at index: Int32) {
        if let value { bind(value, to: statement, at: index) } else { sqlite3_bind_null(statement, index) }
    }
    private static func bindOptional(_ value: Int?, to statement: OpaquePointer, at index: Int32) {
        if let value { sqlite3_bind_int64(statement, index, Int64(value)) } else { sqlite3_bind_null(statement, index) }
    }
    private static func bindOptional(_ value: UInt64?, to statement: OpaquePointer, at index: Int32) {
        if let value { sqlite3_bind_int64(statement, index, Int64(bitPattern: value)) } else { sqlite3_bind_null(statement, index) }
    }
    private static func text(_ statement: OpaquePointer?, _ column: Int32) -> String {
        guard let value = sqlite3_column_text(statement, column) else { return "" }
        return String(cString: value)
    }
    private static func optionalText(_ statement: OpaquePointer?, _ column: Int32) -> String? {
        sqlite3_column_type(statement, column) == SQLITE_NULL ? nil : text(statement, column)
    }
    private static func optionalInt(_ statement: OpaquePointer?, _ column: Int32) -> Int? {
        sqlite3_column_type(statement, column) == SQLITE_NULL ? nil : Int(sqlite3_column_int64(statement, column))
    }
    private static func optionalUInt64(_ statement: OpaquePointer?, _ column: Int32) -> UInt64? {
        sqlite3_column_type(statement, column) == SQLITE_NULL ? nil : UInt64(bitPattern: sqlite3_column_int64(statement, column))
    }
    private static func blob(_ statement: OpaquePointer?, _ column: Int32) -> Data? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL else { return nil }
        let count = Int(sqlite3_column_bytes(statement, column))
        guard count > 0, let pointer = sqlite3_column_blob(statement, column) else { return Data() }
        return Data(bytes: pointer, count: count)
    }
}

private final class DurableTransferQueueRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var queues: [String: DurableTransferQueue] = [:]

    func queue(fileURL: URL) throws -> DurableTransferQueue {
        lock.lock(); defer { lock.unlock() }
        let key = fileURL.standardizedFileURL.path
        if let queue = queues[key] { return queue }
        let queue = try DurableTransferQueue(fileURL: fileURL)
        queues[key] = queue
        return queue
    }
}
