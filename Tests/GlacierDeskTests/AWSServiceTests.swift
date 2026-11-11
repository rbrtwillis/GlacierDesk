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
    func testLegacyMultipartPreservesSpecialCharactersInUploadIDForPartsCompletionAndAbort() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("fake-aws")
        let script = #"""
        #!/bin/sh
        operation=""
        found=0
        for arg in "$@"; do
          case "$arg" in
            initiate-multipart-upload|upload-multipart-part|complete-multipart-upload|abort-multipart-upload) operation="$arg" ;;
            --upload-id=-abc_DEF+xyz=) found=1 ;;
          esac
        done
        case "$operation" in
          initiate-multipart-upload) printf '{"uploadId":"-abc_DEF+xyz="}' ;;
          upload-multipart-part) [ "$found" = 1 ] || exit 40; [ ! -f "$(dirname "$0")/fail" ] || exit 41; printf '{}' ;;
          complete-multipart-upload) [ "$found" = 1 ] || exit 42; printf '{"archiveId":"ok"}' ;;
          abort-multipart-upload) [ "$found" = 1 ] || exit 43; printf '{}' ;;
          *) exit 44 ;;
        esac
        """#
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let file = root.appendingPathComponent("file")
        try Data(repeating: 42, count: 1_048_576).write(to: file)
        var settings = UploadSettings(); settings.thresholdMiB = 1; settings.partSizeMiB = 5; settings.connections = 1
        let service = AWSService(profile: "test", executableURL: executable)
        let id = try await service.uploadLegacyArchive(vault: "v", region: "us-west-2", file: file, description: "file", settings: settings)
        XCTAssertEqual(id, "ok")
        try Data().write(to: root.appendingPathComponent("fail"))
        do {
            _ = try await service.uploadLegacyArchive(vault: "v", region: "us-west-2", file: file, description: "file", settings: settings)
            XCTFail("Expected the part upload to fail")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("AWS confirmed the incomplete upload was aborted"), error.localizedDescription)
        }
    }
}
