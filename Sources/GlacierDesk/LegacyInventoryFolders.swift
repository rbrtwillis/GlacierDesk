import Foundation

/// Reconstructs a virtual hierarchy from archive descriptions; Glacier itself has no folders.
struct LegacyInventoryFolders: Sendable {
    private(set) var folders: [String: Set<String>] = [:]
    private(set) var files: [String: [IndexedGlacierArchive]] = [:]

    static func path(for description: String?) -> String? {
        guard let description, !description.isEmpty else { return nil }
        if description.hasPrefix("<m>") {
            guard description.contains("<v>4</v>"),
                  let start = description.range(of: "<p>"),
                  let end = description.range(of: "</p>", range: start.upperBound..<description.endIndex),
                  let data = Data(base64Encoded: String(description[start.upperBound..<end.lowerBound])),
                  let decoded = String(data: data, encoding: .utf8), !decoded.isEmpty else { return nil }
            return decoded
        }
        // Other structured metadata is not a filename.
        guard !description.hasPrefix("<") else { return nil }
        return description
    }

    mutating func add(_ archive: IndexedGlacierArchive) {
        guard let path = Self.path(for: archive.description) else {
            files["", default: []].append(archive); return
        }
        let components = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard !components.isEmpty, !components.contains("."), !components.contains("..") else {
            files["", default: []].append(archive); return
        }
        var parent = ""
        for component in components.dropLast() {
            folders[parent, default: []].insert(component)
            parent = parent.isEmpty ? component : parent + "/" + component
        }
        files[parent, default: []].append(archive)
    }

    static func filename(_ archive: IndexedGlacierArchive) -> String {
        guard let path = path(for: archive.description),
              let name = path.split(separator: "/").last, name != ".", name != ".." else { return "Unnamed archive" }
        return String(name)
    }

    func listing(folder: String, search: String, offset: Int, pageSize: Int, sort: GlacierArchiveSort, ascending: Bool) -> (folders: [String], page: GlacierArchivePage) {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let matchingFolders = (folders[folder] ?? []).filter { query.isEmpty || $0.localizedCaseInsensitiveContains(query) }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        var matchingFiles = (files[folder] ?? []).filter { query.isEmpty || Self.filename($0).localizedCaseInsensitiveContains(query) || $0.archiveID.localizedCaseInsensitiveContains(query) }
        matchingFiles.sort { a, b in
            let comparison: ComparisonResult
            switch sort {
            case .description: comparison = Self.filename(a).localizedStandardCompare(Self.filename(b))
            case .archiveID: comparison = a.archiveID.compare(b.archiveID)
            case .creationDate: comparison = (a.creationDate ?? "").compare(b.creationDate ?? "")
            case .size: comparison = (a.size ?? -1) == (b.size ?? -1) ? .orderedSame : ((a.size ?? -1) < (b.size ?? -1) ? .orderedAscending : .orderedDescending)
            }
            if comparison == .orderedSame { return a.archiveID < b.archiveID }
            return ascending ? comparison == .orderedAscending : comparison == .orderedDescending
        }
        let start = min(max(offset, 0), matchingFiles.count), end = min(start + pageSize, matchingFiles.count)
        return (matchingFolders, GlacierArchivePage(archives: Array(matchingFiles[start..<end]), totalCount: matchingFiles.count, offset: start, pageSize: pageSize))
    }
}

import SQLite3

struct DiskFolderListing: Sendable {
    let folders: [String]
    let folderCount: Int
    let page: GlacierArchivePage
    let localIDs: Set<String>
}

