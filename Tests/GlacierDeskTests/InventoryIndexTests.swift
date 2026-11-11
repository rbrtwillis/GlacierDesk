import Foundation
import XCTest
import SQLite3
@testable import GlacierDesk

final class InventoryIndexTests: XCTestCase {
    private func makeIndex() throws -> (GlacierInventoryIndex, URL, GlacierInventoryScope) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("GlacierDeskInventoryTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let database = directory.appendingPathComponent("inventory.sqlite")
        let scope = GlacierInventoryScope(profile: "synthetic", accountID: "123456789012", region: "us-east-1", vault: "test-vault")
        return (try GlacierInventoryIndex(databaseURL: database), directory, scope)
    }

    func testStreamingImportEscapingMetadataPaginationAndAccountScope() throws {
        let (index, directory, scope) = try makeIndex()
        defer { try? FileManager.default.removeItem(at: directory) }
        let records: [[String: Any]] = [
            ["ArchiveId": "a-1", "ArchiveDescription": "quote \"hello\" slash \\ snowman ☃", "Size": 12, "CreationDate": "2020-01-01"],
            ["ArchiveId": "a-2", "ArchiveDescription": "100% complete", "Size": 30],
            ["ArchiveId": "a-3", "ArchiveDescription": "another report", "Size": 20]
        ]
        let json: [String: Any] = ["InventoryDate": "2024-10-11T00:00:00Z", "ArchiveList": records]
        let file = directory.appendingPathComponent("inventory.json")
        var bytes = Data(" \n\t".utf8)
        bytes.append(try JSONSerialization.data(withJSONObject: json))
        try bytes.write(to: file)

        XCTAssertEqual(try index.importInventoryJSON(at: file, scope: scope), "2024-10-11T00:00:00Z")
        let metadata = try XCTUnwrap(index.snapshot(scope: scope))
        XCTAssertEqual(metadata.archiveCount, 3)
        XCTAssertEqual(metadata.inventoryDate, "2024-10-11T00:00:00Z")
        let escaped = try index.search(scope: scope, search: "snowman", pageSize: 1)
        XCTAssertEqual(escaped.totalCount, 1)
        XCTAssertEqual(escaped.archives.first?.archiveID, "a-1")
        let percent = try index.search(scope: scope, search: "%", pageSize: 1, sort: .size, ascending: false)
        XCTAssertEqual(percent.totalCount, 1)
        XCTAssertEqual(percent.archives.first?.archiveID, "a-2")
        let page = try index.search(scope: scope, pageSize: 2, sort: .size, ascending: false)
        XCTAssertEqual(page.archives.map(\.archiveID), ["a-2", "a-3"])
        var visited: [String] = []
        try index.forEachArchive(scope: scope, sort: .size, ascending: false) { visited.append($0.archiveID) }
        XCTAssertEqual(visited, ["a-2", "a-3", "a-1"])

        let differentAccount = GlacierInventoryScope(profile: scope.profile, accountID: "999999999999", region: scope.region, vault: scope.vault)
        XCTAssertNil(try index.snapshot(scope: differentAccount))
        XCTAssertEqual(try index.search(scope: differentAccount).totalCount, 0)
    }

    func testMalformedImportsRollbackPreviousSnapshot() throws {
        let (index, directory, scope) = try makeIndex()
        defer { try? FileManager.default.removeItem(at: directory) }
        let good = directory.appendingPathComponent("good.json")
        try JSONSerialization.data(withJSONObject: ["InventoryDate": "old-date", "ArchiveList": [["ArchiveId": "kept"]]]).write(to: good)
        _ = try index.importInventoryJSON(at: good, scope: scope)

        let malformedInputs = [
            #"{"InventoryDate":"new","ArchiveList":[{"ArchiveId":"partial"},"#,
            #"{"InventoryDate":"new","ArchiveList":[{"ArchiveId":"partial"}],}"#,
            #"{"InventoryDate":"new","Unknown":{"broken":tru},"ArchiveList":[{"ArchiveId":"partial"}]}"#,
            #"{"InventoryDate":"new","ArchiveList":[{"ArchiveId":"partial"},]}"#
        ]
        for (offset, source) in malformedInputs.enumerated() {
            let file = directory.appendingPathComponent("bad-\(offset).json")
            try Data(source.utf8).write(to: file)
            XCTAssertThrowsError(try index.importInventoryJSON(at: file, scope: scope))
            let rows = try index.search(scope: scope, pageSize: 10)
            XCTAssertEqual(rows.totalCount, 1)
            XCTAssertEqual(rows.archives.first?.archiveID, "kept")
            XCTAssertEqual(try index.snapshot(scope: scope)?.inventoryDate, "old-date")
        }
    }

    func testOversizedArchiveRecordIsRejectedWithoutReplacingSnapshot() throws {
        let (index, directory, scope) = try makeIndex()
        defer { try? FileManager.default.removeItem(at: directory) }
        try index.replaceInventory(scope: scope, archives: [IndexedGlacierArchive(archiveID: "kept")])
        let file = directory.appendingPathComponent("oversized.json")
        let prefix = Data(#"{"ArchiveList":[{"ArchiveId":"large","ArchiveDescription":""#.utf8)
        let suffix = Data(#""}]}"#.utf8)
        var stream = prefix
        stream.append(Data(repeating: 97, count: 16 * 1024 * 1024 + 1))
        stream.append(suffix)
        try stream.write(to: file)
        XCTAssertThrowsError(try index.importInventoryJSON(at: file, scope: scope))
        XCTAssertEqual(try index.search(scope: scope).archives.first?.archiveID, "kept")
    }

    func testLegacySchemaRebuildsBothArchiveAndSnapshotTables() throws {
        let (_, directory, scope) = try makeIndex()
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = directory.appendingPathComponent("legacy.sqlite")
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(database.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        let legacySQL = """
            CREATE TABLE archives(profile TEXT NOT NULL, vault TEXT NOT NULL, archive_id TEXT NOT NULL, description TEXT, size INTEGER, creation_date TEXT, PRIMARY KEY(profile, vault, archive_id));
            CREATE TABLE inventory_snapshots(profile TEXT NOT NULL, vault TEXT NOT NULL, inventory_date TEXT, imported_at TEXT NOT NULL, archive_count INTEGER NOT NULL, PRIMARY KEY(profile, vault));
            INSERT INTO archives VALUES('synthetic', 'test-vault', 'old', 'old', 1, '2020-01-01');
            INSERT INTO inventory_snapshots VALUES('synthetic', 'test-vault', 'old-date', '2020-01-01T00:00:00Z', 1);
            """
        XCTAssertEqual(sqlite3_exec(db, legacySQL, nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)
        db = nil

        let index = try GlacierInventoryIndex(databaseURL: database)
        XCTAssertNil(try index.snapshot(scope: scope))
        XCTAssertEqual(try index.search(scope: scope).totalCount, 0)
        try index.replaceInventory(scope: scope, archives: [IndexedGlacierArchive(archiveID: "new")])
        XCTAssertEqual(try index.snapshot(scope: scope)?.archiveCount, 1)
    }
}
