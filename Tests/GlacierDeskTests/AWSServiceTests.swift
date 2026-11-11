import Foundation
import XCTest
@testable import GlacierDesk

final class AWSServiceTests: XCTestCase {
    func testLegacyDownloadVerifiesChecksumBeforeReplacingFile() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("fake-aws")
        try Data("#!/bin/sh\nfor last do :; done\nprintf abc > \"$last\"\nprintf '{}'\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let service = AWSService(profile: "test", executableURL: executable)
        let target = root.appendingPathComponent("download")
        try Data("original".utf8).write(to: target)
        let bad = try JSONDecoder().decode(LegacyJob.self, from: Data(#"{"JobId":"j","Action":"ArchiveRetrieval","ArchiveSizeInBytes":3,"ArchiveSHA256TreeHash":"wrong"}"#.utf8))
        do { try await service.legacyJobOutput(vault: "v", region: "us-west-2", job: bad, destination: target); XCTFail("A bad checksum was accepted") } catch {}
        XCTAssertEqual(try Data(contentsOf: target), Data("original".utf8))
        let good = try JSONDecoder().decode(LegacyJob.self, from: Data(#"{"JobId":"j","Action":"ArchiveRetrieval","ArchiveSizeInBytes":3,"ArchiveSHA256TreeHash":"ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"}"#.utf8))
        try await service.legacyJobOutput(vault: "v", region: "us-west-2", job: good, destination: target)
        XCTAssertEqual(try Data(contentsOf: target), Data("abc".utf8))
    }
}
