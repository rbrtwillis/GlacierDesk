import XCTest
@testable import GlacierDesk

final class LegacyInventoryFoldersTests: XCTestCase {
    func testEncodedPathsCreateFoldersAndKeepArchiveIDs() {
        let path = "2026/02/2026_02_15 02 Core Creek State Park/_81A9416.CR3"
        let encoded = Data(path.utf8).base64EncodedString()
        var tree = LegacyInventoryFolders()
        tree.add(IndexedGlacierArchive(archiveID: "encoded", description: "<m><v>4</v><p>\(encoded)</p><lm>20260222T184517Z</lm></m>"))
        tree.add(IndexedGlacierArchive(archiveID: "plain", description: "2026/02/readme.txt"))
        tree.add(IndexedGlacierArchive(archiveID: "unknown", description: "<m><p>invalid</p></m>"))
        let root = tree.listing(folder: "", search: "", offset: 0, pageSize: 100, sort: .description, ascending: true)
        XCTAssertEqual(root.folders, ["2026"])
        XCTAssertEqual(root.page.archives.map(\.archiveID), ["unknown"])
        let nested = tree.listing(folder: "2026/02", search: "", offset: 0, pageSize: 100, sort: .description, ascending: true)
        XCTAssertEqual(nested.folders, ["2026_02_15 02 Core Creek State Park"])
        XCTAssertEqual(nested.page.archives.map(\.archiveID), ["plain"])
        let leaf = tree.listing(folder: "2026/02/2026_02_15 02 Core Creek State Park", search: "9416", offset: 0, pageSize: 100, sort: .description, ascending: true)
        XCTAssertEqual(leaf.page.archives.map(\.archiveID), ["encoded"])
        XCTAssertEqual(LegacyInventoryFolders.filename(leaf.page.archives[0]), "_81A9416.CR3")
    }
}