extension GlacierInventoryIndex {
    /// Streams the snapshot into a disk-backed temporary listing for one folder.
    /// Swift memory remains bounded by the requested pages and local upload records.
    func browseFolder(scope: GlacierInventoryScope, folder: String, search: String, offset: Int, folderOffset: Int,
                      pageSize: Int, sort: GlacierArchiveSort, ascending: Bool,
                      locallySaved: [IndexedGlacierArchive]) throws -> DiskFolderListing {
        var database: OpaquePointer?
        guard sqlite3_open("", &database) == SQLITE_OK, let db = database else { throw InventoryIndexError.sqlite("Could not open temporary browsing index") }
        defer { sqlite3_close(db) }
        func exec(_ sql: String) throws {
            guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw InventoryIndexError.sqlite(String(cString: sqlite3_errmsg(db))) }
        }
        func prepare(_ sql: String) throws -> OpaquePointer {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { throw InventoryIndexError.sqlite(String(cString: sqlite3_errmsg(db))) }
            return stmt
        }
        func text(_ stmt: OpaquePointer, _ column: Int32) -> String? {
            guard let value = sqlite3_column_text(stmt, column) else { return nil }; return String(cString: value)
        }
        func bind(_ value: String?, _ stmt: OpaquePointer, _ index: Int32) {
            if let value { sqlite3_bind_text(stmt, index, value, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) } else { sqlite3_bind_null(stmt, index) }
        }
        try exec("PRAGMA temp_store=FILE; PRAGMA journal_mode=OFF; CREATE TABLE folders(name TEXT PRIMARY KEY); CREATE TABLE files(id TEXT, description TEXT, size INTEGER, date TEXT, name TEXT);")
        let addFolder = try prepare("INSERT OR IGNORE INTO folders(name) VALUES(?)")
        let addFile = try prepare("INSERT INTO files(id,description,size,date,name) VALUES(?,?,?,?,?)")
        defer { sqlite3_finalize(addFolder); sqlite3_finalize(addFile) }
        let prefix = folder.isEmpty ? "" : folder + "/"
        let terms = search.trimmingCharacters(in: .whitespacesAndNewlines)
        func add(_ archive: IndexedGlacierArchive) throws {
            let raw = LegacyInventoryFolders.path(for: archive.description)
            let pieces = raw?.split(separator: "/", omittingEmptySubsequences: true).map(String.init) ?? []
            let valid = !pieces.isEmpty && !pieces.contains(".") && !pieces.contains("..")
            let path = valid ? pieces.joined(separator: "/") : ""
            let relative: String
            if folder.isEmpty { relative = path }
            else if path.hasPrefix(prefix) { relative = String(path.dropFirst(prefix.count)) }
            else { return }
            if let slash = relative.firstIndex(of: "/") {
                let name = String(relative[..<slash])
                guard terms.isEmpty || name.localizedCaseInsensitiveContains(terms) else { return }
                sqlite3_reset(addFolder); sqlite3_clear_bindings(addFolder); bind(name, addFolder, 1)
                guard sqlite3_step(addFolder) == SQLITE_DONE else { throw InventoryIndexError.sqlite(String(cString: sqlite3_errmsg(db))) }
            } else {
                let name = valid ? relative : "Unnamed archive"
                guard terms.isEmpty || name.localizedCaseInsensitiveContains(terms) || archive.archiveID.localizedCaseInsensitiveContains(terms) else { return }
                sqlite3_reset(addFile); sqlite3_clear_bindings(addFile)
                bind(archive.archiveID, addFile, 1); bind(archive.description, addFile, 2)
                if let size = archive.size { sqlite3_bind_int64(addFile, 3, size) } else { sqlite3_bind_null(addFile, 3) }
                bind(archive.creationDate, addFile, 4); bind(name, addFile, 5)
                guard sqlite3_step(addFile) == SQLITE_DONE else { throw InventoryIndexError.sqlite(String(cString: sqlite3_errmsg(db))) }
            }
        }
        var local = Dictionary(locallySaved.map { ($0.archiveID, $0) }, uniquingKeysWith: { first, _ in first })
        try exec("BEGIN")
        try forEachArchive(scope: scope) { archive in try Task.checkCancellation(); local.removeValue(forKey: archive.archiveID); try add(archive) }
        for archive in local.values { try add(archive) }
        try exec("COMMIT")
        func count(_ table: String) throws -> Int {
            let stmt = try prepare("SELECT COUNT(*) FROM \(table)"); defer { sqlite3_finalize(stmt) }
            guard sqlite3_step(stmt) == SQLITE_ROW else { throw InventoryIndexError.sqlite(String(cString: sqlite3_errmsg(db))) }
            return Int(sqlite3_column_int64(stmt, 0))
        }
        let folderCount = try count("folders"), fileCount = try count("files"), safeSize = max(1, min(pageSize, 500))
        let folderStmt = try prepare("SELECT name FROM folders ORDER BY name COLLATE NOCASE, name LIMIT ? OFFSET ?")
        defer { sqlite3_finalize(folderStmt) }
        sqlite3_bind_int(folderStmt, 1, Int32(safeSize)); sqlite3_bind_int64(folderStmt, 2, Int64(max(0, folderOffset)))
        var folders: [String] = []
        while true {
            let step = sqlite3_step(folderStmt)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else { throw InventoryIndexError.sqlite(String(cString: sqlite3_errmsg(db))) }
            if let value = text(folderStmt, 0) { folders.append(value) }
        }
        let column: String
        switch sort { case .description: column = "name COLLATE NOCASE"; case .size: column = "size"; case .creationDate: column = "date"; case .archiveID: column = "id" }
        let stmt = try prepare("SELECT id,description,size,date FROM files ORDER BY \(column) \(ascending ? "ASC" : "DESC") NULLS LAST, id ASC LIMIT ? OFFSET ?")
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int(stmt, 1, Int32(safeSize)); sqlite3_bind_int64(stmt, 2, Int64(max(0, offset)))
        var files: [IndexedGlacierArchive] = []
        while true {
            let step = sqlite3_step(stmt)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else { throw InventoryIndexError.sqlite(String(cString: sqlite3_errmsg(db))) }
            files.append(IndexedGlacierArchive(archiveID: text(stmt, 0) ?? "", description: text(stmt, 1), size: sqlite3_column_type(stmt, 2) == SQLITE_NULL ? nil : sqlite3_column_int64(stmt, 2), creationDate: text(stmt, 3)))
        }
        return DiskFolderListing(folders: folders, folderCount: folderCount, page: GlacierArchivePage(archives: files, totalCount: fileCount, offset: max(0, offset), pageSize: safeSize), localIDs: Set(local.keys))
    }
}
