import Foundation
import XCTest
@testable import GlacierDesk

final class InventoryCaptureTests: XCTestCase {
    @MainActor func testOptInBackgroundCapturePersistsAndChecksAccount() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "GlacierDeskTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let executable = root.appendingPathComponent("fake-aws")
        let script = #"""
        #!/bin/sh
        case " $* " in
          *" get-caller-identity "*) printf '{"Account":"123","Arn":"arn:test","UserId":"user"}' ;;
          *" list-jobs "*) printf '{"JobList":[{"JobId":"job","Action":"InventoryRetrieval","StatusCode":"Succeeded","CreationDate":"2026-11-11T01:00:00Z"}]}' ;;
          *" get-job-output "*) for last do :; done; printf '{"InventoryDate":"2026-11-11T00:00:00Z","ArchiveList":[{"ArchiveId":"archive","ArchiveDescription":"folder/file"}]}' > "$last"; printf '{}' ;;
          *) exit 1 ;;
        esac
        """#
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let coordinator = InventoryCaptureCoordinator(defaults: defaults, applicationSupportRoot: root, serviceFactory: { AWSService(profile: $0, executableURL: executable) })
        let vault = MonitoredVault(profile: "p", account: "123", region: "us-west-2", vault: "v")
        coordinator.register(vault)
        await coordinator.poll(profile: "p", account: "123")
        let database = root.appendingPathComponent("GlacierDesk/legacy-inventory.sqlite")
        XCTAssertFalse(FileManager.default.fileExists(atPath: database.path))
        defaults.set(true, forKey: "legacyAutoCaptureInventory")
        let repointed = MonitoredVault(profile: "p", account: "wrong", region: "us-west-2", vault: "other")
        coordinator.register(repointed)
        await coordinator.poll(profile: "p", account: "wrong")
        XCTAssertFalse(FileManager.default.fileExists(atPath: database.path))
        XCTAssertTrue(coordinator.messages[repointed.key]?.contains("account changed") == true)
        await coordinator.poll(profile: "p", account: "123")
        let index = try GlacierInventoryIndex(databaseURL: database)
        let scope = GlacierInventoryScope(profile: "p", accountID: "123", region: "us-west-2", vault: "v")
        XCTAssertEqual(try index.search(scope: scope).archives.map(\.archiveID), ["archive"])
        XCTAssertEqual(coordinator.messages[vault.key], "Inventory cached locally.")
        await coordinator.poll(profile: "p", account: "123")
        XCTAssertEqual(try index.snapshot(scope: scope)?.archiveCount, 1)
    }
}
