import Foundation
import XCTest
@testable import GlacierDesk

final class FolderUploadTests: XCTestCase {
    func testFolderPathsAndDuplicateDestinations() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("photos", isDirectory: true)
        let nested = folder.appendingPathComponent("2026", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data("image".utf8).write(to: nested.appendingPathComponent("image.jpg"))
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("link"), withDestinationURL: nested)
        let plan = try FolderUploadPlan.build(roots: [folder], bucket: "bucket", prefix: "backup/", profile: "test", storageClass: "STANDARD", settings: .init())
        XCTAssertEqual(plan.items.map(\.key), ["backup/photos/2026/image.jpg"])
        XCTAssertThrowsError(try FolderUploadPlan.build(roots: [folder, folder], bucket: "bucket", prefix: "", profile: "test", storageClass: "STANDARD", settings: .init()))
    }

    func testSnapshotRejectsFileAndDirectorySubstitution() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("selected", isDirectory: true)
        let nested = folder.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let file = nested.appendingPathComponent("file.txt"), secret = root.appendingPathComponent("other.txt")
        try Data("selected".utf8).write(to: file)
        try Data("other".utf8).write(to: secret)
        let plan = try FolderUploadPlan.build(roots: [folder], bucket: "bucket", prefix: "", profile: "test", storageClass: "STANDARD", settings: .init())
        let snapshot = try await plan.items[0].snapshot()
        XCTAssertEqual(try Data(contentsOf: snapshot), Data("selected".utf8))
        try? FileManager.default.removeItem(at: snapshot.deletingLastPathComponent())
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: secret)
        do { _ = try await plan.items[0].snapshot(); XCTFail("Substituted file accepted") } catch {}
        try FileManager.default.removeItem(at: file)
        try FileManager.default.removeItem(at: nested)
        try FileManager.default.createSymbolicLink(at: nested, withDestinationURL: root)
        do { _ = try await plan.items[0].snapshot(); XCTFail("Substituted directory accepted") } catch {}
    }
}
