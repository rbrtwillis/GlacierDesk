import Foundation

/// A single archive entry copied from a completed Amazon Glacier inventory.
/// Keep the source inventory date and vault identity with the comparison so a
/// displayed result can be tied to the snapshot it came from.
struct MigrationArchive: Identifiable, Sendable {
    let archiveID: String
    let description: String?
    let size: Int64?
    let creationDate: String?
    var id: String { archiveID }
}

enum MigrationMatchState: Sendable {
    case candidate(AWSObject)
    case ambiguous([AWSObject])
    case missing
    case insufficientMetadata
}

struct MigrationArchiveAssessment: Identifiable, Sendable {
    let archive: MigrationArchive
    let state: MigrationMatchState
    var id: String { archive.archiveID }
}

struct MigrationAssessment: Sendable {
    let inventoryDate: String?
    let vaultName: String
    let bucketName: String
    let prefix: String
    let rows: [MigrationArchiveAssessment]
    let unmatchedObjects: [AWSObject]

    var candidateCount: Int { rows.filter { if case .candidate = $0.state { true } else { false } }.count }
    var ambiguousCount: Int { rows.filter { if case .ambiguous = $0.state { true } else { false } }.count }
    var missingCount: Int { rows.filter { if case .missing = $0.state { true } else { false } }.count }
}

/// Compares a saved Glacier inventory against an already-fetched S3 listing.
/// This does no AWS I/O and makes no claim about object contents. A candidate
/// means only that the S3 key equals the non-empty archive description and the
/// reported byte size is equal.
enum MigrationAssessmentBuilder {
    static func build(archives: [MigrationArchive], inventoryDate: String?, vaultName: String,
                      bucketName: String, prefix: String, objects: [AWSObject]) -> MigrationAssessment {
        var rows: [MigrationArchiveAssessment] = []
        var consumedKeys = Set<String>()
        let objectsByKey = Dictionary(grouping: objects, by: \.key)
        let archiveKeyCounts = Dictionary(grouping: archives.compactMap { archive -> String? in
            guard let value = archive.description, !value.isEmpty, archive.size != nil else { return nil }
            return prefix + value
        }, by: { $0 }).mapValues(\.count)

        for archive in archives {
            guard let description = archive.description,
                  !description.isEmpty, let size = archive.size else {
                rows.append(.init(archive: archive, state: .insufficientMetadata))
                continue
            }
            let expectedKey = prefix + description
            let matches = (objectsByKey[expectedKey] ?? []).filter { $0.size == size }
            switch matches.count {
            case 0: rows.append(.init(archive: archive, state: .missing))
            case 1 where archiveKeyCounts[expectedKey] == 1:
                rows.append(.init(archive: archive, state: .candidate(matches[0])))
                consumedKeys.insert(matches[0].key)
            default: rows.append(.init(archive: archive, state: .ambiguous(matches)))
            }
        }

        return MigrationAssessment(inventoryDate: inventoryDate, vaultName: vaultName,
                                   bucketName: bucketName, prefix: prefix, rows: rows,
                                   unmatchedObjects: objects.filter { !consumedKeys.contains($0.key) })
    }
}
