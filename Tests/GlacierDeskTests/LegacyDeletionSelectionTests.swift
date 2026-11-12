import XCTest
@testable import GlacierDesk

final class LegacyDeletionSelectionTests: XCTestCase {
    func testFolderIncludesNestedArchivesButNotSimilarPrefixes() {
        let selection = LegacyDeletionSelection(archiveIDs: ["explicit"], folders: ["2026/05"])
        XCTAssertTrue(selection.includes(IndexedGlacierArchive(archiveID: "a", description: "2026/05/file.jpg")))
        XCTAssertTrue(selection.includes(IndexedGlacierArchive(archiveID: "b", description: "2026/05/nested/file.jpg")))
        XCTAssertFalse(selection.includes(IndexedGlacierArchive(archiveID: "c", description: "2026/050/file.jpg")))
        XCTAssertFalse(selection.includes(IndexedGlacierArchive(archiveID: "d", description: "2026/05/../other")))
        XCTAssertTrue(selection.includes(IndexedGlacierArchive(archiveID: "explicit")))
        let encoded = Data("2026/05/nested/raw.CR3".utf8).base64EncodedString()
        XCTAssertTrue(selection.includes(IndexedGlacierArchive(archiveID: "e", description: "<m><v>4</v><p>\(encoded)</p></m>")))
    }
}
