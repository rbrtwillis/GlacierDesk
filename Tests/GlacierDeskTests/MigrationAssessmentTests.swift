import Foundation
import XCTest
@testable import GlacierDesk

final class MigrationAssessmentTests: XCTestCase {
    func testDuplicateArchiveDescriptionsAreAmbiguous() throws {
        let object = try JSONDecoder().decode(AWSObject.self, from: Data(#"{"Key":"prefix/image.jpg","Size":5}"#.utf8))
        let archives = [MigrationArchive(archiveID: "a", description: "image.jpg", size: 5, creationDate: nil),
                        MigrationArchive(archiveID: "b", description: "image.jpg", size: 5, creationDate: nil)]
        let result = MigrationAssessmentBuilder.build(archives: archives, inventoryDate: nil, vaultName: "vault", bucketName: "bucket", prefix: "prefix/", objects: [object])
        XCTAssertEqual(result.ambiguousCount, 2)
        XCTAssertEqual(result.candidateCount, 0)
    }

    func testExactKeyAndSizeAreOnlyCandidateEvidence() throws {
        let object = try JSONDecoder().decode(AWSObject.self, from: Data(#"{"Key":"prefix/file","Size":8}"#.utf8))
        let archives = [MigrationArchive(archiveID: "a", description: "file", size: 8, creationDate: nil),
                        MigrationArchive(archiveID: "b", description: " file", size: 8, creationDate: nil)]
        let result = MigrationAssessmentBuilder.build(archives: archives, inventoryDate: nil, vaultName: "vault", bucketName: "bucket", prefix: "prefix/", objects: [object])
        XCTAssertEqual(result.candidateCount, 1)
        XCTAssertEqual(result.missingCount, 1)
    }
}
