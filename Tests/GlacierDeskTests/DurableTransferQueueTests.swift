import XCTest
@testable import GlacierDesk

final class DurableTransferQueueTests: XCTestCase {
    private func temporaryQueueURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("transfer-queue.sqlite")
    }

    func testRestartMarksInFlightAsInterruptedAndKeepsCompletedOutOfRetry() async throws {
        let url = try temporaryQueueURL()
        let completed = DurableTransferItem(sourcePath: "/private/a", sourceBookmark: Data([1]), target: "bucket/a", state: .completed)
        let running = DurableTransferItem(sourcePath: "/private/b", sourceBookmark: Data([2]), target: "bucket/b", state: .inProgress)
        let unknown = DurableTransferItem(sourcePath: "/private/c", sourceBookmark: Data([3]), target: "bucket/c", state: .outcomeUnknown)
        let session = DurableTransferSession(kind: .s3Upload, accountID: "123456789012", profile: "work", destination: "bucket/prefix",
            thresholdMiB: 64, partSizeMiB: 16, connections: 4, bucket: "bucket", prefix: "prefix",
            storageClass: "GLACIER", items: [completed, running, unknown])
        try await DurableTransferQueue(fileURL: url).add(session)

        let reopened = try DurableTransferQueue(fileURL: url)
        let savedSessions = try await reopened.allSessions()
        let loaded = try XCTUnwrap(savedSessions.first)
        XCTAssertEqual(loaded.items.map(\.state), [.completed, .interrupted, .outcomeUnknown])
        XCTAssertEqual(loaded.thresholdMiB, 64)
        XCTAssertEqual(loaded.partSizeMiB, 16)
        XCTAssertEqual(loaded.connections, 4)
        XCTAssertEqual(loaded.storageClass, "GLACIER")
        do {
            _ = try await reopened.retryableItems(sessionID: session.id, selectedProfile: "work", currentAccountID: "123456789012")
            XCTFail("Interrupted S3 upload requires explicit retry confirmation")
        } catch DurableTransferQueueError.noRetryableItems { }
        let retry = try await reopened.retryableItems(sessionID: session.id, selectedProfile: "work", currentAccountID: "123456789012", confirmInterruptedS3: true)
        XCTAssertEqual(retry.map(\.id), [running.id])
        XCTAssertTrue(loaded.items.first(where: { $0.id == running.id })?.detail?.contains("explicitly confirming a retry") == true)
    }

    func testRetryRequiresSameProfileAndAccount() async throws {
        let url = try temporaryQueueURL()
        let item = DurableTransferItem(sourcePath: "/folder/file", sourceBookmark: Data([9, 8]), target: "archive")
        let session = DurableTransferSession(kind: .legacyDownload, accountID: "111122223333", profile: "original", destination: "/restore", items: [item])
        let queue = try DurableTransferQueue(fileURL: url)
        try await queue.add(session)

        do {
            _ = try await queue.retryableItems(sessionID: session.id, selectedProfile: "original", currentAccountID: "999900001111")
            XCTFail("Different AWS accounts must not be authorized")
        } catch DurableTransferQueueError.accountMismatch { }
        do {
            _ = try await queue.retryableItems(sessionID: session.id, selectedProfile: "other", currentAccountID: "111122223333")
            XCTFail("Different profiles must not be authorized")
        } catch DurableTransferQueueError.profileMismatch { }

        let retry = try await queue.retryableItems(sessionID: session.id, selectedProfile: "original", currentAccountID: "111122223333")
        XCTAssertEqual(retry.map(\.id), [item.id])
    }

    func testDatabasePersistsBookmarksAndNoCredentialFieldsInSchema() async throws {
        let url = try temporaryQueueURL()
        let item = DurableTransferItem(sourcePath: "/source", sourceBookmark: Data([0, 1, 255]), sourceDevice: 2, sourceInode: 3,
            target: "bucket/key", rootPath: "/root", rootBookmark: Data([4, 5]), rootDevice: 6, rootInode: 7,
            relativeComponents: ["dir", "source"])
        let session = DurableTransferSession(kind: .s3Upload, accountID: "123456789012", profile: "profile", destination: "bucket/prefix",
            bucket: "bucket", prefix: "prefix", storageClass: "DEEP_ARCHIVE", items: [item])
        try await DurableTransferQueue(fileURL: url).add(session)
        let reopened = try DurableTransferQueue(fileURL: url)
        let stored = try await reopened.allSessions()
        let restored = try XCTUnwrap(stored.first)
        XCTAssertEqual(restored.id, session.id)
        XCTAssertEqual(restored.kind, session.kind)
        XCTAssertEqual(restored.accountID, session.accountID)
        XCTAssertEqual(restored.bucket, "bucket")
        XCTAssertEqual(restored.storageClass, "DEEP_ARCHIVE")
        XCTAssertEqual(restored.items.first?.sourceBookmark, Data([0, 1, 255]))
        XCTAssertEqual(restored.items.first?.rootBookmark, Data([4, 5]))
        XCTAssertEqual(restored.items.first?.rootDevice, 6)
        XCTAssertEqual(restored.items.first?.relativeComponents, ["dir", "source"])
        let databaseBytes = try Data(contentsOf: url)
        XCTAssertNil(databaseBytes.range(of: Data("secretAccessKey".utf8)))
        XCTAssertNil(databaseBytes.range(of: Data("sessionToken".utf8)))
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testInterruptedLegacyArchiveNeverBecomesRetryable() async throws {
        let url = try temporaryQueueURL()
        let item = DurableTransferItem(sourcePath: "/archive", sourceBookmark: Data([7]), target: "vault/archive", state: .inProgress)
        let session = DurableTransferSession(kind: .legacyArchiveUpload, accountID: "123", profile: "p", destination: "vault@region", vault: "vault", region: "region", items: [item])
        try await DurableTransferQueue(fileURL: url).add(session)
        let reopened = try DurableTransferQueue(fileURL: url)
        let stored = try await reopened.allSessions()
        let restored = try XCTUnwrap(stored.first)
        XCTAssertEqual(restored.items.first?.state, .outcomeUnknown)
        do {
            _ = try await reopened.retryableItems(sessionID: session.id, selectedProfile: "p", currentAccountID: "123")
            XCTFail("Unknown legacy upload outcome must not be retried")
        } catch DurableTransferQueueError.noRetryableItems { }
    }

    func testRecoveryClassifiesEachTransferKindAndPreservesSubsequentState() async throws {
        let url = try temporaryQueueURL()
        let s3 = DurableTransferItem(sourcePath: "/s3", sourceBookmark: Data([1]), target: "bucket/key", state: .inProgress)
        let archive = DurableTransferItem(sourcePath: "/archive", sourceBookmark: Data([2]), target: "vault/archive", state: .inProgress)
        let download = DurableTransferItem(sourcePath: "/download", sourceBookmark: Data([3]), target: "/restore", state: .inProgress)
        let sessions = [
            DurableTransferSession(kind: .s3Upload, accountID: "1", profile: "p", destination: "s3", items: [s3]),
            DurableTransferSession(kind: .legacyArchiveUpload, accountID: "1", profile: "p", destination: "glacier", items: [archive]),
            DurableTransferSession(kind: .legacyDownload, accountID: "1", profile: "p", destination: "local", items: [download])
        ]
        let initial = try DurableTransferQueue(fileURL: url)
        for session in sessions { try await initial.add(session) }

        let recovered = try DurableTransferQueue(fileURL: url)
        let values = try await recovered.allSessions()
        let recoveredByID = Dictionary(uniqueKeysWithValues: values.map { ($0.id, $0) })
        XCTAssertEqual(recoveredByID[sessions[0].id]?.items[0].state, .interrupted)
        XCTAssertEqual(recoveredByID[sessions[1].id]?.items[0].state, .outcomeUnknown)
        XCTAssertEqual(recoveredByID[sessions[2].id]?.items[0].state, .interrupted)
        XCTAssertTrue(recoveredByID[sessions[0].id]?.items[0].detail?.contains("explicitly confirming") == true)
        XCTAssertTrue(recoveredByID[sessions[1].id]?.items[0].detail?.contains("may have been created") == true)

        try await recovered.updateItem(sessionID: sessions[0].id, itemID: s3.id, state: .failed, detail: "safe to retry")
        let reopened = try DurableTransferQueue(fileURL: url)
        let again = try await reopened.allSessions()
        let againByID = Dictionary(uniqueKeysWithValues: again.map { ($0.id, $0) })
        XCTAssertEqual(againByID[sessions[0].id]?.items[0].state, .failed)
        XCTAssertEqual(againByID[sessions[0].id]?.items[0].detail, "safe to retry")
        XCTAssertEqual(againByID[sessions[1].id]?.items[0].state, .outcomeUnknown)
    }

    func testFolderReconstructionVerifiesBookmarksIdentityAndRejectsChangedFile() async throws {
        let url = try temporaryQueueURL()
        let root = url.deletingLastPathComponent().appendingPathComponent("source-folder", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("data.txt")
        try Data("source".utf8).write(to: file)
        var settings = UploadSettings()
        settings.thresholdMiB = 64; settings.partSizeMiB = 16; settings.connections = 2
        let plan = try FolderUploadPlan.build(roots: [root], bucket: "bucket", prefix: "prefix/", profile: "work",
            storageClass: "STANDARD", settings: settings)
        let session = try DurableTransferSession.s3Upload(from: plan, accountID: "123", storageClass: "STANDARD")
        let queue = try DurableTransferQueue(fileURL: url)
        try await queue.add(session)
        let stored = try await queue.allSessions()
        let records = try XCTUnwrap(stored.first?.items)
        let reconstructed = try await queue.reconstructFolderItems(records)
        XCTAssertEqual(reconstructed.first?.file.standardizedFileURL.path, file.standardizedFileURL.path)
        XCTAssertEqual(reconstructed.first?.components, ["data.txt"])

        let replacement = root.appendingPathComponent("replacement.txt")
        try Data("replacement".utf8).write(to: replacement)
        try FileManager.default.removeItem(at: file)
        try FileManager.default.moveItem(at: replacement, to: file)
        do {
            _ = try await queue.reconstructFolderItems(records)
            XCTFail("A replacement file with a different inode must be rejected")
        } catch {
            guard case DurableTransferQueueError.invalidSource = error else {
                return XCTFail("Expected identity mismatch, got \(error)")
            }
        }
    }

    func testLargeQueueUsesPerItemUpdatesWithoutWholeQueueRewrite() async throws {
        let url = try temporaryQueueURL()
        let queue = try DurableTransferQueue(fileURL: url)
        let count = 10_000
        let items = (0..<count).map { index in
            DurableTransferItem(sourcePath: "/source/\(index)", sourceBookmark: Data([UInt8(index & 255)]), target: "bucket/\(index)")
        }
        let session = DurableTransferSession(kind: .s3Upload, accountID: "123", profile: "p", destination: "bucket", bucket: "bucket", items: items)
        try await queue.add(session)
        for item in items { try await queue.updateItem(sessionID: session.id, itemID: item.id, state: .completed) }
        let reopened = try DurableTransferQueue(fileURL: url)
        let sessions = try await reopened.allSessions()
        XCTAssertEqual(sessions.first?.items.count, count)
        XCTAssertTrue(sessions.first?.items.allSatisfy { $0.state == .completed } == true)
        let dbBytes = ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?.intValue ?? Int.max
        XCTAssertLessThan(dbBytes, 20_000_000, "Per-item transitions should not repeatedly serialize the 10k-item session")
    }
}
